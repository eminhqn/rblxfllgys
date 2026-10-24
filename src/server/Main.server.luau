--!strict
-- Server entry point. Services start in dependency order.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = require(ReplicatedStorage.Shared.Remotes)

local Services = script.Parent.Services

Remotes.Setup()
require(Services.EnvironmentService).Init()
require(Services.PlayerState).Init()
require(Services.TeamService).Init()
require(Services.LobbyService).Init()
require(Services.ActionService).Init()
require(Services.CharacterService).Init()
require(Services.MovementValidator).Init()
