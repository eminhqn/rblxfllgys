--!strict
-- Server entry point. Services start in dependency order.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = require(ReplicatedStorage.Shared.Remotes)

local Services = script.Parent.Services
local SoftShutdown = require(Services.SoftShutdown)

-- A temporary holding server during an update runs none of the game (see SoftShutdown).
if SoftShutdown.IsHoldingServer() then
	SoftShutdown.RunHoldingServer()
	return
end

Remotes.Setup()
require(Services.EnvironmentService).Init()
require(Services.PlayerState).Init()
require(Services.DataService).Init()
require(Services.TeamService).Init()
require(Services.LobbyService).Init()
require(Services.ActionService).Init()
require(Services.CharacterService).Init()
require(Services.ShopService).Init()
require(Services.PurchaseService).Init()
require(Services.SettingsService).Init()
require(Services.FriendService).Init()
require(Services.PartyService).Init()
require(Services.ProgressService).Init()
require(Services.LeaderboardService).Init()
require(Services.ParkourBoardService).Init()
require(Services.ParkourService).Init()
require(script.Parent.Match.MatchService).Init()
require(Services.MovementValidator).Init()
require(Services.BotService).Init() -- Studio load test only (Config.Studio)
SoftShutdown.Init()
