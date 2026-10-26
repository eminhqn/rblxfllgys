--!strict
-- Moving hazards are animated on every client from the synced server clock
-- (workspace:GetServerTimeNow()). Every player sees, and collides with, the same pose at the
-- same moment, the server never streams per-frame CFrames, and the server can recompute any pose
-- for validation.

local HazardMath = {}

local TAU = 2 * math.pi

-- Spinner models carry attributes Speed (radians/second, sign = direction) and Phase (radians).
function HazardMath.SpinnerAngle(speed: number, phase: number, serverTime: number): number
	return (phase + speed * serverTime) % TAU
end

-- Surface velocity of a spinner rotating about the vertical axis through `pivot`.
function HazardMath.SpinnerVelocityAt(pivot: Vector3, speed: number, point: Vector3): Vector3
	local offset = point - pivot
	-- angular velocity (0, speed, 0) crossed with the offset
	return Vector3.new(speed * offset.Z, 0, -speed * offset.X)
end

-- Riser parts carry attributes StartTime (server time, 0 = not started), Rate (studs/s) and
-- MaxRise (studs). Returns how far above its starting height the part should be. A negative Rate
-- and MaxRise make it sink instead (e.g. a race start gate dropping into the floor).
function HazardMath.RiserOffset(startTime: number, rate: number, maxRise: number, serverTime: number): number
	if startTime <= 0 then
		return 0
	end
	local offset = (serverTime - startTime) * rate
	return if maxRise >= 0 then math.clamp(offset, 0, maxRise) else math.clamp(offset, maxRise, 0)
end

-- Wobbler parts carry attributes Amplitude (radians), Speed (radians/second) and Phase (radians).
function HazardMath.WobbleAngle(amplitude: number, speed: number, phase: number, serverTime: number): number
	return amplitude * math.sin((speed * serverTime) % TAU + phase)
end

