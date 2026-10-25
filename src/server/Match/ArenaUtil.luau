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

-- `count` ground-level spots in rows behind each other, centred on `center` and facing its
-- LookVector (a starting grid). Rows fill front to back.
function ArenaUtil.GridSpots(center: CFrame, count: number, columns: number, spacing: number): { CFrame }
	local spots: { CFrame } = {}
	local total = math.max(count, 1)
	local rows = math.ceil(total / columns)
	for index = 1, total do
		local row = (index - 1) // columns
		local column = (index - 1) % columns
		local inRow = math.min(columns, total - row * columns)
		local x = (column - (inRow - 1) / 2) * spacing
		local z = (row - (rows - 1) / 2) * spacing
		spots[index] = center * CFrame.new(x, 0, z)
	end
	return spots
end

-- True if `point` is inside the box `size` centred on `cframe`.
function ArenaUtil.InBox(cframe: CFrame, size: Vector3, point: Vector3): boolean
	local localPoint = cframe:PointToObjectSpace(point)
	return math.abs(localPoint.X) <= size.X / 2
		and math.abs(localPoint.Y) <= size.Y / 2
		and math.abs(localPoint.Z) <= size.Z / 2
end

-- Shortest distance from `point` to the infinite horizontal line through `linePoint` along
-- `direction` (all measured on the XZ plane).
function ArenaUtil.DistanceToLine(point: Vector3, linePoint: Vector3, direction: Vector3): number
	local flatDirection = Vector3.new(direction.X, 0, direction.Z).Unit
	local offset = Vector3.new(point.X - linePoint.X, 0, point.Z - linePoint.Z)
	return (offset - flatDirection * offset:Dot(flatDirection)).Magnitude
end

return ArenaUtil
