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
--   * water: you float on it; falling in knocks you over, then you can swim and jump back out
--   * slippery floors (a Grip attribute): you skid, turn slowly and slide downhill
--   * water slides (a Flow attribute, a velocity): the water carries you along and you steer, and
--     sliding never slows you down (a belly slide lasts the whole way and beats the water); fly
--     off the end and you keep the speed for a moment
--   * kick: knocks over whoever is right in front of you (the server decides who)
--   * slap (holding a slapper: you picked SLAPS for the round): a stronger kick; the server
--     decides who and uses one up
--   * items you picked for the round (Shared/Items): SPEED, JUMP and SLIDE boosts, and DOUBLE
--     JUMP (one more jump in mid-air, ready again every time you land)
--   * when the server moves us (round start, race respawn) we drop all momentum and stand up

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local BlobletRig = require(Shared.BlobletRig)
local Config = require(Shared.Config)
local Match = require(Shared.Match)
local MathUtil = require(Shared.MathUtil)
local Remotes = require(Shared.Remotes)
local Tags = require(Shared.Tags)

local ClientEvents = require(script.Parent.ClientEvents)
local Input = require(script.Parent.InputController)
local MatchClient = require(script.Parent.MatchClient)
local ProfileClient = require(script.Parent.ProfileClient)
local WaterSurfaces = require(script.Parent.WaterSurfaces)

type Mode = "Normal" | "Dive" | "Slide" | "Recover" | "Ragdoll"

export type Pose = {
	Grounded: boolean,
	Diving: boolean,
	Ragdolled: boolean,
	Grabbing: boolean,
	Kicking: boolean,
	Slapping: boolean,
}

local MovementController = {}

local GROUND_PROBE_RADIUS = 0.9
local GROUND_PROBE_EXTRA = 0.35 -- how far below standing height still counts as grounded
local BOUNCE_COOLDOWN = 0.25
local BOUNCE_GROUND_LOCK = 0.2 -- ignore the pad for this long after it launches us
local DEFAULT_BOUNCE_POWER = 80
local SPLASH_SPEED = 20 -- falling into water faster than this knocks you over
local SPLASH_COOLDOWN = 2.5
local WATER_GET_UP_HOP = 8
local FLOW_STEER = 0.5 -- share of running speed the stick adds on a water slide
local FLOW_ACCELERATION = 70
local FLOW_CARRY_TIME = 1.5 -- seconds after leaving a water slide that you keep its speed in the air
local FLOW_SLIDE_SPEEDUP = 1.15 -- a belly slide down a water slide goes this much faster than the water
local FLOW_MOMENTUM_DRAG = 4 -- studs/s^2: extra speed on a water slide (from a dive) fades this slowly
local FLOW_BRAKE_DRAG = 30 -- studs/s^2 when you pull back against the water
local FLOW_GRACE = 0.25 -- seconds off the water (a bump) that a belly slide carries on through
local SHIELD_BUMP = 0.25 -- share of an obstacle's push a shield still lets through (no knock-over)
-- A little longer than the server's grace, so one knock is never reported twice.
local SHIELD_REPORT_GAP = Config.Items.ShieldHitGrace + 0.15

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
local groundNormal = Vector3.yAxis
local lastAirVelocityY = 0
local lastGroundedTime = -math.huge
local lastJumpPressTime = -math.huge
local jumpGroundLockUntil = 0
local risingFromJump = false
local airJumpReady = false -- DOUBLE JUMP: the mid-air jump hasn't been used since we last landed
local lastFlowTime = -math.huge -- last time we were on a water slide
local lastBounceTime = -math.huge
local jumpPowerRaised = false -- JumpPower is set to a pad's power until the next step

local lastDiveTime = -math.huge
local lastGrabTime = -math.huge
local grabHeld = false
local lastKickTime = -math.huge
local kickPoseUntil = 0
local lastSlapTime = -math.huge
local slapPoseUntil = 0
local lastShieldHit = -math.huge

