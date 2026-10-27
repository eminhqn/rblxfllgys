--!strict
-- CONVEYOR CANYON (Race)
-- A course of conveyor belts strung across a canyon, with crates raining down the whole way:
--   1. Belt Field: seven lanes running forwards and backwards. The pattern flips halfway, so
--      you have to change lanes.
--   2. Side Sweepers: three belts running sideways towards the drop, with gaps to jump.
--   3. Treadmill Ramps: three uphill belts running downhill at different speeds.
--   4. Crate Bridge: a narrow bridge of sideways belts with a spinner in the middle.
-- Crates flash a target circle where they'll land, drop, ride the belt they land on and smash at
-- its end. Touching one knocks you over. Fall off and you're back at your last checkpoint. Cross
-- the finish line to qualify.

local Geometry = require(script.Parent.Parent.Builders.Geometry)
local Hazards = require(script.Parent.Parent.Builders.Hazards)
local CrateDropper = require(script.Parent.Parent.Match.CrateDropper)
local RaceKit = require(script.Parent.Parent.Match.RaceKit)
local Types = require(script.Parent.Parent.Match.Types)

local DURATION = 120
local COURSE_WIDTH = 56
local LANE_WIDTH = 8
local CRATE_INTERVAL = 0.32 -- seconds between crates over the whole course
local KILL_DEPTH = 22 -- below the start pad

-- Lane speeds for the two halves of the Belt Field (positive = forwards).
local FIELD_SPEEDS = {
	{ 14, -10, 18, -12, 16, -10, 14 },
	{ -10, 16, -12, 14, -10, 18, -12 },
}
local SWEEPER_SPEEDS = { 16, -18, 20 } -- positive = towards +X
local RAMP_SPEEDS = { -9, -15, -9 } -- negative = downhill

local FORWARD_SLATS = Color3.fromRGB(150, 236, 110) -- Belt Field lanes that help you
local BACKWARD_SLATS = Color3.fromRGB(255, 120, 170) -- ...and the ones that fight you
local ROCK = Color3.fromRGB(242, 160, 120)
local ROCK_BAND = Color3.fromRGB(255, 196, 150)
local PAD_COLOR = Color3.fromRGB(255, 214, 236)
local SPINNER_PAD = Color3.fromRGB(190, 236, 255)

local ConveyorCanyon = {}

ConveyorCanyon.Info = {
	Id = "ConveyorCanyon",
	DisplayName = "Conveyor Canyon",
	Type = "Race",
	Rules = "Ride the right belts, dodge the falling crates and cross the finish line!",
	Duration = DURATION,
	MinPlayers = 1,
} :: Types.MiniGameInfo

