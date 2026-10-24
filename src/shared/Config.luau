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
	AirAcceleration = 100, -- high = lots of mid-air steering
	AirDeceleration = 35,
	JumpVelocity = 46, -- with Workspace.Gravity = 160 this is a ~6.6 stud jump
	JumpCutMultiplier = 0.5, -- vertical speed kept when jump is released early
	FallGravityMultiplier = 1.55, -- extra gravity while falling makes jumps feel snappy
	MaxFallSpeed = 110,
	CoyoteTime = 0.12, -- seconds after leaving a ledge where jump still works
	JumpBufferTime = 0.14, -- seconds a jump press is remembered before landing
	JumpGroundLock = 0.12, -- ignore ground contact right after jumping
	HipHeight = 0.5,
	MaxSlopeAngle = 55,
})

-- After a dive lands, the Bloblet belly-slides on its momentum with no steering, jumping, diving
-- or grabbing until the slide ends and it has popped back up.
Config.Dive = table.freeze({
	Speed = 46,
	GroundLift = 18,
	AirLift = 10,
	MinAirTime = 0.12, -- ground contact this soon after launching is ignored
	MaxAirTime = 1.6,
	SlideFriction = 80, -- studs/s^2 the belly slide loses
	SlideStopSpeed = 6, -- the slide ends below this speed...
	SlideMaxTime = 0.6, -- ...or after this long
	RecoverTime = 0.25, -- pop-up after the slide, still no control
	Cooldown = 1.0,
	PoseTime = 1.0, -- how long other players see the dive pose
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

-- Bright candy colours handed out until the customisation screen exists (Milestone 6).
Config.DefaultBodyColors = table.freeze({
	Color3.fromRGB(255, 92, 168),
	Color3.fromRGB(64, 214, 230),
	Color3.fromRGB(132, 104, 255),
	Color3.fromRGB(255, 200, 48),
	Color3.fromRGB(116, 222, 92),
	Color3.fromRGB(255, 132, 72),
	Color3.fromRGB(80, 156, 255),
	Color3.fromRGB(255, 120, 120),
	Color3.fromRGB(190, 110, 255),
	Color3.fromRGB(40, 200, 160),
})

return table.freeze(Config)
