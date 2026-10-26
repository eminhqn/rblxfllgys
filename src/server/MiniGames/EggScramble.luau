--!strict
-- EGG SCRAMBLE (Team)
-- A giant chicken in the middle of a round farmyard keeps laying eggs, which pop out and roll
-- about. GRAB an egg to pick it up and hold it over your head (you're a bit slower carrying one),
-- then run it back to your team's nest. Get knocked over or grabbed and you drop it; DIVE while
-- carrying to throw it (a throw that lands in your nest counts too). Every so often a GOLDEN egg is
-- laid, worth 3. Most eggs when time's up wins; a tie sends both teams through.
--
-- Eggs are server physics parts; a carried egg is welded above its carrier. Picking up goes
-- through the normal grab (ActionService.SetGrabHook), so the server decides who gets an egg.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage.Shared
local MathUtil = require(Shared.MathUtil)
local Signal = require(Shared.Signal)
local Teams = require(Shared.Teams)
local Theme = require(Shared.Theme)
local Ui = require(Shared.Ui)

local Geometry = require(script.Parent.Parent.Builders.Geometry)
local Hazards = require(script.Parent.Parent.Builders.Hazards)
local Types = require(script.Parent.Parent.Match.Types)
local ActionService = require(script.Parent.Parent.Services.ActionService)

local DURATION = 90
local YARD_RADIUS = 52
local NEST_DISTANCE = 38 -- nests on opposite sides of the yard
local NEST_RADIUS = 8
local CHICKEN_RADIUS = 7
local EGG_SIZE = Vector3.new(2.4, 3, 2.4)
local PICKUP_REACH = 6.5
local CARRY_HEIGHT = 3.7 -- above the carrier's middle
local MIN_EGGS, MAX_EGGS = 4, 9
local PLAYERS_PER_EGG = 3 -- one more egg about for every this many players
local LAY_INTERVAL = 2.2 -- seconds between eggs while there are fewer than wanted
local GOLDEN_EVERY = 25 -- seconds between golden eggs
local GOLDEN_VALUE = 3
local THROW_SPEED = 40
local THROW_LIFT = 26
local DROP_POP = 20
local REGRAB_DELAY = 0.8 -- seconds after dropping or throwing before you can pick one up again
local ROLL_DRAG = 1.2 -- per second: loose eggs roll to a stop
local KILL_DEPTH = 18
-- Light and a little bouncy: density, friction, elasticity and their weights.
local EGG_PHYSICS = PhysicalProperties.new(0.05, 0.8, 0.35, 1, 1)

local GRASS = Color3.fromRGB(150, 222, 110)
local FENCE = Color3.fromRGB(255, 244, 226)
local STRAW = Color3.fromRGB(240, 206, 110)
local EGG_WHITE = Color3.fromRGB(255, 250, 238)
local GOLD = Color3.fromRGB(255, 196, 40)
local DECOR: Geometry.PartOptions = { Name = "Decor", CanCollide = false, CastShadow = false }

type Nest = {
	Team: Teams.TeamDef,
	Center: Vector3, -- on the ground
	Pile: number,
}

type Egg = {
	Part: Part,
	Golden: boolean,
	Carrier: Player?,
	Weld: WeldConstraint?,
}

local EggScramble = {}

EggScramble.Info = {
	Id = "EggScramble",
	DisplayName = "Egg Scramble",
	Type = "Team",
	Rules = "GRAB eggs and carry them to your nest. DIVE to throw! Knock carriers over to make them drop.",
	Duration = DURATION,
	MinPlayers = 4,
	TeamCount = 2,
} :: Types.MiniGameInfo

function EggScramble.new(context: Types.RoundContext): Types.MiniGame
	local center = context.Origin.Position
	local random = context.Random
	local nests: { Nest } = {}
	local eggs: { Egg } = {}
	local counts: { [string]: number } = {}
	local teamOf: { [Player]: Nest } = {}
	local spawnOf: { [Player]: CFrame } = {}
	local regrabAt: { [Player]: number } = {}
	local actedConnection: Signal.Connection? = nil
	local heartbeat: RBXScriptConnection? = nil
	local lastLaid = 0
	local nextGolden = 0
	local scoresDirty = true
	local running = false

	local function point(x: number, y: number, z: number): Vector3
		return center + Vector3.new(x, y, z)
	end

	-- The two teams in this round (testing alone still gets two nests).
	local function pickTeams(): { Teams.TeamDef }
		local teams = context.Teams or {}
		local order: { Teams.TeamDef } = {}
		for _, def in Teams.List do
			if teams[def.Id] then
				table.insert(order, def)
			end
		end
		for _, def in Teams.List do
			if #order >= 2 then
				break
			end
			if not table.find(order, def) then
				table.insert(order, def)
			end
		end
		return order
	end

	local function buildYard(arena: Model)
		local yard = Geometry.model(arena, "Yard")
		Geometry.column(yard, 4, YARD_RADIUS * 2, point(0, -4, 0), GRASS, { Name = "Grass" })
		-- A low fence round the edge (you can still be knocked over it).
		local posts = 40
		for index = 1, posts do
			local angle = index / posts * math.pi * 2
			local spot = point(math.cos(angle) * (YARD_RADIUS - 1), 0, math.sin(angle) * (YARD_RADIUS - 1))
			Geometry.column(yard, 2.4, 0.8, spot, FENCE, { Name = "Post" })
			local nextAngle = (index + 1) / posts * math.pi * 2
			local nextSpot = point(math.cos(nextAngle) * (YARD_RADIUS - 1), 0, math.sin(nextAngle) * (YARD_RADIUS - 1))
			Geometry.block(
				yard,
				Vector3.new(0.4, 0.5, (nextSpot - spot).Magnitude),
				CFrame.lookAt((spot + nextSpot) / 2 + Vector3.new(0, 1.8, 0), nextSpot + Vector3.new(0, 1.8, 0)),
				FENCE,
				DECOR
			)
		end
		-- Hay bales to dodge round, and two trampolines.
		for index = 1, 6 do
			local angle = index / 6 * math.pi * 2 + math.pi / 6
			local spot = point(math.cos(angle) * 24, 0, math.sin(angle) * 24)
			Geometry.block(
				yard,
				Vector3.new(7, 4, 4.5),
				CFrame.new(spot + Vector3.new(0, 2, 0)) * CFrame.Angles(0, angle, 0),
				STRAW,
				{ Name = "HayBale", Material = Enum.Material.Fabric }
			)
		end
		for _, side in { -1, 1 } do
			Hazards.BouncePad(yard, point(side * 18, 0, side * 30), { Power = 80 })
		end
	end

	-- The giant chicken in the middle (solid: run round it).
	local function buildChicken(arena: Model)
		local chicken = Geometry.model(arena, "Chicken")
		local white = Color3.fromRGB(255, 255, 255)
		Geometry.column(chicken, 6, CHICKEN_RADIUS * 2, point(0, 0, 0), STRAW, { Name = "NestMound" })
		Geometry.ellipsoid(chicken, Vector3.new(13, 11, 15), CFrame.new(point(0, 11, 0)), white, { Name = "Body" })
		Geometry.ball(chicken, 7.5, point(0, 17.5, -5), white, { Name = "Head" })
		Geometry.ellipsoid(
			chicken,
			Vector3.new(1.4, 3, 3.4),
			CFrame.new(point(0, 21.6, -5)),
			Color3.fromRGB(230, 40, 60),
			DECOR
		)
		Geometry.ellipsoid(
			chicken,
			Vector3.new(1.8, 1.2, 2.6),
			CFrame.new(point(0, 17, -9.2)) * CFrame.Angles(0.3, 0, 0),
			Color3.fromRGB(255, 170, 40),
			DECOR
		)
		for _, side in { -1, 1 } do
			Geometry.ball(chicken, 1.4, point(side * 2.2, 18.4, -8.2), Theme.Colors.Ink, DECOR)
			Geometry.ellipsoid(
				chicken,
				Vector3.new(1.6, 6, 8),
				CFrame.new(point(side * 6.3, 11, 0.5)) * CFrame.Angles(0, 0, side * 0.2),
				Color3.fromRGB(245, 240, 232),
				DECOR
			)
		end
	end

	local function buildNest(arena: Model, team: Teams.TeamDef, side: number): Nest
		local nest = Geometry.model(arena, `{team.Id}Nest`)
		local spot = point(side * NEST_DISTANCE, 0, 0)
		Geometry.column(nest, 0.3, NEST_RADIUS * 2, spot, team.Color:Lerp(Color3.new(1, 1, 1), 0.4), DECOR)
		local pieces = 16
		for index = 1, pieces do
			local angle = index / pieces * math.pi * 2
			Geometry.ellipsoid(
				nest,
				Vector3.new(4.4, 1.6, 2.2),
				CFrame.new(spot + Vector3.new(math.cos(angle) * NEST_RADIUS, 0.6, math.sin(angle) * NEST_RADIUS))
					* CFrame.Angles(0, -angle, 0),
				STRAW,
				DECOR
			)
		end
		local anchor = Geometry.block(nest, Vector3.one * 0.4, CFrame.new(spot + Vector3.new(0, 10, 0)), team.Color, {
			Name = "LabelAnchor",
			Transparency = 1,
			CanCollide = false,
		})
		local gui: BillboardGui = Ui.new("BillboardGui", {
			Size = UDim2.fromOffset(320, 64),
			LightInfluence = 0,
			MaxDistance = 400,
			Parent = anchor,
		})
		local label = Ui.label(
			gui,
			`{string.upper(team.Id)} NEST`,
			Theme.Fonts.Display,
			team.Color,
			UDim2.fromScale(1, 1),
			UDim2.fromScale(0.5, 0.5),
			Vector2.new(0.5, 0.5)
		)
		Ui.stroke(label, Theme.Colors.Ink, 3)
		counts[team.Id] = 0
		return { Team = team, Center = spot, Pile = 0 }
	end

	-- Each team lines up in rows in front of its nest, facing the chicken.
	local function placeTeams(order: { Teams.TeamDef })
		local teams = context.Teams or {}
		for index, def in order do
			local nest = nests[index]
			local inward = MathUtil.flat(center - nest.Center).Unit
			local across = inward:Cross(Vector3.yAxis)
			local members = teams[def.Id] or {}
			for slot, player in members do
				teamOf[player] = nest
				local row = (slot - 1) // 6
				local inRow = math.min(6, #members - row * 6)
				local x = ((slot - 1) % 6 - (inRow - 1) / 2) * 4.5
				local position = nest.Center + inward * (NEST_RADIUS + 3 + row * 4.5) + across * x
				spawnOf[player] = CFrame.lookAt(position, Vector3.new(center.X, position.Y, center.Z))
			end
		end
	end

	local function makeEgg(position: Vector3, golden: boolean): Egg
		local part = Instance.new("Part")
		part.Name = if golden then "GoldenEgg" else "Egg"
		part.Shape = Enum.PartType.Ball
		part.Size = Vector3.one * EGG_SIZE.X
		part.Color = if golden then GOLD else EGG_WHITE
		part.Material = if golden then Enum.Material.Neon else Enum.Material.SmoothPlastic
		part.TopSurface = Enum.SurfaceType.Smooth
		part.BottomSurface = Enum.SurfaceType.Smooth
		part.CustomPhysicalProperties = EGG_PHYSICS
		part.CFrame = CFrame.new(position)
		local mesh = Instance.new("SpecialMesh")
		mesh.MeshType = Enum.MeshType.Sphere
		mesh.Scale = Vector3.new(1, EGG_SIZE.Y / EGG_SIZE.X, 1)
		mesh.Parent = part
		part.Parent = context.Arena
		pcall(function()
			part:SetNetworkOwner(nil)
		end)
		local egg: Egg = { Part = part, Golden = golden, Carrier = nil, Weld = nil }
		table.insert(eggs, egg)
		return egg
	end

	-- The chicken lays: an egg pops out of the top and lands somewhere in the yard.
	local function lay(golden: boolean)
		local egg = makeEgg(point(0, 18, 0), golden)
		local angle = random:NextNumber(0, math.pi * 2)
		local speed = random:NextNumber(14, 26)
		egg.Part.AssemblyLinearVelocity = Vector3.new(math.cos(angle) * speed, 30, math.sin(angle) * speed)
		if golden then
			context.Announce("A GOLDEN EGG! WORTH 3!")
		end
	end

	local function removeEgg(egg: Egg)
		local index = table.find(eggs, egg)
		if index then
			table.remove(eggs, index)
		end
		local carrier = egg.Carrier
		if carrier then
			local character = carrier.Character
			if character then
				character:SetAttribute("Carrying", nil)
			end
		end
		egg.Part:Destroy()
	end

	local function carriedBy(player: Player): Egg?
		for _, egg in eggs do
			if egg.Carrier == player then
				return egg
			end
		end
		return nil
	end

	local function pickUp(egg: Egg, player: Player, root: BasePart)
		local part = egg.Part
		part.CanCollide = false
		part.Massless = true
		part.AssemblyLinearVelocity = Vector3.zero
		part.CFrame = root.CFrame * CFrame.new(0, CARRY_HEIGHT, 0)
		local weld = Instance.new("WeldConstraint")
		weld.Part0 = root
		weld.Part1 = part
		weld.Parent = part
		egg.Weld = weld
		egg.Carrier = player
		local character = player.Character
		if character then
			character:SetAttribute("Carrying", true)
		end
	end

	-- Lets go of an egg, sending it off at `velocity`.
	local function drop(egg: Egg, velocity: Vector3)
		local carrier = egg.Carrier
		local weld = egg.Weld
		if weld then
			weld:Destroy()
			egg.Weld = nil
		end
		egg.Carrier = nil
		if carrier then
			regrabAt[carrier] = os.clock() + REGRAB_DELAY
			local character = carrier.Character
			if character then
				character:SetAttribute("Carrying", nil)
			end
		end
		local part = egg.Part
		if not part.Parent then
			return
		end
		part.Massless = false
		part.CanCollide = true
		part.AssemblyLinearVelocity = velocity
		pcall(function()
			part:SetNetworkOwner(nil)
		end)
	end

	-- GRAB near a loose egg picks it up (instead of grabbing a player).
	local function onGrab(player: Player, root: BasePart): boolean
		if not running or not teamOf[player] or carriedBy(player) then
			return false
		end
		if os.clock() < (regrabAt[player] or 0) then
			return false
		end
		local best: Egg? = nil
		local bestDistance = PICKUP_REACH
		for _, egg in eggs do
			if egg.Carrier then
				continue
			end
			local distance = (egg.Part.Position - root.Position).Magnitude
			if distance < bestDistance then
				best, bestDistance = egg, distance
			end
		end
		if not best then
			return false
		end
		pickUp(best, player, root)
		return true
	end

	-- DIVE while carrying throws the egg forward.
	local function onActed(player: Player, action: string)
		if action ~= "Dive" or not running then
			return
		end
		local egg = carriedBy(player)
		local root = context.GetRoot(player)
		if not egg or not root then
			return
		end
		local look = MathUtil.flat(root.CFrame.LookVector)
		look = if look.Magnitude > 1e-3 then look.Unit else Vector3.zAxis
		drop(egg, look * THROW_SPEED + Vector3.new(0, THROW_LIFT, 0))
	end

	local function score(egg: Egg, nest: Nest)
		local value = if egg.Golden then GOLDEN_VALUE else 1
		counts[nest.Team.Id] += value
		scoresDirty = true
		-- A little egg joins the pile in the nest.
		for _ = 1, value do
			nest.Pile += 1
			local angle = nest.Pile * 2.4
			local distance = math.min(1 + nest.Pile * 0.25, NEST_RADIUS - 2)
			Geometry.ellipsoid(
				context.Arena,
				Vector3.new(1.6, 2, 1.6),
				CFrame.new(nest.Center + Vector3.new(math.cos(angle) * distance, 1, math.sin(angle) * distance)),
				if egg.Golden then GOLD else EGG_WHITE,
				DECOR
			)
		end
		if egg.Golden then
			context.Announce(`{string.upper(nest.Team.Id)} GOT THE GOLDEN EGG!`, nest.Team.Id)
		end
		removeEgg(egg)
	end

	local function grabbed(character: Model): boolean
		local by = character:GetAttribute("GrabbedBy")
		return typeof(by) == "number" and by ~= 0
	end

	local function nestAt(position: Vector3): Nest?
		for _, nest in nests do
			if MathUtil.flat(position - nest.Center).Magnitude <= NEST_RADIUS and position.Y - nest.Center.Y < 6 then
				return nest
			end
		end
		return nil
	end

	-- Loose eggs slowly roll to a stop.
	local function stepEggs(dt: number)
		for _, egg in eggs do
			if egg.Carrier then
				continue
			end
			local velocity = egg.Part.AssemblyLinearVelocity
			local rolling = MathUtil.flat(velocity)
			if rolling.Magnitude > 0.2 then
				egg.Part.AssemblyLinearVelocity = velocity - rolling * (1 - math.exp(-ROLL_DRAG * dt))
			end
		end
	end

	local function wantedEggs(): number
		return math.clamp(MIN_EGGS + #context.Players // PLAYERS_PER_EGG, MIN_EGGS, MAX_EGGS)
	end

	local function update(_dt: number): boolean?
		for _, player in context.GetAlive() do
			local root = context.GetRoot(player)
			local home = spawnOf[player]
			if root and home and root.Position.Y < center.Y - KILL_DEPTH then
				local egg = carriedBy(player)
				if egg then
					removeEgg(egg)
				end
				context.SpawnAt(player, home)
			end
		end
		if not running then
			return nil
		end

		for _, egg in table.clone(eggs) do
			local carrier = egg.Carrier
			if carrier then
				local character = carrier.Character
				local root = context.GetRoot(carrier)
				local nest = teamOf[carrier]
				if carrier.Parent ~= Players or not context.IsAlive(carrier) or not character or not root then
					drop(egg, Vector3.new(0, DROP_POP, 0))
				elseif character:GetAttribute("Ragdolled") == true or grabbed(character) then
					-- Knocked over or grabbed: the egg pops out of your hands.
					local angle = random:NextNumber(0, math.pi * 2)
					drop(egg, Vector3.new(math.cos(angle) * 10, DROP_POP, math.sin(angle) * 10))
				elseif nest and nestAt(root.Position) == nest then
					score(egg, nest)
				end
			else
				local position = egg.Part.Position
				local nest = nestAt(position)
				if nest and egg.Part.AssemblyLinearVelocity.Magnitude < 8 then
					score(egg, nest) -- thrown (or rolled) into a nest
				elseif position.Y < center.Y - KILL_DEPTH then
					removeEgg(egg)
				end
			end
		end

		local now = context.GetServerTime()
		if now >= nextGolden then
			nextGolden = now + GOLDEN_EVERY
			lay(true)
			lastLaid = now
		elseif #eggs < wantedEggs() and now - lastLaid >= LAY_INTERVAL then
			lay(false)
			lastLaid = now
		end
		if scoresDirty then
			scoresDirty = false
			context.SetTeamScores(counts)
		end
		return nil
	end

	local function setup()
		local arena = context.Arena
		buildYard(arena)
		buildChicken(arena)
		local order = pickTeams()
		for index, def in order do
			table.insert(nests, buildNest(arena, def, if index == 1 then -1 else 1))
		end
		placeTeams(order)
		local spots: { CFrame } = {}
		for index, player in context.Players do
			spots[index] = spawnOf[player] or CFrame.new(point(-NEST_DISTANCE + NEST_RADIUS + 3, 0, 0))
		end
		context.SpawnAll(spots)
		context.SetCounterText("MOST EGGS WINS")
		context.SetTeamScores(counts)
		scoresDirty = false
	end

	local function start()
		running = true
		local now = context.GetServerTime()
		lastLaid = now
		nextGolden = now + GOLDEN_EVERY
		for _ = 1, MIN_EGGS do
			lay(false)
		end
		ActionService.SetGrabHook(onGrab)
		actedConnection = ActionService.Acted:Connect(onActed)
		heartbeat = RunService.Heartbeat:Connect(stepEggs)
	end

	local function bestScore(): number
		local best = 0
		for _, count in counts do
			best = math.max(best, count)
		end
		return best
	end

	-- Shown during ROUND OVER, e.g. "CORAL WINS!" or "IT'S A TIE!".
	local function resultText(): string
		local best = bestScore()
		local winners: { string } = {}
		for _, nest in nests do
			if best > 0 and counts[nest.Team.Id] == best then
				table.insert(winners, string.upper(nest.Team.Id))
			end
		end
		return if #winners == 1 then `{winners[1]} WINS!` else "IT'S A TIE!"
	end

	-- The team(s) with the most eggs go through. If nobody scored, everyone does.
	local function getQualified(): { Player }
		local best = bestScore()
		local qualified: { Player } = {}
		for _, player in context.GetAlive() do
			local nest = teamOf[player]
			if best == 0 or (nest and counts[nest.Team.Id] == best) then
				table.insert(qualified, player)
			end
		end
		return qualified
	end

	return {
		Setup = setup,
		Start = start,
		Update = update,
		End = function()
			running = false
			ActionService.SetGrabHook(nil)
			local acted = actedConnection
			if acted then
				acted:Disconnect()
				actedConnection = nil
			end
			local connection = heartbeat
			if connection then
				connection:Disconnect()
				heartbeat = nil
			end
			for _, egg in table.clone(eggs) do
				removeEgg(egg)
			end
			context.SetTeamScores(counts)
			context.SetCounterText(resultText())
		end,
		GetQualified = getQualified,
	}
end

return EggScramble
