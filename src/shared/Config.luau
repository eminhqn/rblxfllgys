--!strict
-- Central tuning values. The server reads the same numbers when it validates client requests,
-- so movement feel and anti-cheat limits can never drift apart.

local Config = {}

Config.MaxPlayers = 30

Config.Movement = table.freeze({
	RunSpeed = 28,
	GroundAcceleration = 150, -- studs/s^2 while speeding up on the ground
	GroundDeceleration = 170, -- studs/s^2 while slowing down on the ground
	TurnAcceleration = 280, -- used when the stick points against the current velocity
	AirAcceleration = 150, -- high = lots of mid-air steering
	AirDeceleration = 70, -- how quickly you can stop in the air
	AirMomentumDrag = 25, -- speed boosts (dives, slide-jumps) fade this slowly in the air
	JumpVelocity = 46, -- with Workspace.Gravity = 160 this is a ~6.6 stud jump
	JumpCutMultiplier = 0.5, -- vertical speed kept when jump is released early
	FallGravityMultiplier = 1.55, -- extra gravity while falling makes jumps feel snappy
	MaxFallSpeed = 110,
	CoyoteTime = 0.12, -- seconds after leaving a ledge where jump still works
	JumpBufferTime = 0.14, -- seconds a jump press is remembered before landing
	JumpGroundLock = 0.12, -- ignore ground contact right after jumping
	HipHeight = 0.5,
	MaxSlopeAngle = 55,
	-- Slippery floors (parts with a Grip attribute below 1, e.g. Sugar Slopes' icing): speeding up,
	-- turning and stopping take longer, and you slide downhill at up to this many studs/s for
	-- every unit of slope steepness (sine of the angle) times how slippery it is.
	SlipperySlopeSlide = 60,
})

-- Dives can be steered mid-air. On landing the Bloblet does a short belly slide that the stick
-- can steer, and pressing jump cancels the slide into a jump that keeps the dive's speed.
Config.Dive = table.freeze({
	Speed = 46,
	GroundLift = 18,
	AirLift = 10,
	AirSteerSpeed = 18, -- how much the stick can bend a dive mid-air
	AirSteerAcceleration = 70,
	AirBrakeFraction = 0.55, -- pulling back mid-dive slows it down to this fraction of Speed
	MinAirTime = 0.12, -- ground contact this soon after launching is ignored
	MaxAirTime = 1.6,
	SlideTime = 0.3, -- length of the belly slide (jump cancels it sooner)
	SlideFriction = 120, -- studs/s^2 pulling the slide towards the speed the stick asks for
	SlideControl = 0.75, -- fraction of run speed you can steer towards while sliding
	SlideBrake = 400, -- studs/s^2 when pulling against the slide (stops it almost instantly)
	SlideStopSpeed = 2, -- a braked slide ends below this speed and gives control back
	Cooldown = 1.0,
	PoseTime = 1.2, -- fallback; the client ends the pose as soon as its slide ends
})

Config.Grab = table.freeze({
	Range = 5.5, -- root-to-root distance
	RangeSlack = 2.0, -- tolerance for latency between client and server positions
	FrontDot = 0.2, -- target must be roughly in front of the grabber
	Cooldown = 0.6,
	MaxHoldTime = 3,
	BreakDistance = 9,
	ReachSpeedMultiplier = 0.8, -- while the grab button is held
	GrabberSpeedMultiplier = 0.6, -- while holding someone
	VictimSpeedMultiplier = 0.4,
	VictimPullSpeed = 8,
	PoseTime = 0.4, -- reach pose shown to others when a grab misses
})

-- A kick knocks over whoever is right in front of you. The server picks the target.
Config.Kick = table.freeze({
	Range = 5.2, -- root-to-root distance
	RangeSlack = 2.0, -- tolerance for latency between client and server positions
	FrontDot = 0.35, -- target must be in front of the kicker
	Cooldown = 1.0,
	PoseTime = 0.35, -- how long others see the kick
	Knockback = 40, -- horizontal push given to the target
	Lift = 20,
	Strength = 0.1, -- ragdoll strength for the target (see Config.RagdollDuration)
})

-- Water (Rising Tide): falling in knocks you over and you float, then you can swim and jump out
-- before the drown timer runs out.
Config.Water = table.freeze({
	GraceTime = 3.5, -- seconds in the water before you're eliminated
	DryResetTime = 0.8, -- stay out this long for the timer to reset (so hopping doesn't cheat it)
	InWaterMargin = 0.9, -- server: your middle below surface + this counts as in the water
	EnterMargin = 0.6, -- client: when the splash starts
	FloatHeight = 0.3, -- where your middle floats, relative to the surface
	SplashRagdollTime = 1.0,
	SwimSpeedMultiplier = 0.55,
	SwimAcceleration = 60,
	DeepFallDepth = 14, -- this far under the surface counts as drowned straight away
})

Config.Ragdoll = table.freeze({
	MinDuration = 1.0,
	MaxDuration = 2.2,
	GetUpHop = 18,
	GetUpRecoverTime = 0.15,
	MinReportInterval = 0.4,
})

-- Knockdown strength (0-1) to ragdoll seconds. Shared so client and server agree.
function Config.RagdollDuration(strength: number): number
	local t = math.clamp(strength, 0, 1)
	return Config.Ragdoll.MinDuration + (Config.Ragdoll.MaxDuration - Config.Ragdoll.MinDuration) * t
end

Config.Hazards = table.freeze({
	KnockdownSpeed = 13, -- contact speed (studs/s) needed to ragdoll a Bloblet
	KnockbackMultiplier = 1.3,
	KnockbackLift = 26,
	HitCooldown = 0.7,
	UpdateDistance = 350, -- hazards further than this from the camera are not animated
	TileWarningTime = 3.0, -- falling tiles flash and shake this long before they drop
})

-- Crates (Conveyor Canyon): a flashing target circle marks the landing spot, the crate drops,
-- rides whatever belt it lands on, then smashes. Touching one knocks you over.
Config.Crates = table.freeze({
	Size = 4.4,
	WarningTime = 1.3, -- the target circle shows this long before the crate starts falling
	FallTime = 0.75,
	DropHeight = 55,
	ReplicationLead = 0.4, -- extra time so the crate reaches every client before its circle shows
	FallHitStrength = 0.6,
	SlideHitStrength = 0.25,
	FallKnockback = 26,
	SlideKnockback = 1.6, -- multiplies the crate's slide velocity
	HitLift = 22,
	RemoveAfter = 1.5, -- seconds after it smashes before the server deletes it
})

-- Giant balloons (Balloon Barrage): arrows on the floor flash, then the balloon rolls (or hops)
-- along it. Touching one knocks you over and away, maybe off the edge.
Config.Balloons = table.freeze({
	WarningTime = 1.6, -- the arrows flash this long before the balloon sets off
	ReplicationLead = 0.4, -- extra time so the balloon reaches every client before its arrows show
	HitMargin = 0.3, -- forgiveness: the hit sphere is this much smaller than the balloon
	Knockback = 46, -- push along the balloon's path
	SideKnockback = 18, -- push away from its centre
	Lift = 30,
	Strength = 0.45,
	RemoveAfter = 1, -- seconds after it rolls away before the server deletes it
})

-- Paint Grab power-ups the client needs to know about too.
Config.PaintPowers = table.freeze({
	GiantTime = 8, -- seconds a GIANT power-up lasts
	GiantScale = 1.8, -- how much bigger the Bloblet looks (its physics ball stays the same)
})

-- Race rounds: checkpoints, respawning after a fall, and the finish line.
Config.Race = table.freeze({
	RespawnCooldown = 1.0, -- ignore new falls this soon after a respawn (the teleport is in flight)
	GateSinkRate = -40, -- studs/s the start gate drops at GO
	GateSinkDepth = -14,
})

Config.Validation = table.freeze({
	CheckInterval = 0.5,
	MaxHorizontalSpeed = 75,
	StrikesBeforeCorrection = 3,
	TeleportGrace = 1.5,
	OutOfBoundsY = -40,
	OutOfBoundsRadius = 420,
	RespawnRequestCooldown = 3,
})

Config.Match = table.freeze({
	MinPlayers = 4, -- players needed in the queue before the countdown starts
	MinPlayersInStudio = 1, -- lets you test alone in Studio (published games use MinPlayers)
	QueueCountdown = 30, -- seconds, once MinPlayers are queued
	StudioQueueCountdown = 8, -- shorter wait when testing in Studio
	FullQueueCountdown = 5, -- seconds, once the queue reaches MaxPlayers
	LoadingTime = 3, -- screen covered while the arena is built and players are moved
	IntroTime = 5, -- round card, then 3-2-1-GO
	CountdownSeconds = 3,
	RoundOverTime = 4,
	WinnerTime = 9,
	EliminatedRespawnDelay = 1.6, -- time to see your fall before you're moved out to spectate
	UpdateRate = 10, -- mini-game Update() calls per second
	MaxRounds = 5, -- the last round is always a Final
	FinalThreshold = 6, -- from round 2 on, this many players or fewer go straight to the Final
	-- Share of players that qualify from each round type (at least one player is always eliminated).
	QualifyFraction = table.freeze({
		Race = 0.7,
		Survival = 0.6,
		Team = 0.5,
	}),
	ArenaOrigin = Vector3.new(0, 80, 2600), -- far from the lobby; arenas are built here
	-- Studio only: play these mini-game ids in this order (e.g. { "CloudCrown" }) to test one game.
	StudioForceRounds = table.freeze({ "SugarSlopes" }) :: { string },
})

-- Crowns buy items (Shared/Cosmetics has the prices). You win a Crown by winning a match, or
-- trade Gumdrops for one; Gumdrops come from simply playing rounds.
Config.Economy = table.freeze({
	StartingCrowns = 1, -- so new players can unlock something straight away
	StartingGumdrops = 100,
	RoundPlayed = 10, -- Gumdrops for every round you take part in
	RoundQualified = 20, -- extra Gumdrops for getting through a round (winning the final counts)
	MatchWinCrowns = 1, -- Crowns for winning the whole match
	GumdropsPerCrown = 500, -- the trade rate
	MaxCurrency = 1e9,
})

-- Saving player data (DataService).
Config.Data = table.freeze({
	StoreName = "WobbleRushProfiles_v1",
	AutosaveInterval = 60, -- seconds; also refreshes the session lock
	LockExpiry = 300, -- a lock not refreshed for this long belongs to a server that died
	LockWaitAttempts = 6, -- tries to load data another server still holds...
	LockWaitDelay = 5, -- ...this many seconds apart
	RetryDelays = table.freeze({ 1, 2, 4, 8 }), -- between attempts of a failed DataStore call
})

Config.Emote = table.freeze({
	MaxMoveSpeed = 6, -- emotes fade out while you run
})

-- Sound levels (client). The sounds themselves are listed in the client's Sfx module.
Config.Audio = table.freeze({
	Volume = 0.8, -- every game sound (the WobbleSfx SoundGroup in SoundService)
	OthersVolume = 0.55, -- other players' dives, kicks, grabs and bonks, relative to your own
	OthersMaxDistance = 110, -- studs; players further away than this aren't heard
	MaxPlaying = 24, -- world sounds playing at once; extra ones are skipped
})

-- Camera moments (client CameraDirector) and the winner's celebration (client Celebration).
Config.Cinematics = table.freeze({
	IntroFlyover = true, -- glide over the arena during the round card and countdown
	SettleBeforeGo = 0.9, -- seconds before GO! that the camera is back behind your Bloblet
	WinnerOrbit = true, -- swing round the podium after the match (players who were in it)
	Fireworks = 12, -- launched behind the podium while the winner celebrates
})

-- Testing helpers that only work in Studio (published games ignore them).
Config.Studio = table.freeze({
	-- Wandering dummy Bloblets in the lobby that jump, dive, kick and emote, so you can see how
	-- the game runs with a full server (try 29). They can't play matches.
	LoadTestBots = 0,
})

return table.freeze(Config)
