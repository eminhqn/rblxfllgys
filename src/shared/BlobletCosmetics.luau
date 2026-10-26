--!strict
-- Builds the wearable bits of a Bloblet from plain parts: body patterns, eyelashes, hats and
-- outfits (see Shared/Cosmetics for the list), and the slapper held in a round. Used by the server
-- on real characters and by the customise screen's preview.
--
-- Slappers are different: their pieces are welded to the right arm (so they swing with it) and
-- tagged "SlapperPiece" instead of "Cosmetic", so changing clothes leaves them alone. They're
-- built in "grip space": the hand at the origin, the slapper running down -Y (tilted forward).
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
local STAR = Color3.fromRGB(255, 220, 70)
local METAL = Color3.fromRGB(160, 170, 196)
local FLAME = Color3.fromRGB(255, 150, 40)
local WING = Color3.fromRGB(214, 196, 255)
local HEART = Color3.fromRGB(255, 80, 130)
local WIZARD = Color3.fromRGB(96, 64, 200)
local HORN = Color3.fromRGB(250, 236, 200)
local GLASS = Color3.fromRGB(190, 230, 255)
local DRAGON = Color3.fromRGB(220, 60, 70)
local SHELL = Color3.fromRGB(90, 170, 90)
local RAINBOW = {
	Color3.fromRGB(255, 80, 90),
	Color3.fromRGB(255, 150, 60),
	Color3.fromRGB(255, 220, 70),
	Color3.fromRGB(110, 210, 90),
	Color3.fromRGB(70, 160, 255),
	Color3.fromRGB(160, 100, 255),
}
local UPRIGHT = CFrame.Angles(0, 0, math.pi / 2) -- turns a cylinder part to stand on its end

local function lighter(color: Color3, amount: number): Color3
	return color:Lerp(WHITE, amount)
end

-- A plain, massless, non-colliding part for a cosmetic.
local function newPart(name: string, shape: Shape, size: Vector3, color: Color3): Part
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
	if shape == "Ellipsoid" then
		local mesh = Instance.new("SpecialMesh")
		mesh.MeshType = Enum.MeshType.Sphere
		mesh.Parent = part
	end
	return part
end

