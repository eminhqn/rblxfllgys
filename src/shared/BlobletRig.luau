--!strict
-- Builds a Bloblet: a round, squishy creature with stubby arms, big floppy feet and cartoon eyes.
--
-- Physics: a single invisible ball (HumanoidRootPart) does all of the colliding. Every visible
-- part is massless, non-colliding and hangs off a Motor6D, so each client can animate
-- squash-and-stretch locally (Motor6D.Transform and SpecialMesh.Scale never replicate and never
-- touch the physics). Everything is generated in code, so there are no assets to upload.

local Config = require(script.Parent.Config)

export type Appearance = {
	BodyColor: Color3,
}

local BlobletRig = {}

-- All measurements in studs. "Ground" is the floor under a standing Bloblet.
BlobletRig.Dimensions = table.freeze({
	RootDiameter = 3.2,
	RootHeight = 2.1, -- root centre above the ground while standing (RootDiameter / 2 + HipHeight)
	BodyDiameter = 3.3,
	BodyBottom = 0.45, -- lowest point of the body above the ground; squash pivots around this
})

BlobletRig.PartNames = table.freeze({
	Root = "HumanoidRootPart",
	VisualRoot = "VisualRoot",
	Body = "Body",
	EyeL = "EyeL",
	EyeR = "EyeR",
	PupilL = "PupilL",
	PupilR = "PupilR",
	ArmL = "ArmL",
	ArmR = "ArmR",
	FootL = "FootL",
	FootR = "FootR",
})

BlobletRig.JointSuffix = "Joint"

-- Rest positions of each joint. Body/eyes/pupils/arms are relative to VisualRoot (a point on the
-- ground under the root), feet are relative to the root itself so they stay planted when the
-- body leans.
BlobletRig.Rest = table.freeze({
	VisualRoot = Vector3.new(0, -2.1, 0),
	Body = Vector3.new(0, 2.1, 0),
	EyeL = Vector3.new(-0.56, 2.62, -1.36),
	EyeR = Vector3.new(0.56, 2.62, -1.36),
	PupilL = Vector3.new(-0.56, 2.58, -1.6),
	PupilR = Vector3.new(0.56, 2.58, -1.6),
	ArmL = Vector3.new(-1.72, 2.3, -0.05), -- shoulder; the arm hangs below it
	ArmR = Vector3.new(1.72, 2.3, -0.05),
	FootL = Vector3.new(-0.72, -1.83, -0.3),
	FootR = Vector3.new(0.72, -1.83, -0.3),
})

BlobletRig.ArmHang = 0.45 -- distance from shoulder joint to the arm's centre

-- Humanoid states a Bloblet never uses. Disabled on the server and on the owning client
-- (the humanoid state machine runs on whoever owns the physics).
BlobletRig.DisabledStates = table.freeze({
	Enum.HumanoidStateType.Climbing,
	Enum.HumanoidStateType.Swimming,
	Enum.HumanoidStateType.Seated,
	Enum.HumanoidStateType.FallingDown,
	Enum.HumanoidStateType.Ragdoll,
	Enum.HumanoidStateType.Flying,
	Enum.HumanoidStateType.PlatformStanding,
	Enum.HumanoidStateType.Dead,
})

local EYE_WHITE = Color3.fromRGB(255, 255, 255)
local PUPIL_COLOR = Color3.fromRGB(28, 24, 44)

local function visualPart(model: Model, name: string, size: Vector3, color: Color3, castShadow: boolean): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.Color = color
	part.Material = Enum.Material.SmoothPlastic
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Massless = true
	part.CastShadow = castShadow

	local mesh = Instance.new("SpecialMesh")
	mesh.MeshType = Enum.MeshType.Sphere
	mesh.Parent = part

	part.Parent = model
	return part
end

local function joint(part0: BasePart, part1: BasePart, c0: CFrame, c1: CFrame?): Motor6D
	local motor = Instance.new("Motor6D")
	motor.Name = part1.Name .. BlobletRig.JointSuffix
	motor.Part0 = part0
	motor.Part1 = part1
	motor.C0 = c0
	motor.C1 = c1 or CFrame.identity
	part1.CFrame = part0.CFrame * motor.C0 * motor.C1:Inverse()
	motor.Parent = part0
	return motor
end

