--!strict
-- Music and background sounds.
--
--   * In the lobby: the lobby song.
--   * In a round: that round's own song (MusicSongs), quietly over the round card and countdown,
--     then full from GO!, fading out when the round ends. With 10 seconds left it speeds up, the
--     hi-hats double and a HURRY sting plays. Some rounds add background sounds: lapping water,
--     wind high up, bubbling syrup.
--   * Silent while the next arena loads and while the winner celebrates (the winner jingle plays).
--
-- Songs are played note by note from Roblox's built-in sounds (pitched like the Sfx jingles), so
-- nothing has to be uploaded. To play your own uploaded music instead for the lobby, a round type
-- or a round, put its asset id in Config.Music.Tracks. Everything here plays through the
-- WobbleMusic SoundGroup, whose volume is the player's MUSIC VOLUME setting.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")

local Shared = ReplicatedStorage.Shared
local Config = require(Shared.Config)
local Match = require(Shared.Match)

local ClientSettings = require(script.Parent.ClientSettings)
local MatchClient = require(script.Parent.MatchClient)
local MusicSongs = require(script.Parent.MusicSongs)
local Sfx = require(script.Parent.Sfx)

local MusicController = {}

local BLIP = "rbxasset://sounds/volume_slider.ogg"
local LAND = "rbxasset://sounds/action_jump_land.mp3"
local BOOM = "rbxasset://sounds/impact_explosion_03.mp3"
local WIND = "rbxasset://sounds/action_falling.ogg"
local SWIM = "rbxasset://sounds/action_swim.mp3"

type Voice = {
	Id: string,
	Pitch: number, -- playback speed for semitone 0
	Volume: number,
	Length: number?, -- seconds before it's cut off
}

-- How each instrument sounds.
local VOICES: { [string]: Voice } = {
	-- Songs write the tune an octave up and the bass two octaves down; these bring them back into a
	-- comfortable range for the blip sound.
	Lead = { Id = BLIP, Pitch = 0.5, Volume = 0.42 },
	Chord = { Id = BLIP, Pitch = 0.5, Volume = 0.2 },
	Bass = { Id = BLIP, Pitch = 2, Volume = 0.55 },
	Kick = { Id = LAND, Pitch = 0.5, Volume = 0.5, Length = 0.2 },
	Snare = { Id = BOOM, Pitch = 3.1, Volume = 0.14, Length = 0.09 },
	Hat = { Id = BLIP, Pitch = 6, Volume = 0.06, Length = 0.03 },
}

local POOL_SIZE = 6 -- sounds per instrument, so notes can ring over each other
local MUSIC_LEVEL = 0.55 -- the music under the game's sound effects
local INTRO_LEVEL = 0.5 -- quieter over the round card and countdown
local SPECTATE_LEVEL = 0.75
local FADE_TIME = 0.8 -- seconds to fade a song in or out
local HURRY_SPEED = 1.12 -- tempo in the last seconds of a round
local STALE_STEPS = 1 -- notes this late (after a hitch) are skipped rather than piled up

type Pool = { Sounds: { Sound }, Next: number }

type Playing = {
	Key: string, -- what's playing (a round id, a round type or "Lobby")
	Song: MusicSongs.Song?, -- nil when playing an uploaded track instead
	Track: Sound?,
	Position: number, -- sixteenth notes since it started
	LoopStart: number, -- Position where the current time round the loop started
	Next: number, -- index of the next note to play
	Level: number, -- 0 to 1, fades in and out
	Target: number,
	Ambience: Sound?,
	NextBubble: number,
}

local group: SoundGroup
local folder: Folder
local pools: { [string]: Pool } = {}
local stops: { { Sound: Sound, At: number } } = {}
local current: Playing? = nil
local fading: { Playing } = {} -- songs on their way out
local hurried = false
local stingRound = 0 -- the round number whose HURRY sting has played
local random = Random.new()