local inWater = false
local lastSplashTime = -math.huge

local teleportPending = false
local teleportConnection: RBXScriptConnection? = nil

local pose: Pose = {
	Grounded = false,
	Diving = false,
	Ragdolled = false,
	Grabbing = false,
	Kicking = false,
	Slapping = false,
}

local groundParams = RaycastParams.new()
groundParams.FilterType = Enum.RaycastFilterType.Exclude
groundParams.IgnoreWater = true
groundParams.RespectCanCollide = true

-- An item (SPEED, JUMP, SLIDE) working for us this round: only while competing, so they never
-- help in the lobby (or on its parkour).
local function boosted(itemId: string): boolean
	return ProfileClient.IsItemActive(itemId) and localPlayer:GetAttribute(Match.PlayerAttr.InMatch) == true
end

local function runSpeed(): number
	return Config.Movement.RunSpeed * (if boosted("Speed") then Config.Items.SpeedMultiplier else 1)
end

local function jumpVelocity(): number
	return Config.Movement.JumpVelocity * (if boosted("Jump") then Config.Items.JumpMultiplier else 1)
end

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

-- The water slide's flow under us (its Flow attribute, flattened), or nil off a water slide.
local function flowHere(): Vector3?
	local floor = groundPart
	if not grounded or not floor then
		return nil
	end
	local flow = floor:GetAttribute("Flow")
	if typeof(flow) ~= "Vector3" or flow.Magnitude < 0.1 then
		return nil
	end
	return MathUtil.flat(flow)
end

-- Where a water slide takes you: along its flow at `least` speed (plus or minus the stick), and any
-- extra speed you bring (a dive, a belly slide) is kept, fading slowly, so sliding never slows you
-- down. The sideways part of the stick steers across the slide.
local function flowTarget(flow: Vector3, current: Vector3, least: number, steer: Vector3, dt: number): Vector3
	local direction = flow.Unit
	local steerAlong = steer:Dot(direction)
	local drag = if steerAlong < 0 then FLOW_BRAKE_DRAG else FLOW_MOMENTUM_DRAG
	local speed = math.max(least + steerAlong, current:Dot(direction) - drag * dt)
	return direction * speed + (steer - direction * steerAlong)
end

-- How much grip the floor gives (1 = normal, lower = icier). Set with a Grip attribute on the part.
local function floorGrip(): number
	local floor = groundPart
	if not floor then
		return 1
	end
	local grip = floor:GetAttribute("Grip")
	return if typeof(grip) == "number" then math.clamp(grip, 0.05, 1) else 1
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
	rootPart.AssemblyLinearVelocity = Vector3.new(velocity.X, jumpVelocity(), velocity.Z)
	jumpGroundLockUntil = now + Config.Movement.JumpGroundLock
	lastGroundedTime = -math.huge -- no second coyote jump
	lastJumpPressTime = -math.huge -- consume the buffered press
	risingFromJump = true
	ClientEvents.Jumped:Fire()
end

local function bounce(hum: Humanoid, rootPart: BasePart, pad: BasePart, now: number)
	local attribute = pad:GetAttribute("Power")
	local power = if typeof(attribute) == "number" then attribute else DEFAULT_BOUNCE_POWER
	local velocity = rootPart.AssemblyLinearVelocity
	-- Launch through the Jumping state, exactly like a normal jump, so every bounce is the same
	-- height. (Launching from Freefall let the Humanoid decide it had "landed" again while still
	-- touching the pad and soak up most of the launch: a random little hop.) The Humanoid applies
	-- JumpPower itself, so it's raised to the pad's power for this one launch.
	hum.JumpPower = power
	jumpPowerRaised = true
	hum:ChangeState(Enum.HumanoidStateType.Jumping)
	rootPart.AssemblyLinearVelocity = Vector3.new(velocity.X, power, velocity.Z)
	lastBounceTime = now
	jumpGroundLockUntil = now + BOUNCE_GROUND_LOCK
	lastJumpPressTime = -math.huge -- a jump pressed just before landing doesn't fire afterwards
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
	-- A small bob in the water, a proper hop on land.
	local hop = if inWater then WATER_GET_UP_HOP else Config.Ragdoll.GetUpHop
	rootPart.AssemblyLinearVelocity = Vector3.new(0, hop, 0)
	jumpGroundLockUntil = now + 0.1
	recoverDuration = Config.Ragdoll.GetUpRecoverTime
	setMode("Recover", now)
	ClientEvents.GotUp:Fire()