-- Mover models carry attributes Travel (Vector3: the furthest offset from home), Speed
-- (radians/second) and Phase (radians). They swing smoothly between home - Travel and
-- home + Travel.
-- Slider models (Tug of Wobble's rope) slide along their Axis: Offset studs at server time At,
-- then Velocity studs per second from there, kept between Min and Max. The server changes all
-- three together whenever the speed changes.
function HazardMath.SliderOffset(
	offset: number,
	velocity: number,
	at: number,
	min: number,
	max: number,
	serverTime: number
): number
	return math.clamp(offset + velocity * (serverTime - at), min, max)
end

function HazardMath.MoverOffset(travel: Vector3, speed: number, phase: number, serverTime: number): Vector3
	return travel * math.sin((speed * serverTime) % TAU + phase)
end

-- How fast a mover is going at that moment (lets Bloblets standing on it ride along).
function HazardMath.MoverVelocity(travel: Vector3, speed: number, phase: number, serverTime: number): Vector3
	return travel * (speed * math.cos((speed * serverTime) % TAU + phase))
end

export type CratePhase = "Waiting" | "Warning" | "Falling" | "Sliding" | "Gone"

-- Crate models carry attributes LandAt (server time it touches down), DropHeight (studs above the
-- landing spot it falls from), SlideVelocity (Vector3, e.g. the belt it lands on) and SlideTime.
-- A target circle warns where it will land for `warningTime`, then it falls for `fallTime`,
-- slides, and smashes. Returns the phase and the crate's offset from its landing spot.
function HazardMath.CratePose(
	landAt: number,
	fallTime: number,
	warningTime: number,
	dropHeight: number,
	slideVelocity: Vector3,
	slideTime: number,
	serverTime: number
): (CratePhase, Vector3)
	local fallStart = landAt - fallTime
	if serverTime < fallStart - warningTime then
		return "Waiting", Vector3.new(0, dropHeight, 0)
	elseif serverTime < fallStart then
		return "Warning", Vector3.new(0, dropHeight, 0)
	elseif serverTime < landAt then
		local progress = (serverTime - fallStart) / fallTime
		return "Falling", Vector3.new(0, dropHeight * (1 - progress * progress), 0)
	elseif serverTime < landAt + slideTime then
		return "Sliding", slideVelocity * (serverTime - landAt)
	end
	return "Gone", slideVelocity * slideTime
end

export type RollerPhase = "Waiting" | "Warning" | "Rolling" | "Gone"

-- Roller models (Balloon Barrage) carry attributes StartAt (server time it starts rolling),
-- Origin (Vector3: its centre at that moment), Velocity (Vector3), Duration (seconds of rolling),
-- Hop (studs; 0 = it rolls along the floor) and HopRate (hops per second). Arrows along its path
-- flash for `warningTime` first. Returns the phase, the centre position and how far it has rolled.
function HazardMath.RollerPose(
	startAt: number,
	origin: Vector3,
	velocity: Vector3,
	duration: number,
	hop: number,
	hopRate: number,
	warningTime: number,
	serverTime: number
): (RollerPhase, Vector3, number)
	if serverTime < startAt - warningTime then
		return "Waiting", origin, 0
	elseif serverTime < startAt then
		return "Warning", origin, 0
	end
	local elapsed = math.min(serverTime - startAt, duration)
	local position = origin + velocity * elapsed
	if hop > 0 then
		position += Vector3.new(0, math.abs(math.sin(math.pi * hopRate * elapsed)) * hop, 0)
	end
	local phase: RollerPhase = if serverTime < startAt + duration then "Rolling" else "Gone"
	return phase, position, velocity.Magnitude * elapsed
end

-- Swinger models (hammers, the wobbling cake) turn about their PrimaryPart, the pivot. They carry
-- attributes Amplitude (Vector3: the biggest angle, in radians, round the pivot's own X, Y and Z
-- axes), Speed (radians/second) and Phase (radians). X and Y swing in step and Z a quarter turn
-- behind, so amplitude on both X and Z makes a wobble that goes round and round. Returns the
-- angles to rotate by: pivot * CFrame.Angles(angles.X, angles.Y, angles.Z).
function HazardMath.SwingAngles(amplitude: Vector3, speed: number, phase: number, serverTime: number): Vector3
	local theta = (speed * serverTime) % TAU + phase
	local s, c = math.sin(theta), math.cos(theta)
	return Vector3.new(amplitude.X * s, amplitude.Y * s, amplitude.Z * c)
end

-- Spike traps carry attributes Period (seconds per cycle; 0 = always up), UpTime (seconds up each
-- cycle) and Phase (seconds). Each cycle they rise, stay up, sink, and stay down, peeking out
-- just before they rise again. Returns how far up they are, 0 (hidden) to 1 (fully up).
function HazardMath.SpikeRise(period: number, upTime: number, phase: number, serverTime: number): number
	if period <= 0 then
		return 1
	end
	local move = 0.12 -- seconds to rise or sink
	local peek = 0.7 -- seconds before rising that they poke out a little
	local t = (serverTime + phase) % period
	if t < move then
		return math.max(t / move, 0.3)
	elseif t < upTime then
		return 1
	elseif t < upTime + move then
		return 1 - (t - upTime) / move
	elseif t > period - peek then
		return 0.3
	end
	return 0
end

-- Jelly tiles carry attributes Level (how far they'd sunk at server time At, 0 to 1) and Rate
-- (per second: up while someone stands on them, down while nobody does). Returns how far they've
-- sunk now, 0 to 1 (1 = melted away).
function HazardMath.JellyLevel(level: number, rate: number, at: number, serverTime: number): number
	return math.clamp(level + rate * math.max(serverTime - at, 0), 0, 1)
end

-- Closest point on an oriented box (given by its CFrame and size) to a world point.
function HazardMath.ClosestPointOnBox(boxCFrame: CFrame, boxSize: Vector3, point: Vector3): Vector3
	local localPoint = boxCFrame:PointToObjectSpace(point)
	local half = boxSize / 2
	local clamped = Vector3.new(
		math.clamp(localPoint.X, -half.X, half.X),
		math.clamp(localPoint.Y, -half.Y, half.Y),
		math.clamp(localPoint.Z, -half.Z, half.Z)
	)
	return boxCFrame:PointToWorldSpace(clamped)
end

return table.freeze(HazardMath)
