--!strict
-- SPRINKLE HILLS (Team)
-- A round candy island with three hills: A and C on either side, B in the middle and taller, with
-- a spinning bar on top. Stand on a hill with more of your team than the other team to capture it
-- (3 seconds, shown on its flag); every hill your team holds earns a point a second until the
-- other team takes it back. First team to 100 points wins, or the most points when time's up (a
-- tie sends both teams through). Ramps lead up the hills and trampolines bounce you up the side.
--
-- The server counts who's on each hill and colours its ring and flag for the team holding it.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local BlobletRig = require(Shared.BlobletRig)
local MathUtil = require(Shared.MathUtil)
local Teams = require(Shared.Teams)
local Theme = require(Shared.Theme)
local Ui = require(Shared.Ui)

local Geometry = require(script.Parent.Parent.Builders.Geometry)
local Hazards = require(script.Parent.Parent.Builders.Hazards)
local Types = require(script.Parent.Parent.Match.Types)

local DURATION = 100
local ISLAND_RADIUS = 92
local BASE_DISTANCE = 70 -- each team starts this far from the middle
local CAPTURE_TIME = 3
local POINTS_TO_WIN = 100
local POINTS_PER_SECOND = 1 -- for each hill held
local KILL_DEPTH = 14

local GROUND = Color3.fromRGB(255, 214, 232)
local HILL = Color3.fromRGB(255, 186, 214)
local NEUTRAL = Color3.fromRGB(235, 228, 245)
local SPRINKLES = {
	Color3.fromRGB(255, 90, 140),
	Color3.fromRGB(90, 200, 255),
	Color3.fromRGB(255, 210, 60),
	Color3.fromRGB(130, 220, 110),
	Color3.fromRGB(180, 120, 255),
}
local DECOR: Geometry.PartOptions = { Name = "Decor", CanCollide = false, CastShadow = false }

type HillSpec = { Name: string, X: number, Z: number, Radius: number, Height: number, Spinner: boolean }

-- Big hills with plenty of room to run between them.
local HILLS: { HillSpec } = {
	{ Name = "A", X = -56, Z = 0, Radius = 16, Height = 8, Spinner = false },
	{ Name = "B", X = 0, Z = 0, Radius = 15, Height = 13, Spinner = true },
	{ Name = "C", X = 56, Z = 0, Radius = 16, Height = 8, Spinner = false },
}
local RAMP_WIDTH = 9
local SPRINKLE_COUNT = 280
local BOT_RETHINK = { 5, 9 } -- seconds a bot sticks with the hill it picked

-- The hill a bot is making for, and when it'll think again.
type BotPlan = { Hill: Hill, Until: number }

type Hill = {
	Spec: HillSpec,
	Top: Vector3, -- middle of its top
	Owner: Teams.TeamDef?,
	Capturing: Teams.TeamDef?,
	Progress: number, -- seconds of capturing so far
	Ring: { BasePart },
	Flag: BasePart,
	Label: TextLabel,
	Bar: Frame,
}

local SprinkleHills = {}

SprinkleHills.Info = {
	Id = "SprinkleHills",
	DisplayName = "Sprinkle Hills",
	Type = "Team",
	Rules = "Hold the hills! Outnumber the other team on a hill to take it. First to 100 points wins.",
	Duration = DURATION,
	MinPlayers = 4,
	TeamCount = 2,
} :: Types.MiniGameInfo