end

-- The server just placed us somewhere new: forget the old momentum and any ragdoll, and stand
-- upright facing the way we were placed.
local function settleAfterTeleport(hum: Humanoid, rootPart: BasePart, now: number)
	teleportPending = false
	if mode == "Ragdoll" then
		hum:ChangeState(Enum.HumanoidStateType.GettingUp)
	end
	if grabHeld then
		grabHeld = false
		Remotes.Event("RequestRelease"):FireServer()
	end
	setMode("Normal", now)
	setFallForce(false, rootPart)
	risingFromJump = false
	lastAirVelocityY = 0
	lastJumpPressTime = -math.huge
	if not rootPart.Anchored then
		rootPart.AssemblyLinearVelocity = Vector3.zero
		rootPart.AssemblyAngularVelocity = Vector3.zero
	end
	local look = MathUtil.flat(rootPart.CFrame.LookVector)
	if look.Magnitude > 1e-3 then
		local position = rootPart.Position
		rootPart.CFrame = CFrame.lookAt(position, position + look.Unit)
	end
	ClientEvents.Teleported:Fire()
end

local function step(dt: number)
	local hum, rootPart = humanoid, root
	if not hum or not rootPart or not rootPart.Parent then
		return
	end
	local now = os.clock()
	if jumpPowerRaised then
		-- The bounce has been applied by the physics step that just ran.
		jumpPowerRaised = false
		hum.JumpPower = jumpVelocity()
	elseif hum.JumpPower ~= jumpVelocity() then
		hum.JumpPower = jumpVelocity() -- a JUMP boost started or ended
	end
	if teleportPending then
		settleAfterTeleport(hum, rootPart, now)
	end
	if rootPart.Anchored then
		-- Frozen by the round manager (e.g. during the round intro): just reset to standing.
		if mode == "Ragdoll" then
			hum:ChangeState(Enum.HumanoidStateType.GettingUp)
		end
		if mode ~= "Normal" then
			setMode("Normal", now)
		end
		setFallForce(false, rootPart)
		hum:Move(Vector3.zero, false)
		return
	end
	local velocity = rootPart.AssemblyLinearVelocity
	-- Only this controller may jump. If Roblox's default controls ever switch themselves back on
	-- (they can when the input device changes), this stops them jumping us out of a slide.
	hum.Jump = false

	-- Water: float at the surface. Falling in fast knocks you over first (the splash).
	local water = Config.Water
	local surface = WaterSurfaces.GetSurfaceAt(rootPart.Position)
	local wasInWater = inWater
	inWater = surface ~= nil and rootPart.Position.Y < surface + water.EnterMargin
	if inWater and surface then
		local floatY = surface + water.FloatHeight
		if rootPart.Position.Y < floatY + 0.15 and velocity.Y < 12 then
			velocity = Vector3.new(velocity.X, math.clamp((floatY - rootPart.Position.Y) * 7, -6, 14), velocity.Z)
			rootPart.AssemblyLinearVelocity = velocity
		end
		if not wasInWater then
			local impactSpeed = -lastAirVelocityY
			if impactSpeed > SPLASH_SPEED and now - lastSplashTime > SPLASH_COOLDOWN and mode ~= "Ragdoll" then
				lastSplashTime = now
				ClientEvents.Splashed:Fire()
				MovementController.Knockdown(
					MathUtil.flat(velocity) * 0.2 + Vector3.new(0, 4, 0),
					0,
					true,
					water.SplashRagdollTime
				)
			end
		end
	end
	pose.Kicking = now < kickPoseUntil
	pose.Slapping = now < slapPoseUntil

	-- Ground check (a short sphere cast is forgiving on edges and slopes).
	local hit = if mode == "Ragdoll" then nil else probeGround(rootPart)
	local wasGrounded = grounded
	grounded = hit ~= nil and now >= jumpGroundLockUntil and velocity.Y < 12
	local hitInstance = if hit then hit.Instance else nil
	groundPart = if grounded and hitInstance and hitInstance:IsA("BasePart") then hitInstance else nil
	groundNormal = if grounded and hit then hit.Normal else Vector3.yAxis
	if grounded then
		lastGroundedTime = now
		airJumpReady = true
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

	local flow = flowHere()
	if flow then
		lastFlowTime = now
	end

	-- Dive -> short steerable belly slide -> normal. Jumping cancels the slide (see below). Down a
	-- water slide the belly slide lasts as long as you're on the water.
	local dive = Config.Dive
	if mode == "Dive" then
		local airTime = now - modeStart
		if (grounded and airTime > dive.MinAirTime) or airTime > dive.MaxAirTime then
			setMode("Slide", now)
		end
	elseif mode == "Slide" then
		local stopped = grounded and current.Magnitude < dive.SlideStopSpeed
		local slideTime = dive.SlideTime * (if boosted("Slide") then Config.Items.SlideTimeMultiplier else 1)
		local onWater = now - lastFlowTime < FLOW_GRACE
		if not onWater and (stopped or now - modeStart >= slideTime) then
			setMode("Normal", now)
		end
	elseif mode == "Recover" then
		if now - modeStart >= recoverDuration then
			setMode("Normal", now)
		end
	end

	-- Jumping with coyote time and buffering. Floating in water counts as standing for jumps.
	local movement = Config.Movement
	if inWater and mode == "Normal" then
		lastGroundedTime = now
		airJumpReady = true
	end
	local jumpBuffered = now - lastJumpPressTime <= movement.JumpBufferTime
	local canJump = (mode == "Normal" or mode == "Slide") and now - lastGroundedTime <= movement.CoyoteTime
	if jumpBuffered and canJump then
		doJump(hum, rootPart, now)
		velocity = rootPart.AssemblyLinearVelocity
	elseif jumpBuffered and airJumpReady and mode == "Normal" and not grounded and boosted("DoubleJump") then
		-- DOUBLE JUMP: one more jump in mid-air.
		airJumpReady = false
		doJump(hum, rootPart, now)
		velocity = rootPart.AssemblyLinearVelocity
		ClientEvents.DoubleJumped:Fire()
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

	setFallForce(not grounded and not inWater and velocity.Y < 0, rootPart)
	if velocity.Y < -movement.MaxFallSpeed then
		rootPart.AssemblyLinearVelocity = Vector3.new(velocity.X, -movement.MaxFallSpeed, velocity.Z)
	end

	-- Horizontal movement: our own acceleration curve.
	local moveInput = Input.GetMoveVector()
	local target: Vector3
	local acceleration: number
	if mode == "Normal" and inWater then
		-- Swimming: slower, but you can still steer to a plank and jump out.
		target = moveInput * runSpeed() * water.SwimSpeedMultiplier * speedMultiplier() + grabPull(rootPart)
		acceleration = water.SwimAcceleration
	elseif mode == "Normal" and flow then
		-- Water slide: the water carries you along; the stick steers you across it.
		target = flowTarget(flow, current, flow.Magnitude, moveInput * runSpeed() * FLOW_STEER, dt)
		acceleration = FLOW_ACCELERATION
	elseif mode == "Slide" and flow then
		-- Belly sliding down a water slide: a little faster than the water, until you leave it or
		-- jump up.
		local least = flow.Magnitude * FLOW_SLIDE_SPEEDUP
		target = flowTarget(flow, current, least, moveInput * runSpeed() * FLOW_STEER, dt)
		acceleration = FLOW_ACCELERATION
	elseif (mode == "Normal" or mode == "Slide") and not grounded and now - lastFlowTime < FLOW_CARRY_TIME then
		-- Flying off a water slide (a jump, a ramp): keep its speed; the stick only bends your path.
		local speed = current.Magnitude
		target = current
		if speed > 1 then
			local steer = moveInput * runSpeed() * FLOW_STEER
			local sideways = steer - current * (steer:Dot(current) / (speed * speed))
			target = (current + sideways).Unit * speed
		end
		acceleration = movement.AirAcceleration
	elseif mode == "Normal" then
		target = moveInput * runSpeed() * speedMultiplier() + grabPull(rootPart)
		if not grounded and target.Magnitude > 0.01 and current.Magnitude > target.Magnitude then
			if current:Dot(target) > 0 then
				-- Faster than running (dive, slide-jump, bounce): keep that speed in the air and let it
				-- fade slowly, while still steering freely.
				local keptSpeed = math.max(target.Magnitude, current.Magnitude - movement.AirMomentumDrag * dt)
				target = target.Unit * keptSpeed
			end
		end
		acceleration = pickAcceleration(current, target)
		local grip = if grounded then floorGrip() else 1
		if grip < 1 then
			-- Slippery: slow to speed up, turn and stop, and you slide down slopes.
			target += MathUtil.flat(groundNormal) * movement.SlipperySlopeSlide * (1 - grip)
			acceleration *= grip
		end
	elseif mode == "Dive" then
		-- The sideways part of the stick bends the dive; pulling back slows it down.
		local along = moveInput:Dot(diveDirection)
		local sideways = moveInput - diveDirection * along
		local brake = math.clamp(-along, 0, 1)
		local diveSpeed = dive.Speed * (1 - brake * (1 - dive.AirBrakeFraction))
		target = (diveDirection * dive.Speed + sideways * dive.AirSteerSpeed).Unit * diveSpeed
		acceleration = dive.AirSteerAcceleration
	elseif mode == "Slide" then
		local pullingBack = current.Magnitude > 1
			and moveInput.Magnitude > 0.3
			and moveInput.Unit:Dot(current.Unit) < -0.3
		if pullingBack then
			-- Stick against the slide: stop almost on the spot (great for landing on platforms).
			target = Vector3.zero
			acceleration = dive.SlideBrake
		else
			-- Short belly slide: friction pulls you towards whatever speed the stick asks for.
			target = moveInput * movement.RunSpeed * dive.SlideControl
			acceleration = dive.SlideFriction * (if boosted("Slide") then Config.Items.SlideFrictionMultiplier else 1)
		end
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

