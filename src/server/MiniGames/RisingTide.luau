--!strict
-- RISING TIDE (Survival)
-- Water rises steadily around a tall candy pillar. Climb the spiral scaffolding (every fourth
-- plank wobbles, every sixth gap is wider). Reaching the golden summit qualifies you straight
-- away. Fall in and you're knocked over and float: you then have a few seconds (Config.Water) to
-- swim and jump back out before you're eliminated.
--
-- Only players who reach the top go through. The round ends once every qualifying spot is taken,
-- once everyone still in has made it, or when time runs out, and anyone who didn't make it to
-- the top by then is eliminated.
--
-- Clients animate the water from the shared clock (Riser tag) and the server uses the same
-- formula to decide who is in it, so what you see is what counts.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local BlobletRig = require(Shared.BlobletRig)
local Config = require(Shared.Config)
local HazardMath = require(Shared.HazardMath)
local Tags = require(Shared.Tags)
local Theme = require(Shared.Theme)
local Ui = require(Shared.Ui)

local Geometry = require(script.Parent.Parent.Builders.Geometry)
local ArenaUtil = require(script.Parent.Parent.Match.ArenaUtil)
local Types = require(script.Parent.Parent.Match.Types)

local DURATION = 70
local WATER_RATE = 1.5 -- studs per second
local WATER_START = -3 -- surface height relative to the island top when the round starts
local WATER_MAX_RISE = 105

local STEP_RISE = 4.2
local STEP_COUNT = 25
local STEP_RADIUS = 15
local STEP_ANGLE = math.rad(32)
local WIDE_STEP_ANGLE = math.rad(46)
local PATHS = 3
local PLANK_SIZE = Vector3.new(7, 1.2, 7)
local PILLAR_DIAMETER = 10
local ISLAND_DIAMETER = 64
local SPAWN_RADIUS = 24
local SUMMIT_DIAMETER = 22

local WHITE = Color3.fromRGB(255, 255, 255)
local ISLAND_COLOR = Color3.fromRGB(255, 214, 170)
local WATER_COLOR = Color3.fromRGB(60, 190, 255)
local GOLD = Color3.fromRGB(255, 205, 64)
local PLANK_COLORS = { Theme.Colors.Yellow, Theme.Colors.Pink, Theme.Colors.Aqua, Theme.Colors.Lime }

local RisingTide = {}

RisingTide.Info = {
	Id = "RisingTide",
	DisplayName = "Rising Tide",
	Type = "Survival",
	Rules = "The water is rising! Reach the golden top before time runs out. Fall in and you have a few seconds to get out.",
	Duration = DURATION,
	MinPlayers = 1,
	QualifyByGoalOnly = true, -- didn't reach the top in time = out
} :: Types.MiniGameInfo

