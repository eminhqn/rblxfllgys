--!strict
-- Animates every Bloblet this client can see: squash-and-stretch on a wobbly spring, leaning,
-- waddling feet, swinging arms, blinking eyes that look where you're going, dive, grab and kick
-- poses and dizzy eyes while ragdolled.
--
-- Everything here is visual only: Motor6D.Transform and SpecialMesh.Scale are local to this
-- client, never replicate and never touch physics. Each client animates other players from
-- their replicated velocity and the server's state attributes, so the server sends no
-- per-frame animation data. Far-away Bloblets update less often or not at all.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local BlobletRig = require(Shared.BlobletRig)
local Config = require(Shared.Config)
local MathUtil = require(Shared.MathUtil)
local Tags = require(Shared.Tags)

local MovementController = require(script.Parent.MovementController)

local BlobletAnimator = {}

local REST = BlobletRig.Rest
local BODY_BOTTOM = BlobletRig.Dimensions.BodyBottom
local BODY_CENTER_Y = REST.Body.Y
local RUN_SPEED = Config.Movement.RunSpeed

local SPRING_STIFFNESS = 300 -- higher = faster wobble
local SPRING_DAMPING = 12 -- lower = more jiggle
local SPRING_SUBSTEP = 1 / 120

local FULL_DETAIL_DISTANCE = 120
local REDUCED_DETAIL_EVERY = 3 -- frames between updates beyond FULL_DETAIL_DISTANCE
local MAX_ANIMATION_DISTANCE = 260

type Rig = {
	Model: Model,
	Root: BasePart,
	VisualRoot: Motor6D,
	Body: Motor6D,
	BodyMesh: SpecialMesh,
	EyeL: Motor6D,
	EyeR: Motor6D,
	EyeMeshL: SpecialMesh,
	EyeMeshR: SpecialMesh,
	PupilL: Motor6D,
	PupilR: Motor6D,
	PupilMeshL: SpecialMesh,
	PupilMeshR: SpecialMesh,
	ShineL: BasePart,
	ShineR: BasePart,
	ArmL: Motor6D,
	ArmR: Motor6D,
	FootL: Motor6D,
	FootR: Motor6D,

	Squash: number,
	SquashVelocity: number,
	Pitch: number,
	Roll: number,
	Phase: number,
	Stride: number,
	Air: number,
	Dive: number,
	Grab: number,
	Kick: number,
	PrevVelocity: Vector3,
	WasGrounded: boolean,
	NextBlink: number,
	BlinkUntil: number,
	Look: Vector2,
	LookTarget: Vector2,
	NextGlance: number,
	FrameCounter: number,
	PendingDt: number,
	Seed: number,
}

local rigs: { [Model]: Rig } = {}
local random = Random.new()
local localPlayer = Players.LocalPlayer

local groundParams = RaycastParams.new()
groundParams.FilterType = Enum.RaycastFilterType.Exclude
groundParams.IgnoreWater = true
groundParams.RespectCanCollide = true

local function refreshRayFilter()
	local models: { Instance } = {}
	for model in rigs do
		table.insert(models, model)
	end
	groundParams.FilterDescendantsInstances = models
end

local function findMotor(parent: Instance, partName: string): Motor6D?
	local motor = parent:FindFirstChild(partName .. BlobletRig.JointSuffix)
	return if motor and motor:IsA("Motor6D") then motor else nil
end

local function findMesh(model: Model, partName: string): SpecialMesh?
	local part = model:FindFirstChild(partName)
	local mesh = if part then part:FindFirstChildOfClass("SpecialMesh") else nil
	return mesh
end

local function findPart(model: Model, partName: string): BasePart?
	local part = model:FindFirstChild(partName)
	return if part and part:IsA("BasePart") then part else nil
end

