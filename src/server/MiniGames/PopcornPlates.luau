--!strict
-- POPCORN PLATES (Final)
-- Three floors of round plates stacked one above the other over a giant popcorn bucket. Any plate
-- you stand on starts to sizzle: it flashes and shakes, then pops into popcorn and drops away a
-- moment later. Keep moving, fall through to the floor below, and be the last Bloblet standing.
-- After a while plates start popping on their own as well.
--
-- The server decides when every plate pops, from where it sees each Bloblet (checked all along the
-- way it moved since the last check, so a fast dive still counts), and turns the plate's collision
-- off at that moment. Clients play the flash, shake and popcorn from the same clock.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local BlobletRig = require(Shared.BlobletRig)
local MathUtil = require(Shared.MathUtil)
local Tags = require(Shared.Tags)

local Geometry = require(script.Parent.Parent.Builders.Geometry)
local ArenaUtil = require(script.Parent.Parent.Match.ArenaUtil)
local Types = require(script.Parent.Parent.Match.Types)

local DURATION = 120
local LAYER_GAP = 18
local RADIUS = 34
local SPACING = 8.6 -- between plate middles (hex grid)
local PLATE_DIAMETER = 8.2
local PLATE_HEIGHT = 1.6
local POP_DELAY = 0.8 -- from first standing on a plate to it dropping (it flashes meanwhile)
local STEP_REACH = PLATE_DIAMETER / 2 + 0.6 -- flat distance from a plate's middle that counts as on it
local STAND_HEIGHT = BlobletRig.Dimensions.RootHeight + 1.4 -- your middle this close above a plate
local SAMPLE_STEP = 2.5 -- studs between checks along the way a Bloblet moved
local MAX_SAMPLE_LINE = 40 -- longer moves (a respawn) aren't traced
local SELF_POP_AFTER = 50 -- seconds after GO before plates start popping on their own
local SELF_POP_EVERY = { 1.2, 0.3 } -- seconds between those pops, from then until the end
local REMOVE_AFTER_FALL = 2.5
local KILL_DEPTH = 15 -- below the bottom floor
local SPAWN_RADIUS = 22

-- Top to bottom: butter, strawberry, blue raspberry.
local LAYER_COLORS = {
	Color3.fromRGB(255, 220, 92),
	Color3.fromRGB(255, 140, 186),
	Color3.fromRGB(110, 200, 255),
}
local KERNEL_COLORS = { Color3.fromRGB(255, 252, 236), Color3.fromRGB(255, 238, 180) }
local BUCKET_RED = Color3.fromRGB(236, 60, 72)
local BUCKET_WHITE = Color3.fromRGB(255, 248, 240)
local DECOR: Geometry.PartOptions = { Name = "Decor", CanCollide = false, CastShadow = false }

type Plate = {
	Model: Model,
	Pad: Part,
	Top: Vector3, -- middle of its top surface
	FallAt: number, -- 0 = still there
}

local PopcornPlates = {}

PopcornPlates.Info = {
	Id = "PopcornPlates",
	DisplayName = "Popcorn Plates",
	Type = "Final",
	Rules = "Plates pop a moment after you step on them. Keep moving and be the last one standing!",
	Duration = DURATION,
	MinPlayers = 1,
} :: Types.MiniGameInfo

