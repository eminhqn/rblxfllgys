--!strict
-- Drives the local player's Bloblet.
--
-- The client owns its Bloblet's physics, so everything here runs immediately on this machine:
-- there is no round trip before you move, jump or dive. That's the "client-side prediction".
-- Actions that affect other players or the match (dive, grab) are also sent to the server, which
-- validates them, broadcasts the result, and can reject them (we then cancel the prediction).
--
-- Movement feel:
--   * our own acceleration curve, fed to the Humanoid each frame via Move() + WalkSpeed
--   * coyote time (jump shortly after leaving a ledge) and jump buffering (jump pressed just
--     before landing still fires)
--   * variable jump height and extra gravity while falling for snappy, readable jumps
--   * strong air control; extra speed from dives and slide-jumps fades slowly in the air
--   * dives steer mid-air, land in a short steerable slide, and jump cancels the slide

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local BlobletRig = require(Shared.BlobletRig)
local Config = require(Shared.Config)
local MathUtil = require(Shared.MathUtil)
local Remotes = require(Shared.Remotes)
local Tags = require(Shared.Tags)

local ClientEvents = require(script.Parent.ClientEvents)
local Input = require(script.Parent.InputController)

type Mode = "Normal" | "Dive" | "Slide" | "Recover" | "Ragdoll"

export type Pose = {
	Grounded: boolean,
	Diving: boolean,
	Ragdolled: boolean,
	Grabbing: boolean,
}

local MovementController = {}

local GROUND_PROBE_RADIUS = 0.9
local GROUND_PROBE_EXTRA = 0.35 -- how far below standing height still counts as grounded
local BOUNCE_COOLDOWN = 0.25
local DEFAULT_BOUNCE_POWER = 80

local localPlayer = Players.LocalPlayer

local character: Model? = nil
local humanoid: Humanoid? = nil
local root: BasePart? = nil
local fallForce: VectorForce? = nil

local mode: Mode = "Normal"
local modeStart = 0
local recoverDuration = 0
local diveDirection = Vector3.new(0, 0, -1)
local ragdollUntil = 0

local grounded = false
local groundPart: BasePart? = nil
local lastAirVelocityY = 0
local lastGroundedTime = -math.huge
local lastJumpPressTime = -math.huge
local jumpGroundLockUntil = 0
local risingFromJump = false
local lastBounceTime = -math.huge

local lastDiveTime = -math.huge
local lastGrabTime = -math.huge
local grabHeld = false

local pose: Pose = { Grounded = false, Diving = false, Ragdolled = false, Grabbing = false }

local groundParams = RaycastParams.new()
groundParams.FilterType = Enum.RaycastFilterType.Exclude
groundParams.IgnoreWater = true
groundParams.RespectCanCollide = true

local function setMode(newMode: Mode, now: number)
	local wasDiving = mode == "Dive" or mode == "Slide"
	mode = newMode
	modeStart = now
	if wasDiving and newMode ~= "Dive" and newMode ~= "Slide" then
		-- Ends the dive pose for everyone else as soon as our slide is over.
		Remotes.Event("EndDive"):FireServer()
	end
end

local function setFallForce(enabled: boolean, rootPart: BasePart?)
	local force = fallForce
	if not force then
		return
	end
	if enabled and rootPart then
		local extra = Config.Movement.FallGravityMultiplier - 1
		force.Force = Vector3.new(0, -rootPart.AssemblyMass * Workspace.Gravity * extra, 0)
	end
	force.Enabled = enabled
end

local function probeGround(rootPart: BasePart): RaycastResult?
	local distance = BlobletRig.Dimensions.RootHeight - GROUND_PROBE_RADIUS + GROUND_PROBE_EXTRA
	return Workspace:Spherecast(rootPart.Position, GROUND_PROBE_RADIUS, Vector3.new(0, -distance, 0), groundParams)
end

local function attributeNumber(instance: Instance, name: string): number
	local value = instance:GetAttribute(name)
	return if typeof(value) == "number" then value else 0