local function buildRig(model: Model): Rig?
	local names = BlobletRig.PartNames
	local root = findPart(model, names.Root)
	local visualRootPart = findPart(model, names.VisualRoot)
	if not root or not visualRootPart then
		return nil
	end
	local visualRoot = findMotor(root, names.VisualRoot)
	local body = findMotor(visualRootPart, names.Body)
	local eyeL = findMotor(visualRootPart, names.EyeL)
	local eyeR = findMotor(visualRootPart, names.EyeR)
	local pupilL = findMotor(visualRootPart, names.PupilL)
	local pupilR = findMotor(visualRootPart, names.PupilR)
	local armL = findMotor(visualRootPart, names.ArmL)
	local armR = findMotor(visualRootPart, names.ArmR)
	local footL = findMotor(root, names.FootL)
	local footR = findMotor(root, names.FootR)
	local bodyMesh = findMesh(model, names.Body)
	local eyeMeshL = findMesh(model, names.EyeL)
	local eyeMeshR = findMesh(model, names.EyeR)
	local pupilMeshL = findMesh(model, names.PupilL)
	local pupilMeshR = findMesh(model, names.PupilR)
	local shineL = findPart(model, "ShineL")
	local shineR = findPart(model, "ShineR")
	if
		not (visualRoot and body and eyeL and eyeR and pupilL and pupilR and armL and armR and footL and footR)
		or not (bodyMesh and eyeMeshL and eyeMeshR and pupilMeshL and pupilMeshR and shineL and shineR)
	then
		return nil
	end

	local now = os.clock()
	return {
		Model = model,
		Root = root,
		VisualRoot = visualRoot,
		Body = body,
		BodyMesh = bodyMesh,
		EyeL = eyeL,
		EyeR = eyeR,
		EyeMeshL = eyeMeshL,
		EyeMeshR = eyeMeshR,
		PupilL = pupilL,
		PupilR = pupilR,
		PupilMeshL = pupilMeshL,
		PupilMeshR = pupilMeshR,
		ShineL = shineL,
		ShineR = shineR,
		ArmL = armL,
		ArmR = armR,
		FootL = footL,
		FootR = footR,

		Squash = 0,
		SquashVelocity = 0,
		Pitch = 0,
		Roll = 0,
		Phase = 0,
		Stride = 0,
		Air = 0,
		Dive = 0,
		Grab = 0,
		Kick = 0,
		PrevVelocity = Vector3.zero,
		WasGrounded = true,
		NextBlink = now + random:NextNumber(1, 4),
		BlinkUntil = 0,
		Look = Vector2.zero,
		LookTarget = Vector2.zero,
		NextGlance = now + random:NextNumber(1, 3),
		FrameCounter = random:NextInteger(0, REDUCED_DETAIL_EVERY - 1),
		PendingDt = 0,
		Seed = random:NextNumber(0, 100),
	}
end

local function attributeNumber(model: Model, name: string): number
	local value = model:GetAttribute(name)
	return if typeof(value) == "number" then value else 0
end

local function stepSpring(rig: Rig, target: number, dt: number)
	local steps = math.max(1, math.ceil(dt / SPRING_SUBSTEP))
	local h = dt / steps
	for _ = 1, steps do
		local acceleration = -SPRING_STIFFNESS * (rig.Squash - target) - SPRING_DAMPING * rig.SquashVelocity
		rig.SquashVelocity += acceleration * h
		rig.Squash += rig.SquashVelocity * h
	end
	rig.Squash = math.clamp(rig.Squash, -0.45, 0.4)
end

