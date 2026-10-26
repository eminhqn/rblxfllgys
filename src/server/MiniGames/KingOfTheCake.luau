--!strict
-- KING OF THE CAKE (Final)
-- A giant three-tier cake that wobbles like it's about to topple. Climb the macaron steps to the
-- top tier and stay there: every second on top fills your KING meter, and the first to fill it
-- wins. A candle bar sweeps round the top, everyone else is trying to kick you off, and the cake
-- wobbles harder in the second half. Fall off the cake and you're out. If time runs out, whoever
-- is still on the cake with the fullest meter wins.
--
-- Each tier is a Swinger (Hazards.Swinger) tilting round the middle of its top; clients animate
-- the wobble. The server times everyone's meter from where it sees their Bloblet.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Match = require(Shared.Match)

local Geometry = require(script.Parent.Parent.Builders.Geometry)
local Hazards = require(script.Parent.Parent.Builders.Hazards)
local ArenaUtil = require(script.Parent.Parent.Match.ArenaUtil)
local Types = require(script.Parent.Parent.Match.Types)

local DURATION = 120
local GOAL = 20 -- seconds on top to win
local NEARLY = 15 -- seconds on top when everyone's told
local KILL_DEPTH = 6 -- your middle this far below the bottom tier's top: out
local SPAWN_RADIUS = 34
local TOP_MARGIN = 0.5 -- how far past the top tier's edge still counts as on top
local WOBBLE_RAMP = { 0.5, 0.7 } -- share of the round over which the wobble grows
local WOBBLE_GROWTH = 1.6 -- how much harder it wobbles by the end of the ramp
local SPINNER_SPEED = { 1.5, 2.1 } -- candle bar speed before and after half time
local PLATE_TOP = -10 -- the cake plate, below the bottom tier's top

local CREAM = Color3.fromRGB(255, 250, 240)
local CANDLE = Color3.fromRGB(240, 80, 100)
local SPRINKLES = {
	Color3.fromRGB(255, 90, 140),
	Color3.fromRGB(90, 200, 255),
	Color3.fromRGB(255, 210, 60),
	Color3.fromRGB(130, 220, 110),
	Color3.fromRGB(180, 120, 255),
}
local MACARONS = {
	Color3.fromRGB(255, 170, 200),
	Color3.fromRGB(170, 230, 190),
	Color3.fromRGB(200, 180, 255),
	Color3.fromRGB(255, 220, 150),
}
local DECOR: Geometry.PartOptions = { Name = "Decor", CanCollide = false, CastShadow = false }

type TierSpec = {
	Radius: number,
	Top: number, -- height of its top above the arena centre
	Height: number,
	Amplitude: number, -- radians it tilts
	Speed: number,
	Phase: number,
	Sponge: Color3,
	Frosting: Color3,
	Steps: { Radius: number, Count: number, Angle: number }?, -- macarons up to the next tier
	Sprinkles: number,
}

local TIERS: { TierSpec } = {
	{
		Radius = 42,
		Top = 0,
		Height = 10,
		Amplitude = 0.03,
		Speed = 1.2,
		Phase = 0,
		Sponge = Color3.fromRGB(255, 175, 205),
		Frosting = CREAM,
		Steps = { Radius = 29.5, Count = 4, Angle = math.pi / 4 },
		Sprinkles = 60,
	},
	{
		Radius = 26,
		Top = 7,
		Height = 10, -- its bottom sits well inside the tier below, so no gap opens as both wobble
		Amplitude = 0.045,
		Speed = 1.6,
		Phase = 2.1,
		Sponge = Color3.fromRGB(135, 85, 60),
		Frosting = Color3.fromRGB(255, 150, 190),
		Steps = { Radius = 14.5, Count = 3, Angle = 0 },
		Sprinkles = 30,
	},
	{
		Radius = 11,
		Top = 14,
		Height = 10,
		Amplitude = 0.055,
		Speed = 2,
		Phase = 4.2,
		Sponge = Color3.fromRGB(255, 225, 140),
		Frosting = CREAM,
		Steps = nil,
		Sprinkles = 12,
	},
}