end

local function speedMultiplier(): number
	local model = character
	if not model then
		return 1
	end
	local multiplier = 1
	if attributeNumber(model, "GrabbedBy") ~= 0 then
		multiplier = math.min(multiplier, Config.Grab.VictimSpeedMultiplier)
	end
	if attributeNumber(model, "Grabbing") ~= 0 then
		multiplier = math.min(multiplier, Config.Grab.GrabberSpeedMultiplier)
	elseif grabHeld then
		multiplier = math.min(multiplier, Config.Grab.ReachSpeedMultiplier)
	end
	return multiplier
end

-- While grabbed, you get tugged towards whoever is holding you.
local function grabPull(rootPart: BasePart): Vector3
	local model = character
	if not model then
		return Vector3.zero
	end
	local grabberId = attributeNumber(model, "GrabbedBy")
	if grabberId == 0 then
		return Vector3.zero
	end
	local grabber = Players:GetPlayerByUserId(grabberId)
	local grabberCharacter = if grabber then grabber.Character else nil
	local grabberRoot = if grabberCharacter then grabberCharacter.PrimaryPart else nil
	if not grabberRoot then
		return Vector3.zero
	end
	local offset = MathUtil.flat(grabberRoot.Position - rootPart.Position)
	if offset.Magnitude < 3.6 then
		return Vector3.zero
	end
	return offset.Unit * Config.Grab.VictimPullSpeed
end

local function pickAcceleration(current: Vector3, target: Vector3): number
	local movement = Config.Movement
	if not grounded then
		return if target.Magnitude < 0.01 then movement.AirDeceleration else movement.AirAcceleration
	end
	if target.Magnitude < 0.01 then
		return movement.GroundDeceleration
	end
	if current.Magnitude > 1 and current.Unit:Dot(target.Unit) < 0.5 then
		return movement.TurnAcceleration -- sharp turns feel responsive instead of floaty
	end
	return if target.Magnitude >= current.Magnitude then movement.GroundAcceleration else movement.GroundDeceleration
end

local function doJump(hum: Humanoid, rootPart: BasePart, now: number)
	if mode == "Slide" then
		setMode("Normal", now) -- slide cancel: keeps the dive's speed
	end
	hum:ChangeState(Enum.HumanoidStateType.Jumping)
	local velocity = rootPart.AssemblyLinearVelocity
	rootPart.AssemblyLinearVelocity = Vector3.new(velocity.X, Config.Movement.JumpVelocity, velocity.Z)
	jumpGroundLockUntil = now + Config.Movement.JumpGroundLock
	lastGroundedTime = -math.huge -- no second coyote jump
	lastJumpPressTime = -math.huge -- consume the buffered press
	risingFromJump = true
	ClientEvents.Jumped:Fire()
end

local function bounce(hum: Humanoid, rootPart: BasePart, pad: BasePart, now: number)
	local power = pad:GetAttribute("Power")
	local velocity = rootPart.AssemblyLinearVelocity
	hum:ChangeState(Enum.HumanoidStateType.Freefall)
	rootPart.AssemblyLinearVelocity =
		Vector3.new(velocity.X, if typeof(power) == "number" then power else DEFAULT_BOUNCE_POWER, velocity.Z)
	lastBounceTime = now
	jumpGroundLockUntil = now + 0.15
	lastGroundedTime = -math.huge
	risingFromJump = false
	if mode == "Dive" or mode == "Slide" then
		setMode("Normal", now)
	end
	ClientEvents.Bounced:Fire(pad)
end

