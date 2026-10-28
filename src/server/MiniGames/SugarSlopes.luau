--!strict
-- SUGAR SLOPES (Race)
-- Up and down a candy mountain:
--   1. Gumdrop Hill: climb a wide slope while giant sugared gumdrops roll (and bounce) down at
--      you. Glowing arrows up the slope show each one's lane first.
--   2. Icing Slide: a slippery frosted slope back down. Icing has hardly any grip, so you skid,
--      turn slowly and slide downhill; candy bars glide across it and peppermint bumpers sit in
--      the way.
--   3. Toffee Crossing: the safe way is round the sides on sticky toffee belts that drag you
--      backwards. The shortcut straight down the middle is three gaps you can only clear with a
--      jump + dive (miss and it's back to the last checkpoint).
--   4. Gumdrop Ridge: a narrower climb to the finish with even more gumdrops.
-- Fall off and you're back at your last checkpoint. Cross the finish line to qualify.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Config = require(Shared.Config)
local Theme = require(Shared.Theme)

local Geometry = require(script.Parent.Parent.Builders.Geometry)
local Hazards = require(script.Parent.Parent.Builders.Hazards)
local RaceKit = require(script.Parent.Parent.Match.RaceKit)
local Types = require(script.Parent.Parent.Match.Types)

local DURATION = 130
local KILL_DEPTH = 24
local ICING_GRIP = 0.2 -- see Config.Movement.SlipperySlopeSlide
local GAP = 17 -- shortcut gaps: too far to jump (about 14.5 studs), close enough to jump + dive
local TOFFEE_SPEED = -14 -- the side belts drag you back towards the slide

local GUMDROP_DIAMETERS = { 7, 8, 9, 10 }
local GUMDROP_SPEED = { 24, 34 }
local GUMDROP_HOP_CHANCE = 0.3
local HILL_EVERY = 0.95 -- seconds between gumdrops on Gumdrop Hill
local RIDGE_EVERY = 0.75 -- ...and on Gumdrop Ridge

local FROSTING = Color3.fromRGB(255, 196, 222)
local ICING = Color3.fromRGB(226, 244, 255)
local PAD_COLOR = Color3.fromRGB(255, 236, 246)
local TOFFEE = Color3.fromRGB(196, 120, 64)
local TOFFEE_LIGHT = Color3.fromRGB(240, 176, 110)
local COTTON = Color3.fromRGB(255, 186, 226)
local CANDY_BAR = Color3.fromRGB(132, 86, 60)
local WHITE = Color3.fromRGB(255, 255, 255)
local GUMDROP_COLORS = {
	Color3.fromRGB(255, 84, 120),
	Color3.fromRGB(255, 170, 40),
	Color3.fromRGB(120, 220, 80),
	Color3.fromRGB(150, 110, 255),
	Color3.fromRGB(40, 200, 230),
}

local DECOR: Geometry.PartOptions = { Name = "Decor", CanCollide = false, CastShadow = false }

-- A straight slope. Frame is the centre of its top surface, looking towards the high end.
type Slope = {
	Frame: CFrame,
	Length: number,
	Width: number,
}

type GumdropSlope = {
	Slope: Slope,
	Every: number,
	Timer: number,
}

local SugarSlopes = {}

SugarSlopes.Info = {
	Id = "SugarSlopes",
	DisplayName = "Sugar Slopes",
	Type = "Race",
	Rules = "Dodge the rolling gumdrops, skid down the icing and take the shortcut if you dare!",
	Duration = DURATION,
	MinPlayers = 1,
} :: Types.MiniGameInfo

-- `low` and `high` are the middles of the slope's two ends, on its surface.
local function slopeBetween(low: Vector3, high: Vector3, width: number): Slope
	return { Frame = CFrame.lookAt((low + high) / 2, high), Length = (high - low).Magnitude, Width = width }
end

-- A ground CFrame on the slope's surface: `x` studs across from its centre line, `t` from 0 (the
-- low end) to 1 (the high end). It's tilted with the slope.
local function onSlope(slope: Slope, x: number, t: number): CFrame
	return slope.Frame * CFrame.new(x, 0, (0.5 - t) * slope.Length)
