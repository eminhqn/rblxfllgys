--!strict
-- JIGGLY JELLY (Survival)
-- A floor of wobbly jelly squares over a pool of syrup. Any square you stand on starts to sink
-- under you, and if it sinks all the way it melts away and you drop into the syrup. Step off and
-- it slowly bobs back up; melted squares grow back after a while. As the round goes on the jelly
-- sinks faster and grows back slower, and near the end it stops growing back at all. The syrup
-- rises too (part of the way: never over the jelly), so a sinking square soon dunks you before it
-- has even melted. Keep moving! The last ones out of the syrup go through.
--
-- The server decides how fast each square is sinking from where it sees each Bloblet and tells
-- clients by setting the square's Level / Rate / At attributes only when that changes; clients
-- sink it smoothly from the same clock (HazardMath.JellyLevel). The syrup is a Riser.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local BlobletRig = require(Shared.BlobletRig)
local HazardMath = require(Shared.HazardMath)
local Tags = require(Shared.Tags)

local Geometry = require(script.Parent.Parent.Builders.Geometry)
local ArenaUtil = require(script.Parent.Parent.Match.ArenaUtil)
local Types = require(script.Parent.Parent.Match.Types)

local DURATION = 100
local RADIUS = 40
local TILE = 8
local GAP = 0.8
local THICKNESS = 4
local SINK_DEPTH = 6 -- how far a square sinks before it melts
local SINK_TIME = { 2.4, 1.2 } -- seconds a square takes to melt under you, at the start and at the end
local RECOVER_TIME = 3 -- seconds a fully sunk square takes to bob back up
local REGROW_TIME = { 4, 9 } -- seconds a melted square takes to grow back, start to end
local NO_REGROW_AFTER = 0.7 -- share of the round after which melted squares stay gone
local SYRUP_START = 7.5 -- syrup surface below the jelly top at first (a fully sunk square is 6 down)
local SYRUP_END = 2.2 -- where it stops rising: below the jelly top, so a square that's up is safe
local SYRUP_RISE_FROM = 12 -- seconds after GO the syrup starts rising
local SYRUP_RISE_TIME = 55 -- seconds it takes to rise all the way it goes
local SYRUP_RATE = (SYRUP_START - SYRUP_END) / SYRUP_RISE_TIME
local DUNK_HEIGHT = 1 -- your middle this close above the syrup surface (or below it): out
local BOWL_RADIUS = RADIUS + 14
local STAND_HEIGHT = BlobletRig.Dimensions.RootHeight + 1.6 -- your middle this close above a square
local SPAWN_RADIUS = 26

local JELLY_COLORS = {
	Color3.fromRGB(255, 90, 140),
	Color3.fromRGB(120, 220, 90),
	Color3.fromRGB(255, 180, 50),
	Color3.fromRGB(150, 110, 255),
	Color3.fromRGB(60, 200, 230),
}
local SYRUP = Color3.fromRGB(170, 90, 40)
local PLATE = Color3.fromRGB(255, 248, 252)
local DECOR: Geometry.PartOptions = { Name = "Decor", CanCollide = false, CastShadow = false }

type Tile = {
	Model: Model,
	Pad: Part,
	Top: Vector3, -- middle of its top surface when it's all the way up
	Level: number, -- how far sunk at time At (0 to 1)
	Rate: number,
	At: number,
	Gone: boolean,
	RegrowAt: number,
}

local JigglyJelly = {}

JigglyJelly.Info = {
	Id = "JigglyJelly",
	DisplayName = "Jiggly Jelly",
	Type = "Survival",
	Rules = "Jelly sinks under your feet! Keep moving or you'll melt into the syrup.",
	Duration = DURATION,
	MinPlayers = 1,
} :: Types.MiniGameInfo

