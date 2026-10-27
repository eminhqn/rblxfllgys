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
local Config = require(Shared.Config)
local MathUtil = require(Shared.MathUtil)
local Tags = require(Shared.Tags)

local Bots = require(script.Parent.Parent.Bots.Bots)
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
	FallAt: number, -- 0 until GO
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
	local neighbours: { [Tile]: { Tile } } = {}
	local botTargets: { [Player]: Tile } = {}
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
		table.insert(tiles, { Model = model, Pad = pad, Offset = offset, FallAt = 0 })
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
		for _, tile in tiles do
			local touching: { Tile } = {}
			for _, other in tiles do
				if other ~= tile and (other.Offset - tile.Offset).Magnitude <= SPACING * 1.1 then
					table.insert(touching, other)
				end
			end
			neighbours[tile] = touching
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
			tile.FallAt = fallAt
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

	-- How long a bot thinks the puff has left. Everyone can see the edge creeping in; a puff about to
	-- go shakes and greys out; only sharp bots see a split coming before that.
	local function timeLeft(tile: Tile, now: number, skill: number): number
		local left = tile.FallAt - now
		if left <= Config.Hazards.TileWarningTime then
			return left
		end
		local byEdge = context.GetStartTime() + FIRST_FALL + (1 - tile.Offset.Magnitude / RADIUS) * SHRINK_SPAN - now
		return byEdge + (left - byEdge) * skill
	end

	-- Bots head for the puff they think will last longest among the ones they can walk to without
	-- crossing a gap, and only change their minds for a clearly better one.
	local function botGoal(bot: Player): Types.BotGoal?
		local root = context.GetRoot(bot)
		if not root or not running then
			return nil
		end
		local now = context.GetServerTime()
		local skill = Bots.SkillOf(bot)
		local position = root.Position
		local here: Tile? = nil
		local nearest: Tile? = nil
		local nearestDistance = math.huge
		for _, tile in tiles do
			if tile.FallAt <= now then
				continue
			end
			local distance = MathUtil.flat(center + tile.Offset - position).Magnitude
			if distance < nearestDistance then
				nearest, nearestDistance = tile, distance
			end
		end
		if nearest and nearestDistance <= TILE_DIAMETER / 2 then
			here = nearest
		end
		local first = here
		if not first then
			-- In the air or on a puff that's gone: make for the nearest one left.
			botTargets[bot] = nil
			local landing = nearest
			return if landing then { MoveTo = center + landing.Offset, Within = 1.5 } else nil
		end

		-- Every puff it can walk to, and how long each has left.
		local reachable: { [Tile]: boolean } = { [first] = true }
		local queue: { Tile } = { first }
		local best = first
		local bestScore = -math.huge
		local current = botTargets[bot]
		local currentScore = -math.huge
		local head = 1
		while head <= #queue do
			local tile = queue[head]
			head += 1
			local distance = MathUtil.flat(center + tile.Offset - position).Magnitude
			local score = timeLeft(tile, now, skill) - distance * 0.25
			if score > bestScore then
				best, bestScore = tile, score
			end
			if tile == current then
				currentScore = score
			end
			for _, other in neighbours[tile] do
				if not reachable[other] and other.FallAt > now + 0.6 then
					reachable[other] = true
					table.insert(queue, other)
				end
			end
		end
		local target = if current and currentScore > bestScore - 1.5 then current else best
		botTargets[bot] = target
		return { MoveTo = center + target.Offset, Within = 2, Wander = 1.5, Careful = true }
	end

	return {
		Setup = setup,
		Start = start,
		Update = update,
		End = function()
			running = false
			table.clear(botTargets)
		end,
		GetQualified = context.DefaultQualified,
		BotGoal = botGoal,
	}
end

return CloudCrown