function BlobletRig.Build(appearance: Appearance): Model
	local names = BlobletRig.PartNames
	local rest = BlobletRig.Rest
	local dims = BlobletRig.Dimensions

	local model = Instance.new("Model")
	model.Name = "Bloblet"
	model.ModelStreamingMode = Enum.ModelStreamingMode.Atomic

	local root = Instance.new("Part")
	root.Name = names.Root
	root.Shape = Enum.PartType.Ball
	root.Size = Vector3.one * dims.RootDiameter
	root.Transparency = 1
	root.CanCollide = true
	root.CanQuery = true
	root.CanTouch = true
	root.CastShadow = false
	-- Light and a little bouncy, so ragdolls tumble and roll nicely.
	root.CustomPhysicalProperties = PhysicalProperties.new(0.8, 0.5, 0.35, 1, 1)
	root.CFrame = CFrame.new(0, dims.RootHeight, 0)
	root.Parent = model
	model.PrimaryPart = root

	local rootAttachment = Instance.new("Attachment")
	rootAttachment.Name = "RootAttachment"
	rootAttachment.Parent = root

	-- Extra gravity while falling; the client toggles this.
	local fallForce = Instance.new("VectorForce")
	fallForce.Name = "FallForce"
	fallForce.Attachment0 = rootAttachment
	fallForce.RelativeTo = Enum.ActuatorRelativeTo.World
	fallForce.ApplyAtCenterOfMass = true
	fallForce.Force = Vector3.zero
	fallForce.Enabled = false
	fallForce.Parent = root

	local visualRoot = Instance.new("Part")
	visualRoot.Name = names.VisualRoot
	visualRoot.Size = Vector3.one * 0.2
	visualRoot.Transparency = 1
	visualRoot.CanCollide = false
	visualRoot.CanQuery = false
	visualRoot.CanTouch = false
	visualRoot.Massless = true
	visualRoot.CastShadow = false
	visualRoot.Parent = model
	joint(root, visualRoot, CFrame.new(rest.VisualRoot))

	local body = visualPart(model, names.Body, Vector3.one * dims.BodyDiameter, appearance.BodyColor, true)
	joint(visualRoot, body, CFrame.new(rest.Body))

	local sides = {
		{ Suffix = "L", Eye = rest.EyeL, Pupil = rest.PupilL, Arm = rest.ArmL, Foot = rest.FootL },
		{ Suffix = "R", Eye = rest.EyeR, Pupil = rest.PupilR, Arm = rest.ArmR, Foot = rest.FootR },
	}
	for _, side in sides do
		local eye = visualPart(model, "Eye" .. side.Suffix, Vector3.new(0.92, 1.18, 0.55), EYE_WHITE, false)
		joint(visualRoot, eye, CFrame.new(side.Eye))

		local pupil = visualPart(model, "Pupil" .. side.Suffix, Vector3.new(0.46, 0.64, 0.22), PUPIL_COLOR, false)
		joint(visualRoot, pupil, CFrame.new(side.Pupil))

		-- Little highlight that makes the eyes read as shiny and alive.
		local shine = visualPart(model, "Shine" .. side.Suffix, Vector3.new(0.17, 0.17, 0.1), EYE_WHITE, false)
		local weld = Instance.new("Weld")
		weld.Name = "ShineWeld"
		weld.Part0 = pupil
		weld.Part1 = shine
		weld.C0 = CFrame.new(0.1, 0.16, -0.1)
		shine.CFrame = pupil.CFrame * weld.C0
		weld.Parent = pupil

		local arm = visualPart(model, "Arm" .. side.Suffix, Vector3.new(0.72, 1.15, 0.72), appearance.BodyColor, false)
		joint(visualRoot, arm, CFrame.new(side.Arm), CFrame.new(0, BlobletRig.ArmHang, 0))

		local foot = visualPart(model, "Foot" .. side.Suffix, Vector3.new(1.25, 0.55, 1.75), appearance.BodyColor, true)
		joint(root, foot, CFrame.new(side.Foot))
	end

	local humanoid = Instance.new("Humanoid")
	humanoid.RigType = Enum.HumanoidRigType.R15
	humanoid.HipHeight = Config.Movement.HipHeight
	humanoid.AutomaticScalingEnabled = false
	humanoid.RequiresNeck = false
	humanoid.BreakJointsOnDeath = false
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
	humanoid.UseJumpPower = true
	humanoid.JumpPower = Config.Movement.JumpVelocity
	humanoid.WalkSpeed = Config.Movement.RunSpeed
	humanoid.MaxSlopeAngle = Config.Movement.MaxSlopeAngle
	humanoid.AutoJumpEnabled = false
	humanoid.Parent = model

	BlobletRig.ApplyAppearance(model, appearance)
	return model
end

function BlobletRig.ApplyAppearance(model: Model, appearance: Appearance)
	local names = BlobletRig.PartNames
	local footColor = appearance.BodyColor:Lerp(Color3.new(0, 0, 0), 0.22)
	for name, color in
		{
			[names.Body] = appearance.BodyColor,
			[names.ArmL] = appearance.BodyColor,
			[names.ArmR] = appearance.BodyColor,
			[names.FootL] = footColor,
			[names.FootR] = footColor,
		}
	do
		local part = model:FindFirstChild(name)
		if part and part:IsA("BasePart") then
			part.Color = color
		end
	end
end

return table.freeze(BlobletRig)
