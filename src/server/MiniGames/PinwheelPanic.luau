--!strict
-- PINWHEEL PANIC (Survival)
-- A round candy pinwheel of a platform with two long bars spinning over it in opposite
-- directions: a low pink one you have to jump, and a high blue one that catches you if you jump
-- while it's passing. Stay on the ground for the high bar, hop the low one.
--   * The bars wait, crossed, until GO, then start spinning and speed up twice. With the second
--     speed-up a second pink bar joins in across the first: it flashes where it is (turning with
--     the first) for a few seconds before it turns solid.
--   * The middle is a big trampoline, so nobody can just stand there: it keeps bouncing you up
--     towards the high bar.
--   * The platform shrinks: its outer ring, then the next, flash and drop away segment by segment,
--     until only the middle is left.
-- Get knocked off and you're out. Still standing at the end (or among the last few) qualifies.
--
-- Hits are judged by each client against the bars it sees (see HazardController), and the
-- server times the speed-ups and the falling segments.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Config = require(Shared.Config)
local Tags = require(Shared.Tags)
local Theme = require(Shared.Theme)

local Bots = require(script.Parent.Parent.Bots.Bots)
local Geometry = require(script.Parent.Parent.Builders.Geometry)
local Hazards = require(script.Parent.Parent.Builders.Hazards)
local ArenaUtil = require(script.Parent.Parent.Match.ArenaUtil)
local Types = require(script.Parent.Parent.Match.Types)

local DURATION = 80
local KILL_DEPTH = 15
local CORE_RADIUS = 14 -- the middle never falls
local CORE_BOUNCE = 58 -- the middle's trampoline (a ~10 stud bounce: right into the high bar)
local FLOOR_HEIGHT = 2
local SPAWN_RADIUS = 29
local REMOVE_AFTER_FALL = 2.5

-- The rings round the middle, outermost first: when its segments drop (seconds after GO, spread
-- over a few seconds so it crumbles) and how many segments it has.
type RingSpec = { Inner: number, Outer: number, Segments: number, FallFrom: number, FallTo: number }
local RINGS: { RingSpec } = {
	{ Inner = 34, Outer = 44, Segments = 20, FallFrom = 22, FallTo = 30 },
	{ Inner = 24, Outer = 34, Segments = 15, FallFrom = 42, FallTo = 50 },
	{ Inner = 14, Outer = 24, Segments = 10, FallFrom = 62, FallTo = 68 },
}

-- Bar speeds (radians per second) for each stage, and when each stage starts (seconds after GO).
local LOW_SPEEDS = { 1.3, 1.7, 2.1 }
local HIGH_SPEEDS = { -1.05, -1.4, -1.75 }
local STAGE_TIMES = { 0, 20, 40 }
local LOW_BAR_HEIGHT = 2.2 -- jump it
local HIGH_BAR_HEIGHT = 6 -- clears a standing Bloblet, but not a jumping one
-- The bars may be lying across someone's spawn when they set off, so for this long after GO they
-- pass through Bloblets without pushing or knocking anyone over.
local START_GRACE = 0.5
local EXTRA_BAR_STAGE = 3 -- the second pink bar comes in with this speed-up

local CANDY_PINK = Color3.fromRGB(255, 120, 176)
local CANDY_WHITE = Color3.fromRGB(255, 246, 250)
local CANDY_AQUA = Color3.fromRGB(120, 214, 255)
local CORE_COLOR = Color3.fromRGB(255, 226, 120)
local DECOR: Geometry.PartOptions = { Name = "Decor", CanCollide = false, CastShadow = false }

type Segment = {
	Model: Model,
	Pad: Part,
	Ring: number,
}

local PinwheelPanic = {}

PinwheelPanic.Info = {
	Id = "PinwheelPanic",
	DisplayName = "Pinwheel Panic",
	Type = "Survival",
	Rules = "Jump the low pink bar, stay down for the high blue one, and don't get knocked off!",
	Duration = DURATION,
	MinPlayers = 1,
} :: Types.MiniGameInfo

