--!strict
-- Server entry point. Services start in dependency order.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = require(ReplicatedStorage.Shared.Remotes)

local Services = script.Parent.Services

Remotes.Setup()
require(Services.EnvironmentService).Init()
require(Services.PlayerState).Init()
require(Services.DataService).Init()
require(Services.TeamService).Init()
require(Services.LobbyService).Init()
require(Services.ActionService).Init()
require(Services.CharacterService).Init()
require(Services.ShopService).Init()
require(script.Parent.Match.MatchService).Init()
require(Services.MovementValidator).Init()
require(Services.BotService).Init() -- Studio load test only (Config.Studio)