local function tryKick()
	local hum, rootPart = humanoid, root
	if not hum or not rootPart or rootPart.Anchored then
		return
	end
	local now = os.clock()
	if mode ~= "Normal" or now - lastKickTime < Config.Kick.Cooldown then
		return
	end
	lastKickTime = now
	kickPoseUntil = now + Config.Kick.PoseTime
	if grabHeld then
		grabHeld = false
		Remotes.Event("RequestRelease"):FireServer()
	end
	-- The server works out who (if anyone) gets hit.
	Remotes.Event("RequestKick"):FireServer()
	ClientEvents.Kicked:Fire()
	ClientEvents.KickCooldownStarted:Fire(Config.Kick.Cooldown)
end

-- Holding a slapper: in a round where we picked SLAPS and still have some.
local function holdingSlapper(): boolean
	return MatchClient.IsCompeting()
		and MatchClient.GetPhase() == "Playing"
		and ProfileClient.IsItemActive("Slap")
		and ProfileClient.GetItemCount("Slap") > 0
end

-- Slap: only while holding a slapper. The server picks who gets hit.
local function trySlap()
	local hum, rootPart = humanoid, root
	if not hum or not rootPart or rootPart.Anchored or not holdingSlapper() then
		return
	end
	local now = os.clock()
	if mode ~= "Normal" or now - lastSlapTime < Config.Slap.Cooldown then
		return
	end
	lastSlapTime = now
	slapPoseUntil = now + Config.Slap.PoseTime
	if grabHeld then
		grabHeld = false
		Remotes.Event("RequestRelease"):FireServer()
	end
	Remotes.Event("RequestSlap"):FireServer()
	ClientEvents.Slapped:Fire()
	ClientEvents.SlapCooldownStarted:Fire(Config.Slap.Cooldown)
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

