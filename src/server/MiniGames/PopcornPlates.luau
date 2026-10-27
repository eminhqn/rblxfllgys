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

local Bots = require(script.Parent.Parent.Bots.Bots)
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
local BOT_REACH = 1.3 -- bots only hop to plates this many plate-widths away (the ring round theirs)

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

-- A bot's next plate, and when it means to step off the one it's reached.
type BotPlan = {
	Plate: Plate?,
	LeaveAt: number, -- 0 = not there yet
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
	local layerOf: { [Plate]: number } = {}
	local neighbours: { [Plate]: { Plate } } = {} -- the plates touching it on its floor
	local botPlans: { [Player]: BotPlan } = {}
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
			for _, plate in plates do
				layerOf[plate] = layer
				local touching: { Plate } = {}
				for _, other in plates do
					local apart = (other.Top - plate.Top).Magnitude
					if other ~= plate and apart <= SPACING * 1.1 then
						table.insert(touching, other)
					end
				end
				neighbours[plate] = touching
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

	local function stillThere(plates: { Plate }): number
		local count = 0
		for _, plate in plates do
			if plate.FallAt == 0 then
				count += 1
			end
		end
		return count
	end

	-- Bots hop from plate to plate on their floor, staying a moment on each (clumsy ones a bit too
	-- long). Sharper bots pick plates with more plates still round them, nearer the middle, so they
	-- don't strand themselves. Once their floor runs out they drop to the next one down.
	local function botGoal(bot: Player): Types.BotGoal?
		local root = context.GetRoot(bot)
		if not root then
			botPlans[bot] = nil
			return nil
		end
		local position = root.Position
		local layer = #layerTops
		for index, top in layerTops do
			if top <= position.Y then
				layer = index
				break
			end
		end
		local skill = Bots.SkillOf(bot)
		local now = context.GetServerTime()
		local plan: BotPlan = botPlans[bot] or { Plate = nil, LeaveAt = 0 }
		botPlans[bot] = plan

		local target = plan.Plate
		if target and layerOf[target] ~= layer then
			target = nil -- fell through to another floor
		end
		if target and MathUtil.flat(position - target.Top).Magnitude <= 2 then
			if plan.LeaveAt == 0 then
				plan.LeaveAt = now + random:NextNumber(0.05, 0.5) * (1.2 - skill)
			end
			if now < plan.LeaveAt then
				return { MoveTo = target.Top, Within = 1.5 }
			end
			target = nil
		elseif target and target.FallAt ~= 0 then
			target = nil -- someone else popped it first
		end

		if not target then
			local bestScore = math.huge
			for _, plate in layers[layer] do
				local distance = MathUtil.flat(plate.Top - position).Magnitude
				if plate.FallAt ~= 0 or distance <= 2 or distance > SPACING * BOT_REACH then
					continue
				end
				local middle = MathUtil.flat(plate.Top - center).Magnitude / RADIUS
				local score = distance * 0.4
					- stillThere(neighbours[plate]) * (0.5 + 2.5 * skill)
					+ middle * 3 * skill
					+ random:NextNumber(0, 2.5)
				if score < bestScore then
					target, bestScore = plate, score
				end
			end
			plan.Plate = target
			plan.LeaveAt = 0
		end
		if target then
			return { MoveTo = target.Top, Within = 1.5 }
		end

		-- Nothing left up here: walk off towards the nearest plate on a floor below.
		local nearest: Plate? = nil
		local nearestDistance = math.huge
		for below = layer + 1, #layers do
			for _, plate in layers[below] do
				local distance = MathUtil.flat(plate.Top - position).Magnitude
				if plate.FallAt == 0 and distance < nearestDistance then
					nearest, nearestDistance = plate, distance
				end
			end
			if nearest then
				break
			end
		end
		local drop = nearest
		return if drop then { MoveTo = drop.Top, Within = 1.5 } else nil
	end

	return {
		Setup = setup,
		Start = function()
			running = true
		end,
		Update = update,
		End = function()
			running = false
			table.clear(botPlans)
		end,
		GetQualified = context.DefaultQualified,
		BotGoal = botGoal,
	}
end

return PopcornPlates