local function add(builder: Builder, name: string, shape: Shape, size: Vector3, rest: CFrame, color: Color3): Part
	local part = newPart(name, shape, size, color)
	part:SetAttribute("Cosmetic", true)
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
	-- Little four-pointed golden stars dotted over the body.
	Stars = function(builder)
		for index, direction in SPOT_DIRECTIONS do
			if index % 3 == 0 then
				continue -- fewer than the spots, so they read as stars
			end
			local position = onBody(builder, direction, 0.04)
			local facing = CFrame.lookAt(position, position + (position - builder.Center).Unit)
			local twist = index * 0.7
			for _, turn in { 0, math.pi / 2 } do
				local point = add(
					builder,
					"Star",
					"Block",
					Vector3.new(0.62, 0.15, 0.06),
					facing * CFrame.Angles(0, 0, twist + turn),
					STAR
				)
				point.Material = Enum.Material.Neon
			end
		end
	end,
	-- A few darker dots on each cheek.
	Freckles = function(builder)
		local color = builder.BodyColor:Lerp(INK, 0.45)
		for _, side in { -1, 1 } do
			for _, offset in
				{ Vector2.new(0, 0), Vector2.new(0.13, 0.1), Vector2.new(-0.11, 0.12), Vector2.new(0.07, -0.11) }
			do
				local direction = Vector3.new(side * (0.62 + offset.X), -0.05 + offset.Y, -0.78)
				add(builder, "Freckle", "Ball", Vector3.one * 0.15, CFrame.new(onBody(builder, direction, 0.05)), color)
			end
		end
	end,
	-- Little pink hearts dotted over the body.
	Hearts = function(builder)
		for index, direction in SPOT_DIRECTIONS do
			if index % 2 == 0 then
				continue
			end
			local position = onBody(builder, direction, 0.03)
			local facing = CFrame.lookAt(position, position + (position - builder.Center).Unit)
				* CFrame.Angles(0, 0, (index % 3 - 1) * 0.3)
			for _, side in { -1, 1 } do
				add(
					builder,
					"Heart",
					"Ellipsoid",
					Vector3.new(0.3, 0.3, 0.08),
					facing * CFrame.new(side * 0.1, 0.06, 0),
					HEART
				)
			end
			add(
				builder,
				"Heart",
				"Block",
				Vector3.new(0.27, 0.27, 0.06),
				facing * CFrame.new(0, -0.05, 0) * CFrame.Angles(0, 0, math.pi / 4),
				HEART
			)
		end
	end,
	-- A zigzag line all the way round the middle.
	Zigzag = function(builder)
		local color = lighter(builder.BodyColor, 0.7)
		local count = 18
		local points: { Vector3 } = {}
		for index = 0, count do
			local angle = index / count * math.pi * 2
			local height = 1.55 + (if index % 2 == 0 then 0.2 else -0.2)
			local radius = bodyRadiusAt(builder, height) + 0.02
			points[index + 1] = Vector3.new(math.cos(angle) * radius, height, math.sin(angle) * radius)
		end
		for index = 1, count do
			stick(builder, "Zigzag", points[index], points[index + 1], 0.16, color)
		end
	end,
	-- Bands in every colour of the rainbow.
	Rainbow = function(builder)
		for index, color in RAINBOW do
			band(builder, "Rainbow", 0.85 + (index - 1) * 0.3, 0.3, 0.04, color)
		end
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
	Googly = { Eye = Vector3.new(1.35, 1.35, 1), Pupil = Vector3.new(0.5, 0.5, 1) },
	Beady = { Eye = Vector3.new(0.72, 0.72, 1), Pupil = Vector3.new(0.85, 0.85, 1) },
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
	-- A striped cone with a pom-pom, worn at an angle.
	PartyHat = function(builder)
		local hat = CFrame.new(0.2, 3.5, 0.05) * CFrame.Angles(0, 0, -0.15)
		local stripes = { PINK, Color3.fromRGB(255, 210, 60), AQUA, PINK, Color3.fromRGB(255, 210, 60) }
		for index, color in stripes do
			local diameter = 1.55 - (index - 1) * 0.28
			add(
				builder,
				"PartyHat",
				"Cylinder",
				Vector3.new(0.34, diameter, diameter),
				hat * CFrame.new(0, (index - 0.5) * 0.32, 0) * UPRIGHT,
				color
			)
		end
		add(builder, "PartyPompom", "Ball", Vector3.one * 0.42, hat * CFrame.new(0, 1.75, 0), WHITE)
	end,
	-- A spiralled golden horn on the forehead.
	UnicornHorn = function(builder)
		local base = Vector3.new(0, 3.45, -0.85)
		local direction = Vector3.new(0, 0.88, -0.48).Unit
		for index = 0, 4 do
			local from = base + direction * index * 0.32
			local to = from + direction * 0.36
			stick(builder, "Horn", from, to, 0.5 - index * 0.085, if index % 2 == 0 then GOLD else WHITE)
		end
		add(builder, "HornTip", "Ball", Vector3.one * 0.14, CFrame.new(base + direction * 1.66), WHITE)
	end,
	-- A glowing golden ring floating over the head.
	Halo = function(builder)
		local center = CFrame.new(0, 4.55, 0.1) * CFrame.Angles(0.15, 0, 0)
		local segments = 10
		local radius = 0.85
		local length = 2 * radius * math.sin(math.pi / segments) + 0.05
		for index = 1, segments do
			local angle = index / segments * math.pi * 2
			local spot = center * CFrame.Angles(0, angle, 0) * CFrame.new(0, 0, -radius)
			local piece = add(builder, "Halo", "Block", Vector3.new(length, 0.12, 0.16), spot, GOLD)
			piece.Material = Enum.Material.Neon
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
	-- A tall puffy white chef's hat.
	ChefHat = function(builder)
		add(builder, "ChefBand", "Cylinder", Vector3.new(0.7, 1.8, 1.8), CFrame.new(0, 3.7, 0.05) * UPRIGHT, WHITE)
		add(builder, "ChefPuff", "Ellipsoid", Vector3.new(2.3, 1.3, 2.3), CFrame.new(0, 4.4, 0.05), WHITE)
		for _, position in { Vector3.new(-0.5, 4.7, 0.05), Vector3.new(0.5, 4.7, 0.05), Vector3.new(0, 4.8, 0.45) } do
			add(builder, "ChefPuff", "Ball", Vector3.one * 0.95, CFrame.new(position), WHITE)
		end
	end,
	-- Pointy ears in your body colour, pink inside.
	CatEars = function(builder)
		for _, side in { -1, 1 } do
			local ear = CFrame.new(side * 0.72, 3.45, 0.1) * CFrame.Angles(0, 0, -side * 0.3)
			add(
				builder,
				"Ear",
				"Block",
				Vector3.new(0.8, 0.8, 0.24),
				ear * CFrame.Angles(0, 0, math.pi / 4),
				builder.BodyColor
			)
			add(
				builder,
				"EarInside",
				"Block",
				Vector3.new(0.48, 0.48, 0.1),
				ear * CFrame.new(0, -0.05, -0.12) * CFrame.Angles(0, 0, math.pi / 4),
				ROSY
			)
		end
	end,
	-- A tall, slightly bent purple hat with a brim and golden stars.
	WizardHat = function(builder)
		local hat = CFrame.new(0.1, 3.55, 0.1) * CFrame.Angles(0, 0, -0.1)
		add(builder, "Brim", "Cylinder", Vector3.new(0.12, 2.7, 2.7), hat * UPRIGHT, WIZARD)
		local layers = 7
		for index = 1, layers do
			local diameter = 1.7 - (index - 1) * 0.22
			local layer = hat * CFrame.new(-(index - 1) ^ 2 * 0.012, (index - 0.5) * 0.36, 0)
			add(builder, "Cone", "Cylinder", Vector3.new(0.38, diameter, diameter), layer * UPRIGHT, WIZARD)
		end
		add(builder, "Tip", "Ball", Vector3.one * 0.3, hat * CFrame.new(-0.45, layers * 0.36 + 0.05, 0), GOLD)
		for _, spot in { Vector3.new(0.45, 0.5, -0.62), Vector3.new(-0.4, 1.15, -0.45), Vector3.new(0.2, 1.75, -0.35) } do
			for _, turn in { 0, math.pi / 2 } do
				local star = add(
					builder,
					"Star",
					"Block",
					Vector3.new(0.34, 0.09, 0.05),
					hat * CFrame.new(spot) * CFrame.Angles(0, 0, math.pi / 4 + turn),
					STAR
				)
				star.Material = Enum.Material.Neon
			end
		end
	end,
	-- A metal helmet with two curly horns.
	VikingHelmet = function(builder)
		add(builder, "Helmet", "Ellipsoid", Vector3.new(2.7, 1.6, 2.7), CFrame.new(0, 3.65, 0.05), METAL)
		band(builder, "HelmetBand", 3.2, 0.35, 0.12, GOLD)
		add(builder, "Nose", "Block", Vector3.new(0.22, 0.7, 0.2), CFrame.new(0, 3.25, -1.25), METAL)
		for _, side in { -1, 1 } do
			local points = {
				Vector3.new(side * 1.05, 3.75, 0.05),
				Vector3.new(side * 1.55, 4.0, 0.05),
				Vector3.new(side * 1.8, 4.5, 0.05),
				Vector3.new(side * 1.75, 4.95, 0.05),
			}
			for index = 1, #points - 1 do
				stick(builder, "Horn", points[index], points[index + 1], 0.5 - index * 0.11, HORN)
			end
		end
	end,
	-- A see-through glass bubble over the top of the body, with a collar and an antenna.
	Astronaut = function(builder)
		local dome = add(builder, "Dome", "Ball", Vector3.one * 3.9, CFrame.new(0, 2.6, 0), GLASS)
		dome.Transparency = 0.7
		dome.Material = Enum.Material.Glass
		band(builder, "Collar", 1.45, 0.4, 0.2, WHITE)
		stick(builder, "Antenna", Vector3.new(0.6, 4.4, 0.3), Vector3.new(0.8, 5.1, 0.35), 0.1, WHITE)
		local light = add(builder, "AntennaLight", "Ball", Vector3.one * 0.3, CFrame.new(0.82, 5.15, 0.35), RED)
		light.Material = Enum.Material.Neon
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
	-- Two tanks on the back, with flames under the nozzles.
	Jetpack = function(builder)
		add(builder, "JetpackFrame", "Block", Vector3.new(1.3, 1.0, 0.3), CFrame.new(0, 2.25, 1.65), METAL)
		for _, side in { -1, 1 } do
			local x = side * 0.5
			add(builder, "Tank", "Cylinder", Vector3.new(1.3, 0.7, 0.7), CFrame.new(x, 2.3, 1.85) * UPRIGHT, METAL)
			add(builder, "TankCap", "Ball", Vector3.one * 0.7, CFrame.new(x, 2.95, 1.85), RED)
			add(builder, "Nozzle", "Cylinder", Vector3.new(0.3, 0.45, 0.45), CFrame.new(x, 1.5, 1.85) * UPRIGHT, INK)
			local flame =
				add(builder, "Flame", "Ellipsoid", Vector3.new(0.38, 0.7, 0.38), CFrame.new(x, 1.0, 1.85), FLAME)
			flame.Material = Enum.Material.Neon
		end
	end,
	-- A stripy swim ring round the middle.
	RubberRing = function(builder)
		local count = 14
		local height = 1.35
		local radius = bodyRadiusAt(builder, height) + 0.28
		for index = 1, count do
			local angle = index / count * math.pi * 2
			add(
				builder,
				"Ring",
				"Ball",
				Vector3.one * 0.9,
				CFrame.new(math.cos(angle) * radius, height, math.sin(angle) * radius),
				if (index // 2) % 2 == 0 then Color3.fromRGB(255, 120, 150) else WHITE
			)
		end
	end,
	-- A little backpack with a flap, and its straps over your front.
	Backpack = function(builder)
		local color = Color3.fromRGB(255, 132, 72)
		add(builder, "Pack", "Block", Vector3.new(1.5, 1.6, 0.8), CFrame.new(0, 2.15, 1.75), color)
		add(builder, "Flap", "Block", Vector3.new(1.55, 0.5, 0.85), CFrame.new(0, 2.85, 1.75), lighter(color, 0.3))
		add(builder, "Pocket", "Block", Vector3.new(0.9, 0.55, 0.2), CFrame.new(0, 1.85, 2.2), lighter(color, 0.15))
		for _, side in { -1, 1 } do
			local top = onBody(builder, Vector3.new(side * 0.45, 0.55, -0.7), -0.03)
			local bottom = onBody(builder, Vector3.new(side * 0.45, -0.35, -0.85), -0.03)
			stick(builder, "Strap", top, bottom, 0.16, INK)
		end
	end,
	-- A ring of flowers round your middle.
	Lei = function(builder)
		local colors = { PINK, Color3.fromRGB(255, 210, 60), WHITE, AQUA }
		local count = 16
		local height = 1.75
		local radius = bodyRadiusAt(builder, height) + 0.12
		for index = 1, count do
			local angle = index / count * math.pi * 2
			add(
				builder,
				"LeiFlower",
				"Ball",
				Vector3.one * 0.48,
				CFrame.new(
					math.cos(angle) * radius,
					height + (if index % 2 == 0 then 0.06 else -0.06),
					math.sin(angle) * radius
				),
				colors[(index - 1) % #colors + 1]
			)
		end
	end,
	-- Big red bat-like wings with spikes along the top.
	DragonWings = function(builder)
		for _, side in { -1, 1 } do
			local root = CFrame.new(side * 0.7, 2.75, 1.6) * CFrame.Angles(0, side * 0.55, 0)
			-- The arm along the top, then the membrane hanging from it in three scallops.
			local tip = root * CFrame.new(side * 2.3, 0.9, 0)
			stick(builder, "WingArm", root.Position, tip.Position, 0.22, lighter(DRAGON, 0.15))
			add(builder, "WingClaw", "Ball", Vector3.one * 0.32, tip, HORN)
			for index = 1, 3 do
				local along = (index - 0.5) / 3
				local membrane = root:Lerp(tip, along) * CFrame.new(0, -0.65, 0)
				add(
					builder,
					"Wing",
					"Ellipsoid",
					Vector3.new(0.95, 1.5 - index * 0.25, 0.08),
					membrane * CFrame.Angles(0, 0, side * 0.2),
					if index % 2 == 0 then DRAGON else DRAGON:Lerp(INK, 0.15)
				)
			end
		end
		-- A row of spikes down the back.
		for index = 1, 4 do
			local spike = onBody(builder, Vector3.new(0, 0.85 - index * 0.35, 1), -0.05)
			add(
				builder,
				"Spike",
				"Block",
				Vector3.new(0.12, 0.34, 0.34),
				CFrame.new(spike) * CFrame.Angles(math.pi / 4, 0, 0),
				HORN
			)
		end
	end,
	-- A green shell on your back with lighter plates.
	Shell = function(builder)
		add(builder, "Shell", "Ellipsoid", Vector3.new(2.8, 2.6, 1.3), CFrame.new(0, 2.05, 1.45), SHELL)
		local plate = lighter(SHELL, 0.35)
		for _, spot in
			{
				Vector3.new(0, 2.05, 2.08),
				Vector3.new(-0.68, 2.5, 1.9),
				Vector3.new(0.68, 2.5, 1.9),
				Vector3.new(-0.68, 1.6, 1.9),
				Vector3.new(0.68, 1.6, 1.9),
			}
		do
			add(builder, "Plate", "Ellipsoid", Vector3.new(0.75, 0.7, 0.18), CFrame.new(spot), plate)
		end
	end,
	-- Two pairs of see-through glowing wings on the back.
	FairyWings = function(builder)
		for _, side in { -1, 1 } do
			local upper = add(
				builder,
				"Wing",
				"Ellipsoid",
				Vector3.new(1.9, 1.3, 0.08),
				CFrame.new(side * 0.95, 2.75, 1.65) * CFrame.Angles(0, side * 0.6, side * 0.45),
				WING
			)
			local lower = add(
				builder,
				"Wing",
				"Ellipsoid",
				Vector3.new(1.25, 0.85, 0.08),
				CFrame.new(side * 0.75, 1.95, 1.6) * CFrame.Angles(0, side * 0.6, -side * 0.35),
				lighter(WING, 0.3)
			)
			for _, wing in { upper, lower } do
				wing.Material = Enum.Material.Neon
				wing.Transparency = 0.35
			end
		end
	end,
}

-------------------------------------------------------------------------------------------------
-- Slappers (held in the right hand; see the header)
-------------------------------------------------------------------------------------------------

-- Adds one piece of a slapper at `grip` (grip space) and returns it.
type Piece = (name: string, shape: Shape, size: Vector3, grip: CFrame, color: Color3) -> Part

local HAND = CFrame.new(0, -0.5, 0) -- the bottom of the arm, in the arm's space
local GRIP_TILT = CFrame.Angles(1.15, 0, 0) -- points the slapper forward and down
local ALONG = CFrame.Angles(0, 0, math.pi / 2) -- turns a cylinder to run along the slapper
local WOOD = Color3.fromRGB(206, 150, 90)
local DARK = Color3.fromRGB(56, 56, 68)
local FOAM = Color3.fromRGB(255, 140, 60)

-- A rod along the slapper from `from` to `to` (distances down it).
local function rod(piece: Piece, name: string, from: number, to: number, diameter: number, color: Color3): Part
	return piece(
		name,
		"Cylinder",
		Vector3.new(to - from, diameter, diameter),
		CFrame.new(0, -(from + to) / 2, 0) * ALONG,
		color
	)
end

local function spatula(piece: Piece, handle: Color3, blade: Color3)
	rod(piece, "Handle", -0.1, 1.2, 0.24, handle)
	piece("Neck", "Block", Vector3.new(0.08, 0.4, 0.2), CFrame.new(0, -1.38, 0), blade)
	piece("Blade", "Block", Vector3.new(0.08, 0.95, 0.78), CFrame.new(0, -2.0, 0), blade)
	for _, z in { -0.22, 0, 0.22 } do
		piece("Slot", "Block", Vector3.new(0.1, 0.55, 0.07), CFrame.new(0, -2.0, z), handle:Lerp(INK, 0.5))
	end
end

local SLAPPERS: { [string]: (Piece) -> () } = {
	-- A big foam hand, open for slapping.
	Hand = function(piece)
		rod(piece, "Handle", -0.1, 0.8, 0.3, lighter(FOAM, 0.35))
		piece("Palm", "Ellipsoid", Vector3.new(0.34, 1.15, 1.05), CFrame.new(0, -1.35, 0), FOAM)
		for index, z in { -0.36, -0.12, 0.12, 0.36 } do
			local length = if index == 1 or index == 4 then 0.55 else 0.68
			piece("Finger", "Ellipsoid", Vector3.new(0.3, length, 0.24), CFrame.new(0, -1.95 - length / 4, z), FOAM)
		end
		piece(
			"Thumb",
			"Ellipsoid",
			Vector3.new(0.3, 0.55, 0.26),
			CFrame.new(0, -1.2, -0.62) * CFrame.Angles(-0.8, 0, 0),
			FOAM
		)
	end,
	Spatula = function(piece)
		spatula(piece, DARK, Color3.fromRGB(80, 80, 98))
	end,
	GoldenSpatula = function(piece)
		spatula(piece, Color3.fromRGB(230, 160, 30), GOLD)
		for _, spot in { Vector3.new(0.1, -1.7, 0.3), Vector3.new(-0.1, -2.3, -0.25), Vector3.new(0.1, -2.35, 0.2) } do
			local sparkle = piece("Sparkle", "Ball", Vector3.one * 0.16, CFrame.new(spot), WHITE)
			sparkle.Material = Enum.Material.Neon
		end
	end,
	Spoon = function(piece)
		rod(piece, "Handle", -0.1, 1.6, 0.2, WOOD)
		piece("Bowl", "Ellipsoid", Vector3.new(0.26, 0.95, 0.72), CFrame.new(0, -2.0, 0), WOOD:Lerp(INK, 0.1))
	end,
	-- Blunt and round-ended: a butter knife.
	ButterKnife = function(piece)
		piece(
			"Handle",
			"Ellipsoid",
			Vector3.new(0.3, 1.05, 0.38),
			CFrame.new(0, -0.45, 0),
			Color3.fromRGB(240, 240, 248)
		)
		local blade = Color3.fromRGB(200, 208, 226)
		piece("Blade", "Block", Vector3.new(0.07, 1.25, 0.42), CFrame.new(0, -1.55, 0), blade)
		piece("Tip", "Ellipsoid", Vector3.new(0.07, 0.42, 0.42), CFrame.new(0, -2.18, 0), blade)
	end,
	-- Held by the tail.
	Fish = function(piece)
		local skin = Color3.fromRGB(110, 170, 230)
		for _, side in { -1, 1 } do
			piece(
				"Tail",
				"Ellipsoid",
				Vector3.new(0.1, 0.5, 0.4),
				CFrame.new(0, -0.15, side * 0.2) * CFrame.Angles(side * 0.6, 0, 0),
				skin:Lerp(INK, 0.15)
			)
		end
		piece("Body", "Ellipsoid", Vector3.new(0.5, 1.95, 0.8), CFrame.new(0, -1.35, 0), skin)
		piece("Belly", "Ellipsoid", Vector3.new(0.52, 1.5, 0.42), CFrame.new(0, -1.4, 0.2), lighter(skin, 0.55))
		for _, side in { -1, 1 } do
			piece("Eye", "Ball", Vector3.one * 0.2, CFrame.new(side * 0.22, -2.0, -0.12), WHITE)
			piece("Pupil", "Ball", Vector3.one * 0.1, CFrame.new(side * 0.3, -2.02, -0.12), INK)
		end
	end,
	ToySword = function(piece)
		piece("Pommel", "Ball", Vector3.one * 0.36, CFrame.new(0, 0.05, 0), Color3.fromRGB(255, 205, 64))
		rod(piece, "Handle", -0.05, 0.7, 0.26, Color3.fromRGB(132, 104, 255))
		piece("Guard", "Block", Vector3.new(0.3, 0.22, 1.0), CFrame.new(0, -0.8, 0), Color3.fromRGB(255, 205, 64))
		local blade = Color3.fromRGB(80, 150, 255)
		piece("Blade", "Block", Vector3.new(0.18, 1.55, 0.44), CFrame.new(0, -1.7, 0), blade)
		piece("Tip", "Ellipsoid", Vector3.new(0.18, 0.5, 0.44), CFrame.new(0, -2.48, 0), blade)
	end,
	-- The flat of the pan faces sideways, the way it swings.
	FryingPan = function(piece)
		rod(piece, "Handle", -0.1, 1.15, 0.22, Color3.fromRGB(40, 40, 50))
		piece("Pan", "Cylinder", Vector3.new(0.16, 1.6, 1.6), CFrame.new(0, -1.95, 0), Color3.fromRGB(60, 60, 72))
		piece("Inside", "Cylinder", Vector3.new(0.2, 1.3, 1.3), CFrame.new(0, -1.95, 0), Color3.fromRGB(96, 96, 110))
	end,
	Baguette = function(piece)
		local crust = Color3.fromRGB(226, 170, 90)
		piece("Loaf", "Ellipsoid", Vector3.new(0.5, 2.5, 0.5), CFrame.new(0, -1.15, 0), crust)
		for _, along in { 0.6, 1.1, 1.6 } do
			piece(
				"Score",
				"Ellipsoid",
				Vector3.new(0.52, 0.14, 0.3),
				CFrame.new(0, -along, 0) * CFrame.Angles(0.5, 0, 0),
				lighter(crust, 0.5)
			)
		end
	end,
	PoolNoodle = function(piece)
		local foam = Color3.fromRGB(80, 220, 120)
		rod(piece, "Noodle", -0.15, 2.5, 0.44, foam)
		rod(piece, "Hole", 2.49, 2.53, 0.2, foam:Lerp(INK, 0.5))
	end,
	CandyCane = function(piece)
		local red = Color3.fromRGB(230, 50, 70)
		for index = 0, 7 do
			rod(piece, "Stripe", -0.1 + index * 0.25, 0.15 + index * 0.25, 0.28, if index % 2 == 0 then red else WHITE)
		end
		-- The hook at the far end.
		for index, spot in
			{
				Vector3.new(0, -2.18, -0.12),
				Vector3.new(0, -2.3, -0.32),
				Vector3.new(0, -2.24, -0.54),
				Vector3.new(0, -2.06, -0.64),
			}
		do
			piece("Hook", "Ball", Vector3.one * 0.3, CFrame.new(spot), if index % 2 == 0 then red else WHITE)
		end
	end,
	-- A big swirly lollipop on a stick.
	Lollipop = function(piece)
		rod(piece, "Stick", -0.1, 1.4, 0.14, WHITE)
		local pink = Color3.fromRGB(255, 120, 200)
		for index, diameter in { 1.7, 1.25, 0.8, 0.35 } do
			piece(
				"Swirl",
				"Cylinder",
				Vector3.new(0.22 + index * 0.02, diameter, diameter),
				CFrame.new(0, -2.2, 0),
				if index % 2 == 1 then pink else WHITE
			)
		end
	end,
	GlowSword = function(piece)
		rod(piece, "Hilt", -0.1, 0.75, 0.3, Color3.fromRGB(150, 160, 190))
		piece("Emitter", "Ball", Vector3.one * 0.36, CFrame.new(0, -0.8, 0), DARK)
		local glow = Color3.fromRGB(90, 230, 255)
		local blade = rod(piece, "Blade", 0.85, 2.75, 0.26, glow)
		local tip = piece("Tip", "Ball", Vector3.one * 0.26, CFrame.new(0, -2.75, 0), glow)
		blade.Material = Enum.Material.Neon
		tip.Material = Enum.Material.Neon
	end,
	-- Held by the feet; the squeaky head does the slapping.
	RubberChicken = function(piece)
		local yellow = Color3.fromRGB(255, 220, 60)
		local orange = Color3.fromRGB(255, 140, 40)
		for _, z in { -0.12, 0.12 } do
			piece("Leg", "Cylinder", Vector3.new(0.45, 0.1, 0.1), CFrame.new(0, -0.2, z) * ALONG, orange)
		end
		piece("Body", "Ellipsoid", Vector3.new(0.6, 1.6, 0.66), CFrame.new(0, -1.2, 0), yellow)
		rod(piece, "Neck", 1.9, 2.15, 0.28, yellow)
		piece("Head", "Ball", Vector3.one * 0.58, CFrame.new(0, -2.35, 0), yellow)
		piece("Beak", "Block", Vector3.new(0.2, 0.18, 0.34), CFrame.new(0, -2.4, -0.36), orange)
		piece("Comb", "Ellipsoid", Vector3.new(0.12, 0.34, 0.36), CFrame.new(0, -2.68, 0), Color3.fromRGB(226, 38, 72))
		for _, side in { -1, 1 } do
			piece("Eye", "Ball", Vector3.one * 0.1, CFrame.new(side * 0.24, -2.4, -0.16), INK)
		end
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

-- Takes away a Bloblet's slapper.
function BlobletCosmetics.ClearSlapper(model: Model)
	for _, child in model:GetChildren() do
		if child:GetAttribute("SlapperPiece") == true then
			child:Destroy()
		end
	end
end

-- Puts a slapper (a Slapper item id; the foam hand if it isn't one) in the hand at the bottom of
-- `arm`, replacing any other.
function BlobletCosmetics.BuildSlapper(model: Model, arm: BasePart, itemId: string)
	BlobletCosmetics.ClearSlapper(model)
	local entry = Cosmetics.Get(itemId)
	local build = if entry and entry.Slot == "Slapper" then SLAPPERS[Cosmetics.Style(itemId)] else nil
	local grip = HAND * GRIP_TILT
	local function piece(name: string, shape: Shape, size: Vector3, at: CFrame, color: Color3): Part
		local part = newPart(name, shape, size, color)
		part:SetAttribute("SlapperPiece", true)
		local weld = Instance.new("Weld")
		weld.Name = "SlapperWeld"
		weld.Part0 = arm
		weld.Part1 = part
		weld.C0 = grip * at
		part.CFrame = arm.CFrame * weld.C0
		weld.Parent = part
		part.Parent = model
		return part
	end
	(build or SLAPPERS.Hand)(piece)
end

return table.freeze(BlobletCosmetics)