function PinwheelPanic.new(context: Types.RoundContext): Types.MiniGame
	local center = context.Origin.Position
	local random = context.Random
	local segments: { Segment } = {}
	local lowBar: Model? = nil
	local highBar: Model? = nil
	local barLength = RINGS[1].Outer * 2 + 4
	local stage = 1
	local running = false

	-- One segment of a ring: a block spanning the ring's width, pink and white in turns like a
	-- pinwheel's blades.
	local function buildSegment(arena: Model, ringIndex: number, ring: RingSpec, index: number)
		local model = Geometry.atomicModel("PinwheelSegment")
		local angle = (index - 0.5) / ring.Segments * math.pi * 2
		local middle = (ring.Inner + ring.Outer) / 2
		local direction = Vector3.new(math.cos(angle), 0, math.sin(angle))
		-- Wide enough at the outer edge that neighbours meet (they overlap a little inside).
		local width = 2 * ring.Outer * math.sin(math.pi / ring.Segments) + 0.2
		local top = center + direction * middle
		local cframe = CFrame.lookAt(top, top + direction) * CFrame.new(0, -FLOOR_HEIGHT / 2, 0)
		local pink = (index + ringIndex) % 2 == 0
		local color = if pink then CANDY_PINK else CANDY_WHITE
		-- Neighbours overlap a little near the middle, so pink segments sit a hair higher than white
		-- ones (and both a hair above the middle) to keep their tops from flickering.
		cframe += Vector3.new(0, if pink then 0.05 else 0.025, 0)
		local pad = Geometry.block(model, Vector3.new(width, FLOOR_HEIGHT, ring.Outer - ring.Inner), cframe, color, {
			Name = "Pad",
		})
		-- A sugar dot on each segment (rides along when it drops).
		Geometry.ball(model, 1.6, top + Vector3.new(0, 0.1, 0), color:Lerp(CANDY_AQUA, 0.5), DECOR)
		model:SetAttribute("FallAt", 0)
		CollectionService:AddTag(model, Tags.FallingTile)
		model.Parent = arena -- only now, with every part inside
		table.insert(segments, { Model = model, Pad = pad, Ring = ringIndex })
	end

	local function buildPlatform(arena: Model)
		-- The middle: a trampoline whose cushion is level with the floor.
		Hazards.BouncePad(arena, center - Vector3.new(0, 1.25, 0), {
			Diameter = CORE_RADIUS * 2,
			Power = CORE_BOUNCE,
			Color = CORE_COLOR,
			RingColor = Theme.Colors.Pink,
		})
		for ringIndex, ring in RINGS do
			for index = 1, ring.Segments do
				buildSegment(arena, ringIndex, ring, index)
			end
		end
		-- A candy stick holding the whole pinwheel up (decoration).
		Geometry.column(arena, 120, 5, center - Vector3.new(0, 122, 0), CANDY_WHITE, DECOR)
	end

	-- Giant pinwheel candies on sticks round the arena (nothing here collides).
	local function buildScenery(arena: Model)
		local scenery = Geometry.model(arena, "Scenery")
		for index = 1, 8 do
			local angle = index / 8 * math.pi * 2 + random:NextNumber(-0.2, 0.2)
			local distance = random:NextNumber(85, 110)
			local base = center + Vector3.new(math.cos(angle) * distance, -60, math.sin(angle) * distance)
			local height = random:NextNumber(60, 90)
			Geometry.column(scenery, height, 1.6, base, CANDY_WHITE, DECOR)
			local hub = base + Vector3.new(0, height, 0)
			local facing = CFrame.lookAt(hub, Vector3.new(center.X, hub.Y, center.Z))
			for blade = 0, 3 do
				local bladeCFrame = facing * CFrame.Angles(0, 0, blade * math.pi / 2) * CFrame.new(0, 5, 0)
				Geometry.block(
					scenery,
					Vector3.new(4, 10, 0.6),
					bladeCFrame,
					if blade % 2 == 0 then CANDY_PINK else CANDY_AQUA,
					DECOR
				)
			end
			Geometry.ball(scenery, 3, hub, Theme.Colors.Yellow, DECOR)
		end
	end

	-- A second pink bar across the first (a quarter turn ahead, same speed), so the pink bars make
	-- a cross. It flashes for a few seconds before it turns solid.
	local function addExtraBar(first: Model, now: number)
		local phase = first:GetAttribute("Phase")
		Hazards.Spinner(context.Arena, center, {
			ArmLength = barLength,
			Speed = LOW_SPEEDS[stage],
			Phase = (if typeof(phase) == "number" then phase else 0) + math.pi / 2,
			ArmHeight = LOW_BAR_HEIGHT,
			Color = Theme.Colors.Pink,
			Mat = false,
			AppearAt = now + Config.Hazards.SpinnerWarningTime,
		})
	end

	local function setup()
		local arena = context.Arena
		buildPlatform(arena)
		lowBar = Hazards.Spinner(arena, center, {
			ArmLength = barLength,
			Speed = 0, -- still until GO
			ArmHeight = LOW_BAR_HEIGHT,
			Color = Theme.Colors.Pink,
			Mat = false,
		})
		highBar = Hazards.Spinner(arena, center, {
			ArmLength = barLength,
			Speed = 0,
			Phase = math.pi / 2,
			ArmHeight = HIGH_BAR_HEIGHT,
			Color = Theme.Colors.Aqua,
			Mat = false,
		})
		for _, bar in { lowBar, highBar } do
			if bar then
				-- Harmless until GO (and a moment after; see start).
				bar:SetAttribute("GraceUntil", context.GetServerTime() + 3600)
			end
		end
		buildScenery(arena)
		context.SpawnAll(ArenaUtil.RingSpots(center, SPAWN_RADIUS, #context.Players))
	end

	local function start()
		running = true
		local startTime = context.GetStartTime()
		-- The bars set off at GO, from where they've been waiting.
		local low, high = lowBar, highBar
		if low then
			Hazards.SetSpinnerSpeed(low, LOW_SPEEDS[1], startTime)
			low:SetAttribute("GraceUntil", startTime + START_GRACE)
		end
		if high then
			Hazards.SetSpinnerSpeed(high, HIGH_SPEEDS[1], startTime)
			high:SetAttribute("GraceUntil", startTime + START_GRACE)
		end
		for _, segment in segments do
			local ring = RINGS[segment.Ring]
			local fallAt = startTime + random:NextNumber(ring.FallFrom, ring.FallTo)
			segment.Model:SetAttribute("FallAt", fallAt)
			task.delay(math.max(0, fallAt - context.GetServerTime()), function()
				if not running then
					return
				end
				segment.Pad.CanCollide = false
				segment.Pad.CanQuery = false
				task.delay(REMOVE_AFTER_FALL, function()
					if segment.Model.Parent then
						segment.Model:Destroy()
					end
				end)
			end)
		end
	end

	local function update(_dt: number): boolean?
		context.EliminateBelow(center.Y - KILL_DEPTH)
		if not running then
			return nil
		end
		-- Speed the bars up when the next stage comes round.
		local elapsed = context.GetServerTime() - context.GetStartTime()
		local nextStage = stage + 1
		if STAGE_TIMES[nextStage] and elapsed >= STAGE_TIMES[nextStage] then
			stage = nextStage
			local now = context.GetServerTime()
			local low, high = lowBar, highBar
			if low then
				Hazards.SetSpinnerSpeed(low, LOW_SPEEDS[stage], now)
			end
			if high then
				Hazards.SetSpinnerSpeed(high, HIGH_SPEEDS[stage], now)
			end
			if stage == EXTRA_BAR_STAGE and low then
				addExtraBar(low, now)
				context.Announce("FASTER! MORE BARS!")
			else
				context.Announce("FASTER!")
			end
		end
		return nil
	end

	-- Bots keep to the ring that falls last and step in to the next one before theirs drops (sharp
	-- ones in good time, clumsy ones only just), ending up on the bouncy middle. The bars are
	-- BotBrain's to jump (or not).
	local function botGoal(bot: Player): Types.BotGoal?
		local root = context.GetRoot(bot)
		if not root or not running then
			return nil
		end
		local elapsed = context.GetServerTime() - context.GetStartTime()
		local lead = 1 + 5 * Bots.SkillOf(bot)
		local away = Vector3.new(root.Position.X - center.X, 0, root.Position.Z - center.Z)
		local direction = if away.Magnitude > 0.1 then away.Unit else Vector3.xAxis
		for index = 2, #RINGS do
			local ring = RINGS[index]
			if elapsed < ring.FallFrom - lead then
				local middle = (ring.Inner + ring.Outer) / 2
				return { MoveTo = center + direction * middle, Within = 2.5, Wander = 2.5, Careful = true }
			end
		end
		return { MoveTo = center, Wander = CORE_RADIUS - 6, Careful = true }
	end

	return {
		Setup = setup,
		Start = start,
		Update = update,
		End = function()
			running = false
		end,
		GetQualified = context.DefaultQualified,
		BotGoal = botGoal,
	}
end

return PinwheelPanic
