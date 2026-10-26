--!strict
-- EGG SCRAMBLE (Team)
-- A two-storey chicken den. Hens sit in nesting boxes on a roost beam high over the middle and lay
-- eggs that drop down to the floor below and roll about. Each team's nest is upstairs, on a loft at
-- its end of the den: GRAB an egg (hold GRAB and walk into one) to pick it up and hold it over your
-- head (you're a bit slower carrying one), then take it back up the ramps (or the trampoline) to
-- your nest. Get knocked over or grabbed and you drop it; DIVE while carrying to throw it (a throw
-- that lands in your nest counts too). Every so often a GOLDEN egg is laid, worth 3. Most eggs when
-- time's up wins; a tie sends both teams through.
--
-- Eggs are server physics parts; a carried egg is welded above its carrier. Picking up goes
-- through the normal grab (ActionService.SetGrabHook), so the server decides who gets an egg.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage.Shared
local Match = require(Shared.Match)
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
local DEN_HALF_X = 62 -- the den runs from -62 to 62 along X, with a loft at each end
local DEN_HALF_Z = 32
local LOFT_HEIGHT = 10 -- the upstairs floor's top
local LOFT_EDGE = 26 -- each loft reaches in this far towards the middle (|X| from 26 to 62)
local WALL_HEIGHT = 22
local RAMP_FOOT = 4 -- the ramps up to each loft start this far from the middle, along X
local RAMP_WIDTH = 8 -- each ramp runs up against a long wall
local LOFT_GAP = 5 -- the loft's low fence has a gap this wide either side of the middle
local BOUNCE_POWER = 64 -- the trampoline in front of each loft, about 12 studs up
local NEST_X = 48
local NEST_RADIUS = 8
local ROOST_Y = 22 -- top of the beam the hens sit on, over the middle
local HEN_SPOTS = { -16, 0, 16 } -- along Z
local EGG_SIZE = Vector3.new(2.4, 3, 2.4)
local PICKUP_REACH = 8
local CARRY_HEIGHT = 3.7 -- above the carrier's middle
local MIN_EGGS, MAX_EGGS = 4, 9
local PLAYERS_PER_EGG = 3 -- one more egg about for every this many players
local LAY_INTERVAL = 2.2 -- seconds between eggs while there are fewer than wanted
local GOLDEN_EVERY = 25 -- seconds between golden eggs
local GOLDEN_VALUE = 3
local THROW_SPEED = 40
local THROW_LIFT = 26
local DROP_POP = 20
local REGRAB_DELAY = 0.6 -- seconds after dropping or throwing before you can pick one up again
local ROLL_DRAG = 1.2 -- per second: loose eggs roll to a stop
local KILL_DEPTH = 8
-- Light and a little bouncy: density, friction, elasticity and their weights.
local EGG_PHYSICS = PhysicalProperties.new(0.05, 0.8, 0.35, 1, 1)

local FLOOR = Color3.fromRGB(222, 186, 134)
local WOOD = Color3.fromRGB(214, 160, 104)
local WOOD_DARK = Color3.fromRGB(170, 112, 70)
local WALL = Color3.fromRGB(196, 102, 80)
local TRIM = Color3.fromRGB(255, 244, 226)
local GLASS = Color3.fromRGB(170, 222, 255)
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
	Rules = "GRAB the eggs the hens drop and carry them up to your nest. DIVE to throw! Knock carriers over.",
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
	local prompts: { [Player]: string? } = {}
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

	-- A ramp from the floor up to a loft (`ends`: which loft), against a long wall (`side`). It's
	-- filled in underneath, in steps hidden under the slope, so nothing gets stuck under it.
	local function buildRamp(parent: Instance, ends: number, side: number)
		local z = side * (DEN_HALF_Z - RAMP_WIDTH / 2)
		local low = point(ends * RAMP_FOOT, 0, z)
		local high = point(ends * LOFT_EDGE, LOFT_HEIGHT, z)
		Hazards.Platform(
			parent,
			CFrame.lookAt((low + high) / 2, high),
			Vector3.new(RAMP_WIDTH, 2, (high - low).Magnitude),
			WOOD,
			"Ramp"
		)
		local run = LOFT_EDGE - RAMP_FOOT
		local steps = 8
		for index = 1, steps - 1 do
			local from = RAMP_FOOT + run * index / steps
			local to = from + run / steps
			local height = (from - RAMP_FOOT) / run * LOFT_HEIGHT - 2.3 -- just under the slope
			if height > 0.2 then
				Geometry.block(
					parent,
					Vector3.new(to - from, height, RAMP_WIDTH),
					CFrame.new(point(ends * (from + to) / 2, height / 2, z)),
					WOOD_DARK,
					{ Name = "RampFill" }
				)
			end
		end
	end

	-- A barn door painted on the front of a loft: dark boards with a white frame and cross brace.
	local function barnDoor(parent: Instance, ends: number, z: number)
		local x = ends * (LOFT_EDGE - 0.1)
		local middle = point(x, 4, z)
		local facing = CFrame.lookAt(middle, middle - Vector3.new(ends, 0, 0))
		Geometry.block(parent, Vector3.new(9, 8, 0.2), facing, WOOD_DARK, DECOR)
		for _, edge in { -1, 1 } do
			Geometry.block(parent, Vector3.new(0.6, 8, 0.3), facing * CFrame.new(edge * 4.5, 0, 0), TRIM, DECOR)
			Geometry.block(parent, Vector3.new(9.6, 0.6, 0.3), facing * CFrame.new(0, edge * 4, 0), TRIM, DECOR)
			local angle = math.atan2(8, 9) * edge
			Geometry.block(parent, Vector3.new(12, 0.5, 0.3), facing * CFrame.Angles(0, 0, angle), TRIM, DECOR)
		end
	end

	-- One upstairs loft: solid underneath (barn doors on its front), two ramps up, a trampoline in
	-- front, and a low fence along its edge with a gap in the middle (for the trampoline).
	local function buildLoft(parent: Instance, ends: number)
		local depth = DEN_HALF_X - LOFT_EDGE
		Geometry.block(
			parent,
			Vector3.new(depth, LOFT_HEIGHT, DEN_HALF_Z * 2),
			CFrame.new(point(ends * (LOFT_EDGE + depth / 2), LOFT_HEIGHT / 2, 0)),
			WOOD,
			{ Name = "Loft", Material = Enum.Material.WoodPlanks }
		)
		Geometry.block(
			parent,
			Vector3.new(0.6, 0.3, DEN_HALF_Z * 2),
			CFrame.new(point(ends * (LOFT_EDGE + 0.3), LOFT_HEIGHT + 0.05, 0)),
			TRIM,
			DECOR
		)
		for _, z in { -13, 13 } do
			barnDoor(parent, ends, z)
		end
		for _, side in { -1, 1 } do
			buildRamp(parent, ends, side)
		end
		Hazards.BouncePad(parent, point(ends * (LOFT_EDGE - 5), 0, 0), { Power = BOUNCE_POWER })
		-- The fence: a rail you can hop over, on posts.
		local x = ends * (LOFT_EDGE + 0.5)
		local fenceEnd = DEN_HALF_Z - RAMP_WIDTH
		for _, side in { -1, 1 } do
			local from, to = side * LOFT_GAP, side * fenceEnd
			Geometry.block(
				parent,
				Vector3.new(0.5, 0.5, math.abs(to - from)),
				CFrame.new(point(x, LOFT_HEIGHT + 1.8, (from + to) / 2)),
				TRIM,
				{ Name = "FenceRail" }
			)
			for z = LOFT_GAP, fenceEnd, (fenceEnd - LOFT_GAP) / 5 do
				Geometry.column(parent, 2.1, 0.6, point(x, LOFT_HEIGHT, side * z), TRIM, DECOR)
			end
		end
	end

	-- The walls round the den, with windows upstairs, and an open roof frame (no roof, so the
	-- camera can see in).
	local function buildWalls(parent: Instance)
		for _, side in { -1, 1 } do
			Geometry.block(
				parent,
				Vector3.new(DEN_HALF_X * 2 + 4, WALL_HEIGHT + 4, 2),
				CFrame.new(point(0, WALL_HEIGHT / 2 - 2, side * (DEN_HALF_Z + 1))),
				WALL,
				{ Name = "Wall", Material = Enum.Material.WoodPlanks }
			)
			Geometry.block(
				parent,
				Vector3.new(2, WALL_HEIGHT + 4, DEN_HALF_Z * 2),
				CFrame.new(point(side * (DEN_HALF_X + 1), WALL_HEIGHT / 2 - 2, 0)),
				WALL,
				{ Name = "Wall", Material = Enum.Material.WoodPlanks }
			)
			-- Windows along the long walls, above the lofts and over the middle.
			for x = -48, 48, 24 do
				local pane = point(x, LOFT_HEIGHT + 6, side * (DEN_HALF_Z - 0.05))
				local window = Geometry.block(parent, Vector3.new(7, 5, 0.1), CFrame.new(pane), GLASS, DECOR)
				window.Material = Enum.Material.SmoothPlastic
				Geometry.block(parent, Vector3.new(8, 0.6, 0.3), CFrame.new(pane + Vector3.new(0, 2.8, 0)), TRIM, DECOR)
				Geometry.block(parent, Vector3.new(8, 0.6, 0.3), CFrame.new(pane - Vector3.new(0, 2.8, 0)), TRIM, DECOR)
				Geometry.block(parent, Vector3.new(0.4, 5, 0.3), CFrame.new(pane), TRIM, DECOR)
			end
			-- Posts up the inside of the long walls, between the windows.
			for x = -60, 60, 24 do
				Geometry.block(
					parent,
					Vector3.new(1.2, WALL_HEIGHT, 0.6),
					CFrame.new(point(x, WALL_HEIGHT / 2, side * (DEN_HALF_Z - 0.3))),
					WOOD_DARK,
					DECOR
				)
			end
		end
		-- Roof frame: cross beams on the walls, posts up to a ridge beam along the den.
		local ridge = WALL_HEIGHT + 11
		for x = -48, 48, 16 do
			if x == 0 then
				continue -- the hens' roost is there
			end
			Geometry.block(
				parent,
				Vector3.new(1.2, 1.2, DEN_HALF_Z * 2 + 2),
				CFrame.new(point(x, WALL_HEIGHT + 0.6, 0)),
				WOOD_DARK,
				DECOR
			)
			Geometry.block(
				parent,
				Vector3.new(1, ridge - WALL_HEIGHT, 1),
				CFrame.new(point(x, (WALL_HEIGHT + ridge) / 2, 0)),
				WOOD_DARK,
				DECOR
			)
			for _, side in { -1, 1 } do
				local from = point(x, WALL_HEIGHT + 1, side * (DEN_HALF_Z + 1))
				local to = point(x, ridge, 0)
				Geometry.block(
					parent,
					Vector3.new(1, 1, (to - from).Magnitude),
					CFrame.lookAt((from + to) / 2, to),
					WOOD_DARK,
					DECOR
				)
			end
		end
		Geometry.block(
			parent,
			Vector3.new(DEN_HALF_X * 2 + 2, 1.2, 1.2),
			CFrame.new(point(0, ridge + 0.6, 0)),
			WOOD_DARK,
			DECOR
		)
	end

	-- A hen sitting in a nesting box, `seat` the bottom of her body, facing `facing` (along X).
	local function buildHen(parent: Instance, seat: Vector3, facing: number)
		local hen = Geometry.model(parent, "Hen")
		local white = Color3.fromRGB(255, 255, 255)
		local scale = 0.42
		-- Built as if facing -Z with the body's bottom at the origin, then scaled and turned.
		local turn = CFrame.new(seat) * CFrame.Angles(0, facing * math.pi / 2, 0)
		local function at(x: number, y: number, z: number): CFrame
			return turn * CFrame.new(Vector3.new(x, y, z) * scale)
		end
		Geometry.ellipsoid(hen, Vector3.new(13, 11, 15) * scale, at(0, 5.5, 0), white, { Name = "Body" })
		Geometry.ball(hen, 7.5 * scale, at(0, 12, -5).Position, white, { Name = "Head" })
		Geometry.ellipsoid(hen, Vector3.new(1.4, 3, 3.4) * scale, at(0, 16.1, -5), Color3.fromRGB(230, 40, 60), DECOR)
		Geometry.ellipsoid(
			hen,
			Vector3.new(1.8, 1.2, 2.6) * scale,
			at(0, 11.5, -9.2) * CFrame.Angles(0.3, 0, 0),
			Color3.fromRGB(255, 170, 40),
			DECOR
		)
		for _, side in { -1, 1 } do
			Geometry.ball(hen, 1.4 * scale, at(side * 2.2, 12.9, -8.2).Position, Theme.Colors.Ink, DECOR)
			Geometry.ellipsoid(
				hen,
				Vector3.new(1.6, 6, 8) * scale,
				at(side * 6.3, 5.5, 0.5) * CFrame.Angles(0, 0, side * 0.2),
				Color3.fromRGB(245, 240, 232),
				DECOR
			)
		end
	end

	-- The roost: a beam across the middle of the den, high up, with a nesting box and a hen at
	-- each of HEN_SPOTS. Eggs drop out from under the beam.
	local function buildRoost(parent: Instance)
		local roost = Geometry.model(parent, "Roost")
		Geometry.block(
			roost,
			Vector3.new(2.4, 1.5, DEN_HALF_Z * 2 + 2),
			CFrame.new(point(0, ROOST_Y - 0.75, 0)),
			WOOD_DARK,
			DECOR
		)
		for index, z in HEN_SPOTS do
			Geometry.block(roost, Vector3.new(6, 3, 6), CFrame.new(point(0, ROOST_Y + 1.5, z)), WOOD, DECOR)
			Geometry.ellipsoid(roost, Vector3.new(6.4, 1.4, 6.4), CFrame.new(point(0, ROOST_Y + 3, z)), STRAW, DECOR)
			buildHen(roost, point(0, ROOST_Y + 3.2, z), if index % 2 == 0 then 1 else -1)
		end
	end

	local function buildDen(arena: Model)
		local den = Geometry.model(arena, "Den")
		-- Downstairs: the floor, with straw scattered under the hens, and hay bales to dodge round.
		Geometry.block(
			den,
			Vector3.new(DEN_HALF_X * 2, 4, DEN_HALF_Z * 2),
			CFrame.new(point(0, -2, 0)),
			FLOOR,
			{ Name = "Floor", Material = Enum.Material.WoodPlanks }
		)
		for _ = 1, 12 do
			Geometry.ellipsoid(
				den,
				Vector3.new(random:NextNumber(5, 9), 0.6, random:NextNumber(4, 7)),
				CFrame.new(point(random:NextNumber(-16, 16), 0.1, random:NextNumber(-20, 20)))
					* CFrame.Angles(0, random:NextNumber(0, math.pi), 0),
				STRAW,
				DECOR
			)
		end
		for _, spot in { Vector2.new(-13, -11), Vector2.new(13, 11), Vector2.new(-13, 11), Vector2.new(13, -11) } do
			Geometry.block(
				den,
				Vector3.new(7, 4, 4.5),
				CFrame.new(point(spot.X, 2, spot.Y)) * CFrame.Angles(0, math.atan2(spot.Y, spot.X), 0),
				STRAW,
				{ Name = "HayBale", Material = Enum.Material.Fabric }
			)
		end
		-- Upstairs: a loft at each end.
		for _, ends in { -1, 1 } do
			buildLoft(den, ends)
		end
		buildWalls(den)
		buildRoost(den)
	end

	-- A team's nest on its loft (`ends`: which end of the den).
	local function buildNest(arena: Model, team: Teams.TeamDef, ends: number): Nest
		local nest = Geometry.model(arena, `{team.Id}Nest`)
		local spot = point(ends * NEST_X, LOFT_HEIGHT, 0)
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
		local anchor = Geometry.block(nest, Vector3.one * 0.4, CFrame.new(spot + Vector3.new(0, 9, 0)), team.Color, {
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

	-- Each team lines up in rows on its loft, between its nest and the edge, facing the middle.
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
				local position = nest.Center + inward * (NEST_RADIUS + 5 + row * 4.5) + across * x
				spawnOf[player] = CFrame.lookAt(position, position + inward)
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

	-- A hen lays: an egg drops out from under the roost and bounces off across the floor.
	local function lay(golden: boolean)
		local z = HEN_SPOTS[random:NextInteger(1, #HEN_SPOTS)]
		local egg = makeEgg(point(random:NextNumber(-0.8, 0.8), ROOST_Y - 3.1, z + random:NextNumber(-1, 1)), golden)
		local angle = random:NextNumber(0, math.pi * 2)
		local speed = random:NextNumber(3, 10)
		egg.Part.AssemblyLinearVelocity = Vector3.new(math.cos(angle) * speed, -4, math.sin(angle) * speed)
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

	-- GRAB near a loose egg picks it up (instead of grabbing a player). Holding GRAB keeps trying,
	-- so you can just run into an egg.
	local function onGrab(player: Player, root: BasePart, _pressed: boolean): boolean
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
			local height = position.Y - nest.Center.Y
			if MathUtil.flat(position - nest.Center).Magnitude <= NEST_RADIUS and height > -1 and height < 6 then
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

	local function setPrompt(player: Player, prompt: string?)
		if prompts[player] == prompt then
			return
		end
		prompts[player] = prompt
		player:SetAttribute(Match.PlayerAttr.RoundPrompt, prompt)
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

		for _, player in context.GetAlive() do
			setPrompt(player, if carriedBy(player) then "CarryEgg" else nil)
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
		buildDen(arena)
		local order = pickTeams()
		for index, def in order do
			table.insert(nests, buildNest(arena, def, if index == 1 then -1 else 1))
		end
		placeTeams(order)
		local spots: { CFrame } = {}
		for index, player in context.Players do
			spots[index] = spawnOf[player] or CFrame.new(point(-(NEST_X - NEST_RADIUS - 5), LOFT_HEIGHT, 0))
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
			for _, player in context.Players do
				setPrompt(player, nil)
			end
			context.SetTeamScores(counts)
			context.SetCounterText(resultText())
		end,
		GetQualified = getQualified,
	}
end

return EggScramble
