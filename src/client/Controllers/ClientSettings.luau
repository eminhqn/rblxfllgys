--!strict
-- This player's settings on this device (Shared/PlayerSettings): sound volume, camera moments,
-- camera shake and the controls hint. A change applies straight away (Changed fires) and is sent
-- to the server to be saved with the profile; when the profile first loads, its saved settings are
-- used. Other modules read Get() and listen to Changed.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local PlayerSettings = require(Shared.PlayerSettings)
local Remotes = require(Shared.Remotes)
local Signal = require(Shared.Signal)

local ProfileClient = require(script.Parent.ProfileClient)

local ClientSettings = {}

ClientSettings.Changed = Signal.new() :: Signal.Signal<PlayerSettings.Settings>

local SEND_DELAY = 0.6 -- changes made in quick succession are saved together

local current: PlayerSettings.Settings = table.clone(PlayerSettings.Defaults)
local adoptedSaved = false -- the profile's saved settings have been taken on
local changedLocally = false -- the player changed something before their profile arrived
local sendToken = 0

function ClientSettings.Get(): PlayerSettings.Settings
	return current
end

local function apply(settings: PlayerSettings.Settings)
	if PlayerSettings.Equal(settings, current) then
		return
	end
	current = settings
	ClientSettings.Changed:Fire(settings)
end

-- Changes some settings (only the fields given) and saves them shortly afterwards.
function ClientSettings.Set(changes: { [string]: any })
	local merged: { [string]: any } = table.clone(current) :: any
	for key, value in changes do
		merged[key] = value
	end
	apply(PlayerSettings.Sanitize(merged))
	changedLocally = true
	sendToken += 1
	local token = sendToken
	task.delay(SEND_DELAY, function()
		if token == sendToken then
			Remotes.Event("RequestSettings"):FireServer(current)
		end
	end)
end

function ClientSettings.Init()
	local function adoptSaved()
		if adoptedSaved or not ProfileClient.IsReady() then
			return
		end
		adoptedSaved = true
		if changedLocally then
			-- They already changed something on this device: keep that (it's being saved).
			return
		end
		apply(ProfileClient.GetSettings())
	end
	ProfileClient.Changed:Connect(adoptSaved)
	adoptSaved()
end

return ClientSettings