function SprinkleHills.new(context: Types.RoundContext): Types.MiniGame
	local center = context.Origin.Position
	local random = context.Random
	local order: { Teams.TeamDef } = {}
	local hills: { Hill } = {}
	local points: { [string]: number } = {}
	local shown: { [string]: number } = {}
	local teamOf: { [Player]: Teams.TeamDef } = {}
	local spawnOf: { [Player]: CFrame } = {}
	local botPlans: { [Player]: BotPlan } = {}
	local winner: Teams.TeamDef? = nil
	local running = false

	local function point(x: number, y: number, z: number): Vector3
		return center + Vector3.new(x, y, z)
	end

	-- The two teams in this round (testing alone still gets two).
	local function pickTeams()
		local teams = context.Teams or {}
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
		for _, def in order do
			points[def.Id] = 0
			shown[def.Id] = 0
		end
	end

	local function buildIsland(arena: Model)
		local island = Geometry.model(arena, "Island")
		Geometry.column(island, 6, ISLAND_RADIUS * 2, point(0, -6, 0), GROUND, { Name = "Ground" })
		Geometry.column(island, 8, ISLAND_RADIUS * 2 - 6, point(0, -13, 0), Color3.fromRGB(150, 98, 72), DECOR)
		for _ = 1, SPRINKLE_COUNT do
			local angle = random:NextNumber(0, math.pi * 2)
			local distance = math.sqrt(random:NextNumber(0, 1)) * (ISLAND_RADIUS - 3)
			local spot = point(math.cos(angle) * distance, 0.1, math.sin(angle) * distance)
			Geometry.block(
				island,
				Vector3.new(1.4, 0.3, 0.45),
				CFrame.new(spot) * CFrame.Angles(0, random:NextNumber(0, math.pi), 0),
				SPRINKLES[random:NextInteger(1, #SPRINKLES)],
				DECOR
			)
		end
	end

	-- A hill: a round mound with a ramp up each side facing the teams, a ring round its top and a
	-- flag on its edge.
	local function buildHill(arena: Model, spec: HillSpec): Hill
		local model = Geometry.model(arena, `Hill{spec.Name}`)
		local base = point(spec.X, 0, spec.Z)
		local top = base + Vector3.new(0, spec.Height, 0)
		Geometry.column(model, spec.Height, spec.Radius * 2, base, HILL, { Name = "Hill" })
		for _, side in { -1, 1 } do
			local low = base + Vector3.new(0, 0, side * (spec.Radius + spec.Height * 2.2))
			local high = top + Vector3.new(0, 0, side * (spec.Radius - 1))
			Hazards.Platform(
				model,
				CFrame.lookAt((low + high) / 2, high),
				Vector3.new(RAMP_WIDTH, 2, (high - low).Magnitude),
				Color3.fromRGB(255, 236, 246),
				"Ramp"
			)
		end
		-- A trampoline on the outer side of each side hill bounces you up onto it.
		if spec.X ~= 0 then
			local outward = if spec.X > 0 then 1 else -1
			Hazards.BouncePad(
				model,
				base + Vector3.new(outward * (spec.Radius + 4), 0, 0),
				{ Power = 60 + spec.Height * 3 }
			)
		end
		local ring: { BasePart } = {}
		local pieces = 28
		for index = 1, pieces do
			local angle = index / pieces * math.pi * 2
			local spot = top
				+ Vector3.new(math.cos(angle) * (spec.Radius - 0.6), 0.1, math.sin(angle) * (spec.Radius - 0.6))
			local piece = Geometry.block(
				model,
				Vector3.new(2 * math.pi * spec.Radius / pieces, 0.2, 1),
				CFrame.lookAt(spot, top + Vector3.new(0, 0.1, 0)),
				NEUTRAL,
				DECOR
			)
			piece.Material = Enum.Material.Neon
			table.insert(ring, piece)
		end
		-- The flag, on the hill's edge (out of the spinner's way).
		local poleFoot = top + Vector3.new(spec.Radius + 0.6, 0, 0)
		Geometry.column(model, 9, 0.5, poleFoot, Color3.fromRGB(255, 255, 255), DECOR)
		local flag = Geometry.block(
			model,
			Vector3.new(0.2, 2.6, 4),
			CFrame.new(poleFoot + Vector3.new(0, 7.6, 2)),
			NEUTRAL,
			DECOR
		)
		flag.Material = Enum.Material.Neon
		if spec.Spinner then
			Hazards.Spinner(model, top, {
				ArmLength = spec.Radius * 2 - 2,
				Speed = 1.1,
				Mat = false,
				Color = Theme.Colors.Purple,
			})
		end
		-- A floating label: the hill's letter, and a bar while it's being captured.
		local anchor = Geometry.block(model, Vector3.one * 0.4, CFrame.new(top + Vector3.new(0, 12, 0)), NEUTRAL, {
			Name = "LabelAnchor",
			Transparency = 1,
			CanCollide = false,
		})
		local gui: BillboardGui = Ui.new("BillboardGui", {
			Size = UDim2.fromOffset(220, 90),
			LightInfluence = 0,
			MaxDistance = 400,
			Parent = anchor,
		})
		local label = Ui.label(
			gui,
			`HILL {spec.Name}`,
			Theme.Fonts.Display,
			Theme.Colors.White,
			UDim2.new(1, 0, 0, 50),
			UDim2.fromScale(0.5, 0),
			Vector2.new(0.5, 0)
		)
		Ui.stroke(label, Theme.Colors.Ink, 3)
		local track: Frame = Ui.new("Frame", {
			Size = UDim2.new(0.8, 0, 0, 14),
			Position = UDim2.new(0.5, 0, 0, 60),
			AnchorPoint = Vector2.new(0.5, 0),
			BackgroundColor3 = Theme.Colors.Ink,
			BorderSizePixel = 0,
			Visible = false,
			Parent = gui,
		})
		Ui.corner(track, UDim.new(0.5, 0))
		local bar: Frame = Ui.new("Frame", {
			Size = UDim2.fromScale(0, 1),
			BackgroundColor3 = Theme.Colors.White,
			BorderSizePixel = 0,
			Parent = track,
		})
		Ui.corner(bar, UDim.new(0.5, 0))
		return {
			Spec = spec,
			Top = top,
			Owner = nil,
			Capturing = nil,
			Progress = 0,
			Ring = ring,
			Flag = flag,
			Label = label,
			Bar = bar,
		}
	end

	local function paint(hill: Hill)
		local owner = hill.Owner
		local color = if owner then owner.Color else NEUTRAL
		for _, piece in hill.Ring do
			piece.Color = color
		end
		hill.Flag.Color = color
		hill.Label.TextColor3 = if owner then owner.Color else Theme.Colors.White
		local capturing = hill.Capturing
		local track = hill.Bar.Parent :: Frame
		track.Visible = capturing ~= nil and hill.Progress > 0
		if capturing then
			hill.Bar.BackgroundColor3 = capturing.Color
			hill.Bar.Size = UDim2.fromScale(math.clamp(hill.Progress / CAPTURE_TIME, 0, 1), 1)
		end
	end

	-- Each team starts in rows at its own edge of the island, facing the middle.
	local function placeTeams()
		local teams = context.Teams or {}
		for index, def in order do
			local ends = if index == 1 then -1 else 1
			local members = teams[def.Id] or {}
			for slot, player in members do
				teamOf[player] = def
				local row = (slot - 1) // 6
				local inRow = math.min(6, #members - row * 6)
				local x = ((slot - 1) % 6 - (inRow - 1) / 2) * 5
				local position = point(x, 0, ends * (BASE_DISTANCE + row * 5))
				spawnOf[player] = CFrame.lookAt(position, Vector3.new(position.X, position.Y, center.Z))
			end
		end
	end

	-- How many of each team are standing on a hill.
	local function countOn(hill: Hill): { [string]: number }
		local counts: { [string]: number } = {}
		for _, player in context.GetAlive() do
			local team = teamOf[player]
			local root = context.GetRoot(player)
			if not team or not root then
				continue
			end
			local offset = root.Position - hill.Top
			if MathUtil.flat(offset).Magnitude <= hill.Spec.Radius + 0.5 and offset.Y > 0.5 and offset.Y < 8 then
				counts[team.Id] = (counts[team.Id] or 0) + 1
			end
		end
		return counts
	end

	-- The team with more players on a hill than any other (nil if it's empty or level).
	local function leaderOn(hill: Hill): Teams.TeamDef?
		local counts = countOn(hill)
		local best: Teams.TeamDef? = nil
		local bestCount, tied = 0, false
		for _, def in order do
			local count = counts[def.Id] or 0
			if count > bestCount then
				best, bestCount, tied = def, count, false
			elseif count == bestCount and count > 0 then
				tied = true
			end
		end
		return if tied then nil else best
	end

	local function stepHill(hill: Hill, dt: number)
		local leader = leaderOn(hill)
		local changed = false
		if leader and leader ~= hill.Owner then
			if hill.Capturing ~= leader then
				hill.Capturing = leader
				hill.Progress = 0
			end
			hill.Progress += dt
			if hill.Progress >= CAPTURE_TIME then
				hill.Owner = leader
				hill.Capturing = nil
				hill.Progress = 0
				context.Announce(`{string.upper(leader.Id)} TOOK HILL {hill.Spec.Name}!`, leader.Id)
			end
			changed = true
		elseif not leader and hill.Progress > 0 and hill.Capturing then
			-- Nobody (or a tie) on it: a half-done capture slowly fades.
			hill.Progress = math.max(hill.Progress - dt * 0.5, 0)
			if hill.Progress == 0 then
				hill.Capturing = nil
			end
			changed = true
		elseif leader and leader == hill.Owner and hill.Capturing then
			hill.Capturing = nil
			hill.Progress = 0
			changed = true
		end
		if changed then
			paint(hill)
		end
		local owner = hill.Owner
		if owner then
			points[owner.Id] += dt * POINTS_PER_SECOND
		end
	end

	local function publishScores(force: boolean)
		local changed = force
		for id, value in points do
			local whole = math.floor(value)
			if shown[id] ~= whole then
				shown[id] = whole
				changed = true
			end
		end
		if changed then
			context.SetTeamScores(shown, POINTS_TO_WIN)
		end
	end

	local function update(dt: number): boolean?
		for _, player in context.GetAlive() do
			local root = context.GetRoot(player)
			local home = spawnOf[player]
			if root and home and root.Position.Y < center.Y - KILL_DEPTH then
				context.SpawnAt(player, home)
			end
		end
		if not running then
			return nil
		end
		for _, hill in hills do
			stepHill(hill, dt)
		end
		publishScores(false)
		for _, def in order do
			if points[def.Id] >= POINTS_TO_WIN then
				winner = def
				return true
			end
		end
		return nil
	end

	local function setup()
		local arena = context.Arena
		pickTeams()
		buildIsland(arena)
		for _, spec in HILLS do
			local hill = buildHill(arena, spec)
			paint(hill)
			table.insert(hills, hill)
		end
		placeTeams()
		local spots: { CFrame } = {}
		for index, player in context.Players do
			spots[index] = spawnOf[player] or CFrame.new(point(0, 0, -BASE_DISTANCE))
		end
		context.SpawnAll(spots)
		context.SetCounterText(`HOLD THE HILLS: FIRST TO {POINTS_TO_WIN}`)
		publishScores(true)
	end

	local function best(): number
		local top = 0
		for _, value in points do
			top = math.max(top, math.floor(value))
		end
		return top
	end

	-- Shown during ROUND OVER.
	local function resultText(): string
		local team = winner
		if team then
			return `{string.upper(team.Id)} WINS!`
		end
		local top = best()
		local leaders: { string } = {}
		for _, def in order do
			if top > 0 and math.floor(points[def.Id]) == top then
				table.insert(leaders, string.upper(def.Id))
			end
		end
		return if #leaders == 1 then `{leaders[1]} WINS!` else "IT'S A TIE!"
	end

	-- The team with the most points goes through (both on a tie, or if nobody scored).
	local function getQualified(): { Player }
		local top = best()
		local qualified: { Player } = {}
		for _, player in context.GetAlive() do
			local team = teamOf[player]
			local through = if winner
				then team == winner
				else top == 0 or (team ~= nil and math.floor(points[team.Id]) == top)
			if through then
				table.insert(qualified, player)
			end
		end
		return qualified
	end

	-- Which hill a bot should help with: one its team doesn't hold (or is about to lose), where it
	-- isn't already well outnumbering the other team, and not too far off.
	local function pickHill(team: Teams.TeamDef, position: Vector3): Hill?
		local choice: Hill? = nil
		local bestScore = math.huge
		for _, hill in hills do
			local counts = countOn(hill)
			local ours = counts[team.Id] or 0
			local theirs = 0
			for id, count in counts do
				if id ~= team.Id then
					theirs = math.max(theirs, count)
				end
			end
			local score = MathUtil.flat(hill.Top - position).Magnitude / 4 + random:NextNumber(0, 8)
			if hill.Owner == team and theirs == 0 then
				score += 20 -- ours and nobody's trying to take it
			end
			if ours > theirs + 1 then
				score += 15 -- plenty of us there already
			end
			if score < bestScore then
				choice, bestScore = hill, score
			end
		end
		return choice
	end

	-- The hill a bot is going for, picked again every few seconds.
	local function botPlan(bot: Player, team: Teams.TeamDef, position: Vector3): BotPlan?
		local plan = botPlans[bot]
		if plan and os.clock() <= plan.Until then
			return plan
		end
		local hill = pickHill(team, position)
		if not hill then
			botPlans[bot] = nil
			return nil
		end
		local fresh: BotPlan = { Hill = hill, Until = os.clock() + random:NextNumber(BOT_RETHINK[1], BOT_RETHINK[2]) }
		botPlans[bot] = fresh
		return fresh
	end

	-- Bots pick a hill, go up the nearer ramp and mill about on top (jumping the spinning bar on
	-- the middle one, shoving the other team off).
	local function botGoal(bot: Player): Types.BotGoal?
		local root = context.GetRoot(bot)
		local team = teamOf[bot]
		if not root or not team or not running then
			return nil
		end
		local position = root.Position
		local plan = botPlan(bot, team, position)
		if not plan then
			return nil
		end
		local hill = plan.Hill
		local spec = hill.Spec
		local offset = position - hill.Top
		local feet = offset.Y - BlobletRig.Dimensions.RootHeight
		if MathUtil.flat(offset).Magnitude <= spec.Radius and feet > -1 then
			return { MoveTo = hill.Top, Wander = spec.Radius - 5, Careful = true }
		end
		local side = if offset.Z >= 0 then 1 else -1
		if math.abs(offset.X) <= RAMP_WIDTH / 2 - 0.5 and offset.Z * side >= spec.Radius - 1 then
			return { MoveTo = hill.Top, Within = 2 } -- on the ramp (or at its foot): up it
		end
		local foot = Vector3.new(hill.Top.X, center.Y, hill.Top.Z + side * (spec.Radius + spec.Height * 2.2 + 3))
		return { MoveTo = foot, Within = 1.5 }
	end

	return {
		Setup = setup,
		Start = function()
			running = true
		end,
		Update = update,
		End = function()
			running = false
			table.clear(botPlans)
			publishScores(true)
			context.SetCounterText(resultText())
		end,
		GetQualified = getQualified,
		BotGoal = botGoal,
	}
end

return SprinkleHills
