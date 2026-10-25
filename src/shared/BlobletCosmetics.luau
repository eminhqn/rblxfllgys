--!strict
-- Builds the wearable bits of a Bloblet from plain parts: body patterns, eyelashes, hats and
-- outfits (see Shared/Cosmetics for the list). Used by the server on real characters and by the
-- customise screen's preview.
--
-- Every piece is a massless, non-colliding part tagged with a "Cosmetic" attribute and held by a
-- Motor6D ("CosmeticJoint", parented to the piece) from VisualRoot, the point on the ground under
-- the Bloblet. Positions below are in VisualRoot space: +Y up, -Z is the way the Bloblet faces.
-- The client animator moves each piece with the body's squash and stretch (and growth), and spins
-- pieces that carry a "Spin" attribute (radians/second, round the piece's own up axis).

local Cosmetics = require(script.Parent.Cosmetics)

local BlobletCosmetics = {}

type Shape = "Ball" | "Block" | "Cylinder" | "Ellipsoid"

type Builder = {
	Model: Model,
	VisualRoot: BasePart,
	BodyColor: Color3,
	Center: Vector3, -- body centre
	Radius: number, -- body radius
}

local WHITE = Color3.fromRGB(255, 255, 255)
local INK = Color3.fromRGB(40, 30, 70)
local GOLD = Color3.fromRGB(255, 205, 64)
local PINK = Color3.fromRGB(255, 92, 168)
local ROSY = Color3.fromRGB(255, 140, 170)
local RED = Color3.fromRGB(226, 38, 72)
local AQUA = Color3.fromRGB(64, 214, 230)
local LEAF = Color3.fromRGB(90, 190, 70)
local UPRIGHT = CFrame.Angles(0, 0, math.pi / 2) -- turns a cylinder part to stand on its end

local function lighter(color: Color3, amount: number): Color3
	return color:Lerp(WHITE, amount)
end

local function add(builder: Builder, name: string, shape: Shape, size: Vector3, rest: CFrame, color: Color3): Part
	local part = Instance.new("Part")
	part.Name = name
	if shape == "Ball" then
		part.Shape = Enum.PartType.Ball
	elseif shape == "Cylinder" then
		part.Shape = Enum.PartType.Cylinder
	else
		part.Shape = Enum.PartType.Block
	end
	part.Size = size
	part.Color = color
	part.Material = Enum.Material.SmoothPlastic
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Massless = true
	part.CastShadow = false
	part:SetAttribute("Cosmetic", true)
	if shape == "Ellipsoid" then
		local mesh = Instance.new("SpecialMesh")
		mesh.MeshType = Enum.MeshType.Sphere
		mesh.Parent = part
	end
	local motor = Instance.new("Motor6D")
	motor.Name = "CosmeticJoint"
	motor.Part0 = builder.VisualRoot
	motor.Part1 = part
	motor.C0 = rest
	part.CFrame = builder.VisualRoot.CFrame * rest
	motor.Parent = part
	part.Parent = builder.Model
	return part
end

-- A point on the body's surface in `direction`, pushed in by `inset`.
local function onBody(builder: Builder, direction: Vector3, inset: number): Vector3
	return builder.Center + direction.Unit * (builder.Radius - inset)
end

-- How wide the body is at a height (for bands that wrap round it).
local function bodyRadiusAt(builder: Builder, height: number): number
	local dy = height - builder.Center.Y
	return math.sqrt(math.max(builder.Radius * builder.Radius - dy * dy, 0))
end

local function band(builder: Builder, name: string, height: number, thickness: number, extra: number, color: Color3)
	local diameter = (bodyRadiusAt(builder, height) + extra) * 2
	add(
		builder,
		name,
		"Cylinder",
		Vector3.new(thickness, diameter, diameter),
		CFrame.new(0, height, 0) * UPRIGHT,
		color
	)
end

-- A cylinder from `from` to `to`.
local function stick(builder: Builder, name: string, from: Vector3, to: Vector3, diameter: number, color: Color3)
	local middle = (from + to) / 2
	local rest = CFrame.lookAt(middle, to) * CFrame.Angles(0, math.pi / 2, 0)
	add(builder, name, "Cylinder", Vector3.new((to - from).Magnitude, diameter, diameter), rest, color)
end

-------------------------------------------------------------------------------------------------
-- Patterns
-------------------------------------------------------------------------------------------------

local SPOT_DIRECTIONS = {
	Vector3.new(0, 1, 0.3),
	Vector3.new(0.8, 0.5, 0.4),
	Vector3.new(-0.8, 0.5, 0.4),
	Vector3.new(0.95, -0.1, 0.3),
	Vector3.new(-0.95, -0.1, 0.3),
	Vector3.new(0.4, 0.2, 0.9),
	Vector3.new(-0.4, 0.2, 0.9),
	Vector3.new(0, -0.4, 0.95),
	Vector3.new(0.6, -0.6, 0.55),
	Vector3.new(-0.6, -0.6, 0.55),
	Vector3.new(0.75, -0.55, -0.45),
	Vector3.new(-0.75, -0.55, -0.45),
}

local PATTERNS: { [string]: (Builder) -> () } = {
	Belly = function(builder)
		add(
			builder,
			"Belly",
			"Ellipsoid",
			Vector3.new(2, 1.3, 0.6),
			CFrame.new(0, 1.35, -1.27),
			lighter(builder.BodyColor, 0.6)
		)
	end,
	RosyCheeks = function(builder)
		for _, side in { -1, 1 } do
			local position = onBody(builder, Vector3.new(side * 0.7, -0.1, -0.7), 0.05)
			local outward = (position - builder.Center).Unit
			add(
				builder,
				"Cheek",
				"Ellipsoid",
				Vector3.new(0.62, 0.36, 0.12),
				CFrame.lookAt(position, position + outward),
				ROSY
			)
		end
	end,
	Spots = function(builder)
		local color = lighter(builder.BodyColor, 0.55)
		for _, direction in SPOT_DIRECTIONS do
			add(builder, "Spot", "Ball", Vector3.one * 0.62, CFrame.new(onBody(builder, direction, 0.2)), color)
		end
	end,
	Stripes = function(builder)
		local color = lighter(builder.BodyColor, 0.6)
		band(builder, "Stripe", 1.05, 0.28, 0.05, color)
		band(builder, "Stripe", 1.5, 0.28, 0.05, color)
	end,
}

-------------------------------------------------------------------------------------------------
-- Eyes
-------------------------------------------------------------------------------------------------

-- Multipliers for the eye whites and pupils of each eye style.
local EYE_SCALES: { [string]: { Eye: Vector3, Pupil: Vector3 } } = {
	Classic = { Eye = Vector3.one, Pupil = Vector3.one },
	Big = { Eye = Vector3.new(1.22, 1.22, 1), Pupil = Vector3.new(1.3, 1.3, 1) },
	Dot = { Eye = Vector3.one, Pupil = Vector3.new(0.55, 0.55, 1) },
	Sleepy = { Eye = Vector3.new(1.05, 0.55, 1), Pupil = Vector3.new(1, 0.6, 1) },
	Lashes = { Eye = Vector3.one, Pupil = Vector3.one },
}

function BlobletCosmetics.EyeScales(style: string): (Vector3, Vector3)
	local scales = EYE_SCALES[style] or EYE_SCALES.Classic
	return scales.Eye, scales.Pupil
end

local function buildLashes(builder: Builder)
	for _, side in { -1, 1 } do
		for index = -1, 1 do
			local x = side * 0.56 + index * 0.24
			-- Outer lashes lean outwards.
			local rest = CFrame.new(x, 3.27, -1.42) * CFrame.Angles(-0.35, 0, -index * 0.35)
			add(builder, "Lash", "Block", Vector3.new(0.09, 0.38, 0.09), rest, INK)
		end
	end
end

-------------------------------------------------------------------------------------------------
-- Hats
-------------------------------------------------------------------------------------------------

local HATS: { [string]: (Builder) -> () } = {
	Beanie = function(builder)
		local color = Color3.fromRGB(132, 104, 255)
		add(builder, "Beanie", "Ellipsoid", Vector3.new(2.7, 1.5, 2.7), CFrame.new(0, 3.75, 0.05), color)
		band(builder, "BeanieRim", 3.35, 0.42, 0.08, WHITE)
		add(builder, "Pompom", "Ball", Vector3.one * 0.8, CFrame.new(0, 4.55, 0.05), WHITE)
	end,
	Bow = function(builder)
		for _, side in { -1, 1 } do
			add(
				builder,
				"BowLoop",
				"Ellipsoid",
				Vector3.new(1, 0.75, 0.45),
				CFrame.new(side * 0.55, 3.78, 0.2) * CFrame.Angles(0, 0, side * 0.35),
				PINK
			)
		end
		add(builder, "BowKnot", "Ball", Vector3.one * 0.42, CFrame.new(0, 3.75, 0.2), lighter(PINK, 0.3))
	end,
	Flower = function(builder)
		local base = Vector3.new(0.2, 3.65, 0.1)
		local head = Vector3.new(0.6, 4.45, 0.1)
		stick(builder, "Stem", base, head, 0.16, LEAF)
		add(
			builder,
			"Leaf",
			"Ellipsoid",
			Vector3.new(0.55, 0.16, 0.3),
			CFrame.new(base:Lerp(head, 0.45) + Vector3.new(0.2, 0, 0)) * CFrame.Angles(0, 0, 0.4),
			LEAF
		)
		add(builder, "FlowerMiddle", "Ball", Vector3.one * 0.42, CFrame.new(head), Color3.fromRGB(255, 210, 60))
		for index = 1, 6 do
			local angle = index / 6 * math.pi * 2
			local petal = head + Vector3.new(math.cos(angle) * 0.38, math.sin(angle) * 0.38, 0.02)
			add(builder, "Petal", "Ball", Vector3.one * 0.4, CFrame.new(petal), if index % 2 == 0 then PINK else WHITE)
		end
	end,
	TopHat = function(builder)
		local hat = CFrame.new(0.15, 3.6, 0.1) * CFrame.Angles(0, 0, -0.12)
		local color = Color3.fromRGB(60, 48, 100)
		add(builder, "Brim", "Cylinder", Vector3.new(0.14, 2.4, 2.4), hat * UPRIGHT, color)
		add(builder, "HatTop", "Cylinder", Vector3.new(1.5, 1.5, 1.5), hat * CFrame.new(0, 0.75, 0) * UPRIGHT, color)
		add(builder, "HatBand", "Cylinder", Vector3.new(0.32, 1.54, 1.54), hat * CFrame.new(0, 0.25, 0) * UPRIGHT, PINK)
	end,
	Propeller = function(builder)
		add(
			builder,
			"Cap",
			"Ellipsoid",
			Vector3.new(2.3, 1.1, 2.3),
			CFrame.new(0, 3.55, 0),
			Color3.fromRGB(255, 200, 48)
		)
		add(builder, "Stick", "Cylinder", Vector3.new(0.5, 0.14, 0.14), CFrame.new(0, 4.3, 0) * UPRIGHT, WHITE)
		for index, color in { RED, Color3.fromRGB(80, 156, 255) } do
			local blade = add(
				builder,
				"Blade",
				"Block",
				Vector3.new(2, 0.06, 0.32),
				CFrame.new(0, 4.56, 0) * CFrame.Angles(0, (index - 1) * math.pi / 2, 0),
				color
			)
			blade:SetAttribute("Spin", 14)
		end
	end,
	Crown = function(builder)
		add(builder, "CrownBand", "Cylinder", Vector3.new(0.55, 1.7, 1.7), CFrame.new(0, 3.75, 0) * UPRIGHT, GOLD)
		for index = 1, 5 do
			local angle = index / 5 * math.pi * 2 + math.pi / 2
			local point = Vector3.new(math.cos(angle) * 0.8, 4.12, math.sin(angle) * 0.8)
			add(builder, "CrownPoint", "Ball", Vector3.one * 0.36, CFrame.new(point), GOLD)
		end
		add(builder, "CrownGem", "Ball", Vector3.one * 0.3, CFrame.new(0, 3.75, -0.86), PINK)
	end,
}

-------------------------------------------------------------------------------------------------
-- Outfits
-------------------------------------------------------------------------------------------------

local OUTFITS: { [string]: (Builder) -> () } = {
	BowTie = function(builder)
		for _, side in { -1, 1 } do
			add(
				builder,
				"TieLoop",
				"Ellipsoid",
				Vector3.new(0.6, 0.45, 0.22),
				CFrame.new(side * 0.33, 1.75, -1.58) * CFrame.Angles(0, 0, side * 0.25),
				RED
			)
		end
		add(builder, "TieKnot", "Ball", Vector3.one * 0.28, CFrame.new(0, 1.75, -1.68), lighter(RED, 0.2))
	end,
	Scarf = function(builder)
		band(builder, "Scarf", 1.7, 0.5, 0.15, AQUA)
		local tail = CFrame.new(0.75, 1.15, -1.55) * CFrame.Angles(0.15, 0, 0.12)
		add(builder, "ScarfTail", "Block", Vector3.new(0.55, 1.2, 0.18), tail, AQUA)
		add(builder, "ScarfStripe", "Block", Vector3.new(0.57, 0.18, 0.2), tail * CFrame.new(0, -0.25, 0), WHITE)
	end,
	Tutu = function(builder)
		local count = 14
		local radius = bodyRadiusAt(builder, 0.95) + 0.12
		for index = 1, count do
			local angle = index / count * math.pi * 2
			local position = Vector3.new(math.cos(angle) * radius, 0.95, math.sin(angle) * radius)
			add(
				builder,
				"TutuPuff",
				"Ball",
				Vector3.one * 0.8,
				CFrame.new(position),
				if index % 2 == 0 then Color3.fromRGB(255, 170, 214) else WHITE
			)
		end
	end,
	Cape = function(builder)
		add(
			builder,
			"Cape",
			"Ellipsoid",
			Vector3.new(2.7, 2.9, 0.22),
			CFrame.new(0, 1.85, 1.62) * CFrame.Angles(0.12, 0, 0),
			RED
		)
	end,
}

-------------------------------------------------------------------------------------------------
-- Public
-------------------------------------------------------------------------------------------------

-- Removes every cosmetic piece from a Bloblet.
function BlobletCosmetics.Clear(model: Model)
	for _, child in model:GetChildren() do
		if child:GetAttribute("Cosmetic") == true then
			child:Destroy()
		end
	end
end

-- Replaces a Bloblet's pattern, lashes, hat and outfit. Item ids come from Shared/Cosmetics.
function BlobletCosmetics.Build(
	model: Model,
	visualRoot: BasePart,
	bodyColor: Color3,
	bodyCenter: Vector3,
	bodyRadius: number,
	itemIds: { string }
)
	BlobletCosmetics.Clear(model)
	local builder: Builder = {
		Model = model,
		VisualRoot = visualRoot,
		BodyColor = bodyColor,
		Center = bodyCenter,
		Radius = bodyRadius,
	}
	for _, id in itemIds do
		local entry = Cosmetics.Get(id)
		if not entry then
			continue
		end
		local style = Cosmetics.Style(id)
		local build: ((Builder) -> ())? = if entry.Slot == "Pattern"
			then PATTERNS[style]
			elseif entry.Slot == "Hat" then HATS[style]
			elseif entry.Slot == "Outfit" then OUTFITS[style]
			elseif entry.Slot == "Eyes" and style == "Lashes" then buildLashes
			else nil
		if build then
			build(builder)
		end
	end
end

return table.freeze(BlobletCosmetics)
