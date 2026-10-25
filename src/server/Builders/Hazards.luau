--!strict
-- Reusable hazard and course pieces. Each builder makes the parts and sets the tags/attributes
-- that clients animate (see Shared/Tags and Shared/HazardMath); nothing here moves on the server.
--
-- Moving pieces are built as atomic models with every part inside before they're parented, so
-- with StreamingEnabled a client always receives the whole thing at once.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Config = require(Shared.Config)
local Tags = require(Shared.Tags)
local Theme = require(Shared.Theme)
local Ui = require(Shared.Ui)

local Geometry = require(script.Parent.Geometry)

local Hazards = {}

local WHITE = Color3.fromRGB(255, 255, 255)
local CREAM = Color3.fromRGB(255, 249, 252)
local GOLD = Color3.fromRGB(255, 205, 64)
local BELT_COLOR = Color3.fromRGB(86, 70, 140)
local SLAT_COLOR = Color3.fromRGB(150, 128, 230)
local CRATE_COLOR = Color3.fromRGB(255, 166, 92)
local CRATE_TRIM = Color3.fromRGB(255, 232, 196)
local GOO_COLOR = Color3.fromRGB(150, 236, 72)
local MARKER_COLOR = Color3.fromRGB(255, 72, 120)

local DECOR: Geometry.PartOptions = { Name = "Decor", CanCollide = false, CastShadow = false }
local SLAT_SPACING = 4

export type SpinnerOptions = {
	ArmLength: number,
	Speed: number, -- radians per second; the sign sets the direction
	Phase: number?,
	ArmHeight: number?, -- height of the bar's centre above the floor (default 2.2)
	Color: Color3?,
	Mat: boolean?, -- soft floor mat under the sweep (default true)
	-- Server time a spinner added mid-round turns solid. Until then it flashes where it is (already
	-- turning) and passes through Bloblets harmlessly. Add it Config.Hazards.SpinnerWarningTime
	-- before this.
	AppearAt: number?,
}

-- A bar that sweeps round a hub standing on the floor at `center`. Clients rotate it and decide
-- hits (see HazardController). Set a GraceUntil attribute (server time) to make the bar pass
-- through Bloblets harmlessly until then, or build it with AppearAt to bring it in mid-round.
function Hazards.Spinner(parent: Instance, center: Vector3, options: SpinnerOptions): Model
	local spinner = Geometry.atomicModel("Spinner")
	local length = options.ArmLength
	local color = options.Color or Theme.Colors.Pink
	if options.Mat ~= false then
		local matOptions: Geometry.PartOptions = { Name = "Mat", CanCollide = false, CastShadow = false }
		Geometry.column(spinner, 0.1, length + 4, center, Color3.fromRGB(255, 160, 206), matOptions)
		Geometry.column(spinner, 0.12, length + 1, center, CREAM, matOptions)
	end
	local armHeight = options.ArmHeight or 2.2
	Geometry.column(spinner, armHeight + 2.4, 3.2, center, WHITE, { Name = "Hub" })
	Geometry.ball(spinner, 3.4, center + Vector3.new(0, armHeight + 2.4, 0), color, { Name = "HubCap" })

	-- The client rotates "Arm" (and anything named "ArmDecor") around the hub's vertical axis.
	local armCFrame = CFrame.new(center + Vector3.new(0, armHeight, 0))
	Geometry.block(spinner, Vector3.new(length, 1.6, 1.6), armCFrame, color, { Name = "Arm" })
	local offset = 4
	while offset <= length / 2 - 3 do
		for _, side in { -1, 1 } do
			Geometry.block(
				spinner,
				Vector3.new(1, 1.75, 1.75),
				armCFrame * CFrame.new(side * offset, 0, 0),
				WHITE,
				{ Name = "ArmDecor", CanCollide = false, CastShadow = false }
			)
		end
		offset += 5
	end
	for _, side in { -1, 1 } do
		local tip = armCFrame * CFrame.new(side * (length / 2 + 0.6), 0, 0)
		Geometry.ball(spinner, 2.4, tip.Position, Theme.Colors.Yellow, { Name = "ArmDecor", CanCollide = false })
	end

	spinner:SetAttribute("Speed", options.Speed)
	spinner:SetAttribute("Phase", options.Phase or 0)
	if options.AppearAt then
		spinner:SetAttribute("AppearAt", options.AppearAt)
		spinner:SetAttribute("GraceUntil", options.AppearAt)
	end
	CollectionService:AddTag(spinner, Tags.Spinner)
	spinner.Parent = parent
	return spinner