function PopcornPlates.new(context: Types.RoundContext): Types.MiniGame
	local center = context.Origin.Position
	local random = context.Random
	local layers: { { Plate } } = {}
	local layerTops: { number } = {}
	local allPlates: { Plate } = {}
	local lastPosition: { [Player]: Vector3 } = {}
	local selfPopTimer = 0
	local running = false

	local function buildPlate(arena: Model, layer: number, top: Vector3): Plate
		local model = Geometry.atomicModel("PopcornPlate")
		local color = LAYER_COLORS[layer]
		local pad = Geometry.column(
			model,
			PLATE_HEIGHT,
			PLATE_DIAMETER,
			top - Vector3.new(0, PLATE_HEIGHT, 0),
			color,
			{ Name = "Pad" }
		)
		-- A pale rim and a couple of kernels so each plate reads as its own piece.
		Geometry.column(model, 0.12, PLATE_DIAMETER - 1.6, top, color:Lerp(Color3.new(1, 1, 1), 0.45), DECOR)
		for _ = 1, 2 do
			local angle = random:NextNumber(0, math.pi * 2)
			local spot = top + Vector3.new(math.cos(angle) * 2.6, 0.4, math.sin(angle) * 2.6)
			Geometry.ball(model, random:NextNumber(0.9, 1.3), spot, KERNEL_COLORS[random:NextInteger(1, 2)], DECOR)
		end
		model:SetAttribute("FallAt", 0)
		model:SetAttribute("WarningTime", POP_DELAY)
		model:SetAttribute("Popcorn", true)
		CollectionService:AddTag(model, Tags.FallingTile)
		model.Parent = arena -- only now, with every part inside
		return { Model = model, Pad = pad, Top = top, FallAt = 0 }
	end

	local function buildLayers(arena: Model)
		local reach = math.ceil(RADIUS / SPACING) + 1
		for layer = 1, #LAYER_COLORS do
			local top = center.Y - (layer - 1) * LAYER_GAP
			-- Each floor's grid is shifted so the holes above don't line up with the ones below.
			local shift =
				Vector3.new(if layer == 2 then SPACING / 2 else 0, 0, if layer == 3 then SPACING * 0.29 else 0)
			local plates: { Plate } = {}
			for q = -reach, reach do
				for r = -reach, reach do
					local offset = Vector3.new(SPACING * (q + r / 2), 0, SPACING * (r * math.sqrt(3) / 2)) + shift
					if offset.Magnitude <= RADIUS then
						local plate = buildPlate(arena, layer, Vector3.new(center.X, top, center.Z) + offset)
						table.insert(plates, plate)
						table.insert(allPlates, plate)
					end
				end
			end
			layers[layer] = plates
			layerTops[layer] = top
		end
	end

	-- A huge striped popcorn bucket underneath everything, and popcorn floating about (nothing
	-- here collides).
	local function buildScenery(arena: Model)
		local scenery = Geometry.model(arena, "Bucket")
		local bottomTop = center.Y - (#LAYER_COLORS - 1) * LAYER_GAP
		local rimY = bottomTop - 10
		local height = 50
		local panels = 28
		local bucketRadius = RADIUS + 16
		for index = 1, panels do
			local angle = index / panels * math.pi * 2
			local middle = Vector3.new(
				center.X + math.cos(angle) * bucketRadius,
				rimY - height / 2,
				center.Z + math.sin(angle) * bucketRadius
			)
			Geometry.block(
				scenery,
				Vector3.new(2 * bucketRadius * math.sin(math.pi / panels) + 0.3, height, 1.5),
				CFrame.lookAt(middle, Vector3.new(center.X, middle.Y, center.Z)),
				if index % 2 == 0 then BUCKET_RED else BUCKET_WHITE,
				DECOR
			)
		end
		-- Heaped popcorn inside the bucket.
		for _ = 1, 40 do
			local angle = random:NextNumber(0, math.pi * 2)
			local distance = random:NextNumber(0, bucketRadius - 4)
			local spot = Vector3.new(
				center.X + math.cos(angle) * distance,
				rimY - 14 + random:NextNumber(-3, 3),
				center.Z + math.sin(angle) * distance
			)
			Geometry.ball(scenery, random:NextNumber(4, 7), spot, KERNEL_COLORS[random:NextInteger(1, 2)], DECOR)
		end
		-- Giant kernels drifting round the outside.
		for _ = 1, 16 do
			local angle = random:NextNumber(0, math.pi * 2)
			local distance = random:NextNumber(60, 95)
			local spot = center
				+ Vector3.new(math.cos(angle) * distance, random:NextNumber(-40, 20), math.sin(angle) * distance)
			Geometry.ball(scenery, random:NextNumber(5, 9), spot, KERNEL_COLORS[random:NextInteger(1, 2)], DECOR)
		end
	end

	local function pop(plate: Plate, fallAt: number)
		if plate.FallAt ~= 0 then
			return
		end
		plate.FallAt = fallAt
		plate.Model:SetAttribute("FallAt", fallAt)
		task.delay(math.max(0, fallAt - context.GetServerTime()), function()
			plate.Pad.CanCollide = false
			plate.Pad.CanQuery = false
			task.delay(REMOVE_AFTER_FALL, function()
				if plate.Model.Parent then
					plate.Model:Destroy()
				end
			end)
		end)
	end

	-- Starts popping every plate a Bloblet at `position` is standing on.
	local function touchAt(position: Vector3, now: number)
		for layer, plates in layers do
			local height = position.Y - layerTops[layer]
			if height < 0 or height > STAND_HEIGHT then
				continue
			end
			for _, plate in plates do
				if plate.FallAt == 0 and MathUtil.flat(position - plate.Top).Magnitude <= STEP_REACH then
					pop(plate, now + POP_DELAY)
				end
			end
		end
	end

	local function updatePlayer(player: Player, now: number)
		local root = context.GetRoot(player)
		if not root then
			lastPosition[player] = nil
			return
		end
		local position = root.Position
		local last = lastPosition[player]
		if last and (position - last).Magnitude <= MAX_SAMPLE_LINE then
			local steps = math.max(1, math.ceil((position - last).Magnitude / SAMPLE_STEP))
			for step = 1, steps do
				touchAt(last:Lerp(position, step / steps), now)
			end
		else
			touchAt(position, now)
		end
		lastPosition[player] = position
	end

	-- Late in the round plates pop by themselves, faster and faster.
	local function selfPop(dt: number, elapsed: number)
		if elapsed < SELF_POP_AFTER then
			return
		end
		local progress = math.clamp((elapsed - SELF_POP_AFTER) / (DURATION - SELF_POP_AFTER), 0, 1)
		local every = SELF_POP_EVERY[1] + (SELF_POP_EVERY[2] - SELF_POP_EVERY[1]) * progress
		selfPopTimer += dt
		while selfPopTimer >= every do
			selfPopTimer -= every
			for _ = 1, 12 do
				local plate = allPlates[random:NextInteger(1, #allPlates)]
				if plate.FallAt == 0 then
					pop(plate, context.GetServerTime() + POP_DELAY)
					break
				end
			end
		end
	end

	local function setup()
		local arena = context.Arena
		buildLayers(arena)
		buildScenery(arena)
		context.SpawnAll(ArenaUtil.RingSpots(center, SPAWN_RADIUS, #context.Players))
	end

	local function update(dt: number): boolean?
		context.EliminateBelow(layerTops[#layerTops] - KILL_DEPTH)
		if not running then
			return nil
		end
		local now = context.GetServerTime()
		for _, player in context.GetAlive() do
			updatePlayer(player, now)
		end
		selfPop(dt, now - context.GetStartTime())
		return nil
	end

	return {
		Setup = setup,
		Start = function()
			running = true
		end,
		Update = update,
		End = function()
			running = false
		end,
		GetQualified = context.DefaultQualified,
	}
end

return PopcornPlates