local function animate(rig: Rig, dt: number, now: number, isLocal: boolean)
	local model = rig.Model
	local root = rig.Root
	local velocity = root.AssemblyLinearVelocity

	-- State: the local player uses its predicted pose; everyone else uses server attributes.
	local grounded: boolean
	local diving: boolean
	local grabbing: boolean
	local kicking: boolean
	local ragdolled: boolean
	if isLocal then
		local pose = MovementController.GetPose()
		grounded = pose.Grounded
		diving = pose.Diving
		grabbing = pose.Grabbing or attributeNumber(model, "Grabbing") ~= 0
		kicking = pose.Kicking
		ragdolled = pose.Ragdolled
	else
		local action = model:GetAttribute("Action")
		diving = action == "Dive"
		grabbing = action == "Grab"
		kicking = action == "Kick"
		ragdolled = model:GetAttribute("Ragdolled") == true
		grounded = velocity.Y < 8
			and Workspace:Raycast(
					root.Position,
					Vector3.new(0, -(BlobletRig.Dimensions.RootHeight + 0.45), 0),
					groundParams
				)
				~= nil
	end
	local grabbed = attributeNumber(model, "GrabbedBy") ~= 0
	local holdingSomeone = attributeNumber(model, "Grabbing") ~= 0

	local localVelocity = root.CFrame:VectorToObjectSpace(velocity)
	local acceleration = root.CFrame:VectorToObjectSpace(velocity - rig.PrevVelocity) / math.max(dt, 1e-3)
	local horizontalSpeed = MathUtil.flat(velocity).Magnitude
	local speedFactor = math.clamp(horizontalSpeed / RUN_SPEED, 0, 1.4)

	-- Squash and stretch: stretch while flying fast, a squash kick on landing, a pop on take-off.
	if grounded and not rig.WasGrounded and rig.PrevVelocity.Y < -10 then
		rig.SquashVelocity -= math.clamp(-rig.PrevVelocity.Y * 0.08, 0.8, 5.5)
	elseif not grounded and rig.WasGrounded and velocity.Y > 15 then
		rig.SquashVelocity += 3.5
	end
	local stretchTarget = if grounded then 0 else math.clamp(math.abs(velocity.Y) / 220, 0, 0.16)
	stepSpring(rig, stretchTarget, dt)

	rig.Air = MathUtil.damp(rig.Air, if not grounded and not diving and not ragdolled then 1 else 0, 10, dt)
	rig.Dive = MathUtil.damp(rig.Dive, if diving then 1 else 0, 14, dt)
	rig.Grab = MathUtil.damp(rig.Grab, if grabbing or holdingSomeone then 1 else 0, 16, dt)
	rig.Kick = MathUtil.damp(rig.Kick, if kicking and not ragdolled then 1 else 0, 25, dt)

	-- Lean into acceleration and turns (not while ragdolled; the whole body is tumbling then).
	local pitchTarget = 0
	local rollTarget = 0
	if not ragdolled then
		local forwardSpeed = -localVelocity.Z
		pitchTarget = -math.clamp(forwardSpeed / RUN_SPEED, -0.5, 1.2) * 0.14
			- math.clamp(-acceleration.Z / 450, -0.16, 0.16)
		rollTarget = -math.clamp(acceleration.X / 500, -0.2, 0.2)
	end
	rig.Pitch = MathUtil.damp(rig.Pitch, pitchTarget, 10, dt)
	rig.Roll = MathUtil.damp(rig.Roll, rollTarget, 10, dt)

	-- Waddle cycle.
	if grounded and horizontalSpeed > 0.8 and not diving and not ragdolled then
		rig.Phase += dt * (5 + horizontalSpeed * 0.38)
		rig.Stride = MathUtil.damp(rig.Stride, math.min(speedFactor, 1), 12, dt)
	else
		rig.Stride = MathUtil.damp(rig.Stride, 0, 10, dt)
	end

	local breathe = if grounded and horizontalSpeed < 1 then math.sin(now * 2.6 + rig.Seed) * 0.018 else 0
	local sy = 1 + rig.Squash + breathe
	local sxz = 1 - rig.Squash * 0.55
	local function squashed(point: Vector3): Vector3
		return Vector3.new(point.X * sxz, BODY_BOTTOM + (point.Y - BODY_BOTTOM) * sy, point.Z * sxz)
	end

	-- Whole upper body: bob, lean (about the feet) and belly-flop (about the body centre).
	local bob = math.abs(math.sin(rig.Phase)) * 0.14 * rig.Stride
	local diveTilt = CFrame.new(0, BODY_CENTER_Y, 0)
		* CFrame.Angles(-1.35 * rig.Dive, 0, 0)
		* CFrame.new(0, -BODY_CENTER_Y, 0)
	-- A kick leans the body back.
	rig.VisualRoot.Transform = CFrame.new(0, bob, 0)
		* CFrame.Angles(rig.Pitch + rig.Kick * 0.22, 0, rig.Roll)
		* diveTilt

	rig.BodyMesh.Scale = Vector3.new(sxz, sy, sxz)
	rig.Body.Transform = CFrame.new(squashed(REST.Body) - REST.Body)

	-- Eyes: blink, widen when surprised, look where we're heading (or spin when dizzy).
	if now >= rig.NextBlink then
		rig.BlinkUntil = now + 0.11
		rig.NextBlink = now + random:NextNumber(1.8, 4.5)
	end
	local blink = if now < rig.BlinkUntil and not ragdolled then 0.1 else 1
	local surprised = grabbed or ragdolled or (not grounded and velocity.Y < -60)
	local eyeSize = if surprised then 1.15 else 1
	local eyeScale = Vector3.new(eyeSize, eyeSize * blink, 1)
	rig.EyeMeshL.Scale = eyeScale
	rig.EyeMeshR.Scale = eyeScale
	rig.EyeL.Transform = CFrame.new(squashed(REST.EyeL) - REST.EyeL)
	rig.EyeR.Transform = CFrame.new(squashed(REST.EyeR) - REST.EyeR)

	if ragdolled then
		rig.LookTarget = Vector2.new(math.cos(now * 14), math.sin(now * 14)) * 0.15
	elseif horizontalSpeed > 2 or math.abs(velocity.Y) > 4 then
		rig.LookTarget = Vector2.new(
			math.clamp(localVelocity.X / RUN_SPEED, -1, 1) * 0.13,
			math.clamp(velocity.Y / 90, -1, 1) * 0.12
		)
	elseif now >= rig.NextGlance then
		rig.LookTarget = Vector2.new(random:NextNumber(-0.13, 0.13), random:NextNumber(-0.08, 0.08))
		rig.NextGlance = now + random:NextNumber(1.2, 3.5)
	end
	rig.Look = MathUtil.dampVector2(rig.Look, rig.LookTarget, if ragdolled then 30 else 12, dt)
	local pupilOffset = Vector3.new(rig.Look.X, rig.Look.Y, (rig.Look.X ^ 2 + rig.Look.Y ^ 2) * 1.5)
	local pupilSize = if surprised then 0.8 else 1
	local pupilScale = Vector3.new(pupilSize, pupilSize * blink, 1)
	rig.PupilMeshL.Scale = pupilScale
	rig.PupilMeshR.Scale = pupilScale
	rig.PupilL.Transform = CFrame.new(squashed(REST.PupilL + pupilOffset) - REST.PupilL)
	rig.PupilR.Transform = CFrame.new(squashed(REST.PupilR + pupilOffset) - REST.PupilR)
	local shineHidden = if blink < 1 then 1 else 0
	rig.ShineL.LocalTransparencyModifier = shineHidden
	rig.ShineR.LocalTransparencyModifier = shineHidden

	-- Arms: swing while running, flap in the air, reach forward to grab or dive, flail when hit.
	local swing = math.sin(rig.Phase) * 0.75 * rig.Stride
	local flap = rig.Air * (1.0 + math.sin(now * 17 + rig.Seed) * 0.25)
	local holdShake = if holdingSomeone then math.sin(now * 30) * 0.08 else 0
	local function arm(motor: Motor6D, rest: Vector3, side: number)
		local pitch = swing * side + rig.Grab * 1.5 + rig.Dive * 2.5 + holdShake - rig.Kick * 0.6
		local roll = side * (0.22 + flap * 0.9)
		if ragdolled or grabbed then
			pitch += math.sin(now * 13 + side) * 0.9
			roll += side * math.cos(now * 11 + side) * 0.5
		end
		motor.Transform = CFrame.new(squashed(rest) - rest) * CFrame.Angles(pitch, 0, roll)
	end
	arm(rig.ArmL, REST.ArmL, -1)
	arm(rig.ArmR, REST.ArmR, 1)

	-- Feet: floppy waddle, dangle in the air, trail behind during a dive, splay when squashed.
	local function foot(motor: Motor6D, side: number, phaseOffset: number)
		local phase = rig.Phase + phaseOffset
		local forward = -math.sin(phase) * 0.5 * rig.Stride + rig.Dive * 0.9
		local lift = math.max(0, math.cos(phase)) * 0.38 * rig.Stride + rig.Dive * 0.7
		local flop = math.sin(phase) * 0.45 * rig.Stride + rig.Dive * 1.0
		forward += rig.Air * math.sin(now * 12 + phaseOffset) * 0.2
		flop += rig.Air * 0.35
		local splay = math.max(0, -rig.Squash) * 0.6 * side
		if side > 0 then
			-- The right foot does the kicking: out in front, up, toes raised.
			forward -= rig.Kick * 1.7
			lift += rig.Kick * 1.1
			flop += rig.Kick * 0.9
		end
		motor.Transform = CFrame.new(splay, lift, forward) * CFrame.Angles(flop, 0, 0)
	end
	foot(rig.FootL, -1, 0)
	foot(rig.FootR, 1, math.pi)

	rig.PrevVelocity = velocity
	rig.WasGrounded = grounded
