--!strict
-- TUMBLE TOWER (Race)
-- Climb the outside of a giant candy tower to the crown on top. Four ledges zigzag up its face,
-- each one a level higher and a little further back:
--   1. Candy Steps: floating steps up, then two platforms gliding back and forth over a gap.
--   2. Hammer Hall: a long ramp with giant candy hammers swinging across it.
--   3. Spike Stairs: steps with spike traps that pop up and sink on a timer (they peek out just
--      before they rise), half-steps of spikes that never go down, and two traps to time at the top.
--   4. Sky Lifts: platforms riding up and down, two more hammers and a gliding last platform.
-- The corner landings between ledges are checkpoints. Fall off and you're back at the last one.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Theme = require(Shared.Theme)

local Geometry = require(script.Parent.Parent.Builders.Geometry)
local Hazards = require(script.Parent.Parent.Builders.Hazards)
local RaceKit = require(script.Parent.Parent.Match.RaceKit)
local Types = require(script.Parent.Parent.Match.Types)

local DURATION = 150
local KILL_DEPTH = 20
local LEDGE_LENGTH = 108 -- each ledge runs from x = -54 to x = 54
local LEDGE_RISE = 16 -- each ledge ends this much higher than it starts
local LEDGE_STEP_BACK = 10 -- and the next one is this much further back (+Z)
local LEDGE_WIDTH = 14
local LANDING_DEPTH = 18
local HAMMER_DROP = 16 -- pivot height above the floor under it (arm 13, head 3 above the floor)
local GLASS_HEIGHT = 4

local CANDY_COLORS = {
	Color3.fromRGB(255, 120, 180),
	Color3.fromRGB(120, 200, 255),
	Color3.fromRGB(255, 205, 80),
	Color3.fromRGB(150, 120, 255),
	Color3.fromRGB(120, 220, 140),
}
local LANDING_COLOR = Color3.fromRGB(255, 236, 246)
local TOWER_PINK = Color3.fromRGB(255, 176, 210)
local TOWER_STRIPE = Color3.fromRGB(255, 240, 248)
local WHITE = Color3.fromRGB(255, 255, 255)

local DECOR: Geometry.PartOptions = { Name = "Decor", CanCollide = false, CastShadow = false }

local TumbleTower = {}

TumbleTower.Info = {
	Id = "TumbleTower",
	DisplayName = "Tumble Tower",
	Type = "Race",
	Rules = "Climb to the crown on top! Watch out for swinging hammers and popping spikes.",
	Duration = DURATION,
	MinPlayers = 1,
} :: Types.MiniGameInfo