-- An obstacle hit us (HazardController). A SHIELD takes it instead: we only get a small bump,
-- and the server counts the hit (one knock counts once, so a spinner rubbing past doesn't use the
-- whole shield up). Without one we're knocked over.
function MovementController.HazardHit(impulse: Vector3, strength: number)
	local current = character
	local hits = if current then current:GetAttribute("Shield") else nil
	if typeof(hits) ~= "number" or hits <= 0 then
		MovementController.Knockdown(impulse, strength, true)
		return
	end
	local now = os.clock()
	if now - lastShieldHit >= SHIELD_REPORT_GAP then
		lastShieldHit = now
		Remotes.Event("ReportShieldHit"):FireServer()
	end
	local rootPart = root
	if rootPart and mode ~= "Ragdoll" then
		rootPart.AssemblyLinearVelocity += MathUtil.flat(impulse) * SHIELD_BUMP
	end
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
	local connection = teleportConnection
	if connection then
		connection:Disconnect()
		teleportConnection = nil
	end
	teleportPending = false
	character = nil
	humanoid = nil
	root = nil
	fallForce = nil
	grabHeld = false
	grounded = false
	groundPart = nil
	groundNormal = Vector3.yAxis
	risingFromJump = false
	inWater = false
	kickPoseUntil = 0
	slapPoseUntil = 0
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
	hum.JumpPower = jumpVelocity()
	jumpPowerRaised = false

	local force = rootPart:FindFirstChild("FallForce")
	character = newCharacter
	humanoid = hum
	root = rootPart
	fallForce = if force and force:IsA("VectorForce") then force else nil
	groundParams.FilterDescendantsInstances = { newCharacter }
	lastGroundedTime = -math.huge
	lastJumpPressTime = -math.huge
	-- Handled on the next physics step, once the new position has arrived with it.
	teleportConnection = newCharacter:GetAttributeChangedSignal("TeleportedAt"):Connect(function()
		teleportPending = true
	end)
end

function MovementController.Init()
	Input.JumpPressed:Connect(function()
		lastJumpPressTime = os.clock()
	end)
	Input.DivePressed:Connect(tryDive)
	Input.GrabChanged:Connect(onGrabChanged)
	Input.KickPressed:Connect(tryKick)
	Input.SlapPressed:Connect(trySlap)
	-- Left click slaps while you're holding a slapper, and kicks the rest of the time.
	Input.ClickPressed:Connect(function()
		if holdingSlapper() then
			trySlap()
		else
			tryKick()
		end
	end)

	Remotes.Event("ActionRejected").OnClientEvent:Connect(function(action: unknown)
		local now = os.clock()
		if action == "Dive" and (mode == "Dive" or mode == "Slide") then
			setMode("Normal", now)
		elseif action == "Grab" then
			grabHeld = false
		elseif action == "Kick" then
			kickPoseUntil = 0
		elseif action == "Slap" then
			slapPoseUntil = 0
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