end

-- Changes a spinner's speed without its bar jumping: the phase is shifted so the bar's angle at
-- `serverTime` (now) stays the same. Clients pick the change up straight away.
function Hazards.SetSpinnerSpeed(spinner: Model, speed: number, serverTime: number)
	local oldSpeed = spinner:GetAttribute("Speed")
	local oldPhase = spinner:GetAttribute("Phase")
	local angle = (if typeof(oldPhase) == "number" then oldPhase else 0)
		+ (if typeof(oldSpeed) == "number" then oldSpeed else 0) * serverTime
	spinner:SetAttribute("Phase", (angle - speed * serverTime) % (2 * math.pi))
	spinner:SetAttribute("Speed", speed)
end

export type BouncePadOptions = {
	Diameter: number?, -- cushion diameter (default 8)
	Power: number?, -- upward launch speed in studs/s (default 85)
	Color: Color3?,
	RingColor: Color3?,
}

-- A round trampoline whose base sits on `bottom`. Bloblets that land anywhere on it, rim
-- included, are launched upwards (MovementController). Returns the cushion part.
function Hazards.BouncePad(parent: Instance, bottom: Vector3, options: BouncePadOptions?): Part
	local opts: BouncePadOptions = options or {}
	local diameter = opts.Diameter or 8
	local ring = Geometry.column(
		parent,
		1.0,
		diameter + 1.6,
		bottom,
		opts.RingColor or Theme.Colors.Yellow,
		{ Name = "PadRing" }
	)
	local cushion = Geometry.column(parent, 1.25, diameter, bottom, opts.Color or Theme.Colors.Pink, {
		Name = "Cushion",
	})
	for _, part in { ring, cushion } do
		part:SetAttribute("Power", opts.Power or 85)
		CollectionService:AddTag(part, Tags.BouncePad)
	end
	return cushion
end

-- A golden crown that slowly spins in the air above `center` (decoration: nothing on it collides).
function Hazards.Crown(parent: Instance, center: Vector3, scale: number?): Model
	local size = scale or 1
	local crown = Geometry.atomicModel("Crown")
	Geometry.block(crown, Vector3.one * 0.4, CFrame.new(center), GOLD, {
		Name = "Hub",
		Transparency = 1,
		CanCollide = false,
	})
	-- Spins like a Spinner hazard, but nothing on it collides.
	local band = Geometry.column(crown, 2.2 * size, 9 * size, center - Vector3.new(0, 1.1 * size, 0), GOLD, {
		Name = "Arm",
		CanCollide = false,
	})
	local glow = Instance.new("PointLight")
	glow.Color = GOLD
	glow.Brightness = 2
	glow.Range = 24 * size
	glow.Parent = band
	for index = 1, 6 do
		local angle = index / 6 * math.pi * 2
		local rim = center + Vector3.new(math.cos(angle) * 4 * size, 0, math.sin(angle) * 4 * size)
		Geometry.column(crown, 2.4 * size, 1.1 * size, rim + Vector3.new(0, 1.1 * size, 0), GOLD, {
			Name = "ArmDecor",
			CanCollide = false,
		})
		Geometry.ball(
			crown,
			1.3 * size,
			rim + Vector3.new(0, 3.9 * size, 0),
			if index % 2 == 0 then Theme.Colors.Pink else Theme.Colors.Aqua,
			{ Name = "ArmDecor", CanCollide = false }
		)
	end
	crown:SetAttribute("Speed", 0.9)
	crown:SetAttribute("Phase", 0)
	CollectionService:AddTag(crown, Tags.Spinner)
	crown.Parent = parent
	return crown
