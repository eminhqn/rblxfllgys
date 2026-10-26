--!strict
-- Each player's own settings, saved with their profile: sound and music volume, the camera
-- moments, camera shake and the controls hint. The client applies them straight away; the server only checks and
-- stores them (SettingsService).

local Config = require(script.Parent.Config)

export type Settings = {
	Volume: number, -- 0 to 1, every game sound
	Music: number, -- 0 to 1, the music and background sounds
	CameraMoments: boolean, -- the round intro glide and the winner camera
	CameraShake: boolean, -- shake on big hits and hard landings
	ControlsHint: boolean, -- the list of keys / buttons in the corner
}

local PlayerSettings = {}

PlayerSettings.Defaults = table.freeze({
	Volume = Config.Audio.Volume,
	Music = Config.Audio.Music,
	CameraMoments = true,
	CameraShake = true,
	ControlsHint = true,
} :: Settings)

PlayerSettings.VolumeStep = 0.1

local TOGGLES = { "CameraMoments", "CameraShake", "ControlsHint" }

-- Turns untrusted data (a saved profile, or whatever a client sent) into valid settings.
function PlayerSettings.Sanitize(raw: unknown): Settings
	local settings: Settings = table.clone(PlayerSettings.Defaults)
	if typeof(raw) ~= "table" then
		return settings
	end
	local data = raw :: any
	for _, key in { "Volume", "Music" } do
		local volume = data[key]
		if typeof(volume) == "number" and volume == volume and volume ~= math.huge and volume ~= -math.huge then
			(settings :: any)[key] = math.clamp(math.round(volume * 10) / 10, 0, 1)
		end
	end
	for _, key in TOGGLES do
		if typeof(data[key]) == "boolean" then
			(settings :: any)[key] = data[key]
		end
	end
	return settings
end

function PlayerSettings.Equal(a: Settings, b: Settings): boolean
	return a.Volume == b.Volume
		and a.Music == b.Music
		and a.CameraMoments == b.CameraMoments
		and a.CameraShake == b.CameraShake
		and a.ControlsHint == b.ControlsHint
end

return table.freeze(PlayerSettings)