end

function SugarSlopes.new(context: Types.RoundContext): Types.MiniGame
	local center = context.Origin.Position
	local random = context.Random
	local race = RaceKit.new(context, { KillHeight = center.Y - KILL_DEPTH })
	local gumdropSlopes: { GumdropSlope } = {}
	local running = false

	-- Ground-level CFrame at an offset from the centre, facing forwards (+Z).
	local function at(x: number, y: number, z: number): CFrame
		local position = center + Vector3.new(x, y, z)
		return CFrame.lookAt(position, position + Vector3.zAxis)
	end

	local function point(x: number, y: number, z: number): Vector3
		return center + Vector3.new(x, y, z)
	end

	local function pick<T>(list: { T }): T
		return list[random:NextInteger(1, #list)]
	end

	local function buildSlope(parent: Instance, slope: Slope, color: Color3, name: string): Part
		return Hazards.Platform(parent, slope.Frame, Vector3.new(slope.Width, 4, slope.Length), color, name)
	end

	-- A giant gumdrop rolling (sometimes bouncing) from the top of a slope to the bottom, in a
	-- random lane. Clients flash arrows up its lane first, then roll it and judge hits.
	local function launchGumdrop(slope: Slope)
		local diameter = pick(GUMDROP_DIAMETERS)
		local x = random:NextNumber(-slope.Width / 2 + diameter / 2, slope.Width / 2 - diameter / 2)
		local top = onSlope(slope, x, 1)
		local bottom = onSlope(slope, x, 0)
		local speed = random:NextNumber(GUMDROP_SPEED[1], GUMDROP_SPEED[2])
		local duration = slope.Length / speed
		local rules = Config.Balloons
		local lead = rules.ReplicationLead + rules.WarningTime
		local gumdrop = Hazards.Gumdrop(context.Arena, {
			Origin = top.Position + slope.Frame.UpVector * (diameter / 2),
			Velocity = -slope.Frame.LookVector * speed,
			StartAt = context.GetServerTime() + lead,
			Duration = duration,
			Diameter = diameter,
			Hop = if random:NextNumber() < GUMDROP_HOP_CHANCE then random:NextNumber(4, 6.5) else 0,
			HopRate = 1.2,
			Color = pick(GUMDROP_COLORS),
			LaneFrom = top.Position,
			LaneTo = bottom.Position,
		})
		task.delay(lead + duration + rules.RemoveAfter, function()
			if gumdrop.Parent then
				gumdrop:Destroy()
			end
		end)
	end

	-- A big round peppermint standing on the slope (it's solid: bounce off it).
	local function peppermint(parent: Instance, ground: CFrame)
		local bottom = ground.Position - Vector3.new(0, 1.2, 0)
		Geometry.column(parent, 4.4, 6, bottom, WHITE, { Name = "Peppermint" })
		for index = 0, 5 do
			local angle = index / 6 * math.pi * 2
			local offset = Vector3.new(math.cos(angle) * 1.5, 4.45, math.sin(angle) * 1.5)
			-- A pink swirl stripe on top, pointing out from the middle.
			Geometry.block(
				parent,
				Vector3.new(2.8, 0.12, 1.1),
				CFrame.new(bottom + offset) * CFrame.Angles(0, -angle, 0),
				Theme.Colors.Pink,
				DECOR
			)
		end
	end

	local function buildHill(arena: Model)
		local hill = Geometry.model(arena, "GumdropHill")
		local slope = slopeBetween(point(0, 0, 16), point(0, 20, 106), 48)
		buildSlope(hill, slope, FROSTING, "Hill")
		table.insert(gumdropSlopes, { Slope = slope, Every = HILL_EVERY, Timer = 0 })
		-- Bots climb straight up (side-stepping gumdrops as they come).
		race.AddBotPoint(point(0, 0, 14))
		race.AddBotPoint(point(0, 10, 60))
		race.AddBotPoint(point(0, 20, 110))
		Hazards.Platform(hill, at(0, 20, 115), Vector3.new(48, 4, 18), PAD_COLOR, "Checkpoint1Pad")
		race.AddCheckpoint(at(0, 20, 115), Vector2.new(48, 18))
	end

	local function buildIcing(arena: Model)
		local slide = Geometry.model(arena, "IcingSlide")
		local slope = slopeBetween(point(0, 4, 214), point(0, 20, 124), 48)
		local icing = buildSlope(slide, slope, ICING, "Icing")
		icing:SetAttribute("Grip", ICING_GRIP)
		icing.Reflectance = 0.25
		-- Candy bars gliding from side to side (they push you; on icing you'll skid a long way).
		for index, t in { 0.76, 0.5, 0.24 } do
			local ground = onSlope(slope, 0, t)
			Hazards.Mover(slide, Vector3.new(16, 0, 0), 1 + index * 0.15, index * 2.1, function(model: Model)
				local bar = ground * CFrame.new(0, 1.5, 0)
				Geometry.block(model, Vector3.new(12, 3, 3.4), bar, CANDY_BAR, { Name = "CandyBar" })
				for stripe = -2, 2 do
					Geometry.block(
						model,
						Vector3.new(0.5, 3.1, 3.5),
						bar * CFrame.new(stripe * 2.3, 0, 0),
						CANDY_BAR:Lerp(WHITE, 0.25),
						DECOR
					)
				end
			end)
		end
		for _, spot in { Vector2.new(-15, 0.63), Vector2.new(15, 0.63), Vector2.new(0, 0.37), Vector2.new(-17, 0.12) } do
			peppermint(slide, onSlope(slope, spot.X, spot.Y))
		end
		peppermint(slide, onSlope(slope, 17, 0.12))
		-- Bots go down between the peppermints.
		for _, t in { 0.95, 0.8, 0.5, 0.15 } do
			race.AddBotPoint(onSlope(slope, -7, t).Position, { Within = 4 })
		end
		race.AddBotPoint(point(0, 4, 222))
	end

	local function buildToffee(arena: Model)
		local crossing = Geometry.model(arena, "ToffeeCrossing")
		Hazards.Platform(crossing, at(0, 4, 222), Vector3.new(56, 4, 16), PAD_COLOR, "Runout")
		local front = 230 -- the runout pad's far edge
		local islandDepth = 8
		local finish = front + 3 * GAP + 2 * islandDepth -- where the next checkpoint pad starts
		-- The safe way: sticky toffee belts down both sides, running backwards.
		for _, side in { -1, 1 } do
			Hazards.Conveyor(
				crossing,
				at(side * 24, 4, (front + finish) / 2),
				Vector2.new(8, finish - front),
				TOFFEE_SPEED,
				{ Rails = true, Color = TOFFEE, SlatColor = TOFFEE_LIGHT }
			)
		end
		-- The shortcut: cotton candy islands with jump + dive gaps between them.
		for index = 0, 1 do
			local z = front + GAP + islandDepth / 2 + index * (GAP + islandDepth)
			Hazards.Platform(crossing, at(0, 4, z), Vector3.new(12, 4, islandDepth), COTTON, "ShortcutIsland")
			for _, side in { -1, 1 } do
				Geometry.ball(crossing, 5, point(side * 5, 0.5, z), COTTON:Lerp(WHITE, 0.3), DECOR)
			end
		end
		Geometry.sign(crossing, "SHORTCUT: JUMP + DIVE!", point(-13, 4, 226), 15, 2.8, Theme.Colors.Yellow, 4)
		Hazards.Goo(
			crossing,
			CFrame.new(point(0, -12, (front + finish) / 2)),
			Vector2.new(72, finish - front + 10),
			random
		)

		local checkpointZ = finish + 8
		-- Bots take the toffee belt round the side, or (sharper ones, more often) jump + dive the
		-- shortcut. One that falls in goes round by the belt after that (RaceKit).
		for _, z in { front - 2, finish - 2 } do
			race.AddBotPoint(point(-24, 4, z), { Fork = "Toffee", Way = "Belt" })
		end
		race.AddBotPoint(point(0, 4, front - 1.5), { Fork = "Toffee", Way = "Shortcut", Hard = true, Within = 1.5 })
		for index = 0, 1 do
			local z = front + GAP + islandDepth / 2 + index * (GAP + islandDepth)
			race.AddBotPoint(point(0, 4, z), { Fork = "Toffee", Way = "Shortcut", Hard = true, Within = 2 })
		end
		race.AddBotPoint(point(0, 4, checkpointZ - 3))
		Hazards.Platform(crossing, at(0, 4, checkpointZ), Vector3.new(56, 4, 16), PAD_COLOR, "Checkpoint2Pad")
		race.AddCheckpoint(at(0, 4, checkpointZ), Vector2.new(56, 16))
		return checkpointZ + 8
	end

	local function buildRidge(arena: Model, startZ: number)
		local ridge = Geometry.model(arena, "GumdropRidge")
		local topZ = startZ + 70
		local slope = slopeBetween(point(0, 4, startZ), point(0, 22, topZ), 28)
		buildSlope(ridge, slope, FROSTING, "Ridge")
		table.insert(gumdropSlopes, { Slope = slope, Every = RIDGE_EVERY, Timer = 0 })
		race.AddBotPoint(onSlope(slope, 0, 0.05).Position)
		race.AddBotPoint(onSlope(slope, 0, 0.5).Position)
		race.AddBotPoint(onSlope(slope, 0, 0.98).Position)
		race.BuildFinish(at(0, 22, topZ + 20), 40, 40)
	end

	-- Frosted hills and lollipops round the course (nothing here collides).
	local function buildScenery(arena: Model)
		local scenery = Geometry.model(arena, "Scenery")
		for index = 0, 9 do
			for _, side in { -1, 1 } do
				local z = -20 + index * 46 + random:NextNumber(-8, 8)
				local x = side * random:NextNumber(70, 95)
				local size =
					Vector3.new(random:NextNumber(40, 60), random:NextNumber(30, 55), random:NextNumber(40, 60))
				Geometry.ellipsoid(
					scenery,
					size,
					CFrame.new(point(x, -18, z)),
					pick({ FROSTING, ICING, COTTON, PAD_COLOR }),
					DECOR
				)
				if index % 2 == 0 then
					local stickBottom = point(x * 0.78, -10, z + 20)
					Geometry.column(scenery, 34, 1.2, stickBottom, WHITE, DECOR)
					Geometry.ball(scenery, 12, stickBottom + Vector3.new(0, 36, 0), pick(GUMDROP_COLORS), DECOR)
				end
			end
		end
	end

	local function setup()
		local arena = context.Arena
		race.BuildStart(at(0, 0, 0), 48, 32)
		buildHill(arena)
		buildIcing(arena)
		local ridgeStart = buildToffee(arena)
		buildRidge(arena, ridgeStart)
		buildScenery(arena)
		race.SpawnPlayers()
	end

	local function start()
		race.Start()
		running = true
		for _, entry in gumdropSlopes do
			entry.Timer = entry.Every -- the first gumdrop sets off straight away
		end
	end

	local function update(dt: number): boolean?
		race.Update()
		if running then
			for _, entry in gumdropSlopes do
				entry.Timer += dt
				while entry.Timer >= entry.Every do
					entry.Timer -= entry.Every
					launchGumdrop(entry.Slope)
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
			race.Stop()
		end,
		GetQualified = context.DefaultQualified,
		BotGoal = race.BotGoal,
	}
end

return SugarSlopes
