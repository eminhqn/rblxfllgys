--!strict
-- Owns the lobby: builds it once, hands out spawn points and keeps the big screen up to date.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local Config = require(Shared.Config)
local Teams = require(Shared.Teams)

local Builders = script.Parent.Parent.Builders
local Backdrop = require(Builders.Backdrop)
local LobbyBuilder = require(Builders.LobbyBuilder)

local LobbyService = {}

local lobby: LobbyBuilder.Lobby? = nil

local function getLobby(): LobbyBuilder.Lobby
	assert(lobby, "LobbyService.Init must run first")
	return lobby
end

function LobbyService.Init()
	Backdrop.Build(Workspace)
	lobby = LobbyBuilder.Build(Workspace)

	-- Joins are refreshed by CharacterService once the player has a team.
	Players.PlayerRemoving:Connect(function()
		-- The leaving player is still listed during PlayerRemoving.
		task.defer(LobbyService.RefreshScreen)
	end)
	LobbyService.RefreshScreen()
end

-- Ground-level spawn CFrame on the team's deck (facing the plaza).
function LobbyService.GetSpawnCFrame(teamId: string?): CFrame
	local spawns = getLobby().Spawns
	local teamSpawns = if teamId then spawns[teamId] else nil
	local options: { CFrame } = if teamSpawns and #teamSpawns > 0 then teamSpawns else spawns[Teams.List[1].Id]
	return options[math.random(#options)]
end

function LobbyService.RefreshScreen()
	local screen = getLobby().Screen
	local players = Players:GetPlayers()
	screen.PlayerCount.Text = `{#players} / {Config.MaxPlayers}`

	local counts: { [string]: number } = {}
	for _, player in players do
		local team = Teams.FromPlayer(player)
		if team then
			counts[team.Id] = (counts[team.Id] or 0) + 1
		end
	end
	for _, team in Teams.List do
		screen.TeamCounts[team.Id].Text = `{string.upper(team.Id)}  {counts[team.Id] or 0}`
	end
end

return LobbyService
