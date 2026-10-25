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
-- A shadow warns where it will land for `warningTime`, then it falls for `fallTime`, slides, and
-- smashes. Returns the phase and the crate's offset from its landing spot.
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