function ConveyorCanyon.new(context: Types.RoundContext): Types.MiniGame
	local center = context.Origin.Position
	local race = RaceKit.new(context, { KillHeight = center.Y - KILL_DEPTH })
	local crateZones: { CrateDropper.Zone } = {}
	local dropper: CrateDropper.Dropper? = nil

	-- Ground-level CFrame at an offset from the centre, facing `direction` (default: forwards, +Z).
	local function at(x: number, y: number, z: number, direction: Vector3?): CFrame
		local position = center + Vector3.new(x, y, z)
		return CFrame.lookAt(position, position + (direction or Vector3.zAxis))
	end

	local function belt(
		parent: Instance,
		top: CFrame,
		width: number,
		length: number,
		speed: number,
		options: Hazards.ConveyorOptions?
	)
		Hazards.Conveyor(parent, top, Vector2.new(width, length), speed, options)
		table.insert(crateZones, { Top = top, Size = Vector2.new(width, length), SlideSpeed = speed })
	end

	local function buildBeltField(arena: Model)
		local field = Geometry.model(arena, "BeltField")
		local halfLength = 37
		for half, speeds in FIELD_SPEEDS do
			local z = 18 + halfLength * (half - 0.5)
			for lane, speed in speeds do
				local x = (lane - (#speeds + 1) / 2) * LANE_WIDTH
				belt(field, at(x, 0, z), LANE_WIDTH, halfLength, speed, {
					SlatColor = if speed > 0 then FORWARD_SLATS else BACKWARD_SLATS,
				})
			end
		end
	end

	local function buildSweepers(arena: Model)
		local sweepers = Geometry.model(arena, "SideSweepers")
		for index, speed in SWEEPER_SPEEDS do
			local z = 117 + (index - 1) * 17
			-- Facing +X with a positive speed (or -X with a negative one) carries you that way.
			local direction = if speed > 0 then Vector3.xAxis else -Vector3.xAxis
			belt(sweepers, at(0, 0, z, direction), 12, COURSE_WIDTH, math.abs(speed))
		end
		Hazards.Platform(sweepers, at(0, 0, 166), Vector3.new(COURSE_WIDTH, 4, 8), PAD_COLOR, "Landing")
	end

	local function buildRamps(arena: Model)
		local ramps = Geometry.model(arena, "TreadmillRamps")
		local bottom, top = Vector3.new(0, 0, 170), Vector3.new(0, 14, 222)
		local slope = (top - bottom).Unit
		local length = (top - bottom).Magnitude
		local middle = (bottom + top) / 2
		for index, speed in RAMP_SPEEDS do
			local x = (index - 2) * 20
			local position = center + middle + Vector3.new(x, 0, 0)
			belt(ramps, CFrame.lookAt(position, position + slope), 16, length, speed, { Rails = index == 2 })
		end
	end

	local function buildBridge(arena: Model)
		local bridge = Geometry.model(arena, "CrateBridge")
		local width = 18
		belt(bridge, at(0, 14, 242, Vector3.xAxis), 12, width, 10)
		belt(bridge, at(0, 14, 254, -Vector3.xAxis), 12, width, 12)
		Hazards.Platform(bridge, at(0, 14, 275), Vector3.new(30, 4, 30), SPINNER_PAD, "SpinnerPad")
		Hazards.Spinner(bridge, center + Vector3.new(0, 14, 275), { ArmLength = 26, Speed = 1.5, Mat = false })
		belt(bridge, at(0, 14, 296, Vector3.xAxis), 12, width, 12)
	end

	-- Sandstone cliffs either side and a goo river far below (decoration).
	local function buildCanyon(arena: Model)
		local canyon = Geometry.model(arena, "Canyon")
		for _, side in { -1, 1 } do
			for index = 0, 5 do
				local z = -30 + index * 66
				local height = 70 + (index % 3) * 12
				local x = side * (78 + (index % 2) * 8)
				Geometry.block(
					canyon,
					Vector3.new(40, height, 64),
					CFrame.new(center + Vector3.new(x, -50 + height / 2, z)),
					ROCK,
					{ Name = "Cliff", Material = Enum.Material.Sandstone }
				)
				Geometry.block(
					canyon,
					Vector3.new(40.4, 3, 64.4),
					CFrame.new(center + Vector3.new(x, -50 + height * 0.62, z)),
					ROCK_BAND,
					{ Name = "CliffBand", CanCollide = false, CastShadow = false }
				)
			end
		end
		Hazards.Goo(canyon, CFrame.new(center + Vector3.new(0, -40, 160)), Vector2.new(140, 440), context.Random)
	end

	-- Bots' route through a stretch (points on the floor, from the centre).
	local function botRoute(points: { Vector3 })
		for _, offset in points do
			race.AddBotPoint(center + offset)
		end
	end

	local function setup()
		local arena = context.Arena
		race.BuildStart(at(0, 0, 0), COURSE_WIDTH, 36)
		buildBeltField(arena)
		-- The fastest forward lane in each half of the Belt Field.
		botRoute({ Vector3.new(-8, 0, 22), Vector3.new(-8, 0, 52), Vector3.new(0, 0, 58), Vector3.new(0, 0, 90) })
		Hazards.Platform(arena, at(0, 0, 99), Vector3.new(COURSE_WIDTH, 4, 14), PAD_COLOR, "Checkpoint1Pad")
		race.AddCheckpoint(at(0, 0, 99), Vector2.new(COURSE_WIDTH, 14))
		buildSweepers(arena)
		buildRamps(arena)
		-- Straight over the sweepers (jumping the gaps), then up a slow ramp.
		botRoute({
			Vector3.new(0, 0, 104),
			Vector3.new(0, 0, 117),
			Vector3.new(0, 0, 134),
			Vector3.new(0, 0, 151),
			Vector3.new(0, 0, 166),
			Vector3.new(-20, 0, 173),
			Vector3.new(-20, 14, 220),
		})
		Hazards.Platform(arena, at(0, 14, 229), Vector3.new(COURSE_WIDTH, 4, 14), PAD_COLOR, "Checkpoint2Pad")
		race.AddCheckpoint(at(0, 14, 229), Vector2.new(COURSE_WIDTH, 14))
		buildBridge(arena)
		botRoute({
			Vector3.new(0, 14, 234),
			Vector3.new(0, 14, 242),
			Vector3.new(0, 14, 254),
			Vector3.new(0, 14, 266),
			Vector3.new(0, 14, 284),
			Vector3.new(0, 14, 296),
		})
		race.BuildFinish(at(0, 14, 322), 40, 40)
		buildCanyon(arena)
		dropper = CrateDropper.new(context, crateZones, CRATE_INTERVAL)
		race.SpawnPlayers()
	end

	local function update(dt: number): boolean?
		race.Update()
		local crates = dropper
		if crates then
			crates.Update(dt)
		end
		return nil
	end

	return {
		Setup = setup,
		Start = race.Start,
		Update = update,
		End = function()
			dropper = nil
			race.Stop()
		end,
		GetQualified = context.DefaultQualified,
		BotGoal = race.BotGoal,
	}
end

return ConveyorCanyon
