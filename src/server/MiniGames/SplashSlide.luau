--!strict
-- SPLASH SLIDE (Race)
-- A giant water slide from a tower in the sky down to a pool. The water carries you along (a Flow
-- on every slide piece: MovementController) and you steer, jump and dive as you go:
--   * twists and turns, with glass walls round the bends
--   * peppermint bumpers in the way and candy hammers swinging across the slide
--   * two splash pools to catch your breath (checkpoints), one with a spinning bar
--   * a ramp that launches you over a gap: miss the landing and it's back to the last checkpoint
-- The first to splash across the finish line at the bottom qualify. Fall off (or get knocked over
-- the walls) and you're back at your last checkpoint.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local MathUtil = require(Shared.MathUtil)
local Theme = require(Shared.Theme)

local Geometry = require(script.Parent.Parent.Builders.Geometry)
local Hazards = require(script.Parent.Parent.Builders.Hazards)
local RaceKit = require(script.Parent.Parent.Match.RaceKit)
local Types = require(script.Parent.Parent.Match.Types)

local DURATION = 120
local START_HEIGHT = 100 -- the top of the slide, above the arena origin
local FLOW_SPEED = 38 -- studs/s the water carries you
local SLIDE_WIDTH = 14
local WALL_HEIGHT = 5
local THICKNESS = 3
local FALL_MARGIN = 16 -- this far below the slide under you counts as fallen off
local SAMPLE_SPACING = 4
local KICKER_LENGTH = 6
local KICKER_LIFT = 2.6
local HAMMER_DROP = 16

local WATER = Color3.fromRGB(80, 190, 255)
local WATER_LIGHT = Color3.fromRGB(170, 228, 255)
local GLASS = Color3.fromRGB(150, 230, 255)
local POOL_EDGE = Color3.fromRGB(255, 236, 246)
local WHITE = Color3.fromRGB(255, 255, 255)
local PEPPERMINT = Theme.Colors.Pink
local DECOR: Geometry.PartOptions = { Name = "Decor", CanCollide = false, CastShadow = false }

type LegKind = "Slide" | "Pool" | "Gap"

-- One piece of the course, built in order from the top. Turn (degrees) is applied first.
type Leg = {
	Kind: LegKind,
	Turn: number,
	Length: number, -- along the ground
	Drop: number,
	Width: number?,
	Hammers: { number }?, -- 0 to 1 along the leg
	Bumpers: { Vector2 }?, -- (studs across from the middle, 0 to 1 along)
	Kicker: boolean?, -- a launch ramp at the end
	Checkpoint: boolean?,
	Spinner: boolean?,
}

local LEGS: { Leg } = {
	{ Kind = "Slide", Turn = 0, Length = 40, Drop = 12, Width = 22 },
	{ Kind = "Slide", Turn = 30, Length = 34, Drop = 10 },
	{ Kind = "Slide", Turn = 25, Length = 30, Drop = 9, Bumpers = { Vector2.new(-3.5, 0.45), Vector2.new(3.5, 0.75) } },
	{ Kind = "Slide", Turn = -40, Length = 36, Drop = 10 },
	{ Kind = "Slide", Turn = -35, Length = 34, Drop = 10, Hammers = { 0.5 } },
	{ Kind = "Slide", Turn = 20, Length = 30, Drop = 8 },
	{ Kind = "Pool", Turn = 0, Length = 26, Drop = 0, Width = 30, Checkpoint = true },
	{ Kind = "Slide", Turn = 0, Length = 40, Drop = 12, Hammers = { 0.3, 0.72 } },
	{
		Kind = "Slide",
		Turn = 35,
		Length = 32,
		Drop = 9,
		Bumpers = { Vector2.new(0, 0.3), Vector2.new(-4, 0.6), Vector2.new(4, 0.85) },
	},
	{ Kind = "Slide", Turn = 0, Length = 24, Drop = 6, Kicker = true },
	{ Kind = "Gap", Turn = 0, Length = 9, Drop = 6 },
	{
		Kind = "Slide",
		Turn = 0,
		Length = 34,
		Drop = 10,
		Width = 18,
		Bumpers = { Vector2.new(-5, 0.35), Vector2.new(5, 0.55), Vector2.new(-5, 0.75) },
	},
	{ Kind = "Slide", Turn = -35, Length = 30, Drop = 9, Hammers = { 0.5 } },
	{ Kind = "Pool", Turn = -30, Length = 32, Drop = 0, Width = 34, Checkpoint = true, Spinner = true },
	{ Kind = "Slide", Turn = 30, Length = 40, Drop = 12, Hammers = { 0.35, 0.7 } },
	{ Kind = "Slide", Turn = 25, Length = 30, Drop = 9 },
	{ Kind = "Slide", Turn = -55, Length = 36, Drop = 10, Bumpers = { Vector2.new(-3, 0.4), Vector2.new(3, 0.7) } },
}

