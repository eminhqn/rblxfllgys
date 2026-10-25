--!strict
-- BALLOON BARRAGE (Survival)
-- A round party deck floating in the sky. Giant balloons roll across it from every side: more of
-- them, and faster, as the round goes on, and after a while some of them hop. Before a balloon
-- sets off, its lane flashes on the floor. A balloon knocks you over and away; get knocked off
-- the deck and you're out. The round ends once only the qualifying number of Bloblets is left,
-- and everyone still on the deck when time runs out goes through.
--
-- The server only decides each balloon's path and timing (see Hazards.Balloon). Every client rolls
-- it from the shared clock and judges its own hits; falling off is checked here.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Config = require(Shared.Config)
local MathUtil = require(Shared.MathUtil)
local Theme = require(Shared.Theme)

local Geometry = require(script.Parent.Parent.Builders.Geometry)
local Hazards = require(script.Parent.Parent.Builders.Hazards)
local ArenaUtil = require(script.Parent.Parent.Match.ArenaUtil)
local Types = require(script.Parent.Parent.Match.Types)

local DURATION = 90
local RADIUS = 44
local KILL_DEPTH = 25
local SPAWN_RADIUS = 18
local EXIT_MARGIN = 6 -- balloons set off and finish this far beyond the edge
local AIM_SPREAD = 0.65 -- how far from the middle (share of RADIUS) a balloon's path can pass
local MAX_BALLOONS = 24
local FIRST_BALLOON = 1.2 -- seconds after GO

-- Pace over the round: [start, end] values reached after RAMP_TIME seconds.
local RAMP_TIME = 60
local INTERVAL = { 2.0, 0.75 } -- seconds between launches
local SPEED = { 15, 30 } -- studs per second
local DOUBLE_AFTER = 25 -- two balloons per launch from here
local TRIPLE_AFTER = 50 -- three from here
local HOP_AFTER = 20 -- hopping balloons appear from here
local HOP_CHANCE = 0.3

local DIAMETERS = { 8, 10, 10, 13, 16 }
local BALLOON_COLORS = {
	Theme.Colors.Pink,
	Theme.Colors.Aqua,
	Theme.Colors.Yellow,
	Theme.Colors.Purple,
	Theme.Colors.Lime,
	Theme.Colors.Orange,
}

local WHITE = Color3.fromRGB(255, 255, 255)
local DECK_RINGS = {
	{ Diameter = 84, Color = WHITE },
	{ Diameter = 66, Color = Color3.fromRGB(255, 160, 206) },
	{ Diameter = 48, Color = WHITE },
	{ Diameter = 30, Color = Theme.Colors.Yellow },
	{ Diameter = 13, Color = Theme.Colors.Pink },
}
local DECOR: Geometry.PartOptions = { Name = "Decor", CanCollide = false, CastShadow = false }

local BalloonBarrage = {}

BalloonBarrage.Info = {
	Id = "BalloonBarrage",
	DisplayName = "Balloon Barrage",
	Type = "Survival",
	Rules = "Giant balloons are rolling in! Watch for the flashing lanes and don't get knocked off the deck.",
	Duration = DURATION,
	MinPlayers = 1,
} :: Types.MiniGameInfo

-- Where a line from `start` along `direction` crosses a circle round `center` (on the XZ plane):
-- the two distances along the line, or nil if it misses.
local function circleCrossings(center: Vector3, radius: number, start: Vector3, direction: Vector3): (number?, number?)
	local offset = MathUtil.flat(start - center)
	local b = offset:Dot(direction)
	local discriminant = b * b - (offset:Dot(offset) - radius * radius)
	if discriminant < 0 then
		return nil, nil
	end
	local root = math.sqrt(discriminant)
	return -b - root, -b + root
end

