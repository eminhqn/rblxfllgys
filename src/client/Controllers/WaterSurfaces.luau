--!strict
-- Where the water is right now. HazardController moves water parts (Riser parts with a Water
-- attribute) every frame and records their current top here; MovementController asks it whether
-- the local Bloblet is in the water.

local WaterSurfaces = {}

type Surface = {
	Top: number,
	Center: Vector3,
	HalfSize: Vector2, -- X and Z half extents
}

local surfaces: { [BasePart]: Surface } = {}

function WaterSurfaces.Update(part: BasePart, cframe: CFrame)
	surfaces[part] = {
		Top = cframe.Position.Y + part.Size.Y / 2,
		Center = cframe.Position,
		HalfSize = Vector2.new(part.Size.X / 2, part.Size.Z / 2),
	}
end

function WaterSurfaces.Remove(part: BasePart)
	surfaces[part] = nil
end

-- Height of the water surface above `position`, or nil if there's no water there.
function WaterSurfaces.GetSurfaceAt(position: Vector3): number?
	local best: number? = nil
	for _, surface in surfaces do
		local offset = position - surface.Center
		if math.abs(offset.X) <= surface.HalfSize.X and math.abs(offset.Z) <= surface.HalfSize.Y then
			if not best or surface.Top > best then
				best = surface.Top
			end
		end
	end
	return best
end

return WaterSurfaces
