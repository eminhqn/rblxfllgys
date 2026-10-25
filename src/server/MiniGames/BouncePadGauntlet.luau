--!strict
-- BOUNCE PAD GAUNTLET (Race)
-- Everything hangs over a pit of bright green goo:
--   1. Trampoline Hop: rows of trampolines; some rows slide side to side or back and forth.
--   2. Sliding Platforms: platforms gliding sideways and back and forth. Time your jumps.
--   3. Big Bounce: giant pads launch you up to a high platform guarded by a spinner, and the
--      finish line is just past it.
-- Land on a trampoline and it bounces you, so keep holding forwards. Fall in the goo and you're
-- back at your last checkpoint.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Theme = require(ReplicatedStorage.Shared.Theme)

local Geometry = require(script.Parent.Parent.Builders.Geometry)
local Hazards = require(script.Parent.Parent.Builders.Hazards)
local RaceKit = require(script.Parent.Parent.Match.RaceKit)
local Types = require(script.Parent.Parent.Match.Types)

local DURATION = 120
local COURSE_WIDTH = 56
local GOO_LEVEL = -10
local KILL_ABOVE_GOO = 1 -- respawn once a Bloblet's middle sinks this low (it's half in the goo)

local TRAMPOLINE_POWER = 70
local TRAMPOLINE_DIAMETER = 10
local TRAMPOLINE_TOP = -1
local BIG_BOUNCE_POWER = 105
local HIGH_LEVEL = 24

type TrampolineRow = {
	Z: number,
	Xs: { number },
	Travel: Vector3?,
	Speed: number?,
}

type PlatformRow = {
	Z: number,
	Xs: { number },
	Size: Vector3,
	Travel: Vector3,
	Speed: number,
	Phase: number,
	Color: Color3,
}

local TRAMPOLINE_ROWS: { TrampolineRow } = {
	{ Z = 30, Xs = { -21, -7, 7, 21 } },
	{ Z = 50, Xs = { -14, 0, 14 }, Travel = Vector3.new(7, 0, 0), Speed = 1.2 },
	{ Z = 70, Xs = { -21, -7, 7, 21 } },
	{ Z = 90, Xs = { -14, 0, 14 }, Travel = Vector3.new(0, 0, 4), Speed = 1.4 },
}

local PLATFORM_ROWS: { PlatformRow } = {
	{
		Z = 132,
		Xs = { -12, 12 },
		Size = Vector3.new(12, 1.5, 10),
		Travel = Vector3.new(12, 0, 0),
		Speed = 1.0,
		Phase = 0,
		Color = Theme.Colors.Aqua,
	},
	{
		Z = 150,
		Xs = { 0 },
		Size = Vector3.new(30, 1.5, 10),
		Travel = Vector3.new(0, 0, 4),
		Speed = 1.3,
		Phase = 0,
		Color = Theme.Colors.Yellow,
	},
	{
		Z = 168,
		Xs = { -12, 12 },
		Size = Vector3.new(12, 1.5, 10),
		Travel = Vector3.new(12, 0, 0),
		Speed = 1.3,
		Phase = math.pi,
		Color = Theme.Colors.Pink,
	},
	{
		Z = 186,
		Xs = { -18, 0, 18 },
		Size = Vector3.new(10, 1.5, 10),
		Travel = Vector3.new(6, 0, 0),
		Speed = 1.8,
		Phase = 0,
		Color = Theme.Colors.Lime,
	},
}

local PAD_COLOR = Color3.fromRGB(255, 214, 236)
local HIGH_COLOR = Color3.fromRGB(190, 236, 255)
local POST_COLOR = Color3.fromRGB(255, 255, 255)

local BouncePadGauntlet = {}

BouncePadGauntlet.Info = {
	Id = "BouncePadGauntlet",
	DisplayName = "Bounce Pad Gauntlet",
	Type = "Race",
	Rules = "Bounce across the goo, ride the sliding platforms and reach the finish line!",
	Duration = DURATION,
	MinPlayers = 1,
} :: Types.MiniGameInfo

