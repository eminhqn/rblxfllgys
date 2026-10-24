--!strict
-- Owns the lobby: builds it once, hands out spawn points and keeps the big screen up to date.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local Config = require(Shared.Config)

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

	Players.PlayerAdded:Connect(LobbyService.RefreshScreen)
	Players.PlayerRemoving:Connect(function()
		-- The leaving player is still listed during PlayerRemoving.
		task.defer(LobbyService.RefreshScreen)
	end)
	LobbyService.RefreshScreen()
end

-- Ground-level spawn CFrame on a random deck (facing the plaza).
function LobbyService.GetSpawnCFrame(): CFrame
	local spawns = getLobby().Spawns
	return spawns[math.random(#spawns)]
end

function LobbyService.GetWinnerSpot(): CFrame
	return getLobby().WinnerSpot
end

-- The line under the player count on the big screen (matchmaking and match progress).
function LobbyService.SetStatus(text: string)
	getLobby().Screen.Status.Text = text
end

function LobbyService.RefreshScreen()
	local screen = getLobby().Screen
	local players = Players:GetPlayers()
	screen.PlayerCount.Text = `{#players} / {Config.MaxPlayers}`
end

return LobbyService