local function newSound(id: string, parent: Instance): Sound
	local sound = Instance.new("Sound")
	sound.SoundId = id
	sound.SoundGroup = group
	sound.Parent = parent
	return sound
end

local function playVoice(instrument: MusicSongs.Instrument, semitones: number, volume: number, level: number)
	local voice = VOICES[instrument]
	local pool = pools[instrument]
	local sound = pool.Sounds[pool.Next]
	pool.Next = pool.Next % #pool.Sounds + 1
	sound.PlaybackSpeed = voice.Pitch * 2 ^ (semitones / 12)
	sound.Volume = voice.Volume * volume * level
	sound.TimePosition = 0
	sound:Play()
	local length = voice.Length
	if length then
		table.insert(stops, { Sound = sound, At = os.clock() + length })
	end
end

-- An uploaded track for this key, if one is set in Config.Music.Tracks.
local function trackFor(key: string, roundType: string?): number?
	local tracks = Config.Music.Tracks
	local id = tracks[key] or (if roundType then tracks[roundType] else nil)
	return if id and id ~= 0 then id else nil
end

local function startAmbience(playing: Playing, kind: MusicSongs.Ambience?)
	if kind == "Water" or kind == "Wind" then
		local sound = newSound(if kind == "Water" then SWIM else WIND, folder)
		sound.Looped = true
		sound.PlaybackSpeed = if kind == "Water" then 0.8 else 0.55
		sound.Volume = 0
		sound:SetAttribute("BaseVolume", if kind == "Water" then 0.35 else 0.25)
		sound:Play()
		playing.Ambience = sound
	end
end

local function start(key: string, roundType: string?, target: number)
	local playing: Playing = {
		Key = key,
		Song = nil,
		Track = nil,
		Position = 0,
		LoopStart = 0,
		Next = 1,
		Level = 0,
		Target = target,
		Ambience = nil,
		NextBubble = 0,
	}
	local song = MusicSongs.Get(key, roundType)
	local trackId = trackFor(key, roundType)
	if trackId then
		local track = newSound(`rbxassetid://{trackId}`, folder)
		track.Looped = true
		track.Volume = 0
		track:Play()
		playing.Track = track
	else
		playing.Song = song
	end
	startAmbience(playing, song.Ambience)
	current = playing
end

local function stopPlaying(playing: Playing)
	local track = playing.Track
	if track then
		track:Destroy()
	end
	local ambience = playing.Ambience
	if ambience then
		ambience:Destroy()
	end
end

-- What should be playing now, and how loud (0 = fade it out).
local function wanted(): (string?, string?, number)
	if not MatchClient.IsInMatchFlow() then
		return "Lobby", nil, 1
	end
	local phase = MatchClient.GetPhase()
	local roundId = MatchClient.GetString(Match.Attr.RoundId)
	local roundType = MatchClient.GetString(Match.Attr.RoundType)
	if roundType == "" or (phase ~= "Intro" and phase ~= "Playing" and phase ~= "RoundOver") then
		return nil, nil, 0
	end
	local key = if roundId ~= "" then roundId else roundType
	if phase == "Intro" then
		return key, roundType, INTRO_LEVEL
	elseif phase == "RoundOver" then
		return key, roundType, 0
	end
	return key, roundType, if MatchClient.IsCompeting() then 1 else SPECTATE_LEVEL
end

-- The last seconds of a round: faster, busier, and a HURRY sting once.
local function updateHurry()
	local phase = MatchClient.GetPhase()
	local left = MatchClient.TimeLeft()
	hurried = phase == "Playing" and left > 0 and left <= Config.Music.HurryAt
	if hurried and MatchClient.IsInMatchFlow() then
		local round = MatchClient.GetNumber(Match.Attr.RoundNumber)
		if stingRound ~= round then
			stingRound = round
			Sfx.Play("HurryUp")
		end
	end
end