function BalloonBarrage.new(context: Types.RoundContext): Types.MiniGame
	local center = context.Origin.Position
	local random = context.Random
	local running = false
	local timer = 0
	local balloons = 0

	local function buildDeck(arena: Model)
		local deck = Geometry.model(arena, "Deck")
		Geometry.column(deck, 4, RADIUS * 2, center - Vector3.new(0, 4, 0), Theme.Colors.Pink, { Name = "Floor" })
		-- Party-target rings painted on top (each a hair higher so they don't flicker).
		for index, ring in DECK_RINGS do
			Geometry.column(deck, 0.1, ring.Diameter, center + Vector3.new(0, index * 0.02, 0), ring.Color, DECOR)
		end
		-- Studs round the rim mark the edge.
		local studs = 44
		for index = 1, studs do
			local angle = index / studs * math.pi * 2
			local position = center + Vector3.new(math.cos(angle) * RADIUS, 0.2, math.sin(angle) * RADIUS)
			Geometry.ball(deck, 2.2, position, if index % 2 == 0 then Theme.Colors.Yellow else WHITE, DECOR)
		end
		-- A soft rounded underside (its top is hidden inside the deck).
		Geometry.ellipsoid(
			deck,
			Vector3.new(RADIUS * 2 - 2, 26, RADIUS * 2 - 2),
			CFrame.new(center - Vector3.new(0, 16, 0)),
			Color3.fromRGB(255, 196, 226),
			DECOR
		)
	end

	-- Big decorative balloons floating round the deck.
	local function buildScenery(arena: Model)
		local scenery = Geometry.model(arena, "Scenery")
		for index = 1, 9 do
			local angle = index / 9 * math.pi * 2 + random:NextNumber(-0.2, 0.2)
			local distance = random:NextNumber(90, 120)
			local height = random:NextNumber(5, 40)
			local diameter = random:NextNumber(14, 24)
			local position = center + Vector3.new(math.cos(angle) * distance, height, math.sin(angle) * distance)
			Geometry.ball(scenery, diameter, position, BALLOON_COLORS[index % #BALLOON_COLORS + 1], DECOR)
			Geometry.column(scenery, 30, 0.3, position - Vector3.new(0, diameter / 2 + 30, 0), WHITE, DECOR)
		end
	end

	local function launch(elapsed: number)
		local ramp = math.clamp(elapsed / RAMP_TIME, 0, 1)
		local diameter = DIAMETERS[random:NextInteger(1, #DIAMETERS)]
		local exitRadius = RADIUS + diameter / 2 + EXIT_MARGIN

		-- From a random point outside the edge, across the deck, out the other side.
		local angle = random:NextNumber(0, math.pi * 2)
		local outward = Vector3.new(math.cos(angle), 0, math.sin(angle))
		local start = center + outward * exitRadius
		local side = Vector3.new(-outward.Z, 0, outward.X)
		local aim = center + side * random:NextNumber(-AIM_SPREAD, AIM_SPREAD) * RADIUS
		local direction = MathUtil.flat(aim - start).Unit
		local _, travel = circleCrossings(center, exitRadius, start, direction)
		local laneIn, laneOut = circleCrossings(center, RADIUS, start, direction)
		if not travel or not laneIn or not laneOut then
			return
		end

		local speed = (SPEED[1] + (SPEED[2] - SPEED[1]) * ramp) * random:NextNumber(0.9, 1.1)
		if diameter >= 13 then
			speed *= 0.85 -- the big ones lumber
		end
		local hop = if elapsed >= HOP_AFTER and random:NextNumber() < HOP_CHANCE then random:NextNumber(5.5, 8) else 0

		local rules = Config.Balloons
		local lead = rules.ReplicationLead + rules.WarningTime
		local duration = travel / speed
		local balloon = Hazards.Balloon(context.Arena, {
			Origin = start + Vector3.new(0, diameter / 2, 0),
			Velocity = direction * speed,
			StartAt = context.GetServerTime() + lead,
			Duration = duration,
			Diameter = diameter,
			Hop = hop,
			HopRate = 1.1,
			Color = BALLOON_COLORS[random:NextInteger(1, #BALLOON_COLORS)],
			LaneFrom = start + direction * laneIn,
			LaneTo = start + direction * laneOut,
		})
		balloons += 1
		task.delay(lead + duration + rules.RemoveAfter, function()
			balloons -= 1
			if balloon.Parent then
				balloon:Destroy()
			end
		end)
	end

	local function setup()
		local arena = context.Arena
		buildDeck(arena)
		buildScenery(arena)
		context.SpawnAll(ArenaUtil.RingSpots(center, SPAWN_RADIUS, #context.Players))
	end

	local function start()
		running = true
		timer = INTERVAL[1] - FIRST_BALLOON
	end

	local function update(dt: number): boolean?
		context.EliminateBelow(center.Y - KILL_DEPTH)
		if not running then
			return nil
		end
		local elapsed = context.GetServerTime() - context.GetStartTime()
		local ramp = math.clamp(elapsed / RAMP_TIME, 0, 1)
		local interval = INTERVAL[1] + (INTERVAL[2] - INTERVAL[1]) * ramp
		timer += dt
		while timer >= interval do
			timer -= interval
			local count = if elapsed >= TRIPLE_AFTER then 3 elseif elapsed >= DOUBLE_AFTER then 2 else 1
			for _ = 1, count do
				if balloons < MAX_BALLOONS then
					launch(elapsed)
				end
			end
		end
		return nil
	end

	return {
		Setup = setup,
		Start = start,
		Update = update,
		End = function()
			running = false
		end,
		GetQualified = context.DefaultQualified,
	}
end

return BalloonBarrage