local function getUp(hum: Humanoid, rootPart: BasePart, now: number)
	local position = rootPart.Position + Vector3.new(0, 0.6, 0)
	local look = MathUtil.flat(rootPart.CFrame.LookVector)
	if look.Magnitude < 1e-3 then
		look = Vector3.new(0, 0, -1)
	end
	rootPart.AssemblyAngularVelocity = Vector3.zero
	rootPart.CFrame = CFrame.lookAt(position, position + look.Unit)
	hum:ChangeState(Enum.HumanoidStateType.GettingUp)
	rootPart.AssemblyLinearVelocity = Vector3.new(0, Config.Ragdoll.GetUpHop, 0)
	jumpGroundLockUntil = now + 0.1
	recoverDuration = Config.Ragdoll.GetUpRecoverTime
	setMode("Recover", now)
	ClientEvents.GotUp:Fire()
end

local function step(dt: number)
	local hum, rootPart = humanoid, root
	if not hum or not rootPart or not rootPart.Parent then
		return
	end
	local now = os.clock()
	local velocity = rootPart.AssemblyLinearVelocity
	-- Only this controller may jump. If Roblox's default controls ever switch themselves back on
	-- (they can when the input device changes), this stops them jumping us out of a slide.
	hum.Jump = false

	-- Ground check (a short sphere cast is forgiving on edges and slopes).
	local hit = if mode == "Ragdoll" then nil else probeGround(rootPart)
	local wasGrounded = grounded
	grounded = hit ~= nil and now >= jumpGroundLockUntil and velocity.Y < 12
	local hitInstance = if hit then hit.Instance else nil
	groundPart = if grounded and hitInstance and hitInstance:IsA("BasePart") then hitInstance else nil
	if grounded then
		lastGroundedTime = now
		if not wasGrounded then
			ClientEvents.Landed:Fire(-lastAirVelocityY)
		end
	else
		lastAirVelocityY = velocity.Y
	end

	pose.Grounded = grounded
	pose.Diving = mode == "Dive" or mode == "Slide"
	pose.Ragdolled = mode == "Ragdoll"
	pose.Grabbing = grabHeld

	if mode == "Ragdoll" then
		setFallForce(false, rootPart)
		if now >= ragdollUntil then
			getUp(hum, rootPart, now)
		end
		return
	end

	local pad = groundPart
	if pad and now - lastBounceTime > BOUNCE_COOLDOWN and CollectionService:HasTag(pad, Tags.BouncePad) then
		bounce(hum, rootPart, pad, now)
		return
	end

	-- Horizontal velocity relative to whatever we're standing on (so conveyors and moving
	-- platforms keep working).
	local floorVelocity = if groundPart
		then MathUtil.flat(groundPart:GetVelocityAtPosition(rootPart.Position))
		else Vector3.zero
	local current = MathUtil.flat(velocity) - floorVelocity

	-- Dive -> short steerable belly slide -> normal. Jumping cancels the slide (see below).
	local dive = Config.Dive
	if mode == "Dive" then
		local airTime = now - modeStart
		if (grounded and airTime > dive.MinAirTime) or airTime > dive.MaxAirTime then
			setMode("Slide", now)
		end
	elseif mode == "Slide" then
		if now - modeStart >= dive.SlideTime then
			setMode("Normal", now)
		end
	elseif mode == "Recover" then
		if now - modeStart >= recoverDuration then
			setMode("Normal", now)
		end
	end

	-- Jumping with coyote time and buffering.
	local movement = Config.Movement
	local jumpBuffered = now - lastJumpPressTime <= movement.JumpBufferTime
	local canJump = (mode == "Normal" or mode == "Slide") and now - lastGroundedTime <= movement.CoyoteTime
	if jumpBuffered and canJump then
		doJump(hum, rootPart, now)
		velocity = rootPart.AssemblyLinearVelocity
	end
	if risingFromJump then
		if velocity.Y <= 0 then
			risingFromJump = false
		elseif not Input.IsJumpHeld() then
			-- Short tap = short hop.
			velocity = Vector3.new(velocity.X, velocity.Y * movement.JumpCutMultiplier, velocity.Z)
			rootPart.AssemblyLinearVelocity = velocity
			risingFromJump = false
		end
	end

	setFallForce(not grounded and velocity.Y < 0, rootPart)
	if velocity.Y < -movement.MaxFallSpeed then
		rootPart.AssemblyLinearVelocity = Vector3.new(velocity.X, -movement.MaxFallSpeed, velocity.Z)
	end

	-- Horizontal movement: our own acceleration curve.
	local moveInput = Input.GetMoveVector()
	local target: Vector3
	local acceleration: number
	if mode == "Normal" then
		target = moveInput * movement.RunSpeed * speedMultiplier() + grabPull(rootPart)
		if not grounded and target.Magnitude > 0.01 and current.Magnitude > target.Magnitude then
			if current:Dot(target) > 0 then
				-- Faster than running (dive, slide-jump, bounce): keep that speed in the air and let it
				-- fade slowly, while still steering freely.
				local keptSpeed = math.max(target.Magnitude, current.Magnitude - movement.AirMomentumDrag * dt)
				target = target.Unit * keptSpeed
			end
		end
		acceleration = pickAcceleration(current, target)
	elseif mode == "Dive" then
		-- Keep the dive's speed but let the sideways part of the stick bend its direction.
		local sideways = moveInput - diveDirection * moveInput:Dot(diveDirection)
		target = (diveDirection * dive.Speed + sideways * dive.AirSteerSpeed).Unit * dive.Speed
		acceleration = dive.AirSteerAcceleration
	elseif mode == "Slide" then
		-- Short belly slide: friction pulls you towards whatever speed the stick asks for.
		target = moveInput * movement.RunSpeed * dive.SlideControl
		acceleration = dive.SlideFriction
	else
		target = Vector3.zero
		acceleration = if grounded then movement.GroundDeceleration else 0
	end

	local newVelocity = MathUtil.moveTowards(current, target, acceleration * dt)
	local speed = newVelocity.Magnitude
	if mode == "Dive" and speed > 1 then
		diveDirection = newVelocity / speed
	end
	if speed > 0.05 then
		hum.WalkSpeed = speed
		hum:Move(newVelocity / speed, false)
	else
		hum.WalkSpeed = 0
		hum:Move(Vector3.zero, false)
	end