function BouncePadGauntlet.new(context: Types.RoundContext): Types.MiniGame
	local center = context.Origin.Position
	local random = context.Random
	local race = RaceKit.new(context, { KillHeight = center.Y + GOO_LEVEL + KILL_ABOVE_GOO })

	-- Ground-level CFrame at an offset from the centre, facing forwards (+Z).
	local function at(x: number, y: number, z: number): CFrame
		local position = center + Vector3.new(x, y, z)
		return CFrame.lookAt(position, position + Vector3.zAxis)
	end

	-- A trampoline on a post rising out of the goo.
	local function trampoline(parent: Instance, x: number, z: number)
		local padBottom = TRAMPOLINE_TOP - 1.25
		local postBottom = GOO_LEVEL - 2
		Geometry.column(
			parent,
			padBottom - postBottom,
			3,
			center + Vector3.new(x, postBottom, z),
			POST_COLOR,
			{ Name = "Post" }
		)
		Hazards.BouncePad(parent, center + Vector3.new(x, padBottom, z), {
			Diameter = TRAMPOLINE_DIAMETER,
			Power = TRAMPOLINE_POWER,
		})
	end

	local function buildTrampolines(arena: Model)
		local section = Geometry.model(arena, "TrampolineHop")
		for rowIndex, row in TRAMPOLINE_ROWS do
			for index, x in row.Xs do
				local travel = row.Travel
				if travel then
					-- Neighbours swing out of step so the row opens and closes.
					local phase = (index + rowIndex) * 1.3
					Hazards.Mover(section, travel, row.Speed or 1, phase, function(model: Model)
						trampoline(model, x, row.Z)
					end)
				else
					trampoline(section, x, row.Z)
				end
			end
		end
	end

	local function buildSlidingPlatforms(arena: Model)
		local section = Geometry.model(arena, "SlidingPlatforms")
		for _, row in PLATFORM_ROWS do
			for _, x in row.Xs do
				Hazards.MovingPlatform(section, at(x, 0, row.Z), row.Size, row.Color, row.Travel, row.Speed, row.Phase)
			end
		end
	end

	local function buildBigBounce(arena: Model)
		local section = Geometry.model(arena, "BigBounce")
		-- Checkpoint 2 floor, with giant pads set into its far end.
		Hazards.Platform(section, at(0, 0, 212), Vector3.new(COURSE_WIDTH, 4, 28), PAD_COLOR, "Checkpoint2Pad")
		for _, x in { -18, -6, 6, 18 } do
			Hazards.BouncePad(section, center + Vector3.new(x, -1, 219), {
				Diameter = 9,
				Power = BIG_BOUNCE_POWER,
				Color = Theme.Colors.Purple,
			})
		end
		Geometry.sign(section, "BIG BOUNCE!", center + Vector3.new(-24, 0, 214), 13, 3, Theme.Colors.Purple, 6)

		-- The high platform with its spinner, leading straight onto the finish.
		Hazards.Platform(section, at(0, HIGH_LEVEL, 253), Vector3.new(40, 4, 30), HIGH_COLOR, "HighPad")
		Hazards.Spinner(section, center + Vector3.new(0, HIGH_LEVEL, 253), { ArmLength = 30, Speed = 1.6, Mat = false })
	end

	local function buildScenery(arena: Model)
		local scenery = Geometry.model(arena, "Scenery")
		Hazards.Goo(scenery, CFrame.new(center + Vector3.new(0, GOO_LEVEL, 145)), Vector2.new(130, 340), random)
		for _, corner in { Vector2.new(-62, 16), Vector2.new(62, 16), Vector2.new(-62, 290), Vector2.new(62, 290) } do
			local base = center + Vector3.new(corner.X, GOO_LEVEL - 2, corner.Y)
			for index = 0, 5 do
				Geometry.column(
					scenery,
					6,
					7,
					base + Vector3.new(0, index * 6, 0),
					if index % 2 == 0 then Theme.Colors.Pink else POST_COLOR,
					{ Name = "CandyPillar" }
				)
			end
			Geometry.ball(scenery, 9, base + Vector3.new(0, 38, 0), Theme.Colors.Yellow, { Name = "PillarCap" })
		end
		Geometry.sign(scenery, "BOUNCE ACROSS!", center + Vector3.new(-24, 0, 14), 14, 3, Theme.Colors.Pink, 6)
	end

	local function setup()
		local arena = context.Arena
		race.BuildStart(at(0, 0, 0), COURSE_WIDTH, 36)
		buildTrampolines(arena)
		Hazards.Platform(arena, at(0, 0, 113), Vector3.new(COURSE_WIDTH, 4, 14), PAD_COLOR, "Checkpoint1Pad")
		race.AddCheckpoint(at(0, 0, 113), Vector2.new(COURSE_WIDTH, 14))
		buildSlidingPlatforms(arena)
		buildBigBounce(arena)
		race.AddCheckpoint(at(0, 0, 205), Vector2.new(COURSE_WIDTH, 14))
		race.BuildFinish(at(0, HIGH_LEVEL, 286), 40, 36)
		buildScenery(arena)
		race.SpawnPlayers()
	end

	return {
		Setup = setup,
		Start = race.Start,
		Update = function(_dt: number): boolean?
			race.Update()
			return nil
		end,
		End = race.Stop,
		GetQualified = context.DefaultQualified,
	}
end

return BouncePadGauntlet
