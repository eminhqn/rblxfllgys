--!strict
-- Saves each player's settings (volume, camera moments, camera shake, controls hint) with their
-- profile. The client applies a change straight away and sends the whole set; this checks it
-- (Shared/PlayerSettings.Sanitize clamps and fills in anything odd) and stores it.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local PlayerSettings = require(Shared.PlayerSettings)
local Remotes = require(Shared.Remotes)

local DataService = require(script.Parent.DataService)
local RateLimiter = require(script.Parent.Parent.Util.RateLimiter)

local SettingsService = {}

local limiter = RateLimiter.new(5, 1)

local function onRequestSettings(player: Player, raw: unknown)
	if not limiter:Allow(player) then
		return
	end
	local settings = PlayerSettings.Sanitize(raw)
	local profile = DataService.Get(player)
	if not profile or PlayerSettings.Equal(profile.Settings, settings) then
		return
	end
	DataService.Update(player, function(current: DataService.Profile)
		current.Settings = settings
	end)
end

function SettingsService.Init()
	Remotes.Event("RequestSettings").OnServerEvent:Connect(onRequestSettings)
end

return SettingsService