local function stepSong(playing: Playing, dt: number)
	local song = playing.Song
	if not song or #song.Notes == 0 then
		return
	end
	local loop = MusicSongs.LoopSteps
	local before = playing.Position
	local after = before + dt * song.Tempo / 60 * 4 * (if hurried then HURRY_SPEED else 1)
	if after - playing.LoopStart > loop * 2 then
		-- A long hitch: carry on from here rather than racing through everything missed.
		playing.LoopStart = after - after % loop
		playing.Next = 1
	end
	-- Every note that has come due since last time.
	while true do
		local note = song.Notes[playing.Next]
		local due = playing.LoopStart + note.Step
		if due > after then
			break
		end
		if after - due <= STALE_STEPS then
			playVoice(note.Instrument, note.Semitones, note.Volume, playing.Level)
		end
		playing.Next += 1
		if playing.Next > #song.Notes then
			playing.Next = 1
			playing.LoopStart += loop
		end
	end
	-- In the last seconds, sixteenth-note hi-hats over everything.
	if hurried and math.floor(after) > math.floor(before) then
		playVoice("Hat", 0, 1.3, playing.Level)
	end
	playing.Position = after
end

local function stepAmbience(playing: Playing, now: number)
	local ambience = playing.Ambience
	if ambience then
		local base = ambience:GetAttribute("BaseVolume")
		ambience.Volume = (if typeof(base) == "number" then base else 0.3) * playing.Level
	end
	local song = playing.Song
	local kind = if song then song.Ambience else nil
	if kind == "Bubbles" and now >= playing.NextBubble and playing.Level > 0.05 then
		-- Syrup bubbling: low "bloops", sometimes two at once.
		playing.NextBubble = now + random:NextNumber(0.25, 0.9)
		playVoice("Bass", random:NextNumber(-30, -20), 0.35 * playing.Level, 1)
	end
end

local function fadeTowards(playing: Playing, dt: number)
	local step = dt / FADE_TIME
	if playing.Level < playing.Target then
		playing.Level = math.min(playing.Level + step, playing.Target)
	elseif playing.Level > playing.Target then
		playing.Level = math.max(playing.Level - step, playing.Target)
	end
	local track = playing.Track
	if track then
		track.Volume = playing.Level
		track.PlaybackSpeed = if hurried then HURRY_SPEED else 1
	end
end

local function onHeartbeat(dt: number)
	local now = os.clock()
	for index = #stops, 1, -1 do
		local entry = stops[index]
		if now >= entry.At then
			entry.Sound:Stop()
			table.remove(stops, index)
		end
	end

	updateHurry()
	local key, roundType, level = wanted()
	local playing = current
	if playing and playing.Key ~= key then
		playing.Target = 0
		table.insert(fading, playing)
		current = nil
		playing = nil
	end
	if not playing and key and level > 0 then
		start(key, roundType, level)
		playing = current
	end
	if playing then
		playing.Target = level
		fadeTowards(playing, dt)
		stepSong(playing, dt)
		stepAmbience(playing, now)
	end
	for index = #fading, 1, -1 do
		local old = fading[index]
		fadeTowards(old, dt)
		stepSong(old, dt)
		stepAmbience(old, now)
		if old.Level <= 0 then
			stopPlaying(old)
			table.remove(fading, index)
		end
	end
end

local function applyVolume()
	group.Volume = ClientSettings.Get().Music * MUSIC_LEVEL
end

function MusicController.Init()
	group = Instance.new("SoundGroup")
	group.Name = "WobbleMusic"
	group.Parent = SoundService
	folder = Instance.new("Folder")
	folder.Name = "WobbleMusicPlaying"
	folder.Parent = SoundService
	for instrument, voice in VOICES do
		local pool: Pool = { Sounds = {}, Next = 1 }
		for _ = 1, POOL_SIZE do
			table.insert(pool.Sounds, newSound(voice.Id, folder))
		end
		pools[instrument] = pool
	end
	applyVolume()
	ClientSettings.Changed:Connect(applyVolume)
	RunService.Heartbeat:Connect(onHeartbeat)
end

return MusicController