end

local function tryDive()
	local hum, rootPart = humanoid, root
	if not hum or not rootPart then
		return
	end
	local now = os.clock()
	if mode ~= "Normal" or now - lastDiveTime < Config.Dive.Cooldown then
		return
	end
	local direction = Input.GetMoveVector()
	if direction.Magnitude < 0.1 then
		direction = MathUtil.flat(rootPart.CFrame.LookVector)
	end
	if direction.Magnitude < 1e-3 then
		return
	end
	direction = direction.Unit

	if grabHeld then
		grabHeld = false
		Remotes.Event("RequestRelease"):FireServer()
	end

	local velocity = rootPart.AssemblyLinearVelocity
	local lift = if grounded then Config.Dive.GroundLift else math.max(velocity.Y, 0) * 0.4 + Config.Dive.AirLift
	lastDiveTime = now
	diveDirection = direction
	setMode("Dive", now)
	risingFromJump = false
	jumpGroundLockUntil = now + Config.Dive.MinAirTime

	hum:ChangeState(Enum.HumanoidStateType.Freefall)
	local position = rootPart.Position
	rootPart.CFrame = CFrame.lookAt(position, position + direction)
	rootPart.AssemblyLinearVelocity = direction * Config.Dive.Speed + Vector3.new(0, lift, 0)

	Remotes.Event("RequestDive"):FireServer(direction)
	ClientEvents.Dived:Fire()
	ClientEvents.DiveCooldownStarted:Fire(Config.Dive.Cooldown)
end

local function onGrabChanged(held: boolean)
	local now = os.clock()
	if held then
		if mode ~= "Normal" or now - lastGrabTime < Config.Grab.Cooldown then
			return
		end
		grabHeld = true
		lastGrabTime = now
		Remotes.Event("RequestGrab"):FireServer()
		ClientEvents.GrabStarted:Fire()
	elseif grabHeld then
		grabHeld = false
		Remotes.Event("RequestRelease"):FireServer()
	end