end

local function onStep(dt: number)
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end
	local cameraPosition = camera.CFrame.Position
	local now = os.clock()
	local localCharacter = localPlayer.Character

	for model, rig in rigs do
		if not rig.Root.Parent then
			continue
		end
		local isLocal = model == localCharacter
		local distance = (rig.Root.Position - cameraPosition).Magnitude
		if not isLocal and distance > MAX_ANIMATION_DISTANCE then
			continue
		end
		local stepDt = dt
		if not isLocal and distance > FULL_DETAIL_DISTANCE then
			rig.FrameCounter += 1
			rig.PendingDt += dt
			if rig.FrameCounter % REDUCED_DETAIL_EVERY ~= 0 then
				continue
			end
			stepDt = rig.PendingDt
		end
		rig.PendingDt = 0
		animate(rig, math.min(stepDt, 0.1), now, isLocal)
	end
end

local pending: { [Model]: number } = {} -- models whose parts haven't all arrived yet

local function tryRegister(model: Model): boolean
	local rig = buildRig(model)
	if not rig then
		return false
	end
	rigs[model] = rig
	refreshRayFilter()
	return true
end

local function onTagged(instance: Instance)
	if not instance:IsA("Model") or rigs[instance] then
		return
	end
	if not tryRegister(instance) then
		pending[instance] = os.clock()
	end
end

local function onUntagged(instance: Instance)
	if instance:IsA("Model") then
		pending[instance] = nil
		if rigs[instance] then
			rigs[instance] = nil
			refreshRayFilter()
		end
	end
end

function BlobletAnimator.Init()
	CollectionService:GetInstanceAddedSignal(Tags.Bloblet):Connect(onTagged)
	CollectionService:GetInstanceRemovedSignal(Tags.Bloblet):Connect(onUntagged)
	for _, instance in CollectionService:GetTagged(Tags.Bloblet) do
		onTagged(instance)
	end

	-- Retry models that arrived incomplete (gives up after 10 seconds).
	task.spawn(function()
		while true do
			task.wait(0.5)
			local now = os.clock()
			for model, since in pending do
				if tryRegister(model) or now - since > 10 or not model.Parent then
					pending[model] = nil
				end
			end
		end
	end)

	-- Motor6D.Transform should be written before physics each frame.
	RunService.PreSimulation:Connect(onStep)
end

return BlobletAnimator