end

export type ConveyorOptions = {
	Rails: boolean?, -- padded rails along both sides (default false)
	Color: Color3?,
	SlatColor: Color3?,
}

-- A conveyor belt. `top` is the centre of the belt's top surface and its LookVector is the way
-- the surface moves when `speed` is positive. `size` is (width, length). Tilt `top` for a ramp.
-- Clients slide the slats along and give the belt its surface speed (see HazardController).
function Hazards.Conveyor(parent: Instance, top: CFrame, size: Vector2, speed: number, options: ConveyorOptions?): Model
	local opts: ConveyorOptions = options or {}
	local width, length = size.X, size.Y
	local conveyor = Geometry.atomicModel("Conveyor")
	local thickness = 2
	local belt = Geometry.block(
		conveyor,
		Vector3.new(width, thickness, length),
		top * CFrame.new(0, -thickness / 2, 0),
		opts.Color or BELT_COLOR,
		{ Name = "Belt" }
	)

	local slatColor = opts.SlatColor or SLAT_COLOR
	local count = math.max(1, math.floor(length / SLAT_SPACING))
	for index = 0, count - 1 do
		local along = -length / 2 + (index + 0.5) * (length / count)
		Geometry.block(
			conveyor,
			Vector3.new(width - 1.2, 0.16, 1),
			top * CFrame.new(0, 0.06, along),
			slatColor,
			{ Name = "Slat", CanCollide = false, CastShadow = false }
		)
	end
	-- Rollers at both ends (decoration).
	for _, side in { -1, 1 } do
		local rollerCFrame = top * CFrame.new(0, -thickness / 2, side * length / 2)
		Geometry.block(
			conveyor,
			Vector3.new(width, thickness + 0.2, thickness + 0.2),
			rollerCFrame,
			WHITE,
			{ Name = "Roller", CanCollide = false, CastShadow = false }
		)
	end
	if opts.Rails then
		for _, side in { -1, 1 } do
			local from = top * CFrame.new(side * (width / 2 + 0.6), 1.1, length / 2)
			local to = top * CFrame.new(side * (width / 2 + 0.6), 1.1, -length / 2)
			Geometry.tube(conveyor, from.Position, to.Position, 1.6, Theme.Colors.Yellow, { Name = "Rail" })
		end
	end

	conveyor:SetAttribute("Speed", speed)
	CollectionService:AddTag(conveyor, Tags.Conveyor)
	conveyor.Parent = parent
	-- Clients set this too (HazardController); it's what carries Bloblets along.
	belt.AssemblyLinearVelocity = top.LookVector * speed
	return conveyor
end

-- A model that slides back and forth between home - travel and home + travel. `build` adds the
-- parts in their home position.
function Hazards.Mover(
	parent: Instance,
	travel: Vector3,
	speed: number,
	phase: number,
	build: (model: Model) -> ()
): Model
	local mover = Geometry.atomicModel("Mover")
	build(mover)
	if not mover.PrimaryPart then
		mover.PrimaryPart = mover:FindFirstChildWhichIsA("BasePart", true)
	end
	mover:SetAttribute("Travel", travel)
	mover:SetAttribute("Speed", speed)
	mover:SetAttribute("Phase", phase)
	CollectionService:AddTag(mover, Tags.Mover)
	mover.Parent = parent
	return mover
end