function RisingTide.new(context: Types.RoundContext): Types.MiniGame
	local center = context.Origin.Position
	local waterStartTop = center.Y + WATER_START
	local summitTop = center.Y + STEP_RISE * (STEP_COUNT + 1)
	local water: BasePart? = nil
	local waterSince: { [Player]: number } = {}
	local dryFrom: { [Player]: number } = {}
	local stepTops: { { Vector3 } } = {} -- each path's planks, bottom to top (middle of the top)
	local botPaths: { [Player]: number } = {} -- the stairway each bot is climbing
	local botAims: { [Player]: number } = {} -- the plank it's making for

	local function buildSummit(arena: Model)
		local summitCenter = center + Vector3.new(0, summitTop - center.Y - 1.2, 0)
		Geometry.column(arena, 1.2, SUMMIT_DIAMETER, summitCenter, GOLD, { Name = "Summit" })
		local rim = summitTop + 0.3
		for index = 1, 12 do
			local angle = index / 12 * math.pi * 2
			local offset = Vector3.new(math.cos(angle), 0, math.sin(angle)) * (SUMMIT_DIAMETER / 2)
			Geometry.ball(arena, 1.4, Vector3.new(center.X, rim, center.Z) + offset, Theme.Colors.Pink, {
				Name = "SummitStud",
				CanCollide = false,
				CastShadow = false,
			})
		end
		-- A floating label so everyone knows where the finish is.
		local anchor = Geometry.block(
			arena,
			Vector3.one * 0.4,
			CFrame.new(center.X, summitTop + 9, center.Z),
			WHITE,
			{ Name = "SummitLabelAnchor", Transparency = 1, CanCollide = false, CastShadow = false }
		)
		local gui: BillboardGui = Ui.new("BillboardGui", {
			Size = UDim2.fromOffset(240, 64),
			LightInfluence = 0,
			MaxDistance = 400,
			Parent = anchor,
		})
		local label = Ui.label(
			gui,
			"QUALIFY!",
			Theme.Fonts.Display,
			GOLD,
			UDim2.fromScale(1, 1),
			UDim2.fromScale(0.5, 0.5),
			Vector2.new(0.5, 0.5)
		)
		Ui.new("UIStroke", {
			Color = Theme.Colors.Ink,
			Thickness = 3,
			ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual,
			Parent = label,
		})
	end

	local function buildScaffolding(arena: Model)
		local pillarHeight = summitTop - center.Y - 1.2
		local segment = 7
		local segments = math.ceil(pillarHeight / segment)
		for index = 0, segments - 1 do
			local height = math.min(segment, pillarHeight - index * segment)
			Geometry.column(
				arena,
				height,
				PILLAR_DIAMETER,
				center + Vector3.new(0, index * segment, 0),
				if index % 2 == 0 then Theme.Colors.Pink else WHITE,
				{ Name = "Pillar" }
			)
		end
		buildSummit(arena)

		for path = 0, PATHS - 1 do
			local angle = path * (math.pi * 2 / PATHS)
			local tops: { Vector3 } = {}
			stepTops[path + 1] = tops
			for step = 1, STEP_COUNT do
				angle += if step % 6 == 0 then WIDE_STEP_ANGLE else STEP_ANGLE
				local top = center.Y + STEP_RISE * step
				local direction = Vector3.new(math.cos(angle), 0, math.sin(angle))
				local position = Vector3.new(center.X, top - PLANK_SIZE.Y / 2, center.Z) + direction * STEP_RADIUS
				local facing = Vector3.new(center.X, position.Y, center.Z)
				local plank = Geometry.block(
					arena,
					PLANK_SIZE,
					CFrame.lookAt(position, facing),
					PLANK_COLORS[(step + path) % #PLANK_COLORS + 1],
					{ Name = "Plank" }
				)
				table.insert(tops, Vector3.new(position.X, top, position.Z))
				if step % 4 == 0 then
					plank:SetAttribute("Amplitude", 0.22)
					plank:SetAttribute("Speed", context.Random:NextNumber(1.3, 2))
					plank:SetAttribute("Phase", context.Random:NextNumber(0, math.pi * 2))
					CollectionService:AddTag(plank, Tags.Wobbler)
				end
				-- Support beam back to the pillar (decorative).
				local beamY = top - center.Y - 1.6
				Geometry.tube(
					arena,
					center + direction * (PILLAR_DIAMETER / 2) + Vector3.new(0, beamY, 0),
					center + direction * (STEP_RADIUS - PLANK_SIZE.X / 2) + Vector3.new(0, beamY, 0),
					0.7,
					WHITE,
					{ Name = "Beam", CanCollide = false, CastShadow = false }
				)
			end
		end
	end

	local function setup()
		local arena = context.Arena
		Geometry.column(arena, 4, ISLAND_DIAMETER, center - Vector3.new(0, 4, 0), ISLAND_COLOR, { Name = "Island" })
		buildScaffolding(arena)

		local waterPart = Geometry.block(
			arena,
			Vector3.new(300, 8, 300),
			CFrame.new(center.X, waterStartTop - 4, center.Z),
			WATER_COLOR,
			{ Name = "Water", Transparency = 0.3, CanCollide = false, CastShadow = false }
		)
		waterPart:SetAttribute("StartTime", 0)
		waterPart:SetAttribute("Rate", WATER_RATE)
		waterPart:SetAttribute("MaxRise", WATER_MAX_RISE)
		waterPart:SetAttribute("Water", true) -- clients float Bloblets on it
		CollectionService:AddTag(waterPart, Tags.Riser)
		water = waterPart

		context.SpawnAll(ArenaUtil.RingSpots(center, SPAWN_RADIUS, #context.Players))
	end

	local function start()
		local waterPart = water
		if waterPart then
			-- Every client starts raising its water from this moment.
			waterPart:SetAttribute("StartTime", context.GetStartTime())
		end
	end

	local function waterLevel(): number
		local rise = HazardMath.RiserOffset(context.GetStartTime(), WATER_RATE, WATER_MAX_RISE, context.GetServerTime())
		return waterStartTop + rise
	end

	-- The DrownAt attribute (server time, 0 = safe) drives the "get out!" countdown on clients.
	local function setDrownAt(player: Player, value: number)
		local character = player.Character
		if character then
			character:SetAttribute("DrownAt", value)
		end
	end

	local function clearWater(player: Player)
		if waterSince[player] then
			setDrownAt(player, 0)
		end
		waterSince[player] = nil
		dryFrom[player] = nil
	end

	local function update(_dt: number): boolean?
		local now = context.GetServerTime()
		local level = waterLevel()
		local rules = Config.Water
		for _, player in context.GetAlive() do
			if context.IsQualified(player) then
				continue -- made it to the top
			end
			local root = context.GetRoot(player)
			if not root then
				continue
			end
			local position = root.Position
			local fromAxis = Vector3.new(position.X - center.X, 0, position.Z - center.Z).Magnitude

			if position.Y >= summitTop + 1 and fromAxis <= SUMMIT_DIAMETER / 2 + 0.5 then
				clearWater(player)
				context.Qualify(player)
			elseif position.Y < level - rules.DeepFallDepth then
				clearWater(player)
				context.Eliminate(player)
			elseif position.Y < level + rules.InWaterMargin then
				dryFrom[player] = nil
				local since = waterSince[player]
				if not since then
					waterSince[player] = now
					setDrownAt(player, now + rules.GraceTime)
				elseif now - since >= rules.GraceTime then
					clearWater(player)
					context.Eliminate(player)
				end
			elseif waterSince[player] then
				-- Out of the water: the timer resets once you've stayed out for a moment.
				local dry = dryFrom[player]
				if not dry then
					dryFrom[player] = now
				elseif now - dry >= rules.DryResetTime then
					clearWater(player)
				end
			end
		end
		return nil
	end

	-- The stairway (path) and plank a Bloblet is standing on, if it's on one (not just flying up
	-- past it).
	local function plankUnder(root: BasePart): (number?, number?)
		if root.AssemblyLinearVelocity.Y > 4 then
			return nil, nil
		end
		local position = root.Position
		local feet = position.Y - BlobletRig.Dimensions.RootHeight
		for path, tops in stepTops do
			for index, top in tops do
				local flat = Vector3.new(position.X - top.X, 0, position.Z - top.Z).Magnitude
				if flat <= PLANK_SIZE.X / 2 + 1 and math.abs(feet - top.Y) <= 1.5 then
					return path, index
				end
			end
		end
		return nil, nil
	end

	-- A stairway for a bot starting out: a near one, without too many bots on it already.
	local function pickPath(position: Vector3): number
		local taken: { [number]: number } = {}
		for _, path in botPaths do
			taken[path] = (taken[path] or 0) + 1
		end
		local best, bestScore = 1, math.huge
		for path, tops in stepTops do
			local score = (tops[1] - position).Magnitude + (taken[path] or 0) * 8
			if score < bestScore then
				best, bestScore = path, score
			end
		end
		return best
	end

	-- Bots climb a stairway plank by plank: always the plank after the one they're standing on (so
	-- the aim doesn't change mid-jump), then up onto the summit. They leave each other alone on the
	-- way up. Fallen in, they swim to the nearest plank they can jump up onto and carry on from it.
	local function botGoal(bot: Player): Types.BotGoal?
		local root = context.GetRoot(bot)
		if not root then
			return nil
		end
		local summit = Vector3.new(center.X, summitTop, center.Z)
		if context.IsQualified(bot) then
			return { MoveTo = summit, Wander = 4, Calm = true }
		end
		local position = root.Position
		local feet = position.Y - BlobletRig.Dimensions.RootHeight
		local path = botPaths[bot] or pickPath(position)
		local aim = botAims[bot] or 1
		local onPath, onIndex = plankUnder(root)
		if onPath and onIndex then
			path, aim = onPath, onIndex + 1
		elseif feet < center.Y + 1 then
			aim = 1 -- on the island (or swimming over it)
		else
			local tops = stepTops[path]
			local aimed = tops and tops[math.min(aim, #tops)]
			if aimed and aimed.Y - feet > 6 then
				-- Well below where it was going (fell): the nearest plank it can jump up onto.
				local nearest = math.huge
				for otherPath, others in stepTops do
					for index, top in others do
						local up = top.Y - feet
						local distance = Vector3.new(top.X - position.X, 0, top.Z - position.Z).Magnitude
						if up > 0.5 and up < 5 and distance < nearest then
							nearest, path, aim = distance, otherPath, index
						end
					end
				end
			end
		end
		botPaths[bot] = path
		botAims[bot] = aim
		local tops = stepTops[path] or {}
		local upNext = tops[aim]
		if upNext then
			return { MoveTo = upNext, Within = 1.2, Calm = true, Note = `plank {aim}/{#tops}` }
		end
		-- Off the last plank and up onto the summit.
		local last = tops[#tops]
		local inward = if last then Vector3.new(last.X - center.X, 0, last.Z - center.Z) else Vector3.xAxis
		inward = if inward.Magnitude > 0.1 then inward.Unit else Vector3.xAxis
		return { MoveTo = summit + inward * (SUMMIT_DIAMETER / 2 - 4), Within = 2, Calm = true, Note = "summit" }
	end

	local function finish()
		for _, player in context.Players do
			clearWater(player)
		end
	end

	return {
		Setup = setup,
		Start = start,
		Update = update,
		End = finish,
		-- Only players who reached the top (QualifyByGoalOnly).
		GetQualified = context.DefaultQualified,
		BotGoal = botGoal,
	}
end

return RisingTide