local SplashSlide = {}

SplashSlide.Info = {
	Id = "SplashSlide",
	DisplayName = "Splash Slide",
	Type = "Race",
	Rules = "Ride the water slide to the bottom! Steer round the bumpers, dodge the hammers, fly the gap.",
	Duration = DURATION,
	MinPlayers = 1,
} :: Types.MiniGameInfo

function SplashSlide.new(context: Types.RoundContext): Types.MiniGame
	local center = context.Origin.Position
	local random = context.Random
	local samples: { Vector3 } = {} -- points along the course's surface, for "fallen off"

	local function surfaceBelow(position: Vector3): number?
		local best: number? = nil
		local bestDistance = math.huge
		for _, point in samples do
			local distance = MathUtil.flat(point - position).Magnitude
			if distance < bestDistance then
				bestDistance = distance
				best = point.Y
			end
		end
		return best
	end

	local race = RaceKit.new(context, {
		KillHeight = center.Y - 80,
		Fallen = function(position: Vector3): boolean
			local surface = surfaceBelow(position)
			return surface ~= nil and position.Y < surface - FALL_MARGIN
		end,
	})

	local function addSamples(from: Vector3, to: Vector3)
		local count = math.max(1, math.ceil(MathUtil.flat(to - from).Magnitude / SAMPLE_SPACING))
		for index = 0, count do
			table.insert(samples, from:Lerp(to, index / count))
		end
	end

	local function directionOf(heading: number): Vector3
		return Vector3.new(math.sin(heading), 0, math.cos(heading))
	end

	-- Glass walls along both sides of a surface whose top is `top` (centre), `length` long.
	local function sideWalls(parent: Instance, top: CFrame, width: number, length: number)
		for _, side in { -1, 1 } do
			Geometry.block(
				parent,
				Vector3.new(1, WALL_HEIGHT, length),
				top * CFrame.new(side * (width / 2 + 0.5), WALL_HEIGHT / 2 - 0.5, 0),
				GLASS,
				{ Name = "Wall", Transparency = 0.55, CastShadow = false }
			)
		end
	end

	-- A sloping piece of slide from `from` down to `to` (the middle of its surface at each end).
	local function slidePiece(parent: Instance, from: Vector3, to: Vector3, width: number, flow: Vector3): CFrame
		local top = CFrame.lookAt((from + to) / 2, to)
		local length = (to - from).Magnitude
		local part = Hazards.Platform(parent, top, Vector3.new(width, THICKNESS, length), WATER, "Slide")
		part.Reflectance = 0.15
		part:SetAttribute("Flow", flow)
		sideWalls(parent, top, width, length)
		-- White foam chevrons pointing downhill.
		local along = 5
		while along < length - 3 do
			for _, side in { -1, 1 } do
				Geometry.block(
					parent,
					Vector3.new(0.4, 0.1, 2.6),
					top * CFrame.new(side * 0.9, 0.05, -length / 2 + along) * CFrame.Angles(0, side * 0.6, 0),
					WATER_LIGHT,
					DECOR
				)
			end
			along += 9
		end
		return top
	end

	-- A round joint where two slide pieces meet at an angle, walled round the outside.
	local function joint(parent: Instance, at: Vector3, inDir: Vector3, outDir: Vector3, width: number)
		local diameter = width + 2
		local disc = Geometry.column(parent, THICKNESS, diameter, at - Vector3.new(0, THICKNESS, 0), WATER, {
			Name = "Bend",
		})
		disc:SetAttribute("Flow", (inDir + outDir).Unit * FLOW_SPEED)
		local radius = diameter / 2 + 0.5
		local pieces = 18
		local open = math.cos(math.rad(50))
		for index = 0, pieces - 1 do
			local angle = index / pieces * math.pi * 2
			local out = Vector3.new(math.sin(angle), 0, math.cos(angle))
			if out:Dot(-inDir) > open or out:Dot(outDir) > open then
				continue -- where the slide comes in and goes out
			end
			local middle = at + out * radius + Vector3.new(0, WALL_HEIGHT / 2 - 0.5, 0)
			Geometry.block(
				parent,
				Vector3.new(2 * math.pi * radius / pieces + 0.4, WALL_HEIGHT, 1),
				CFrame.lookAt(middle, at + Vector3.new(0, WALL_HEIGHT / 2 - 0.5, 0)),
				GLASS,
				{ Name = "Wall", Transparency = 0.55, CastShadow = false }
			)
		end
	end

	-- A peppermint bumper standing on the slide.
	local function bumper(parent: Instance, ground: CFrame)
		local bottom = ground.Position - Vector3.new(0, 0.8, 0)
		Geometry.column(parent, 4.4, 4, bottom, WHITE, { Name = "Bumper" })
		for index = 0, 3 do
			local angle = index / 4 * math.pi * 2
			Geometry.block(
				parent,
				Vector3.new(1.8, 0.12, 0.8),
				CFrame.new(bottom + Vector3.new(math.cos(angle) * 1, 4.45, math.sin(angle) * 1))
					* CFrame.Angles(0, -angle, 0),
				PEPPERMINT,
				DECOR
			)
		end
	end

	local function buildCourse(arena: Model)
		local course = Geometry.model(arena, "Slide")
		local position = center + Vector3.new(0, START_HEIGHT, 0)
		local heading = 0
		local startDirection = directionOf(heading)
		race.BuildStart(CFrame.lookAt(position - startDirection * 14, position), 40, 28)
		addSamples(position - startDirection * 28, position)
		-- Glass that funnels the start pad onto the (narrower) slide.
		local right = startDirection:Cross(Vector3.yAxis)
		for _, side in { -1, 1 } do
			local from = position - startDirection * 4 + right * side * 20
			local to = position + right * side * ((LEGS[1].Width or SLIDE_WIDTH) / 2 + 0.5)
			local middle = (from + to) / 2 + Vector3.new(0, WALL_HEIGHT / 2, 0)
			Geometry.block(
				course,
				Vector3.new(1, WALL_HEIGHT, (to - from).Magnitude),
				CFrame.lookAt(middle, middle + (to - from)),
				GLASS,
				{ Name = "Wall", Transparency = 0.55, CastShadow = false }
			)
		end

		local previous: Leg? = nil
		local previousDirection = startDirection
		for _, leg in LEGS do
			heading += math.rad(leg.Turn)
			local direction = directionOf(heading)
			local width = leg.Width or SLIDE_WIDTH
			local finish = position + direction * leg.Length - Vector3.new(0, leg.Drop, 0)
			if leg.Kind == "Gap" then
				position = finish
				previous = leg
				previousDirection = direction
				continue
			end
			if leg.Kind == "Slide" and previous and previous.Kind == "Slide" then
				joint(course, position, previousDirection, direction, math.max(width, previous.Width or SLIDE_WIDTH))
			end
			if leg.Kind == "Slide" then
				local top = slidePiece(course, position, finish, width, direction * FLOW_SPEED)
				local length = (finish - position).Magnitude
				local hammers = leg.Hammers
				if hammers then
					for _, t in hammers do
						local spot = position:Lerp(finish, t) + Vector3.new(0, HAMMER_DROP, 0)
						Hazards.Hammer(course, CFrame.lookAt(spot, spot + direction), {
							Amplitude = 1.1,
							Speed = 2.1,
							Phase = random:NextNumber(0, math.pi * 2),
							FrameSpan = width + 6,
							Color = Theme.Colors.Purple,
						})
					end
				end
				local bumpers = leg.Bumpers
				if bumpers then
					for _, spot in bumpers do
						bumper(course, top * CFrame.new(spot.X, 0, length * (0.5 - spot.Y)))
					end
				end
				addSamples(position, finish)
				if leg.Kicker then
					-- A ramp up at the end that throws you over the gap.
					local lip = finish + direction * KICKER_LENGTH + Vector3.new(0, KICKER_LIFT, 0)
					local kickerTop = CFrame.lookAt((finish + lip) / 2, lip)
					local ramp = Hazards.Platform(
						course,
						kickerTop,
						Vector3.new(width, THICKNESS, (lip - finish).Magnitude),
						Theme.Colors.Yellow,
						"Kicker"
					)
					ramp:SetAttribute("Flow", direction * FLOW_SPEED)
					sideWalls(course, kickerTop, width, (lip - finish).Magnitude)
					finish = lip
				end
			else
				-- A flat splash pool to catch your breath: a checkpoint, maybe with a spinning bar.
				local middle = (position + finish) / 2
				local top = CFrame.lookAt(middle, middle + direction)
				Hazards.Platform(course, top, Vector3.new(width, 4, leg.Length), POOL_EDGE, "Pool")
				Geometry.block(
					course,
					Vector3.new(width - 4, 0.2, leg.Length - 4),
					top * CFrame.new(0, 0.1, 0),
					WATER_LIGHT,
					DECOR
				)
				sideWalls(course, top, width, leg.Length)
				if leg.Checkpoint then
					race.AddCheckpoint(top, Vector2.new(width, leg.Length))
				end
				if leg.Spinner then
					Hazards.Spinner(course, middle, {
						ArmLength = width - 6,
						Speed = 1.3,
						Mat = false,
						Color = Theme.Colors.Orange,
					})
				end
				addSamples(position, finish)
			end
			position = finish
			previous = leg
			previousDirection = direction
		end

		-- The finish: a pool deck at the bottom.
		local finishDepth = 30
		local direction = directionOf(heading)
		race.BuildFinish(
			CFrame.lookAt(position + direction * (finishDepth / 2), position + direction * finishDepth),
			34,
			finishDepth
		)
		addSamples(position, position + direction * finishDepth)
		return position, direction
	end

	-- A big pool round the bottom, rubber rings floating about, and clouds (none of it collides).
	local function buildScenery(arena: Model, bottom: Vector3, direction: Vector3)
		local scenery = Geometry.model(arena, "Scenery")
		local poolCenter = bottom + direction * 15 - Vector3.new(0, 6, 0)
		Geometry.column(scenery, 1, 150, poolCenter - Vector3.new(0, 1, 0), WATER, {
			Name = "Decor",
			CanCollide = false,
			CastShadow = false,
			Transparency = 0.25,
		})
		for _ = 1, 8 do
			local angle = random:NextNumber(0, math.pi * 2)
			local distance = random:NextNumber(30, 65)
			local ringCenter = poolCenter + Vector3.new(math.cos(angle) * distance, 0.6, math.sin(angle) * distance)
			for index = 1, 10 do
				local around = index / 10 * math.pi * 2
				Geometry.ball(
					scenery,
					1.6,
					ringCenter + Vector3.new(math.cos(around) * 2.4, 0, math.sin(around) * 2.4),
					if index % 2 == 0 then WHITE else Theme.Colors.Pink,
					DECOR
				)
			end
		end
		-- The tower the slide starts from.
		local top = center + Vector3.new(0, START_HEIGHT, -14)
		Geometry.column(
			scenery,
			START_HEIGHT + 40,
			26,
			top - Vector3.new(0, START_HEIGHT + 44, 0),
			Color3.fromRGB(255, 196, 222),
			DECOR
		)
		for _ = 1, 20 do
			local spot = center
				+ Vector3.new(
					random:NextNumber(-160, 200),
					random:NextNumber(-20, START_HEIGHT + 30),
					random:NextNumber(-60, 380)
				)
			local surface = surfaceBelow(spot)
			if surface and math.abs(spot.Y - surface) < 30 then
				continue -- not in the way of the slide
			end
			Geometry.ellipsoid(
				scenery,
				Vector3.new(random:NextNumber(18, 32), random:NextNumber(8, 12), random:NextNumber(14, 24)),
				CFrame.new(spot),
				WHITE,
				DECOR
			)
		end
	end

	local function setup()
		local arena = context.Arena
		local bottom, direction = buildCourse(arena)
		buildScenery(arena, bottom, direction)
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

return SplashSlide
