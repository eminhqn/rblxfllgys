--!strict
-- RISING TIDE (Survival)
-- Water rises steadily around a tall candy pillar. Climb the spiral scaffolding (every fourth
-- plank wobbles, every sixth gap is wider) and stay above it. The round ends once only the
-- qualifying share is left, or when time runs out.
--
-- Clients animate the water from the shared clock (Riser tag) and the server uses the same
-- formula to decide who is under, so what you see is what counts.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local HazardMath = require(Shared.HazardMath)
local Tags = require(Shared.Tags)
local Theme = require(Shared.Theme)

local Geometry = require(script.Parent.Parent.Builders.Geometry)
local ArenaUtil = require(script.Parent.Parent.Match.ArenaUtil)
local Types = require(script.Parent.Parent.Match.Types)

local DURATION = 70
local WATER_RATE = 1.5 -- studs per second
local WATER_START = -3 -- surface height relative to the island top when the round starts
local WATER_MAX_RISE = 105
local DROWN_MARGIN = 0.9 -- your middle this close to the surface means you're under

local STEP_RISE = 4.2
local STEP_COUNT = 25
local STEP_RADIUS = 15
local STEP_ANGLE = math.rad(32)
local WIDE_STEP_ANGLE = math.rad(46)
local PATHS = 3
local PLANK_SIZE = Vector3.new(7, 1.2, 7)
local PILLAR_DIAMETER = 10
local ISLAND_DIAMETER = 64
local SPAWN_RADIUS = 24

local WHITE = Color3.fromRGB(255, 255, 255)
local ISLAND_COLOR = Color3.fromRGB(255, 214, 170)
local WATER_COLOR = Color3.fromRGB(60, 190, 255)
local PLANK_COLORS = { Theme.Colors.Yellow, Theme.Colors.Pink, Theme.Colors.Aqua, Theme.Colors.Lime }

local RisingTide = {}

RisingTide.Info = {
	Id = "RisingTide",
	DisplayName = "Rising Tide",
	Type = "Survival",
	Rules = "The water is rising! Climb the wobbly scaffolding and stay above it.",
	Duration = DURATION,
	MinPlayers = 1,
} :: Types.MiniGameInfo

function RisingTide.new(context: Types.RoundContext): Types.MiniGame
	local center = context.Origin.Position
	local waterStartTop = center.Y + WATER_START
	local water: BasePart? = nil

	local function buildScaffolding(arena: Model)
		local summitTop = center.Y + STEP_RISE * (STEP_COUNT + 1)
		local pillarHeight = summitTop - center.Y - 1.2
		local segment = 7
		local segments = math.ceil(pillarHeight / segment)
		for index = 0, segments - 1 do
			local height = math.min(segment, pillarHeight - index * segment)
			Geometry.column(
				arena,
				height,
				PILLAR_DIAMETER,
				center + Vector3.new(0, index * segment, 0),
				if index % 2 == 0 then Theme.Colors.Pink else WHITE,
				{ Name = "Pillar" }
			)
		end
		-- Safe summit on top of the pillar.
		Geometry.column(arena, 1.2, 22, center + Vector3.new(0, summitTop - center.Y - 1.2, 0), WHITE, {
			Name = "Summit",
		})

		for path = 0, PATHS - 1 do
			local angle = path * (math.pi * 2 / PATHS)
			for step = 1, STEP_COUNT do
				angle += if step % 6 == 0 then WIDE_STEP_ANGLE else STEP_ANGLE
				local top = center.Y + STEP_RISE * step
				local direction = Vector3.new(math.cos(angle), 0, math.sin(angle))
				local position = Vector3.new(center.X, top - PLANK_SIZE.Y / 2, center.Z) + direction * STEP_RADIUS
				local facing = Vector3.new(center.X, position.Y, center.Z)
				local plank = Geometry.block(
					arena,
					PLANK_SIZE,
					CFrame.lookAt(position, facing),
					PLANK_COLORS[(step + path) % #PLANK_COLORS + 1],
					{ Name = "Plank" }
				)
				if step % 4 == 0 then
					plank:SetAttribute("Amplitude", 0.22)
					plank:SetAttribute("Speed", context.Random:NextNumber(1.3, 2))
					plank:SetAttribute("Phase", context.Random:NextNumber(0, math.pi * 2))
					CollectionService:AddTag(plank, Tags.Wobbler)
				end
				-- Support beam back to the pillar (decorative).
				local beamY = top - center.Y - 1.6
				Geometry.tube(
					arena,
					center + direction * (PILLAR_DIAMETER / 2) + Vector3.new(0, beamY, 0),
					center + direction * (STEP_RADIUS - PLANK_SIZE.X / 2) + Vector3.new(0, beamY, 0),
					0.7,
					WHITE,
					{ Name = "Beam", CanCollide = false, CastShadow = false }
				)
			end
		end
	end

	local function setup()
		local arena = context.Arena
		Geometry.column(arena, 4, ISLAND_DIAMETER, center - Vector3.new(0, 4, 0), ISLAND_COLOR, { Name = "Island" })
		buildScaffolding(arena)

		local waterPart = Geometry.block(
			arena,
			Vector3.new(300, 8, 300),
			CFrame.new(center.X, waterStartTop - 4, center.Z),
			WATER_COLOR,
			{ Name = "Water", Transparency = 0.3, CanCollide = false, CastShadow = false }
		)
		waterPart:SetAttribute("StartTime", 0)
		waterPart:SetAttribute("Rate", WATER_RATE)
		waterPart:SetAttribute("MaxRise", WATER_MAX_RISE)
		CollectionService:AddTag(waterPart, Tags.Riser)
		water = waterPart

		context.SpawnAll(ArenaUtil.RingSpots(center, SPAWN_RADIUS, #context.Players))
	end

	local function start()
		local waterPart = water
		if waterPart then
			-- Every client starts raising its water from this moment.
			waterPart:SetAttribute("StartTime", context.GetStartTime())
		end
	end

	local function waterLevel(): number
		local rise = HazardMath.RiserOffset(context.GetStartTime(), WATER_RATE, WATER_MAX_RISE, context.GetServerTime())
		return waterStartTop + rise
	end

	local function update(_dt: number): boolean?
		context.EliminateBelow(waterLevel() + DROWN_MARGIN)
		return nil
	end

	return {
		Setup = setup,
		Start = start,
		Update = update,
		End = function() end,
		GetQualified = context.DefaultQualified,
	}
end

return RisingTide