local KingOfTheCake = {}

KingOfTheCake.Info = {
	Id = "KingOfTheCake",
	DisplayName = "King of the Cake",
	Type = "Final",
	Rules = `Stand on the top tier to fill your KING meter. First to {GOAL} seconds wins!`,
	Duration = DURATION,
	MinPlayers = 1,
} :: Types.MiniGameInfo

function KingOfTheCake.new(context: Types.RoundContext): Types.MiniGame
	local center = context.Origin.Position
	local random = context.Random
	local state = Match.GetFolder()
	local topTier = TIERS[#TIERS]
	local topCenter = center + Vector3.new(0, topTier.Top, 0)

	local tierModels: { Model } = {}
	local spinner: Model? = nil
	local running = false
	local spedUp = false
	local wobble = 1
	local seconds: { [Player]: number } = {}
	local shown: { [Player]: number } = {}
	local warned: { [Player]: boolean } = {}
	local winner: Player? = nil
	local counterText = ""

	-- A macaron step standing on `bottom`: two shells with filling between, all solid.
	local function buildMacaron(parent: Instance, bottom: Vector3, color: Color3)
		Geometry.column(parent, 1.4, 6, bottom, color, { Name = "Step" })
		Geometry.column(parent, 0.7, 5.4, bottom + Vector3.new(0, 1.4, 0), CREAM, { Name = "Step" })
		Geometry.column(parent, 1.4, 6, bottom + Vector3.new(0, 2.1, 0), color, { Name = "Step" })
	end

	local function buildTier(arena: Model, spec: TierSpec): Model
		local top = center + Vector3.new(0, spec.Top, 0)
		local amplitude = Vector3.new(spec.Amplitude, 0, spec.Amplitude)
		return Hazards.Swinger(arena, CFrame.new(top), amplitude, spec.Speed, spec.Phase, function(model)
			model.Name = "CakeTier"
			local diameter = spec.Radius * 2
			Geometry.column(model, spec.Height - 1.2, diameter, top - Vector3.new(0, spec.Height, 0), spec.Sponge, {
				Name = "Sponge",
			})
			-- Frosting on top (what you stand on), a little wider than the sponge, with drips.
			Geometry.column(model, 1.2, diameter + 1.2, top - Vector3.new(0, 1.2, 0), spec.Frosting, {
				Name = "Frosting",
			})
			local drips = math.floor(spec.Radius * 0.9)
			for index = 1, drips do
				local angle = index / drips * math.pi * 2
				local length = random:NextNumber(1.6, 3.4)
				local spot = top
					+ Vector3.new(
						math.cos(angle) * (spec.Radius + 0.3),
						-1.2 - length / 2,
						math.sin(angle) * (spec.Radius + 0.3)
					)
				Geometry.ellipsoid(model, Vector3.new(1.6, length + 1, 1.6), CFrame.new(spot), spec.Frosting, DECOR)
			end
			-- Sprinkles lying on the frosting (you walk through them).
			for _ = 1, spec.Sprinkles do
				local angle = random:NextNumber(0, math.pi * 2)
				local distance = math.sqrt(random:NextNumber(0, 1)) * (spec.Radius - 1.5)
				local spot = top + Vector3.new(math.cos(angle) * distance, 0.1, math.sin(angle) * distance)
				Geometry.block(
					model,
					Vector3.new(0.9, 0.25, 0.3),
					CFrame.new(spot) * CFrame.Angles(0, random:NextNumber(0, math.pi), 0),
					SPRINKLES[random:NextInteger(1, #SPRINKLES)],
					DECOR
				)
			end
			local steps = spec.Steps
			if steps then
				for index = 1, steps.Count do
					local angle = steps.Angle + (index - 1) / steps.Count * math.pi * 2
					local foot = top + Vector3.new(math.cos(angle) * steps.Radius, 0, math.sin(angle) * steps.Radius)
					buildMacaron(model, foot, MACARONS[(index - 1) % #MACARONS + 1])
				end
			end
		end)
	end

	-- The plate the cake stands on (solid, so whoever falls off lands on it), and giant treats
	-- round the outside (nothing there collides).
	local function buildScenery(arena: Model)
		local scenery = Geometry.model(arena, "Table")
		local plateTop = center + Vector3.new(0, PLATE_TOP, 0)
		Geometry.column(scenery, 2, 120, plateTop - Vector3.new(0, 2, 0), CREAM, { Name = "Plate" })
		Geometry.column(scenery, 1, 130, plateTop - Vector3.new(0, 2.6, 0), Color3.fromRGB(220, 215, 230), DECOR)
		for index = 1, 8 do
			local angle = index / 8 * math.pi * 2 + 0.2
			local spot = plateTop + Vector3.new(math.cos(angle) * 54, 0, math.sin(angle) * 54)
			if index % 2 == 0 then
				-- A strawberry.
				Geometry.ellipsoid(
					scenery,
					Vector3.new(6, 7, 6),
					CFrame.new(spot + Vector3.new(0, 3.2, 0)),
					Color3.fromRGB(235, 50, 70),
					DECOR
				)
				Geometry.ellipsoid(
					scenery,
					Vector3.new(5, 1, 5),
					CFrame.new(spot + Vector3.new(0, 6.6, 0)),
					Color3.fromRGB(80, 180, 70),
					DECOR
				)
			else
				-- A cherry on a stalk.
				Geometry.ball(scenery, 5, spot + Vector3.new(0, 2.5, 0), Color3.fromRGB(200, 20, 50), DECOR)
				Geometry.block(
					scenery,
					Vector3.new(0.4, 5, 0.4),
					CFrame.new(spot + Vector3.new(0.6, 6.5, 0)) * CFrame.Angles(0, 0, -0.3),
					Color3.fromRGB(90, 140, 50),
					DECOR
				)
			end
		end
		-- Floating candles high up round the cake.
		for index = 1, 10 do
			local angle = index / 10 * math.pi * 2
			local bottom = center + Vector3.new(math.cos(angle) * 75, random:NextNumber(14, 30), math.sin(angle) * 75)
			Geometry.column(scenery, 9, 2.4, bottom, SPRINKLES[index % #SPRINKLES + 1], DECOR)
			Geometry.ellipsoid(
				scenery,
				Vector3.new(1.4, 2.6, 1.4),
				CFrame.new(bottom + Vector3.new(0, 10.4, 0)),
				Color3.fromRGB(255, 170, 40),
				{ Name = "Decor", CanCollide = false, CastShadow = false, Material = Enum.Material.Neon }
			)
		end
	end

	-- The big candle in the middle of the top tier, its flame, and the bar it sweeps round.
	local function buildCandle(arena: Model)
		spinner = Hazards.Spinner(arena, topCenter, {
			ArmLength = topTier.Radius * 2 + 2,
			Speed = SPINNER_SPEED[1],
			Phase = random:NextNumber(0, math.pi * 2),
			Color = CANDLE,
			Mat = false,
		})
		Geometry.ellipsoid(
			arena,
			Vector3.new(1.6, 3, 1.6),
			CFrame.new(topCenter + Vector3.new(0, 7.2, 0)),
			Color3.fromRGB(255, 170, 40),
			{ Name = "Flame", CanCollide = false, CastShadow = false, Material = Enum.Material.Neon }
		)
	end

	local function isOnTop(root: BasePart): boolean
		local offset = root.Position - topCenter
		return Vector2.new(offset.X, offset.Z).Magnitude <= topTier.Radius + TOP_MARGIN and offset.Y >= TOP_MARGIN
	end

	local function leader(): (Player?, number)
		local best: Player? = nil
		local bestTime = 0
		for _, player in context.GetAlive() do
			local time = seconds[player] or 0
			if time > bestTime then
				best = player
				bestTime = time
			end
		end
		return best, bestTime
	end

	local function setCounter(text: string)
		if text ~= counterText then
			counterText = text
			context.SetCounterText(text)
		end
	end

	local function refreshCounter()
		local best, time = leader()
		if best then
			setCounter(`KING: {string.upper(best.DisplayName)} {math.floor(time)}/{GOAL}`)
		else
			setCounter("CLIMB TO THE TOP!")
		end
	end

	-- The cake wobbles harder as the round goes on (in small steps, so the tiers don't jump).
	local function updateWobble(t: number)
		local ramp = math.clamp((t - WOBBLE_RAMP[1]) / (WOBBLE_RAMP[2] - WOBBLE_RAMP[1]), 0, 1)
		local target = math.floor((1 + (WOBBLE_GROWTH - 1) * ramp) * 20 + 0.5) / 20
		if target == wobble then
			return
		end
		wobble = target
		for index, model in tierModels do
			local amplitude = TIERS[index].Amplitude * wobble
			model:SetAttribute("Amplitude", Vector3.new(amplitude, 0, amplitude))
		end
	end

	local function update(dt: number): boolean?
		context.EliminateBelow(center.Y - KILL_DEPTH)
		if not running then
			return nil
		end
		local now = context.GetServerTime()
		local t = math.clamp((now - context.GetStartTime()) / DURATION, 0, 1)
		updateWobble(t)
		local candle = spinner
		if candle and not spedUp and t >= 0.5 then
			spedUp = true
			Hazards.SetSpinnerSpeed(candle, SPINNER_SPEED[2], now)
			context.Announce("THE CAKE IS WOBBLING!")
		end

		for _, player in context.GetAlive() do
			local root = context.GetRoot(player)
			if not (root and isOnTop(root)) then
				continue
			end
			local time = math.min((seconds[player] or 0) + dt, GOAL)
			seconds[player] = time
			-- A quarter-second meter is plenty smooth and keeps attribute traffic down.
			local quarter = math.floor(time * 4) / 4
			if quarter ~= shown[player] then
				shown[player] = quarter
				player:SetAttribute(Match.PlayerAttr.RoundScore, quarter)
			end
			if time >= NEARLY and not warned[player] then
				warned[player] = true
				context.Announce(`{string.upper(player.DisplayName)} IS NEARLY KING!`)
			end
			if time >= GOAL and not winner then
				winner = player
			end
		end
		refreshCounter()
		return if winner then true else nil
	end

	local function setup()
		local arena = context.Arena
		for _, spec in TIERS do
			table.insert(tierModels, buildTier(arena, spec))
		end
		buildCandle(arena)
		buildScenery(arena)
		context.SpawnAll(ArenaUtil.RingSpots(center, SPAWN_RADIUS, #context.Players))
	end

	local function start()
		running = true
		for _, player in context.Players do
			seconds[player] = 0
			player:SetAttribute(Match.PlayerAttr.RoundScore, 0)
		end
		state:SetAttribute(Match.Attr.ScoreLabel, "KING")
		state:SetAttribute(Match.Attr.ScoreGoal, GOAL)
		refreshCounter()
	end

	local function finish()
		running = false
		state:SetAttribute(Match.Attr.ScoreGoal, nil)
		state:SetAttribute(Match.Attr.ScoreLabel, nil)
		for _, player in context.Players do
			if player.Parent == Players then
				player:SetAttribute(Match.PlayerAttr.RoundScore, nil)
			end
		end
	end

	-- Whoever filled their meter; else whoever's still on the cake with the fullest meter; else
	-- the last one standing.
	local function getQualified(): { Player }
		if winner then
			return { winner }
		end
		local best = leader()
		if best then
			setCounter(`{string.upper(best.DisplayName)} IS KING OF THE CAKE!`)
			return { best }
		end
		return context.DefaultQualified()
	end

	return {
		Setup = setup,
		Start = start,
		Update = update,
		End = finish,
		GetQualified = getQualified,
	}
end

return KingOfTheCake
