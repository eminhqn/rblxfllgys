--!strict
-- Small helpers mini-games share when laying out arenas.

local ArenaUtil = {}

-- `count` ground-level spawn CFrames on a circle, each facing `lookAt` (default: the centre).
function ArenaUtil.RingSpots(center: Vector3, radius: number, count: number, lookAt: Vector3?): { CFrame }
	local spots: { CFrame } = {}
	local target = lookAt or center
	local total = math.max(count, 1)
	for index = 1, total do
		local angle = (index - 1) / total * math.pi * 2
		local position = center + Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius)
		local facing = Vector3.new(target.X, position.Y, target.Z)
		spots[index] = if (facing - position).Magnitude > 1e-3
			then CFrame.lookAt(position, facing)
			else CFrame.new(position)
	end
	return spots
end

-- Shortest distance from `point` to the infinite horizontal line through `linePoint` along
-- `direction` (all measured on the XZ plane).
function ArenaUtil.DistanceToLine(point: Vector3, linePoint: Vector3, direction: Vector3): number
	local flatDirection = Vector3.new(direction.X, 0, direction.Z).Unit
	local offset = Vector3.new(point.X - linePoint.X, 0, point.Z - linePoint.Z)
	return (offset - flatDirection * offset:Dot(flatDirection)).Magnitude
end

return ArenaUtil