-- A padded platform block whose top surface is centred on `top`.
function Hazards.Platform(parent: Instance, top: CFrame, size: Vector3, color: Color3, name: string?): Part
	local platform = Geometry.block(parent, size, top * CFrame.new(0, -size.Y / 2, 0), color, {
		Name = name or "Platform",
	})
	-- A white rim round the top so edges are easy to read from the air.
	local corners = {
		top * CFrame.new(-size.X / 2, 0, -size.Z / 2),
		top * CFrame.new(size.X / 2, 0, -size.Z / 2),
		top * CFrame.new(size.X / 2, 0, size.Z / 2),
		top * CFrame.new(-size.X / 2, 0, size.Z / 2),
	}
	for index, corner in corners do
		local nextCorner = corners[index % #corners + 1]
		local from, to = corner.Position, nextCorner.Position
		local middle = (from + to) / 2
		Geometry.block(
			parent,
			Vector3.new(0.5, 0.3, (to - from).Magnitude + 0.5),
			CFrame.lookAt(middle, to) * CFrame.new(0, 0.05, 0),
			WHITE,
			DECOR
		)
	end
	return platform
end

-- A platform that slides back and forth (see Hazards.Mover).
function Hazards.MovingPlatform(
	parent: Instance,
	top: CFrame,
	size: Vector3,
	color: Color3,
	travel: Vector3,
	speed: number,
	phase: number
): Model
	return Hazards.Mover(parent, travel, speed, phase, function(model: Model)
		Hazards.Platform(model, top, size, color)
	end)
end

-- A crate that falls onto `landing` (a ground CFrame: position on the surface, rotation to sit
-- flush with it). Clients flash a target circle on the landing spot, then drop the crate, slide it
-- along `slideVelocity` for `slideTime` seconds and smash it. The server only places it and
-- deletes it afterwards.
function Hazards.Crate(
	parent: Instance,
	landing: CFrame,
	landAt: number,
	slideVelocity: Vector3,
	slideTime: number
): Model
	local crates = Config.Crates
	local size = crates.Size
	local crate = Geometry.atomicModel("Crate")
	local boxOptions: Geometry.PartOptions = { Name = "Box", Material = Enum.Material.WoodPlanks, CanCollide = false }
	local boxCFrame = landing * CFrame.new(0, size / 2, 0)
	Geometry.block(crate, Vector3.one * size, boxCFrame, CRATE_COLOR, boxOptions)
	for _, corner in { Vector2.new(-1, -1), Vector2.new(1, -1), Vector2.new(1, 1), Vector2.new(-1, 1) } do
		local inset = size / 2 - 0.25
		Geometry.block(
			crate,
			Vector3.new(0.7, size + 0.1, 0.7),
			boxCFrame * CFrame.new(corner.X * inset, 0, corner.Y * inset),
			CRATE_TRIM,
			{ Name = "Trim", CanCollide = false, CastShadow = false }
		)
	end
	-- A glowing target circle (ring + dot) on the landing spot warns players before the crate
	-- drops. It sits just above belt slats. Clients flash it and show it only while it matters.
	local markerDiameter = size * 1.35
	local discs = {
		{ Name = "Marker", Diameter = markerDiameter, Lift = 0.22, Color = MARKER_COLOR },
		{ Name = "MarkerFill", Diameter = markerDiameter * 0.66, Lift = 0.25, Color = WHITE },
		{ Name = "Marker", Diameter = markerDiameter * 0.24, Lift = 0.28, Color = MARKER_COLOR },
	}
	for _, disc in discs do
		local part = Geometry.block(
			crate,
			Vector3.new(0.1, disc.Diameter, disc.Diameter),
			landing * CFrame.new(0, disc.Lift, 0) * CFrame.Angles(0, 0, math.pi / 2),
			disc.Color,
			{
				Name = disc.Name,
				Material = if disc.Name == "Marker" then Enum.Material.Neon else nil,
				CanCollide = false,
				CastShadow = false,
			}
		)
		part.Shape = Enum.PartType.Cylinder
	end

	crate:SetAttribute("LandAt", landAt)
	crate:SetAttribute("DropHeight", crates.DropHeight)
	crate:SetAttribute("SlideVelocity", slideVelocity)
	crate:SetAttribute("SlideTime", slideTime)
	CollectionService:AddTag(crate, Tags.Crate)
	crate.Parent = parent
	return crate
end

export type BalloonOptions = {
	Origin: Vector3, -- its centre when it sets off
	Velocity: Vector3,
	StartAt: number, -- server time it sets off
	Duration: number, -- seconds of rolling
	Diameter: number,
	Hop: number?, -- hop height in studs (default 0: it rolls)
	HopRate: number?, -- hops per second
	Color: Color3,
	LaneFrom: Vector3, -- where its path crosses the floor (points on the surface)
	LaneTo: Vector3,
}

local function setRollerAttributes(model: Model, options: BalloonOptions)
	model:SetAttribute("StartAt", options.StartAt)
	model:SetAttribute("Origin", options.Origin)
	model:SetAttribute("Velocity", options.Velocity)
	model:SetAttribute("Duration", options.Duration)
	model:SetAttribute("Diameter", options.Diameter)
	model:SetAttribute("Hop", options.Hop or 0)
	model:SetAttribute("HopRate", options.HopRate or 1)
	-- Clients draw arrows along this stretch of floor, pointing the way it will roll.
	model:SetAttribute("LaneFrom", options.LaneFrom)
	model:SetAttribute("LaneTo", options.LaneTo)
	CollectionService:AddTag(model, Tags.Roller)
end

-- A giant balloon that rolls (or hops) along a straight line. Clients first flash arrows on the
-- floor along its path, then roll it, hide each arrow as it rolls past, and decide their own hits
-- (see HazardController).
function Hazards.Balloon(parent: Instance, options: BalloonOptions): Model
	local balloon = Geometry.atomicModel("Balloon")
	local diameter = options.Diameter
	local origin = options.Origin
	local flat = Vector3.new(options.Velocity.X, 0, options.Velocity.Z)
	local direction = if flat.Magnitude > 1e-3 then flat.Unit else Vector3.zAxis

	local ball = Geometry.ball(balloon, diameter, origin, options.Color, { Name = "Ball", CanCollide = false })
	ball.Reflectance = 0.12
	-- A white band round its middle and a knot on top make the roll easy to see.
	local band = Geometry.block(
		balloon,
		Vector3.new(0.8, diameter + 0.15, diameter + 0.15),
		CFrame.lookAt(origin, origin + direction) * CFrame.Angles(0, math.pi / 2, 0),
		WHITE,
		{ Name = "Band", CanCollide = false, CastShadow = false }
	)
	band.Shape = Enum.PartType.Cylinder
	Geometry.ball(
		balloon,
		diameter * 0.14,
		origin + Vector3.new(0, diameter / 2 + diameter * 0.03, 0),
		options.Color:Lerp(Color3.new(0, 0, 0), 0.25),
		{ Name = "Knot", CanCollide = false, CastShadow = false }
	)

	setRollerAttributes(balloon, options)
	balloon.Parent = parent
	return balloon
end

-- A giant sugar-coated gumdrop that rolls (or bounces) along a straight line, which can run down
-- a slope. Same attributes, arrows and client animation as Hazards.Balloon; only the look differs.
function Hazards.Gumdrop(parent: Instance, options: BalloonOptions): Model
	local gumdrop = Geometry.atomicModel("Gumdrop")
	local diameter = options.Diameter
	local origin = options.Origin
	local ball = Geometry.ball(gumdrop, diameter, origin, options.Color, { Name = "Ball", CanCollide = false })
	ball.Reflectance = 0.18
	-- Sugar crystals spread evenly over the surface (a golden-angle spiral) show it rolling.
	local crystals = 14
	for index = 1, crystals do
		local y = 1 - (index - 0.5) / crystals * 2
		local ring = math.sqrt(1 - y * y)
		local angle = index * 2.39996
		local point = origin + Vector3.new(math.cos(angle) * ring, y, math.sin(angle) * ring) * (diameter / 2)
		Geometry.block(
			gumdrop,
			Vector3.one * diameter * 0.1,
			CFrame.new(point) * CFrame.Angles(angle, angle * 0.7, 0),
			WHITE,
			{ Name = "Sugar", CanCollide = false, CastShadow = false }
		)
	end
	setRollerAttributes(gumdrop, options)
	gumdrop.Parent = parent
	return gumdrop
end

export type PaintPickupKind = "Splash" | "Giant" | "Stripe"

local PICKUP_LABELS: { [PaintPickupKind]: string } = {
	Splash = "SPLASH",
	Giant = "GIANT",
	Stripe = "STRIPE",
}

-- Splash: a paint bucket with blobs of every team's colour and drips down the side.
local function buildBucket(model: Model, bottom: Vector3, paintColors: { Color3 }): Part
	local height = 2.6
	local body = Geometry.column(model, height, 3, bottom, WHITE, { Name = "Arm", CanCollide = false })
	Geometry.column(model, 0.3, 2.6, bottom + Vector3.new(0, height - 0.1, 0), Theme.Colors.Purple, {
		Name = "ArmDecor",
		CanCollide = false,
	})
	for index, color in paintColors do
		local angle = index / #paintColors * math.pi * 2
		local offset = Vector3.new(math.cos(angle) * 1.4, height + 0.2, math.sin(angle) * 1.4)
		Geometry.ball(model, 0.9, bottom + offset, color, { Name = "ArmDecor", CanCollide = false })
		Geometry.block(
			model,
			Vector3.new(0.5, 1.2, 0.3),
			CFrame.lookAt(
				bottom + Vector3.new(offset.X * 1.07, height - 0.7, offset.Z * 1.07),
				bottom + Vector3.new(0, height - 0.7, 0)
			),
			color,
			{ Name = "ArmDecor", CanCollide = false, CastShadow = false }
		)
	end
	return body
end

-- Giant: a big spotty candy mushroom.
local function buildMushroom(model: Model, bottom: Vector3): Part
	Geometry.column(model, 2, 1.5, bottom, CREAM, { Name = "ArmDecor", CanCollide = false })
	local capCenter = bottom + Vector3.new(0, 2.3, 0)
	local cap = Geometry.ellipsoid(model, Vector3.new(4.2, 2.4, 4.2), CFrame.new(capCenter), Theme.Colors.Lime, {
		Name = "Arm",
		CanCollide = false,
	})
	for index = 1, 5 do
		local angle = index / 5 * math.pi * 2
		local spot = capCenter + Vector3.new(math.cos(angle) * 1.3, 0.75, math.sin(angle) * 1.3)
		Geometry.ball(model, 0.75, spot, WHITE, { Name = "ArmDecor", CanCollide = false, CastShadow = false })
	end
	Geometry.ball(model, 0.85, capCenter + Vector3.new(0, 1.15, 0), WHITE, {
		Name = "ArmDecor",
		CanCollide = false,
		CastShadow = false,
	})
	return cap
end

-- Stripe: a paint roller with team-coloured stripes round the drum.
local function buildRoller(model: Model, bottom: Vector3, paintColors: { Color3 }): Part
	local drumCenter = bottom + Vector3.new(0, 1, 0)
	local length = 3.4
	local drum = Geometry.block(model, Vector3.new(length, 1.5, 1.5), CFrame.new(drumCenter), Theme.Colors.Purple, {
		Name = "Arm",
		CanCollide = false,
	})
	drum.Shape = Enum.PartType.Cylinder
	for index, color in paintColors do
		local x = -length / 2 + length * index / (#paintColors + 1)
		local band = Geometry.block(
			model,
			Vector3.new(0.35, 1.62, 1.62),
			CFrame.new(drumCenter + Vector3.new(x, 0, 0)),
			color,
			{ Name = "ArmDecor", CanCollide = false, CastShadow = false }
		)
		band.Shape = Enum.PartType.Cylinder
	end
	-- Frame and handle.
	local frameOptions: Geometry.PartOptions = { Name = "ArmDecor", CanCollide = false, CastShadow = false }
	for _, side in { -1, 1 } do
		local x = side * (length / 2 + 0.2)
		Geometry.block(
			model,
			Vector3.new(0.25, 1.6, 0.25),
			CFrame.new(drumCenter + Vector3.new(x, 0.8, 0)),
			WHITE,
			frameOptions
		)
	end
	Geometry.block(
		model,
		Vector3.new(length + 0.65, 0.25, 0.25),
		CFrame.new(drumCenter + Vector3.new(0, 1.6, 0)),
		WHITE,
		frameOptions
	)
	Geometry.column(model, 2.2, 0.45, drumCenter + Vector3.new(0, 1.6, 0), Theme.Colors.Yellow, frameOptions)
	return drum
end

-- A floating, spinning Paint Grab power-up over the floor point `floor`, with its name above it.
-- The round decides who grabs it; it then sets GrabbedBy (a UserId) and SplashColor, and clients
-- burst it in that colour.
function Hazards.PaintPickup(parent: Instance, floor: Vector3, kind: PaintPickupKind, paintColors: { Color3 }): Model
	local pickup = Geometry.atomicModel("PaintPickup")
	local bottom = floor + Vector3.new(0, 1.4, 0)
	local hub = Geometry.block(pickup, Vector3.one * 0.4, CFrame.new(bottom), WHITE, {
		Name = "Hub",
		Transparency = 1,
		CanCollide = false,
	})
	-- Spins like a Spinner hazard ("Arm" + "ArmDecor"), but nothing on it collides.
	local arm = if kind == "Splash"
		then buildBucket(pickup, bottom, paintColors)
		elseif kind == "Giant" then buildMushroom(pickup, bottom)
		else buildRoller(pickup, bottom, paintColors)
	local glow = Instance.new("PointLight")
	glow.Color = Theme.Colors.Yellow
	glow.Brightness = 2
	glow.Range = 14
	glow.Parent = arm

	local gui: BillboardGui = Ui.new("BillboardGui", {
		Size = UDim2.fromOffset(130, 38),
		StudsOffset = Vector3.new(0, 5.4, 0),
		LightInfluence = 0,
		MaxDistance = 160,
		Parent = hub,
	})
	local label = Ui.label(
		gui,
		PICKUP_LABELS[kind],
		Theme.Fonts.Display,
		Theme.Colors.Yellow,
		UDim2.fromScale(1, 1),
		UDim2.fromScale(0.5, 0.5),
		Vector2.new(0.5, 0.5)
	)
	Ui.new("UIStroke", {
		Color = Theme.Colors.Ink,
		Thickness = 3,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual,
		Parent = label,
	})

	pickup:SetAttribute("Kind", kind)
	pickup:SetAttribute("Speed", 2.2)
	pickup:SetAttribute("Phase", 0)
	CollectionService:AddTag(pickup, Tags.Spinner)
	CollectionService:AddTag(pickup, Tags.PaintPickup)
	pickup.Parent = parent
	return pickup
end

-- A pit of bright green goo (decoration: it doesn't collide; races respawn whoever falls in).
function Hazards.Goo(parent: Instance, surface: CFrame, size: Vector2, random: Random)
	Geometry.block(
		parent,
		Vector3.new(size.X, 2, size.Y),
		surface * CFrame.new(0, -1, 0),
		GOO_COLOR,
		{ Name = "Goo", Transparency = 0.12, CanCollide = false, CastShadow = false }
	)
	local bubbles = math.floor(size.X * size.Y / 900)
	for _ = 1, bubbles do
		local offset = Vector3.new(
			random:NextNumber(-size.X / 2 + 3, size.X / 2 - 3),
			random:NextNumber(-0.6, 0.3),
			random:NextNumber(-size.Y / 2 + 3, size.Y / 2 - 3)
		)
		Geometry.ball(
			parent,
			random:NextNumber(1.5, 4),
			(surface * CFrame.new(offset)).Position,
			GOO_COLOR:Lerp(WHITE, 0.25),
			{ Name = "GooBubble", Transparency = 0.2, CanCollide = false, CastShadow = false }
		)
	end
end

return Hazards
