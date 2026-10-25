--!strict
-- The world around the lobby: a soft green ground, pastel hills with snowy caps and
-- lollipop trees. Marked Persistent so far-away scenery is always visible with streaming on.

local Geometry = require(script.Parent.Geometry)

local Backdrop = {}

local GROUND_COLOR = Color3.fromRGB(150, 226, 140)
local SNOW_COLOR = Color3.fromRGB(255, 252, 255)

local HILL_COLORS = {
	Color3.fromRGB(255, 182, 214),
	Color3.fromRGB(196, 176, 250),
	Color3.fromRGB(255, 206, 178),
	Color3.fromRGB(172, 214, 255),
}

local TREE_COLORS = {
	Color3.fromRGB(255, 92, 168),
	Color3.fromRGB(255, 200, 48),
	Color3.fromRGB(132, 104, 255),
	Color3.fromRGB(64, 214, 230),
}

local function hill(parent: Instance, angle: number, distance: number, width: number, height: number, color: Color3)
	local center = Vector3.new(math.cos(angle) * distance, -height * 0.18, math.sin(angle) * distance)
	local size = Vector3.new(width, height, width * 0.85)
	local facing = CFrame.new(center) * CFrame.Angles(0, -angle, 0)
	Geometry.ellipsoid(parent, size, facing, color, { Name = "Hill", CanCollide = false, CastShadow = false })

	-- A smaller ellipsoid that only pokes out near the summit reads as a snow cap.
	local capSize = Vector3.new(size.X * 0.5, size.Y * 0.32, size.Z * 0.5)
	local capCenter = center + Vector3.new(0, size.Y / 2 - capSize.Y * 0.375, 0)
	Geometry.ellipsoid(
		parent,
		capSize,
		CFrame.new(capCenter) * CFrame.Angles(0, -angle, 0),
		SNOW_COLOR,
		{ Name = "SnowCap", CanCollide = false, CastShadow = false }
	)
end

local function lollipopTree(parent: Instance, position: Vector3, color: Color3, scale: number)
	Geometry.column(parent, 9 * scale, 0.8 * scale, position, Color3.fromRGB(255, 255, 255), { Name = "TreeStick" })
	Geometry.ball(parent, 7 * scale, position + Vector3.new(0, 9 * scale + 2.5 * scale, 0), color, { Name = "TreeTop" })
end

export type Rect = {
	Min: Vector2, -- (X, Z)
	Max: Vector2,
}

local CLEARANCE = 10 -- trees stay this far outside the areas they're kept off

local function blocked(position: Vector3, keepClear: { Rect }): boolean
	for _, rect in keepClear do
		if
			position.X > rect.Min.X - CLEARANCE
			and position.X < rect.Max.X + CLEARANCE
			and position.Z > rect.Min.Y - CLEARANCE
			and position.Z < rect.Max.Y + CLEARANCE
		then
			return true
		end
	end
	return false
end

-- `keepClear`: ground (X, Z rectangles) the lobby stands on, where no trees grow.
function Backdrop.Build(parent: Instance, keepClear: { Rect }?): Model
	local model = Geometry.model(parent, "Backdrop")
	model.ModelStreamingMode = Enum.ModelStreamingMode.Persistent

	Geometry.column(model, 4, 2048, Vector3.new(0, -6, 0), GROUND_COLOR, { Name = "Ground", CastShadow = false })

	local random = Random.new(7)
	local hillCount = 14
	for index = 1, hillCount do
		local angle = (index / hillCount) * math.pi * 2 + random:NextNumber(-0.12, 0.12)
		local distance = random:NextNumber(560, 780)
		local width = random:NextNumber(260, 420)
		local height = random:NextNumber(170, 320)
		hill(model, angle, distance, width, height, HILL_COLORS[(index - 1) % #HILL_COLORS + 1])
	end

	for index = 1, 18 do
		local angle = (index / 18) * math.pi * 2 + random:NextNumber(-0.1, 0.1)
		local distance = random:NextNumber(120, 190)
		local position = Vector3.new(math.cos(angle) * distance, -2, math.sin(angle) * distance)
		local scale = random:NextNumber(0.8, 1.4)
		if not blocked(position, keepClear or {}) then
			lollipopTree(model, position, TREE_COLORS[(index - 1) % #TREE_COLORS + 1], scale)
		end
	end

	return model
end

return Backdrop