function TumbleTower.new(context: Types.RoundContext): Types.MiniGame
	local center = context.Origin.Position
	local random = context.Random
	local race = RaceKit.new(context, { KillHeight = center.Y - KILL_DEPTH })

	-- Ledge `ledge` (1 to 4): which way it runs along X, and where it is.
	local function ledgeDir(ledge: number): number
		return if ledge % 2 == 1 then 1 else -1
	end

	-- A point `s` studs along a ledge (from its start corner), `rise` above the ledge's start height
	-- and `across` towards the tower (+Z).
	local function ledgePoint(ledge: number, s: number, rise: number, across: number?): Vector3
		local dir = ledgeDir(ledge)
		return center
			+ Vector3.new(
				dir * (-LEDGE_LENGTH / 2 + s),
				(ledge - 1) * LEDGE_RISE + rise,
				(ledge - 1) * LEDGE_STEP_BACK + (across or 0)
			)
	end

	-- A ground CFrame on a ledge, looking along it.
	local function ledgeFrame(ledge: number, s: number, rise: number, across: number?): CFrame
		local point = ledgePoint(ledge, s, rise, across)
		return CFrame.lookAt(point, point + Vector3.new(ledgeDir(ledge), 0, 0))
	end

	local function pick<T>(list: { T }): T
		return list[random:NextInteger(1, #list)]
	end

	-- A flat piece of ledge from `from` to `to` (studs along it) at `rise`.
	local function walkway(parent: Instance, ledge: number, from: number, to: number, rise: number, color: Color3?)
		local top = ledgeFrame(ledge, (from + to) / 2, rise)
		Hazards.Platform(parent, top, Vector3.new(LEDGE_WIDTH, 4, to - from), color or pick(CANDY_COLORS), "Walkway")
	end

	-- A glass rail along the tower side of a ledge, so not every knock sends you over.
	local function backGlass(
		parent: Instance,
		ledge: number,
		from: number,
		to: number,
		riseFrom: number,
		riseTo: number
	)
		local low = ledgePoint(ledge, from, riseFrom, LEDGE_WIDTH / 2 - 0.3)
		local high = ledgePoint(ledge, to, riseTo, LEDGE_WIDTH / 2 - 0.3)
		local middle = (low + high) / 2 + Vector3.new(0, GLASS_HEIGHT / 2, 0)
		Geometry.block(
			parent,
			Vector3.new(0.6, GLASS_HEIGHT, (high - low).Magnitude),
			CFrame.lookAt(middle, middle + (high - low)),
			Theme.Colors.Aqua,
			{ Name = "Glass", Transparency = 0.6, CastShadow = false }
		)
	end

	-- A corner landing between ledge `ledge` and the next one: a checkpoint.
	local function landing(arena: Model, ledge: number)
		local nearEdge = ledgePoint(ledge, LEDGE_LENGTH + LANDING_DEPTH / 2, LEDGE_RISE)
		local width = LEDGE_STEP_BACK + LEDGE_WIDTH -- reaches from this ledge to the next
		local middle = nearEdge + Vector3.new(0, 0, LEDGE_STEP_BACK / 2)
		local top = CFrame.lookAt(middle, middle + Vector3.new(ledgeDir(ledge), 0, 0))
		Hazards.Platform(arena, top, Vector3.new(width, 4, LANDING_DEPTH), LANDING_COLOR, "Landing")
		race.AddCheckpoint(top, Vector2.new(width, LANDING_DEPTH))
		-- Glass round the outside corner.
		local outer = top * CFrame.new(0, GLASS_HEIGHT / 2, -LANDING_DEPTH / 2 + 0.3)
		Geometry.block(arena, Vector3.new(width, GLASS_HEIGHT, 0.6), outer, Theme.Colors.Aqua, {
			Name = "Glass",
			Transparency = 0.6,
			CastShadow = false,
		})
	end

	-- A hammer swinging across a ledge, held up from the outside (the next ledge is right behind).
	local function hammer(parent: Instance, ledge: number, s: number, floorRise: number, phase: number)
		local pivot = ledgeFrame(ledge, s, floorRise + HAMMER_DROP)
		Hazards.Hammer(parent, pivot, {
			Amplitude = 1.15,
			Speed = 2.0,
			Phase = phase,
			Color = pick({ Theme.Colors.Pink, Theme.Colors.Purple, Theme.Colors.Orange }),
			-- The post goes on the open (-Z) side: that's the pivot's RightVector side when the
			-- ledge runs towards -X.
			Side = -ledgeDir(ledge),
		})
	end

	-- 1. Candy Steps.
	local function buildSteps(arena: Model)
		local section = Geometry.model(arena, "CandySteps")
		-- A wide apron off the start pad that narrows onto the ledge.
		local apron = ledgeFrame(1, 9, 0, -10)
		Hazards.Platform(section, apron, Vector3.new(48, 4, 18), LANDING_COLOR, "Apron")
		for index = 1, 5 do
			local s = 25 + (index - 1) * 7.5
			Hazards.Platform(
				section,
				ledgeFrame(1, s, 2.6 * index),
				Vector3.new(LEDGE_WIDTH - 2, 3, 6),
				CANDY_COLORS[(index - 1) % #CANDY_COLORS + 1],
				"Step"
			)
		end
		-- Two platforms gliding together along the ledge over a gap.
		for _, s in { 68, 84 } do
			Hazards.MovingPlatform(
				section,
				ledgeFrame(1, s, 14),
				Vector3.new(10, 2, 9),
				Theme.Colors.Yellow,
				Vector3.new(6, 0, 0),
				1.1,
				0
			)
		end
		walkway(section, 1, 96, LEDGE_LENGTH, LEDGE_RISE)
		landing(arena, 1)
	end

	-- 2. Hammer Hall.
	local function buildHammers(arena: Model)
		local section = Geometry.model(arena, "HammerHall")
		local rampEnd = 96
		local low = ledgePoint(2, 0, 0)
		local high = ledgePoint(2, rampEnd, LEDGE_RISE)
		Hazards.Platform(
			section,
			CFrame.lookAt((low + high) / 2, high),
			Vector3.new(LEDGE_WIDTH - 2, 4, (high - low).Magnitude),
			Color3.fromRGB(255, 196, 222),
			"Ramp"
		)
		-- (It stops short of the end, where the next ledge starts just above.)
		backGlass(section, 2, 0, 80, 0, LEDGE_RISE * 80 / rampEnd)
		for index, s in { 16, 34, 52, 70, 88 } do
			hammer(section, 2, s, LEDGE_RISE * s / rampEnd, index * 1.3)
		end
		walkway(section, 2, rampEnd, LEDGE_LENGTH, LEDGE_RISE)
		landing(arena, 2)
	end

	-- 3. Spike Stairs.
	local function buildSpikes(arena: Model)
		local section = Geometry.model(arena, "SpikeStairs")
		walkway(section, 3, 0, 16, 0)
		for index = 1, 6 do
			local s = 16 + (index - 0.5) * 10
			local rise = 2.4 * index
			local top = ledgeFrame(3, s, rise)
			Hazards.Platform(
				section,
				top,
				Vector3.new(LEDGE_WIDTH - 2, 3, 10),
				CANDY_COLORS[index % #CANDY_COLORS + 1],
				"Step"
			)
			if index % 2 == 1 then
				-- A trap across the middle of the step, popping up on a timer.
				Hazards.Spikes(section, top, Vector2.new(LEDGE_WIDTH - 2, 5), {
					Period = 3,
					UpTime = 1.3,
					Phase = index * 0.9,
				})
			else
				-- Spikes that never go down on one half: take the other.
				local side = if index % 4 == 0 then 1 else -1
				Hazards.Spikes(section, top * CFrame.new(side * 3, 0, 0), Vector2.new(5.5, 8))
			end
		end
		walkway(section, 3, 76, LEDGE_LENGTH, LEDGE_RISE)
		-- Two traps across the whole way at the top: time them.
		for index, s in { 86, 98 } do
			Hazards.Spikes(section, ledgeFrame(3, s, LEDGE_RISE), Vector2.new(LEDGE_WIDTH, 4), {
				Period = 2.4,
				UpTime = 1.0,
				Phase = index * 1.2,
			})
		end
		landing(arena, 3)
	end

	-- 4. Sky Lifts, then the finish on top of the tower.
	local function buildLifts(arena: Model)
		local section = Geometry.model(arena, "SkyLifts")
		walkway(section, 4, 0, 12, 0)
		for index, s in { 20, 34, 48 } do
			Hazards.MovingPlatform(
				section,
				ledgeFrame(4, s, 3 + (index - 1) * 4),
				Vector3.new(10, 2, 10),
				CANDY_COLORS[index],
				Vector3.new(0, 3, 0),
				1.3,
				(index - 1) * 2.1
			)
		end
		walkway(section, 4, 57, 80, 14)
		backGlass(section, 4, 57, 80, 14, 14)
		hammer(section, 4, 63, 14, 0)
		hammer(section, 4, 74, 14, 1.6)
		Hazards.MovingPlatform(
			section,
			ledgeFrame(4, 88, 15),
			Vector3.new(10, 2, 10),
			Theme.Colors.Yellow,
			Vector3.new(-3, 0, 0),
			1.2,
			0
		)
		local finishDepth = 24
		local entry = ledgePoint(4, 98 + finishDepth / 2, LEDGE_RISE + 2)
		race.BuildFinish(CFrame.lookAt(entry, entry + Vector3.new(ledgeDir(4), 0, 0)), 30, finishDepth)
	end

	-- The tower itself behind the course, with candy stripes and round windows (nothing here is
	-- in the way), plus clouds and lollipops round it.
	local function buildScenery(arena: Model)
		local scenery = Geometry.model(arena, "Scenery")
		local towerBottom = center.Y - 60
		local towerTop = center.Y + 4 * LEDGE_RISE + 10
		local towerHeight = towerTop - towerBottom
		local towerCenter = center + Vector3.new(0, (towerBottom + towerTop) / 2 - center.Y, 4 * LEDGE_STEP_BACK + 30)
		Geometry.block(scenery, Vector3.new(150, towerHeight, 50), CFrame.new(towerCenter), TOWER_PINK, DECOR)
		for band = 0, math.floor(towerHeight / 12) do
			local y = towerBottom + band * 12 + 3
			Geometry.block(
				scenery,
				Vector3.new(151, 2.5, 51),
				CFrame.new(towerCenter.X, y, towerCenter.Z),
				TOWER_STRIPE,
				DECOR
			)
		end
		for row = 0, 5 do
			for column = -3, 3 do
				local spot = Vector3.new(towerCenter.X + column * 20, towerBottom + 20 + row * 22, towerCenter.Z - 25.4)
				Geometry.ellipsoid(scenery, Vector3.new(7, 9, 1), CFrame.new(spot), Theme.Colors.Purple, DECOR)
			end
		end
		-- A giant cherry on top.
		Geometry.ball(
			scenery,
			26,
			Vector3.new(towerCenter.X, towerTop + 10, towerCenter.Z),
			Color3.fromRGB(226, 38, 72),
			DECOR
		)
		for _ = 1, 18 do
			local spot = center
				+ Vector3.new(random:NextNumber(-150, 150), random:NextNumber(-40, 90), random:NextNumber(-120, -40))
			Geometry.ellipsoid(
				scenery,
				Vector3.new(random:NextNumber(18, 34), random:NextNumber(8, 14), random:NextNumber(14, 26)),
				CFrame.new(spot),
				WHITE,
				DECOR
			)
		end
		for index = 0, 5 do
			local x = -120 + index * 48
			local stick = center + Vector3.new(x, -55, -70)
			Geometry.column(scenery, 60, 1.6, stick, WHITE, DECOR)
			Geometry.ball(scenery, 16, stick + Vector3.new(0, 62, 0), pick(CANDY_COLORS), DECOR)
		end
	end

	local function setup()
		local arena = context.Arena
		local startFront = ledgePoint(1, 0, 0, -10)
		local startMiddle = startFront - Vector3.new(16, 0, 0)
		race.BuildStart(CFrame.lookAt(startMiddle, startMiddle + Vector3.xAxis), 48, 32)
		buildSteps(arena)
		buildHammers(arena)
		buildSpikes(arena)
		buildLifts(arena)
		buildScenery(arena)
		race.SpawnPlayers()
	end

	return {
		Setup = setup,
		Start = race.Start,
		Update = function(): boolean?
			race.Update()
			return nil
		end,
		End = race.Stop,
		GetQualified = context.DefaultQualified,
	}
end

return TumbleTower
