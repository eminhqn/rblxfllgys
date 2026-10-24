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
-- MaxRise (studs). Returns how far above its starting height the part should be.
function HazardMath.RiserOffset(startTime: number, rate: number, maxRise: number, serverTime: number): number
	if startTime <= 0 then
		return 0
	end
	return math.clamp((serverTime - startTime) * rate, 0, maxRise)
end

-- Wobbler parts carry attributes Amplitude (radians), Speed (radians/second) and Phase (radians).
function HazardMath.WobbleAngle(amplitude: number, speed: number, phase: number, serverTime: number): number
	return amplitude * math.sin((speed * serverTime) % TAU + phase)
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
