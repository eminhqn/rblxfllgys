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

local DECOR: Geometry.PartOptions = { Name = "Decor", CanCollide = false, CastShadow = false }
local SLAT_SPACING = 4

export type SpinnerOptions = {
	ArmLength: number,
	Speed: number, -- radians per second; the sign sets the direction
	Phase: number?,
	ArmHeight: number?, -- height of the bar's centre above the floor (default 2.2)
	Color: Color3?,
	Mat: boolean?, -- soft floor mat under the sweep (default true)
}

-- A bar that sweeps round a hub standing on the floor at `center`. Clients rotate it and decide
-- hits (see HazardController).
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
	CollectionService:AddTag(spinner, Tags.Spinner)
	spinner.Parent = parent
	return spinner
end

export type BouncePadOptions = {
	Diameter: number?, -- cushion diameter (default 8)
	Power: number?, -- upward launch speed in studs/s (default 85)
	Color: Color3?,
	RingColor: Color3?,
}

-- A round trampoline whose base sits on `bottom`. Bloblets that land on it are launched upwards
-- (MovementController). Returns the cushion part.
function Hazards.BouncePad(parent: Instance, bottom: Vector3, options: BouncePadOptions?): Part
	local opts: BouncePadOptions = options or {}
	local diameter = opts.Diameter or 8
	Geometry.column(parent, 1.0, diameter + 1.6, bottom, opts.RingColor or Theme.Colors.Yellow, { Name = "PadRing" })
	local cushion = Geometry.column(parent, 1.25, diameter, bottom, opts.Color or Theme.Colors.Pink, {
		Name = "Cushion",
	})
	cushion:SetAttribute("Power", opts.Power or 85)
	CollectionService:AddTag(cushion, Tags.BouncePad)
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
-- flush with it). Clients hide it until its shadow shows, drop it, slide it along `slideVelocity`
-- for `slideTime` seconds and smash it. The server only places it and deletes it afterwards.
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
	-- A dark circle on the landing spot warns players before the crate drops.
	local shadow = Geometry.block(
		crate,
		Vector3.new(0.1, size * 1.3, size * 1.3),
		landing * CFrame.new(0, 0.12, 0) * CFrame.Angles(0, 0, math.pi / 2),
		Theme.Colors.Ink,
		{ Name = "Shadow", Transparency = 0.45, CanCollide = false, CastShadow = false }
	)
	shadow.Shape = Enum.PartType.Cylinder

	crate:SetAttribute("LandAt", landAt)
	crate:SetAttribute("DropHeight", crates.DropHeight)
	crate:SetAttribute("SlideVelocity", slideVelocity)
	crate:SetAttribute("SlideTime", slideTime)
	CollectionService:AddTag(crate, Tags.Crate)
	crate.Parent = parent
	return crate
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
