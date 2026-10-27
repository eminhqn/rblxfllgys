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
	-- Fallback; the client ends the pose as soon as its slide ends. Long, because a belly slide down
	-- a water slide lasts until you leave the water.
	PoseTime = 8,
})

Config.Grab = table.freeze({
	Range = 7, -- root-to-root distance
	RangeSlack = 2.0, -- tolerance for latency between client and server positions
	FrontDot = 0, -- target must be in front of the grabber (anywhere in the front half)
	Cooldown = 0.35,
	-- Holding GRAB keeps reaching: the server looks for something to grab this often, for up to
	-- MaxReachTime seconds, until something is grabbed or the button is let go.
	ReachInterval = 0.1,
	MaxReachTime = 8,
	MaxHoldTime = 3,
	BreakDistance = 11,
	ReachSpeedMultiplier = 0.8, -- while the grab button is held
	GrabberSpeedMultiplier = 0.6, -- while holding someone
	CarrySpeedMultiplier = 0.82, -- while carrying something (Egg Scramble's eggs)
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

-- A slap (the SLAPS item, Shared/Items) works like a kick but sends players much further. It only
-- works in matches, and a slap is used up only when it lands on someone.
Config.Slap = table.freeze({
	Range = 5.6, -- root-to-root distance
	RangeSlack = 2.0,
	FrontDot = 0.35,
	Cooldown = 2.0,
	PoseTime = 0.4,
	Knockback = 60, -- a kick's is 40
	Lift = 28,
	Strength = 0.35, -- ragdoll strength (a kick's is 0.1)
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
	SpinnerWarningTime = 3.0, -- a spinner added mid-round flashes (harmless) this long first
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
	StudioForceRounds = table.freeze({}) :: { string },
})

-- Bots (Server/Bots) fill a match when there aren't enough players, so nobody waits for a full
-- server and team rounds always have teams. They play every round like players do (run, jump,
-- dive, grab, kick, get knocked about) and can qualify or win. They only ever appear in matches.
Config.Bots = table.freeze({
	Enabled = true,
	FillTo = 12, -- competitors per match: bots join until there are this many
	-- With bots on, a match starts this long after the first player presses PLAY (more players
	-- can still join meanwhile). The usual QueueCountdown applies once MinPlayers are queued.
	QueueCountdown = 15,
	-- How good bots are, 0 (clumsy) to 1 (sharp): each bot gets a random skill in this range. Skill
	-- sets their running speed, how often they dodge hazards and how often they fluff a jump.
	SkillMin = 0.3,
	SkillMax = 0.85,
	-- How often a bot that has someone right in front of it kicks (per second) or grabs them.
	KickRate = 0.35,
	GrabRate = 0.15,
	Names = table.freeze({
		"Jellybean",
		"Sprinkles",
		"Gumdrop",
		"Waffles",
		"Marshmallow",
		"Pudding",
		"Bubbles",
		"Noodle",
		"Pickle",
		"Muffin",
		"Toffee",
		"Biscuit",
		"Nugget",
		"Pebble",
		"Doodle",
		"Sundae",
		"Cupcake",
		"Taffy",
		"Fudge",
		"Wiggles",
		"Pancake",
		"Dumpling",
		"Sprout",
		"Bonbon",
		"Popsicle",
		"Truffle",
		"Churro",
		"Mochi",
		"Kiwi",
		"Puddle",
		"Bean",
		"Scoop",
	}) :: { string },
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

-- Playing with friends and in parties (FriendService, PartyService).
Config.Social = table.freeze({
	-- Extra Gumdrops from a match's rounds when your Roblox friends play in the same match.
	FriendBonusOne = 0.15, -- one friend
	FriendBonusMore = 0.25, -- two or more
	PartyMaxSize = 4, -- a party always lands on the same team in team rounds
	PartyInviteTime = 30, -- seconds a party invite stays open
})

-- The leaderboards in the lobby (LeaderboardService). Scores are saved in ordered DataStores.
Config.Leaderboards = table.freeze({
	StoreVersion = 1, -- bump to start every board from scratch
	Rows = 10, -- players shown on each board
	RefreshInterval = 120, -- seconds between reading the top players
	WriteInterval = 120, -- seconds between saving players' scores
	LiveInterval = 10, -- seconds between mixing this server's latest scores into the boards
})

-- The parkour tower in the lobby playground (ParkourService, ParkourBoardService).
Config.Parkour = table.freeze({
	FirstFinishGumdrops = 150, -- for your first finish ever
	MinTime = 20, -- seconds; a faster "finish" isn't believed
	FallDrop = 14, -- falling this far below your checkpoint puts you back on it
	-- The "fastest today" board starts again every day at midnight UTC (when the daily challenges
	-- change). Whoever is fastest when the day ends wins these Gumdrops, paid the next time they
	-- play within PrizeDays days.
	DailyPrize = 1000,
	PrizeDays = 7,
	BoardRows = 10,
	BoardRefresh = 60, -- seconds between reading the saved board
})

-- Crowns sold for Robux (PurchaseService). Create a Developer Product for each pack in the Creator
-- Dashboard (your experience > Monetization > Developer Products), set its Robux price there, and
-- paste its id here. 0 = not set up yet (that pack shows as "coming soon" and can't be bought).
Config.CrownPacks = table.freeze({
	table.freeze({ Crowns = 5, ProductId = 3722401910 }),
	table.freeze({ Crowns = 15, ProductId = 3722401974 }),
	table.freeze({ Crowns = 40, ProductId = 3722402027 }),
	table.freeze({ Crowns = 100, ProductId = 3722402108 }),
	table.freeze({ Crowns = 500, ProductId = 3722402206 }),
})

-- Items bought with Robux in the ITEMS shop (Shared/Items has what each one is). Never sold for
-- Crowns. Players pick which ones to use at the start of each round.
Config.Items = table.freeze({
	MaxStack = 999, -- the most of one item a profile can hold
	SpeedMultiplier = 1.2, -- SPEED BOOST: running and swimming speed
	JumpMultiplier = 1.12, -- JUMP BOOST: jump launch speed (about 25% higher jumps)
	SlideTimeMultiplier = 2.2, -- SLIDE BOOST: belly slides after a dive last this much longer...
	SlideFrictionMultiplier = 0.45, -- ...and slow down this much more gently
	DoubleRewardsMultiplier = 2, -- DOUBLE REWARDS: Gumdrops and XP from the round
	ShieldHits = 3, -- SHIELD: knocks it takes (players or obstacles) before it breaks
	ShieldHitGrace = 1.0, -- seconds after a shield hit when the same knock can't count again
	RespawnOfferTime = 6, -- seconds you have to take a respawn after you're knocked out
	RespawnsPerRound = 1, -- respawns one player can use in a single round
	RespawnInFinal = true, -- false = no respawns in the final round
	-- Robux packs. Like Crown packs: create a Developer Product for each one in the Creator
	-- Dashboard, set its price there and paste its id here. 0 = not set up yet ("coming soon").
	-- Suggested prices are in the README (section 6, "Item packs").
	Packs = table.freeze({
		table.freeze({ Item = "Slap", Amount = 10, ProductId = 3722409852 }),
		table.freeze({ Item = "Respawn", Amount = 3, ProductId = 3722409931 }),
		table.freeze({ Item = "Speed", Amount = 3, ProductId = 3722410115 }),
		table.freeze({ Item = "Jump", Amount = 3, ProductId = 3722410157 }),
		table.freeze({ Item = "DoubleJump", Amount = 3, ProductId = 3722415389 }),
		table.freeze({ Item = "Slide", Amount = 3, ProductId = 3722410193 }),
		table.freeze({ Item = "Shield", Amount = 3, ProductId = 3722410222 }),
		table.freeze({ Item = "DoubleRewards", Amount = 2, ProductId = 3722410269 }),
	}),
})

-- Badges. Create each one in the Creator Dashboard (your experience > Engagement > Badges), then
-- paste its badge id here. 0 = not set up yet (nothing is awarded).
Config.Badges = table.freeze({
	FirstQualify = 0, -- get through any round
	ReachFinal = 0, -- play in a final
	FirstWin = 0, -- win a match
	TenWins = 0, -- win 10 matches
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
	Music = 0.6, -- the music and background sounds (the WobbleMusic SoundGroup), set apart from sounds
	OthersVolume = 0.55, -- other players' dives, kicks, grabs and bonks, relative to your own
	OthersMaxDistance = 110, -- studs; players further away than this aren't heard
	MaxPlaying = 24, -- world sounds playing at once; extra ones are skipped
})

-- Music (client MusicController, MusicSongs). Every round has its own song built from Roblox's own
-- sounds. To play your own uploaded music instead, put its asset id here under "Lobby", a round
-- type ("Race", "Survival", "Team", "Final") or a round id (e.g. "SplashSlide"); the most exact
-- one wins. Uploaded music loops, so pick tracks that loop well.
Config.Music = table.freeze({
	Tracks = table.freeze({}) :: { [string]: number },
	HurryAt = 10, -- seconds left in a round when the music speeds up and the HURRY sting plays
})

-- Camera moments (client CameraDirector) and the winner's celebration (client Celebration).
Config.Cinematics = table.freeze({
	IntroFlyover = true, -- glide over the arena during the round card and countdown
	SettleBeforeGo = 0.9, -- seconds before GO! that the camera is back behind your Bloblet
	WinnerOrbit = true, -- swing round the podium after the match (players who were in it)
	Fireworks = 12, -- launched behind the podium while the winner celebrates
})

-- The tutorial (TutorialService, Shared/Tutorial).
Config.Tutorial = table.freeze({
	Reward = 100, -- Gumdrops for finishing it the first time
	OfferDelay = 3, -- seconds after a new player's data loads before they're offered it
})

-- Timed events (Shared/Events), the same in every server. Times are UTC.
Config.Events = table.freeze({
	DoubleXP = table.freeze({
		Multiplier = 2,
		-- Every week from StartDay (1 = Monday ... 5 = Friday ... 7 = Sunday) at StartHour, for
		-- Hours hours. 54 hours from Friday 18:00 runs to Monday 00:00.
		StartDay = 5,
		StartHour = 18,
		Hours = 54,
		-- Extra double XP windows, as { From = unix time, To = unix time } (e.g. a holiday). Find
		-- unix times with any "epoch converter" website.
		Extra = table.freeze({}) :: { { From: number, To: number } },
	}),
})

-- The PREMIUM reward track (Shared/Progression): a Game Pass bought with Robux. Create the pass on
-- the Creator Dashboard (your experience > Monetization > Passes), set its price there and paste
-- its id here. 0 = not set up yet: the track still shows, but its UNLOCK button says so.
Config.Premium = table.freeze({
	GamePassId = 2058604261,
	PastTrackGumdrops = 100, -- each level after the track, on top of the free track's Gumdrops
})

-- Testing helpers that only work in Studio (published games ignore them).
Config.Studio = table.freeze({
	-- Wandering dummy Bloblets in the lobby that jump, dive, kick and emote, so you can see how
	-- the game runs with a full server (try 29). They can't play matches.
	LoadTestBots = 0,
	-- Match bots (Config.Bots) show a line over their heads saying what they're up to: where
	-- they're going, how far, whether they're waiting for a hazard or stuck. Keep it off.
	ShowBotThoughts = false,
	-- Multiplies all XP earned, to try the reward track quickly (e.g. 20). Keep it at 1.
	XPMultiplier = 1,
	-- Treat everyone in the server as friends, to try the friend bonus in a local test server
	-- (Test tab > Clients and Servers). Keep it off.
	EveryoneIsFriends = false,
	-- Make a parkour "day" this many minutes long (e.g. 3) to see the fastest-today board reset and
	-- its prize paid without waiting for midnight. Nothing is saved while it's on. Keep it at 0.
	ParkourDayMinutes = 0,
	-- Show the cosmetic shop as it will be this many days from now, to see (and buy) other items.
	-- Keep it at 0.
	ShopDaysAhead = 0,
	-- In Studio your profile is topped up to this many of every item (Shared/Items) when you join,
	-- to try them without buying any. If saving works in Studio they're saved to your own data
	-- (yours only). 0 = off.
	TestItems = 3,
	-- Act as if you own the PREMIUM track in Studio (its rewards are paid out as if you'd bought
	-- it, but owning it isn't saved). Buying it in Studio also works once GamePassId is set: Studio
	-- purchases are free tests. Keep it off.
	TestPremium = false,
	-- Take your PREMIUM track away again every time you join in Studio, so you can try buying it
	-- (again): your saved pass and premium level are reset, the premium-only items are taken back,
	-- and Roblox's own "you own this pass" (true for the game's creator) is ignored. Rewards that
	-- were paid in Crowns, Gumdrops or items stay. Keep it off (and TestPremium off with it).
	ResetPremium = false,
	-- "On" or "Off" forces the DOUBLE XP WEEKEND on or off in Studio, to see it without waiting for
	-- the weekend. "Auto" follows the real schedule. Keep it "Auto".
	DoubleXP = "Auto" :: "Auto" | "On" | "Off",
})

return table.freeze(Config)
