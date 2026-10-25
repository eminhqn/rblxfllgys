--!strict
-- Every game sound plays through Sfx.Play(name), or Sfx.PlayAt(name, position) for a sound that
-- comes from somewhere in the world (it gets quieter with distance).
--
-- The defaults only use sounds that ship with Roblox (rbxasset://sounds/...), pitched and layered
-- into little tunes, so they work in any place without uploading anything. A sound is a list of
-- layers: one sound file at a volume and pitch, started Delay seconds after the first layer and,
-- optionally, cut off after Length seconds. To use your own uploaded audio instead, replace a
-- sound's layers, e.g. Dive = sound({ layer("rbxassetid://1234567", 0.6, 1) }).
--
-- Everything plays through one SoundGroup (WobbleSfx in SoundService), so the player's volume
-- setting (default Config.Audio.Volume) turns all of it up or down. Footsteps, jumping, landing and getting up are Roblox's built-in
-- character sounds and aren't in that group.
--
-- You also hear the players around you: their dives, kicks, grabs and bonks come from their
-- Bloblet, a bit quieter, and only while they're near the camera.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local Config = require(Shared.Config)
local Tags = require(Shared.Tags)

local ClientEvents = require(script.Parent.ClientEvents)
local ClientSettings = require(script.Parent.ClientSettings)

type Layer = {
	Id: string,
	Volume: number,
	Pitch: number,
	Delay: number,
	Length: number?,
}

type SoundDef = {
	Layers: { Layer },
	Jitter: number, -- random pitch change each time it plays (0.05 = up to 5% higher or lower)
	Gap: number, -- seconds before the same sound can play again (stops pile-ups)
}

-- Built-in sounds.
local JUMP = "rbxasset://sounds/action_jump.mp3"
local LAND = "rbxasset://sounds/action_jump_land.mp3"
local GET_UP = "rbxasset://sounds/action_get_up.mp3"
local STEP = "rbxasset://sounds/action_footsteps_plastic.mp3"
local WATER = "rbxasset://sounds/impact_water.mp3"
local WIND = "rbxasset://sounds/action_falling.ogg"
local BOOM = "rbxasset://sounds/impact_explosion_03.mp3"
local BLIP = "rbxasset://sounds/volume_slider.ogg"

local AUDIO = Config.Audio
local WORLD_SOUND_LIFETIME = 4 -- seconds a layer without a Length is allowed to ring on
local FADE_TIME = 0.08

-- Playback speed for a note `semitones` above the sound's own pitch.
local function semitone(semitones: number): number
	return 2 ^ (semitones / 12)
end

local function layer(id: string, volume: number, pitch: number, delay: number?, length: number?): Layer
	return { Id = id, Volume = volume, Pitch = pitch, Delay = delay or 0, Length = length }
end

-- A run of notes on one sound: each `semitones` entry above `pitch`, `spacing` seconds apart.
local function notes(
	id: string,
	volume: number,
	pitch: number,
	semitones: { number },
	spacing: number,
	start: number?
): { Layer }
	local list: { Layer } = {}
	for index, step in semitones do
		table.insert(list, layer(id, volume, pitch * semitone(step), (start or 0) + (index - 1) * spacing))
	end
	return list
end

-- Several notes at once.
local function chord(id: string, volume: number, semitones: { number }, delay: number): { Layer }
	local list: { Layer } = {}
	for _, step in semitones do
		table.insert(list, layer(id, volume, semitone(step), delay))
	end
	return list
end

local function join(lists: { { Layer } }): { Layer }
	local all: { Layer } = {}
	for _, list in lists do
		table.move(list, 1, #list, #all + 1, all)
	end
	return all
end

local function sound(layers: { Layer }, jitter: number?, gap: number?): SoundDef
	return { Layers = layers, Jitter = jitter or 0, Gap = gap or 0.04 }
end

local SOUNDS: { [string]: SoundDef } = {
	-- Your Bloblet (and the players near you).
	Dive = sound({ layer(JUMP, 0.5, 0.8), layer(WIND, 0.3, 1.7, 0, 0.35) }, 0.06),
	Bounce = sound(join({ { layer(JUMP, 0.7, 1.45) }, notes(BLIP, 0.35, 1, { 0, 7 }, 0.05) }), 0.04),
	Bonk = sound({ layer(LAND, 1, 0.6), layer(BOOM, 0.18, 2.4, 0, 0.3) }, 0.08),
	Grab = sound({ layer(STEP, 0.8, 1.3), layer(LAND, 0.35, 1.9) }, 0.06),
	Kick = sound({ layer(LAND, 0.8, 1.5), layer(WIND, 0.25, 2.2, 0, 0.22) }, 0.06),
	Splash = sound({ layer(WATER, 0.9, 1) }, 0.05),
	Respawn = sound({ layer(JUMP, 0.5, 0.65), layer(WIND, 0.3, 1.2, 0, 0.4) }),

	-- Hazards and pick-ups.
	CrateSmash = sound({ layer(LAND, 1, 0.45), layer(BOOM, 0.3, 1.8, 0, 0.5) }, 0.08),
	Pop = sound({ layer(LAND, 1, 2.2), layer(BOOM, 0.25, 3, 0, 0.3) }, 0.1),
	PaintSplash = sound({ layer(WATER, 1, 1.3) }, 0.08),
	PlatePop = sound({ layer(LAND, 0.8, 2.6), layer(BOOM, 0.15, 3.2, 0, 0.2) }, 0.15, 0.03),

	-- Round moments.
	CountdownTick = sound({ layer(BLIP, 0.9, 1), layer(LAND, 0.3, 1.6) }),
	Go = sound(join({ chord(BLIP, 0.7, { 12, 16, 19 }, 0), { layer(GET_UP, 0.8, 1.6), layer(JUMP, 0.5, 1.3) } })),
	Checkpoint = sound(join({ notes(BLIP, 0.7, 1, { 0, 4, 7 }, 0.07), { layer(JUMP, 0.4, 2) } })),
	Qualify = sound(join({ notes(BLIP, 0.8, 1, { 0, 4, 7, 12 }, 0.09), { layer(GET_UP, 0.8, 1.5, 0.3) } })),
	Eliminated = sound(join({ notes(BLIP, 0.7, 1, { 7, 3, 0, -5 }, 0.16), { layer(LAND, 0.6, 0.5, 0.62) } })),
	RoundOver = sound(notes(BLIP, 0.8, 1, { 19, 19, 24 }, 0.13)),
	Whoosh = sound({ layer(WIND, 0.35, 1.5, 0, 0.55) }, 0.05, 0.2),
	Announce = sound(join({ notes(BLIP, 0.7, 1, { 0, 7, 12 }, 0.08), { layer(JUMP, 0.4, 1.8) } })),

	-- The winner's celebration.
	WinnerJingle = sound(
		join({
			notes(BLIP, 0.8, 1, { 0, 4, 7, 12 }, 0.12),
			notes(BLIP, 0.8, 1, { 7, 12 }, 0.12, 0.6),
			chord(BLIP, 0.7, { 12, 16, 19 }, 0.96),
			{ layer(GET_UP, 0.8, 1.25, 0.96) },
		}),
		0,
		1
	),
	FireworkLaunch = sound({ layer(WIND, 0.3, 2.6, 0, 0.7) }, 0.1, 0),
	Firework = sound({ layer(BOOM, 0.8, 1), layer(BLIP, 0.25, semitone(24), 0.05) }, 0.15, 0),
	Cannon = sound({ layer(BOOM, 0.6, 1.6, 0, 0.6), layer(JUMP, 0.4, 0.6) }, 0.05, 0),

	-- Rewards and menus.
	Gumdrops = sound(notes(BLIP, 0.45, 1.4, { 0, 7 }, 0.05)),
	Crown = sound(join({ notes(BLIP, 0.7, 1, { 0, 4, 7, 12, 16 }, 0.07), { layer(GET_UP, 0.7, 1.25) } })),
	Unlock = sound(join({ notes(BLIP, 0.7, 1, { 0, 5, 9, 12 }, 0.06), { layer(GET_UP, 0.7, 1.7) } })),
	UiClick = sound({ layer(BLIP, 0.35, 1.3) }, 0.03, 0.03),
}

-- Other players' actions (their Bloblet's Action attribute) and the sound each one makes.
local OTHER_ACTIONS: { [string]: string } = {
	Dive = "Dive",
	Kick = "Kick",
	Grab = "Grab",
}

local Sfx = {}

local localPlayer = Players.LocalPlayer
local random = Random.new()
local group: SoundGroup? = nil
local folder: Folder? = nil
local lastPlayed: { [string]: number } = {}
local worldSoundsPlaying = 0
local watched: { [Model]: { RBXScriptConnection } } = {}

local function getGroup(): SoundGroup
	local existing = group
	if existing then
		return existing
	end
	local created = Instance.new("SoundGroup")
	created.Name = "WobbleSfx"
	created.Volume = AUDIO.Volume
	created.Parent = SoundService
	group = created
	return created
end

local function getFolder(): Folder
	local existing = folder
	if existing then
		return existing
	end
	local created = Instance.new("Folder")
	created.Name = "WobbleSfxPlaying"
	created.Parent = SoundService
	folder = created
	return created
end

-- The sound's definition, if it may play now (it isn't silent and didn't just play).
local function take(name: string): SoundDef?
	local def = SOUNDS[name]
	if not def or #def.Layers == 0 then
		return nil
	end
	local now = os.clock()
	if now - (lastPlayed[name] or -math.huge) < def.Gap then
		return nil
	end
	lastPlayed[name] = now
	return def
end

-- Creates one Sound per layer under `parent` and starts each at its delay.
local function playLayers(def: SoundDef, parent: Instance, volumeScale: number, ownsSounds: boolean)
	local pitch = 1 + random:NextNumber(-def.Jitter, def.Jitter)
	for _, entry in def.Layers do
		local instance = Instance.new("Sound")
		instance.SoundId = entry.Id
		instance.Volume = entry.Volume * volumeScale
		instance.PlaybackSpeed = entry.Pitch * pitch
		instance.SoundGroup = getGroup()
		instance.Parent = parent
		if ownsSounds then
			-- Each 2D sound cleans itself up; a world sound goes with its emitter.
			instance.Ended:Once(function()
				instance:Destroy()
			end)
		end
		local function start()
			if not instance.Parent then
				return
			end
			instance:Play()
			local length = entry.Length
			if length then
				task.delay(math.max(length - FADE_TIME, 0), function()
					if instance.Parent then
						local fade = TweenService:Create(instance, TweenInfo.new(FADE_TIME), { Volume = 0 })
						fade.Completed:Once(function()
							instance:Destroy()
						end)
						fade:Play()
					end
				end)
			end
		end
		if entry.Delay > 0 then
			task.delay(entry.Delay, start)
		else
			start()
		end
	end
end

-- Plays a sound "in your head" (same volume wherever the camera is).
function Sfx.Play(name: string)
	local def = take(name)
	if def then
		playLayers(def, getFolder(), 1, true)
	end
end

-- Plays a sound from a point in the world. `volumeScale` makes it quieter (other players).
function Sfx.PlayAt(name: string, position: Vector3, volumeScale: number?)
	if worldSoundsPlaying >= AUDIO.MaxPlaying then
		return
	end
	local def = take(name)
	if not def then
		return
	end
	local emitter = Instance.new("Attachment")
	emitter.Name = name
	emitter.Parent = Workspace.Terrain
	emitter.WorldPosition = position
	local lifetime = 0
	for _, entry in def.Layers do
		lifetime = math.max(lifetime, entry.Delay + (entry.Length or WORLD_SOUND_LIFETIME))
	end
	playLayers(def, emitter, volumeScale or 1, false)
	for _, child in emitter:GetChildren() do
		if child:IsA("Sound") then
			child.RollOffMinDistance = 12
			child.RollOffMaxDistance = 160
		end
	end
	worldSoundsPlaying += 1
	task.delay(lifetime, function()
		worldSoundsPlaying -= 1
		emitter:Destroy()
	end)
end

-- Sets the overall volume of every game sound (0 = silent, 1 = full).
function Sfx.SetVolume(volume: number)
	getGroup().Volume = math.clamp(volume, 0, 1)
end

-- A nearby player's Bloblet did something we should hear.
local function playFromBloblet(model: Model, name: string)
	if model == localPlayer.Character then
		return -- our own sounds come from ClientEvents, straight away
	end
	local root = model.PrimaryPart
	local camera = Workspace.CurrentCamera
	if not root or not camera then
		return
	end
	if (root.Position - camera.CFrame.Position).Magnitude > AUDIO.OthersMaxDistance then
		return
	end
	Sfx.PlayAt(name, root.Position, AUDIO.OthersVolume)
end

local function watchBloblet(instance: Instance)
	if not instance:IsA("Model") or watched[instance] or not instance:IsDescendantOf(Workspace) then
		return
	end
	local model = instance
	watched[model] = {
		model:GetAttributeChangedSignal("Action"):Connect(function()
			local action = model:GetAttribute("Action")
			local name = if typeof(action) == "string" then OTHER_ACTIONS[action] else nil
			if name then
				playFromBloblet(model, name)
			end
		end),
		model:GetAttributeChangedSignal("Ragdolled"):Connect(function()
			if model:GetAttribute("Ragdolled") == true then
				playFromBloblet(model, "Bonk")
			end
		end),
	}
end

local function unwatchBloblet(instance: Instance)
	if not instance:IsA("Model") then
		return
	end
	local connections = watched[instance]
	if connections then
		for _, connection in connections do
			connection:Disconnect()
		end
		watched[instance] = nil
	end
end

-- Every button in our menus clicks when pressed (except screens marked SilentButtons, like the
-- on-screen touch controls, which would click on every jump).
local function hookButton(instance: Instance)
	if not instance:IsA("GuiButton") then
		return
	end
	local button = instance
	button.Activated:Connect(function()
		local screen = button:FindFirstAncestorWhichIsA("LayerCollector")
		if screen and screen:GetAttribute("SilentButtons") == true then
			return
		end
		Sfx.Play("UiClick")
	end)
end

function Sfx.Init()
	getGroup()
	Sfx.SetVolume(ClientSettings.Get().Volume)
	ClientSettings.Changed:Connect(function(settings)
		Sfx.SetVolume(settings.Volume)
	end)

	ClientEvents.Dived:Connect(function()
		Sfx.Play("Dive")
	end)
	ClientEvents.Bounced:Connect(function()
		Sfx.Play("Bounce")
	end)
	ClientEvents.KnockedDown:Connect(function()
		Sfx.Play("Bonk")
	end)
	ClientEvents.GrabStarted:Connect(function()
		Sfx.Play("Grab")
	end)
	ClientEvents.Kicked:Connect(function()
		Sfx.Play("Kick")
	end)
	ClientEvents.Splashed:Connect(function()
		Sfx.Play("Splash")
	end)
	ClientEvents.Teleported:Connect(function()
		Sfx.Play("Respawn")
	end)

	CollectionService:GetInstanceAddedSignal(Tags.Bloblet):Connect(watchBloblet)
	CollectionService:GetInstanceRemovedSignal(Tags.Bloblet):Connect(unwatchBloblet)
	for _, instance in CollectionService:GetTagged(Tags.Bloblet) do
		watchBloblet(instance)
	end

	local playerGui = localPlayer:WaitForChild("PlayerGui")
	playerGui.DescendantAdded:Connect(hookButton)
	for _, descendant in playerGui:GetDescendants() do
		hookButton(descendant)
	end
end

return Sfx
