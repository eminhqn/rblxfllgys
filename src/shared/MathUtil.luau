--!strict
-- Small math helpers shared by movement, animation and server validation.

local MathUtil = {}

function MathUtil.flat(vector: Vector3): Vector3
	return Vector3.new(vector.X, 0, vector.Z)
end

function MathUtil.isFiniteNumber(value: number): boolean
	return value == value and value ~= math.huge and value ~= -math.huge
end

function MathUtil.isFiniteVector(vector: Vector3): boolean
	return MathUtil.isFiniteNumber(vector.X) and MathUtil.isFiniteNumber(vector.Y) and MathUtil.isFiniteNumber(vector.Z)
end

-- Moves `current` towards `target` by at most `maxDelta`.
function MathUtil.moveTowards(current: Vector3, target: Vector3, maxDelta: number): Vector3
	local delta = target - current
	local distance = delta.Magnitude
	if distance <= maxDelta or distance < 1e-6 then
		return target
	end
	return current + delta / distance * maxDelta
end

function MathUtil.clampMagnitude(vector: Vector3, maxMagnitude: number): Vector3
	local magnitude = vector.Magnitude
	if magnitude > maxMagnitude and magnitude > 0 then
		return vector / magnitude * maxMagnitude
	end
	return vector
end

-- Frame-rate independent exponential smoothing. `rate` is roughly "1/seconds to settle".
function MathUtil.damp(current: number, target: number, rate: number, dt: number): number
	return target + (current - target) * math.exp(-rate * dt)
end

function MathUtil.dampVector2(current: Vector2, target: Vector2, rate: number, dt: number): Vector2
	return target + (current - target) * math.exp(-rate * dt)
end

return MathUtil
