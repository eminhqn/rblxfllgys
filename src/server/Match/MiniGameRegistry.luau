--!strict
-- Finds every mini-game in ServerScriptService.Server.MiniGames and picks the next round.
--
-- Adding a mini-game = adding a ModuleScript to that folder (copy _Template.luau). Modules whose
-- name starts with "_" are ignored, so the template never shows up in a real match.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage.Shared.Config)
local Match = require(ReplicatedStorage.Shared.Match)
local Types = require(script.Parent.Types)

local MiniGameRegistry = {}

local modules: { Types.MiniGameModule } = {}
local byId: { [string]: Types.MiniGameModule } = {}
local random = Random.new()

local NON_FINAL_TYPES: { Types.RoundType } = { "Race", "Survival", "Team" }

local function validate(name: string, candidate: any): Types.MiniGameModule?
	if typeof(candidate) ~= "table" then
		warn(`[MiniGames] {name} must return a table`)
		return nil
	end
	local info = candidate.Info
	if typeof(info) ~= "table" or typeof(info.Id) ~= "string" or typeof(info.DisplayName) ~= "string" then
		warn(`[MiniGames] {name} needs Info.Id and Info.DisplayName`)
		return nil
	end
	if not Match.IsRoundType(info.Type) then
		warn(`[MiniGames] {name} has an unknown Info.Type ({tostring(info.Type)})`)
		return nil
	end
	if typeof(info.Duration) ~= "number" or info.Duration <= 0 then
		warn(`[MiniGames] {name} needs a positive Info.Duration`)
		return nil
	end
	if typeof(candidate.new) ~= "function" then
		warn(`[MiniGames] {name} needs a new(context) function`)
		return nil
	end
	return candidate :: Types.MiniGameModule
end

function MiniGameRegistry.Init()
	local folder = script.Parent.Parent.MiniGames
	for _, child in folder:GetChildren() do
		if not child:IsA("ModuleScript") or string.sub(child.Name, 1, 1) == "_" then
			continue
		end
		local ok, result = pcall(require, child)
		if not ok then
			warn(`[MiniGames] {child.Name} failed to load: {result}`)
			continue
		end
		local module = validate(child.Name, result)
		if module then
			if byId[module.Info.Id] then
				warn(`[MiniGames] duplicate id {module.Info.Id}`)
				continue
			end
			table.insert(modules, module)
			byId[module.Info.Id] = module
		end
	end
	if #modules == 0 then
		warn("[MiniGames] no mini-games found; matches can't start")
	end
end

local function playable(module: Types.MiniGameModule, aliveCount: number): boolean
	local info = module.Info
	if aliveCount < (info.MinPlayers or 1) then
		return false
	end
	if info.Type == "Team" then
		return aliveCount >= 2 * (info.TeamCount or 2) -- at least two players per team
	end
	return true
end

local function available(roundType: string, aliveCount: number, played: { [string]: boolean })
	local list: { Types.MiniGameModule } = {}
	for _, module in modules do
		if module.Info.Type == roundType and not played[module.Info.Id] and playable(module, aliveCount) then
			table.insert(list, module)
		end
	end
	return list
end

local function pickFrom(list: { Types.MiniGameModule }): Types.MiniGameModule?
	if #list == 0 then
		return nil
	end
	return list[random:NextInteger(1, #list)]
end

-- Chooses the next round: a random type, then a random game of that type that hasn't been played
-- this match. Round 1 prefers a race; once few players remain (or at MaxRounds) it's the Final.
function MiniGameRegistry.PickNext(
	roundNumber: number,
	aliveCount: number,
	played: { [string]: boolean }
): Types.MiniGameModule?
	if RunService:IsStudio() then
		local forcedId = Config.Match.StudioForceRounds[roundNumber]
		if forcedId then
			local forced = byId[forcedId]
			if forced then
				return forced
			end
			warn(`[MiniGames] StudioForceRounds lists unknown id {forcedId}`)
		end
	end

	local matchConfig = Config.Match
	local wantFinal = roundNumber >= matchConfig.MaxRounds
		or (roundNumber > 1 and aliveCount <= matchConfig.FinalThreshold)

	if not wantFinal then
		local types: { Types.RoundType } = {}
		for _, roundType in NON_FINAL_TYPES do
			if #available(roundType, aliveCount, played) > 0 then
				table.insert(types, roundType)
			end
		end
		if #types > 0 then
			local chosenType = if roundNumber == 1 and table.find(types, "Race")
				then "Race"
				else types[random:NextInteger(1, #types)]
			return pickFrom(available(chosenType, aliveCount, played))
		end
	end

	return pickFrom(available("Final", aliveCount, played))
end

function MiniGameRegistry.GetAll(): { Types.MiniGameModule }
	return table.clone(modules)
end

return MiniGameRegistry
