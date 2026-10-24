--!strict
-- TEMPLATE: copy this file to make a new mini-game.
--
--   1. Duplicate this file in the same folder and rename it, e.g. "HotPotato.luau"
--      (no leading underscore; files starting with "_" are ignored, which is why this template
--      never shows up in a real match).
--   2. Change Info below. Info.Id must match the file name.
--   3. Fill in Setup / Start / Update / End / GetQualified.
--   4. In Studio, set Config.Match.StudioForceRounds = { "HotPotato" } to play just your game.
--
-- That's all: MiniGameRegistry finds the module on its own and MatchService handles the queue,
-- screens, round card, countdown, counters, eliminations, spectating and the winner.
--
-- Good habits:
--   * Build everything inside context.Arena, relative to context.Origin.
--   * Let clients animate moving hazards (tag parts Spinner / Wobbler / Riser / FallingTile, see
--     Shared/Tags and HazardController) and keep the server to rules and checks.
--   * Update runs about 10 times a second, not every frame. Prefer events where you can.
--   * Call context.Qualify / context.Eliminate. Never trust anything a client says.

local Builders = script.Parent.Parent.Builders
local Geometry = require(Builders.Geometry)
local ArenaUtil = require(script.Parent.Parent.Match.ArenaUtil)
local Types = require(script.Parent.Parent.Match.Types)

local PLATFORM_SIZE = 60
local FALL_DEPTH = 15

local Template = {}

Template.Info = {
	Id = "_Template",
	DisplayName = "Template",
	Type = "Survival", -- "Race" | "Survival" | "Team" | "Final"
	Rules = "Stay on the platform until time runs out!",
	Duration = 30,
	MinPlayers = 1,
} :: Types.MiniGameInfo

function Template.new(context: Types.RoundContext): Types.MiniGame
	local floorTop = context.Origin.Position.Y

	-- Build the map and place everyone. Players stay frozen until Start.
	local function setup()
		local center = context.Origin.Position
		Geometry.column(
			context.Arena,
			2,
			PLATFORM_SIZE,
			center - Vector3.new(0, 2, 0),
			Color3.fromRGB(255, 255, 255),
			{ Name = "Floor" }
		)
		context.SpawnAll(ArenaUtil.RingSpots(center, PLATFORM_SIZE / 3, #context.Players))
	end

	-- GO! Start timers, turn hazards on.
	local function start() end

	-- About 10 times a second. Return true to end the round early.
	local function update(_dt: number): boolean?
		context.EliminateBelow(floorTop - FALL_DEPTH)
		return nil
	end

	-- Stop anything you started (the arena itself is destroyed for you).
	local function finish() end

	-- Who goes through. DefaultQualified suits most Race/Survival/Final games.
	local function getQualified(): { Player }
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

return Template