function JigglyJelly.new(context: Types.RoundContext): Types.MiniGame
	local center = context.Origin.Position
	local random = context.Random
	local tiles: { Tile } = {}
	local running = false
	local syrup: Part? = nil
	local riseAt = 0 -- server time the syrup starts rising (0 until GO)
	local announced = false

	-- How far through the round we are (0 at GO, 1 at the end).
	local function progress(now: number): number
		local started = context.GetStartTime()
		if started <= 0 then
			return 0
		end
		return math.clamp((now - started) / DURATION, 0, 1)
	end

	local function between(range: { number }, t: number): number
		return range[1] + (range[2] - range[1]) * t
	end

	local function buildTile(arena: Model, top: Vector3): Tile
		local model = Geometry.atomicModel("Jelly")
		local color = JELLY_COLORS[random:NextInteger(1, #JELLY_COLORS)]
		local pad = Geometry.block(
			model,
			Vector3.new(TILE, THICKNESS, TILE),
			CFrame.new(top - Vector3.new(0, THICKNESS / 2, 0)),
			color,
			{ Name = "Pad", Material = Enum.Material.Glass, Transparency = 0.15 }
		)
		model.PrimaryPart = pad
		-- A shiny lighter top and a little highlight, so it reads as jelly.
		Geometry.block(
			model,
			Vector3.new(TILE - 0.6, 0.2, TILE - 0.6),
			CFrame.new(top + Vector3.new(0, 0.05, 0)),
			color:Lerp(Color3.new(1, 1, 1), 0.35),
			DECOR
		)
		Geometry.ellipsoid(
			model,
			Vector3.new(2.4, 0.3, 1.2),
			CFrame.new(top + Vector3.new(-1.6, 0.2, -1.8)) * CFrame.Angles(0, 0.5, 0),
			Color3.new(1, 1, 1),
			DECOR
		)
		model:SetAttribute("Level", 0)
		model:SetAttribute("Rate", 0)
		model:SetAttribute("At", 0)
		model:SetAttribute("SinkDepth", SINK_DEPTH)
		model:SetAttribute("Gone", false)
		CollectionService:AddTag(model, Tags.Jelly)
		model.Parent = arena -- only now, with every part inside
		return { Model = model, Pad = pad, Top = top, Level = 0, Rate = 0, At = 0, Gone = false, RegrowAt = 0 }
	end

	local function buildFloor(arena: Model)
		local spacing = TILE + GAP
		local reach = math.ceil(RADIUS / spacing)
		for column = -reach, reach do
			for row = -reach, reach do
				local offset = Vector3.new(column * spacing, 0, row * spacing)
				if offset.Magnitude <= RADIUS then
					table.insert(tiles, buildTile(arena, center + offset))
				end
			end
		end
	end

	-- A bowl of syrup under the jelly, with sugar crystals round its rim (nothing here collides).
	local function buildScenery(arena: Model)
		local scenery = Geometry.model(arena, "Bowl")
		local syrupTop = center - Vector3.new(0, SYRUP_START, 0)
		local bowlBottom = syrupTop - Vector3.new(0, 15, 0)
		local syrupPart = Geometry.column(scenery, 14, BOWL_RADIUS * 2, syrupTop - Vector3.new(0, 14, 0), SYRUP, {
			Name = "Syrup",
			CanCollide = false,
			CastShadow = false,
			Material = Enum.Material.Glass,
			Transparency = 0.1,
		})
		-- Clients raise it from GO + SYRUP_RISE_FROM (StartTime is set in Start).
		syrupPart:SetAttribute("StartTime", 0)
		syrupPart:SetAttribute("Rate", SYRUP_RATE)
		syrupPart:SetAttribute("MaxRise", SYRUP_START - SYRUP_END)
		CollectionService:AddTag(syrupPart, Tags.Riser)
		syrup = syrupPart
		Geometry.column(scenery, 2, BOWL_RADIUS * 2 + 10, bowlBottom - Vector3.new(0, 2, 0), PLATE, DECOR)
		-- The bowl's side, up to just under the jelly.
		local rimTop = center.Y - 1
		local pieces = 36
		for index = 1, pieces do
			local angle = index / pieces * math.pi * 2
			local out = Vector3.new(math.cos(angle), 0, math.sin(angle))
			local middle = Vector3.new(center.X, (rimTop + bowlBottom.Y) / 2, center.Z) + out * (BOWL_RADIUS + 2)
			Geometry.block(
				scenery,
				Vector3.new(2 * math.pi * (BOWL_RADIUS + 4) / pieces + 0.4, rimTop - bowlBottom.Y, 4),
				CFrame.lookAt(middle, Vector3.new(center.X, middle.Y, center.Z)),
				PLATE,
				DECOR
			)
		end
		for index = 1, 24 do
			local angle = index / 24 * math.pi * 2
			local spot = Vector3.new(center.X, rimTop + 1.2, center.Z)
				+ Vector3.new(math.cos(angle), 0, math.sin(angle)) * (BOWL_RADIUS + 2)
			Geometry.block(
				scenery,
				Vector3.one * random:NextNumber(2.5, 4.5),
				CFrame.new(spot) * CFrame.Angles(random:NextNumber(0, 3), random:NextNumber(0, 3), 0),
				JELLY_COLORS[index % #JELLY_COLORS + 1],
				{ Name = "Decor", CanCollide = false, CastShadow = false, Material = Enum.Material.Glass }
			)
		end
		-- Giant gummy bears watching from round the outside.
		for index = 1, 6 do
			local angle = index / 6 * math.pi * 2 + 0.3
			local foot = center + Vector3.new(math.cos(angle) * 85, -20, math.sin(angle) * 85)
			local color = JELLY_COLORS[index % #JELLY_COLORS + 1]
			local look = CFrame.lookAt(foot, Vector3.new(center.X, foot.Y, center.Z))
			Geometry.ellipsoid(scenery, Vector3.new(14, 20, 11), look * CFrame.new(0, 10, 0), color, DECOR)
			Geometry.ball(scenery, 12, (look * CFrame.new(0, 24, 0)).Position, color, DECOR)
			for _, side in { -1, 1 } do
				Geometry.ball(scenery, 5, (look * CFrame.new(side * 4.5, 29, 0)).Position, color, DECOR)
			end
		end
	end

	-- Tells clients how a square is sinking from now on (only when that changes).
	local function setRate(tile: Tile, rate: number, now: number)
		if tile.Rate == rate then
			return
		end
		tile.Level = HazardMath.JellyLevel(tile.Level, tile.Rate, tile.At, now)
		tile.Rate = rate
		tile.At = now
		tile.Model:SetAttribute("Level", tile.Level)
		tile.Model:SetAttribute("At", now)
		tile.Model:SetAttribute("Rate", rate)
	end

	local function melt(tile: Tile, now: number)
		tile.Gone = true
		tile.Level = 1
		tile.Rate = 0
		tile.At = now
		tile.Pad.CanCollide = false
		tile.Pad.CanQuery = false
		tile.Model:SetAttribute("Gone", true)
		tile.RegrowAt = if progress(now) < NO_REGROW_AFTER then now + between(REGROW_TIME, progress(now)) else 0
	end

	local function regrow(tile: Tile, now: number)
		tile.Gone = false
		tile.Level = 0
		tile.Rate = 0
		tile.At = now
		tile.RegrowAt = 0
		tile.Model:SetAttribute("Level", 0)
		tile.Model:SetAttribute("Rate", 0)
		tile.Model:SetAttribute("At", now)
		tile.Model:SetAttribute("Gone", false)
		tile.Pad.CanCollide = true
		tile.Pad.CanQuery = true
	end

	-- Which squares have someone standing on them right now.
	local function occupiedTiles(now: number): { [Tile]: boolean }
		local occupied: { [Tile]: boolean } = {}
		local half = TILE / 2 + 0.4
		for _, player in context.GetAlive() do
			local root = context.GetRoot(player)
			if not root then
				continue
			end
			local position = root.Position
			for _, tile in tiles do
				if tile.Gone then
					continue
				end
				local offset = position - tile.Top
				if math.abs(offset.X) > half or math.abs(offset.Z) > half then
					continue
				end
				local top = tile.Top.Y - HazardMath.JellyLevel(tile.Level, tile.Rate, tile.At, now) * SINK_DEPTH
				local height = position.Y - top
				if height > -0.5 and height < STAND_HEIGHT then
					occupied[tile] = true
				end
			end
		end
		return occupied
	end

	-- The syrup's surface height right now (same as clients show).
	local function syrupLevel(now: number): number
		return center.Y - SYRUP_START + HazardMath.RiserOffset(riseAt, SYRUP_RATE, SYRUP_START - SYRUP_END, now)
	end

	local function update(_dt: number): boolean?
		local now = context.GetServerTime()
		context.EliminateBelow(syrupLevel(now) + DUNK_HEIGHT)
		if not running then
			return nil
		end
		if not announced and riseAt > 0 and now >= riseAt then
			announced = true
			context.Announce("THE SYRUP IS RISING!")
		end
		local t = progress(now)
		local sinkRate = 1 / between(SINK_TIME, t)
		local occupied = occupiedTiles(now)
		for _, tile in tiles do
			if tile.Gone then
				if tile.RegrowAt > 0 and now >= tile.RegrowAt then
					regrow(tile, now)
				end
				continue
			end
			local level = HazardMath.JellyLevel(tile.Level, tile.Rate, tile.At, now)
			if level >= 1 then
				melt(tile, now)
			elseif occupied[tile] then
				setRate(tile, sinkRate, now)
			elseif level > 0 then
				setRate(tile, -1 / RECOVER_TIME, now)
			else
				setRate(tile, 0, now)
			end
		end
		return nil
	end

	local function setup()
		local arena = context.Arena
		buildFloor(arena)
		buildScenery(arena)
		context.SpawnAll(ArenaUtil.RingSpots(center, SPAWN_RADIUS, #context.Players))
	end

	return {
		Setup = setup,
		Start = function()
			running = true
			riseAt = context.GetStartTime() + SYRUP_RISE_FROM
			local syrupPart = syrup
			if syrupPart then
				syrupPart:SetAttribute("StartTime", riseAt)
			end
		end,
		Update = update,
		End = function()
			running = false
		end,
		-- Whoever's still out of the syrup.
		GetQualified = context.DefaultQualified,
	}
end

return JigglyJelly