end

-- Knock the local Bloblet over. `report` tells the server (for client-detected hazard hits).
function MovementController.Knockdown(impulse: Vector3, strength: number, report: boolean, duration: number?)
	local hum, rootPart = humanoid, root
	if not hum or not rootPart or mode == "Ragdoll" then
		return
	end
	local now = os.clock()
	grabHeld = false
	setMode("Ragdoll", now)
	ragdollUntil = now + (duration or Config.RagdollDuration(strength))
	setFallForce(false, rootPart)
	hum:Move(Vector3.zero, false)
	hum:ChangeState(Enum.HumanoidStateType.Physics)

	rootPart.AssemblyLinearVelocity = rootPart.AssemblyLinearVelocity * 0.3 + impulse
	-- Roll in the direction we were hit: spin axis = up x push direction.
	local push = MathUtil.flat(impulse)
	local rollAxis = Vector3.new(push.Z, 0, -push.X)
	rollAxis = if rollAxis.Magnitude > 1e-3 then rollAxis.Unit else Vector3.xAxis
	rootPart.AssemblyAngularVelocity = rollAxis * (8 + 10 * strength)

	if report then
		Remotes.Event("ReportKnockdown"):FireServer(strength)
	end
	ClientEvents.KnockedDown:Fire(strength)
end

function MovementController.GetPose(): Pose
	return pose
end

function MovementController.GetRoot(): BasePart?
	return root
end

function MovementController.IsRagdolled(): boolean
	return mode == "Ragdoll"
end

local function detach()
	character = nil
	humanoid = nil
	root = nil
	fallForce = nil
	grabHeld = false
	grounded = false
	groundPart = nil
	risingFromJump = false
	setMode("Normal", os.clock())
end

local function attach(newCharacter: Model)
	detach()
	local hum = newCharacter:WaitForChild("Humanoid", 10)
	local rootPart = newCharacter:WaitForChild(BlobletRig.PartNames.Root, 10)
	if not (hum and hum:IsA("Humanoid") and rootPart and rootPart:IsA("BasePart")) then
		warn("[MovementController] Bloblet is missing its Humanoid or root")
		return
	end
	if localPlayer.Character ~= newCharacter then
		return -- replaced while we were waiting
	end
	for _, state in BlobletRig.DisabledStates do
		hum:SetStateEnabled(state, false)
	end
	hum.AutoRotate = true

	local force = rootPart:FindFirstChild("FallForce")
	character = newCharacter
	humanoid = hum
	root = rootPart
	fallForce = if force and force:IsA("VectorForce") then force else nil
	groundParams.FilterDescendantsInstances = { newCharacter }
	lastGroundedTime = -math.huge
	lastJumpPressTime = -math.huge
end

function MovementController.Init()
	Input.JumpPressed:Connect(function()
		lastJumpPressTime = os.clock()
	end)
	Input.DivePressed:Connect(tryDive)
	Input.GrabChanged:Connect(onGrabChanged)

	Remotes.Event("ActionRejected").OnClientEvent:Connect(function(action: unknown)
		local now = os.clock()
		if action == "Dive" and (mode == "Dive" or mode == "Slide") then
			setMode("Normal", now)
		elseif action == "Grab" then
			grabHeld = false
		end
	end)

	Remotes.Event("ApplyRagdoll").OnClientEvent:Connect(function(impulse: unknown, duration: unknown)
		if typeof(impulse) == "Vector3" and typeof(duration) == "number" then
			MovementController.Knockdown(impulse, 0.5, false, duration)
		end
	end)

	localPlayer.CharacterAdded:Connect(attach)
	localPlayer.CharacterRemoving:Connect(function(oldCharacter: Model)
		if oldCharacter == character then
			detach()
		end
	end)
	local existing = localPlayer.Character
	if existing then
		task.spawn(attach, existing)
	end

	RunService.PreSimulation:Connect(step)
end

return MovementController
