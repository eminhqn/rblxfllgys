--!strict
-- CLOUD CROWN (Final)
-- A big round cloud platform under a spinning crown. The edge crumbles inwards, and twice the
-- cloud splits along a line, leaving islands. Each puff shakes and greys out before it drops.
-- The last Bloblet on the cloud wins the match.
--
-- The server decides when every puff falls (a FallAt time on each tile) and turns its collision
-- off at that moment. Clients play the shake and drop from the same clock.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Tags = require(Shared.Tags)

local Geometry = require(script.Parent.Parent.Builders.Geometry)
local Hazards = require(script.Parent.Parent.Builders.Hazards)
local ArenaUtil = require(script.Parent.Parent.Match.ArenaUtil)
local Types = require(script.Parent.Parent.Match.Types)

local DURATION = 100
local RADIUS = 40
local SPACING = 8.2 -- hex grid spacing between puff centres
local TILE_DIAMETER = 9
local TILE_HEIGHT = 2
local FIRST_FALL = 8 -- seconds after GO before the edge starts going
local SHRINK_SPAN = 70 -- seconds from the first edge puff to the centre puff
local SPLIT_TIMES = { 26, 46 } -- seconds after GO when the cloud splits
local SPLIT_WIDTH = 4.6
local JITTER = 1.5
local KILL_DEPTH = 25
local REMOVE_AFTER_FALL = 2.5
local SPAWN_RADIUS = 26

local CLOUD_COLOR = Color3.fromRGB(246, 249, 255)

type Tile = {
	Model: Model,
	Pad: Part,
	Offset: Vector3, -- from the arena centre, on the XZ plane
}

type SplitLine = {
	Point: Vector3,
	Direction: Vector3,
}

local CloudCrown = {}

CloudCrown.Info = {
	Id = "CloudCrown",
	DisplayName = "Cloud Crown",
	Type = "Final",
	Rules = "The cloud is shrinking and splitting apart. Be the last Bloblet on it to win!",
	Duration = DURATION,
	MinPlayers = 1,
} :: Types.MiniGameInfo

function CloudCrown.new(context: Types.RoundContext): Types.MiniGame
	local center = context.Origin.Position
	local random = context.Random
	local tiles: { Tile } = {}
	local running = false

	local function buildTile(arena: Model, offset: Vector3)
		local model = Geometry.atomicModel("CloudPuff")
		local pad = Geometry.column(
			model,
			TILE_HEIGHT,
			TILE_DIAMETER,
			center + offset - Vector3.new(0, TILE_HEIGHT, 0),
			CLOUD_COLOR,
			{ Name = "Pad" }
		)
		-- Fluffy bits around the edge so the cloud doesn't look like a hex grid.
		for _ = 1, 3 do
			local angle = random:NextNumber(0, math.pi * 2)
			local puffOffset = Vector3.new(math.cos(angle) * 3.4, -1.3, math.sin(angle) * 3.4)
			Geometry.ball(model, random:NextNumber(3.4, 4.8), center + offset + puffOffset, CLOUD_COLOR, {
				Name = "Puff",
				CanCollide = false,
				CastShadow = false,
			})
		end
		model:SetAttribute("FallAt", 0)
		CollectionService:AddTag(model, Tags.FallingTile)
		model.Parent = arena -- only now, with every part inside
		table.insert(tiles, { Model = model, Pad = pad, Offset = offset })
	end

	local function setup()
		local arena = context.Arena
		local reach = math.ceil(RADIUS / SPACING) + 1
		for q = -reach, reach do
			for r = -reach, reach do
				local offset = Vector3.new(SPACING * (q + r / 2), 0, SPACING * (r * math.sqrt(3) / 2))
				if offset.Magnitude <= RADIUS then
					buildTile(arena, offset)
				end
			end
		end
		Hazards.Crown(arena, center + Vector3.new(0, 16, 0))
		context.SpawnAll(ArenaUtil.RingSpots(center, SPAWN_RADIUS, #context.Players))
	end

	local function start()
		running = true
		local startTime = context.GetStartTime()
		local splits: { SplitLine } = {}
		for _ = 1, #SPLIT_TIMES do
			local angle = random:NextNumber(0, math.pi)
			local nudge = Vector3.new(random:NextNumber(-5, 5), 0, random:NextNumber(-5, 5))
			table.insert(splits, { Point = nudge, Direction = Vector3.new(math.cos(angle), 0, math.sin(angle)) })
		end

		for _, tile in tiles do
			-- Outside first, centre last, a little randomness so the edge looks ragged.
			local distance = tile.Offset.Magnitude / RADIUS
			local fallAt = startTime + FIRST_FALL + (1 - distance) * SHRINK_SPAN + random:NextNumber(-JITTER, JITTER)
			for index, line in splits do
				if ArenaUtil.DistanceToLine(tile.Offset, line.Point, line.Direction) <= SPLIT_WIDTH then
					fallAt = math.min(fallAt, startTime + SPLIT_TIMES[index])
				end
			end
			fallAt = math.max(fallAt, startTime + FIRST_FALL)
			tile.Model:SetAttribute("FallAt", fallAt)

			task.delay(math.max(0, fallAt - context.GetServerTime()), function()
				if not running then
					return
				end
				tile.Pad.CanCollide = false
				tile.Pad.CanQuery = false
				task.delay(REMOVE_AFTER_FALL, function()
					if tile.Model.Parent then
						tile.Model:Destroy()
					end
				end)
			end)
		end
	end

	local function update(_dt: number): boolean?
		context.EliminateBelow(center.Y - KILL_DEPTH)
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

return CloudCrown
