--!strict
-- Sound effect hooks. Every game sound is played through Sfx.Play(name) so you can swap in your
-- own uploaded audio by changing an Id below.
--
-- Footsteps, jump, landing and get-up sounds come from Roblox's built-in character sounds.
-- The defaults below reuse built-in sounds at different pitches. Entries with an empty Id are
-- hooks that stay silent until you add a sound.

local Debris = game:GetService("Debris")
local SoundService = game:GetService("SoundService")
local Workspace = game:GetService("Workspace")

local ClientEvents = require(script.Parent.ClientEvents)

type SoundDef = {
	Id: string,
	Volume: number,
	Pitch: number,
}

local SOUNDS: { [string]: SoundDef } = {
	Dive = { Id = "rbxasset://sounds/action_jump.mp3", Volume = 0.5, Pitch = 0.8 },
	Bounce = { Id = "rbxasset://sounds/action_jump.mp3", Volume = 0.7, Pitch = 1.45 },
	Bonk = { Id = "rbxasset://sounds/action_jump_land.mp3", Volume = 1, Pitch = 0.6 },
	Grab = { Id = "", Volume = 0.6, Pitch = 1 },
	Kick = { Id = "rbxasset://sounds/action_jump_land.mp3", Volume = 0.8, Pitch = 1.5 },
	Splash = { Id = "rbxasset://sounds/impact_water.mp3", Volume = 0.9, Pitch = 1 },
	CrateSmash = { Id = "rbxasset://sounds/action_jump_land.mp3", Volume = 1, Pitch = 0.45 },
	Checkpoint = { Id = "rbxasset://sounds/action_jump.mp3", Volume = 0.6, Pitch = 2 },
	Qualify = { Id = "rbxasset://sounds/action_get_up.mp3", Volume = 1, Pitch = 1.5 },
	Respawn = { Id = "rbxasset://sounds/action_jump.mp3", Volume = 0.5, Pitch = 0.65 },
	Pop = { Id = "rbxasset://sounds/action_jump_land.mp3", Volume = 1, Pitch = 2.2 },
	PaintSplash = { Id = "rbxasset://sounds/impact_water.mp3", Volume = 1, Pitch = 1.3 },
	UiClick = { Id = "", Volume = 0.5, Pitch = 1 },
}

local Sfx = {}

local folder: Folder? = nil

local function getFolder(): Folder
	local existing = folder
	if existing then
		return existing
	end
	local created = Instance.new("Folder")
	created.Name = "WobbleSfx"
	created.Parent = SoundService
	folder = created
	return created
end

function Sfx.Play(name: string)
	local def = SOUNDS[name]
	if not def or def.Id == "" then
		return
	end
	local sound = Instance.new("Sound")
	sound.SoundId = def.Id
	sound.Volume = def.Volume
	sound.PlaybackSpeed = def.Pitch
	sound.Parent = getFolder()
	sound.Ended:Once(function()
		sound:Destroy()
	end)
	sound:Play()
end

-- Plays a sound from a point in the world (it gets quieter with distance).
function Sfx.PlayAt(name: string, position: Vector3)
	local def = SOUNDS[name]
	if not def or def.Id == "" then
		return
	end
	local emitter = Instance.new("Attachment")
	emitter.Parent = Workspace.Terrain
	emitter.WorldPosition = position
	local sound = Instance.new("Sound")
	sound.SoundId = def.Id
	sound.Volume = def.Volume
	sound.PlaybackSpeed = def.Pitch
	sound.RollOffMinDistance = 12
	sound.RollOffMaxDistance = 160
	sound.Parent = emitter
	sound:Play()
	Debris:AddItem(emitter, 4)
end

function Sfx.Init()
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
end

return Sfx
