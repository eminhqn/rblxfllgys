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

-- The box round everything solid in `model` (parts you can stand on or bump into), ignoring
-- decoration, goo and water that can't be touched. Returns its centre and size, or nil if there's
-- nothing solid.
function ArenaUtil.SolidBounds(model: Instance): (Vector3?, Vector3?)
	local low = Vector3.one * math.huge
	local high = -Vector3.one * math.huge
	local found = false
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") and descendant.CanCollide then
			local cframe = descendant.CFrame
			local half = descendant.Size / 2
			-- Half the world-space extents of the rotated box.
			local extents = Vector3.new(
				math.abs(cframe.XVector.X) * half.X
					+ math.abs(cframe.YVector.X) * half.Y
					+ math.abs(cframe.ZVector.X) * half.Z,
				math.abs(cframe.XVector.Y) * half.X
					+ math.abs(cframe.YVector.Y) * half.Y
					+ math.abs(cframe.ZVector.Y) * half.Z,
				math.abs(cframe.XVector.Z) * half.X
					+ math.abs(cframe.YVector.Z) * half.Y
					+ math.abs(cframe.ZVector.Z) * half.Z
			)
			low = low:Min(cframe.Position - extents)
			high = high:Max(cframe.Position + extents)
			found = true
		end
	end
	if not found then
		return nil, nil
	end
	return (low + high) / 2, high - low
end

return ArenaUtil
