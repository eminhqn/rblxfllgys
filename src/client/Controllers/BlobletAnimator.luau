--!strict
-- Animates every Bloblet this client can see: squash-and-stretch on a wobbly spring, leaning,
-- waddling feet, swinging arms, blinking eyes that look where you're going, dive, grab and kick
-- poses, leaning back on a rope, dizzy eyes while ragdolled, a happy bouncing cheer once a player
-- has qualified or won, emotes (wave, spin, wiggle, belly flop, backflip, cartwheel), and swelling
-- up to giant size (Paint Grab's GIANT power-up; only the looks grow, not the physics). Hats, outfits and patterns
-- (BlobletCosmetics) ride along with the squash and stretch, and eye styles reshape the eyes.
--
-- It also animates preview Bloblets that aren't in the world (the customise screen's pedestal):
-- see AddPreview.
--
-- Everything here is visual only: Motor6D.Transform and SpecialMesh.Scale are local to this
-- client, never replicate and never touch physics. Each client animates other players from
-- their replicated velocity and the server's state attributes, so the server sends no
-- per-frame animation data.
--
-- With 30 players most Bloblets are somewhere you aren't looking, so only the ones on screen and
-- close by are animated every frame: far-away ones every few frames, off-screen ones a few times
-- a second, and very distant ones not at all. Updates are spread across frames.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local BlobletCosmetics = require(Shared.BlobletCosmetics)
local BlobletRig = require(Shared.BlobletRig)
local Config = require(Shared.Config)
local Cosmetics = require(Shared.Cosmetics)
local Match = require(Shared.Match)
local MathUtil = require(Shared.MathUtil)
local Tags = require(Shared.Tags)

local EmoteController = require(script.Parent.EmoteController)
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
local OFF_SCREEN_EVERY = 6 -- frames between updates while off screen
local ALWAYS_ON_SCREEN_DISTANCE = 12 -- this close to the camera always counts as on screen
local SCREEN_MARGIN = 0.15 -- of the screen width, so Bloblets at the edges count as on screen
local MAX_ANIMATION_DISTANCE = 260

local ROOT_HEIGHT = BlobletRig.Dimensions.RootHeight
local NAME_TAG_HEIGHT = 3.2 -- above the root, at normal size
local GIANT_SCALE = Config.PaintPowers.GiantScale

type CosmeticPiece = {
	Part: BasePart,
	Motor: Motor6D,
	C0: CFrame,
	Rest: Vector3, -- where it sits in VisualRoot space
	BaseSize: Vector3,
	Spin: number, -- radians/second round its own up axis
}

type Rig = {
	Model: Model,
	Preview: boolean, -- a ViewportFrame Bloblet: always standing, always animated, parts placed by us
	Player: Player?,
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
	SizeMeshes: { SpecialMesh }, -- arms, feet and eye shines: only rescaled when the size changes
	NameTag: BillboardGui?,
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
	Slap: number,
	Cheer: number,
	Carry: number, -- 0..1: holding something up over its head (an egg in Egg Scramble)
	Tug: number, -- 0..1: holding a rope and leaning back on it (Tug of Wobble)
	Emote: number, -- 0..1 blend of the emote pose
	EmoteStyle: string, -- the emote being shown (kept while it fades out)
	EmoteTime: number, -- seconds into it
	Cosmetics: { [BasePart]: CosmeticPiece },
	CosmeticsDirty: boolean,
	Connections: { RBXScriptConnection },
	Grow: number, -- 1 = normal size
	AppliedGrow: number,
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
	local sizeMeshes: { SpecialMesh } = {}
	for _, partName in { names.ArmL, names.ArmR, names.FootL, names.FootR, "ShineL", "ShineR" } do
		local mesh = findMesh(model, partName)
		if mesh then
			table.insert(sizeMeshes, mesh)
		end
	end
	local nameTag = root:FindFirstChild("NameTag")
	if
		not (visualRoot and body and eyeL and eyeR and pupilL and pupilR and armL and armR and footL and footR)
		or not (bodyMesh and eyeMeshL and eyeMeshR and pupilMeshL and pupilMeshR and shineL and shineR)
	then
		return nil
	end

	local now = os.clock()
	return {
		Model = model,
		Preview = false,
		Player = Players:GetPlayerFromCharacter(model),
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
		SizeMeshes = sizeMeshes,
		NameTag = if nameTag and nameTag:IsA("BillboardGui") then nameTag else nil,
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
		Slap = 0,
		Cheer = 0,
		Carry = 0,
		Tug = 0,
		Emote = 0,
		EmoteStyle = "",
		EmoteTime = 0,
		Cosmetics = {},
		CosmeticsDirty = true,
		Connections = {},
		Grow = 1,
		AppliedGrow = 1,
		PrevVelocity = Vector3.zero,
		WasGrounded = true,
		NextBlink = now + random:NextNumber(1, 4),
		BlinkUntil = 0,
		Look = Vector2.zero,
		LookTarget = Vector2.zero,
		NextGlance = now + random:NextNumber(1, 3),
		FrameCounter = random:NextInteger(0, OFF_SCREEN_EVERY - 1), -- spreads updates across frames
		PendingDt = 0,
		Seed = random:NextNumber(0, 100),
	}
end

local function attributeNumber(model: Model, name: string): number
	local value = model:GetAttribute(name)
	return if typeof(value) == "number" then value else 0
end

-- Picks up hats, outfits and pattern pieces (added or swapped by the server at any time).
local function refreshCosmetics(rig: Rig)
	rig.CosmeticsDirty = false
	local seen: { [BasePart]: boolean } = {}
	for _, child in rig.Model:GetChildren() do
		if not child:IsA("BasePart") or child:GetAttribute("Cosmetic") ~= true then
			continue
		end
		local motor = child:FindFirstChild("CosmeticJoint")
		if not motor or not motor:IsA("Motor6D") then
			continue
		end
		seen[child] = true
		if not rig.Cosmetics[child] then
			local spin = child:GetAttribute("Spin")
			rig.Cosmetics[child] = {
				Part = child,
				Motor = motor,
				C0 = motor.C0,
				Rest = motor.C0.Position,
				BaseSize = child.Size,
				Spin = if typeof(spin) == "number" then spin else 0,
			}
			rig.AppliedGrow = -1 -- size the new piece on the next frame
		end
	end
	for part in rig.Cosmetics do
		if not seen[part] then
			rig.Cosmetics[part] = nil
		end
	end
end

local function watchCosmetics(rig: Rig)
	local function markDirty(child: Instance)
		if child:IsA("BasePart") then
			rig.CosmeticsDirty = true
		end
	end
	table.insert(rig.Connections, rig.Model.ChildAdded:Connect(markDirty))
	table.insert(rig.Connections, rig.Model.ChildRemoved:Connect(markDirty))
end

-- The emote this Bloblet is doing (if any) and how far into it.
local function currentEmote(model: Model, isLocal: boolean, serverNow: number): (string?, number)
	if isLocal then
		local id, elapsed = EmoteController.GetLocal()
		if id then
			return id, elapsed
		end
	end
	local id = model:GetAttribute("Emote")
	local startedAt = model:GetAttribute("EmoteAt")
	if typeof(id) ~= "string" or typeof(startedAt) ~= "number" then
		return nil, 0
	end
	return id, serverNow - startedAt
end

local function smoothstep(t: number): number
	local x = math.clamp(t, 0, 1)
	return x * x * (3 - 2 * x)
end

-- Qualified (or the match winner) and standing still: time to celebrate.
local function isCelebrating(rig: Rig): boolean
	local player = rig.Player
	if not player then
		player = Players:GetPlayerFromCharacter(rig.Model)
		rig.Player = player
	end
	-- A bot's status is on its Bloblet (Shared/Competitors).
	local status = if player
		then player:GetAttribute(Match.PlayerAttr.Status)
		else rig.Model:GetAttribute(Match.PlayerAttr.Status)
	return status == "Qualified" or status == "Winner"
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

local function animate(rig: Rig, dt: number, now: number, serverNow: number, isLocal: boolean)
	local model = rig.Model
	local root = rig.Root
	local velocity = root.AssemblyLinearVelocity

	-- State: the local player uses its predicted pose; everyone else uses server attributes.
	local grounded: boolean
	local diving: boolean
	local grabbing: boolean
	local kicking: boolean
	local slapping: boolean
	local ragdolled: boolean
	if isLocal then
		local pose = MovementController.GetPose()
		grounded = pose.Grounded
		diving = pose.Diving
		grabbing = pose.Grabbing or attributeNumber(model, "Grabbing") ~= 0
		kicking = pose.Kicking
		slapping = pose.Slapping
		ragdolled = pose.Ragdolled
	else
		local action = model:GetAttribute("Action")
		diving = action == "Dive"
		grabbing = action == "Grab"
		kicking = action == "Kick"
		slapping = action == "Slap"
		ragdolled = model:GetAttribute("Ragdolled") == true
		if rig.Preview or (rig.WasGrounded and math.abs(velocity.Y) < 1.5) then
			grounded = true -- standing or walking on level ground: no need to look again
		else
			grounded = velocity.Y < 8
				and Workspace:Raycast(
						root.Position,
						Vector3.new(0, -(BlobletRig.Dimensions.RootHeight + 0.45), 0),
						groundParams
					)
					~= nil
		end
	end
	local grabbed = attributeNumber(model, "GrabbedBy") ~= 0
	local holdingSomeone = attributeNumber(model, "Grabbing") ~= 0
	local onRope = typeof(model:GetAttribute("OnRope")) == "Vector3" and not ragdolled
	grabbing = grabbing or onRope

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
	rig.Slap = MathUtil.damp(rig.Slap, if slapping and not ragdolled then 1 else 0, 22, dt)
	local cheering = grounded
		and not diving
		and not ragdolled
		and not grabbed
		and not kicking
		and not slapping
		and horizontalSpeed < 6
		and isCelebrating(rig)
	rig.Cheer = MathUtil.damp(rig.Cheer, if cheering then 1 else 0, 8, dt)
	local carrying = model:GetAttribute("Carrying") == true and not ragdolled
	rig.Carry = MathUtil.damp(rig.Carry, if carrying then 1 else 0, 12, dt)
	rig.Tug = MathUtil.damp(rig.Tug, if onRope then 1 else 0, 10, dt)
	-- Each tug is a quick heave back: ours on every JUMP, everyone else's in a steady rhythm.
	local heave = 0
	if rig.Tug > 0.01 then
		heave = if isLocal
			then math.exp(-(now - MovementController.GetPose().PulledAt) * 9)
			else math.max(math.sin(now * 9 + rig.Seed), 0)
	end

	-- Emotes: play while standing fairly still, fade out if you run off.
	local emoteId, emoteElapsed = currentEmote(model, isLocal, serverNow)
	local emoteEntry = if emoteId then Cosmetics.Get(emoteId) else nil
	local emoteDuration = if emoteEntry and emoteEntry.Duration then emoteEntry.Duration else 0
	local emoting = emoteEntry ~= nil
		and emoteElapsed >= 0
		and emoteElapsed < emoteDuration
		and grounded
		and not diving
		and not ragdolled
		and not grabbed
		and horizontalSpeed < Config.Emote.MaxMoveSpeed
	if emoting and emoteId then
		rig.EmoteStyle = Cosmetics.Style(emoteId)
		rig.EmoteTime = emoteElapsed
	end
	rig.Emote = MathUtil.damp(rig.Emote, if emoting then 1 else 0, 12, dt)
	local emote = rig.Emote
	local emoteStyle = rig.EmoteStyle
	local et = rig.EmoteTime
	local spinYaw = 0
	local emoteRoll = 0
	local emoteBob = 0
	local flop = 0
	local flip = 0 -- backflip: radians tipped backwards round the body's middle
	local wheel = 0 -- cartwheel: radians rolled sideways round the body's middle
	if emote > 0.01 then
		if emoteStyle == "Spin" and emoting then
			spinYaw = smoothstep(et / math.max(emoteDuration, 0.1)) * math.pi * 4
		elseif emoteStyle == "Wiggle" then
			emoteRoll = math.sin(et * 10) * 0.25 * emote
			emoteBob = math.abs(math.sin(et * 8)) * 0.4 * emote
		elseif emoteStyle == "Wave" then
			emoteRoll = math.sin(et * 6) * 0.06 * emote
		elseif emoteStyle == "Flop" then
			local rise = math.clamp(et / 0.25, 0, 1)
			local fall = math.clamp((math.max(emoteDuration, 0.5) - et) / 0.3, 0, 1)
			flop = rise * fall * emote
		elseif emoteStyle == "Backflip" and emoting then
			-- A hop with a full turn backwards, landing back on its feet.
			local progress = math.clamp(et / math.max(emoteDuration, 0.1), 0, 1)
			flip = smoothstep(progress) * math.pi * 2
			emoteBob = math.sin(progress * math.pi) * 2.6 * emote
		elseif emoteStyle == "Cartwheel" and emoting then
			-- A full roll over sideways, arms out, with a little hop.
			local progress = math.clamp(et / math.max(emoteDuration, 0.1), 0, 1)
			wheel = smoothstep(progress) * math.pi * 2
			emoteBob = math.sin(progress * math.pi) * 1.6 * emote
		end
	end
	local diveAmount = math.max(rig.Dive, flop)
	local giant = attributeNumber(model, "GiantUntil") > serverNow
	rig.Grow = MathUtil.damp(rig.Grow, if giant then GIANT_SCALE else 1, 5, dt)
	local grow = rig.Grow
	local resized = math.abs(grow - rig.AppliedGrow) > 1e-3
	if resized then
		rig.AppliedGrow = grow
		local scale = Vector3.one * grow
		for _, mesh in rig.SizeMeshes do
			mesh.Scale = scale
		end
		local nameTag = rig.NameTag
		if nameTag then
			nameTag.StudsOffset = Vector3.new(0, NAME_TAG_HEIGHT + (grow - 1) * 3.4, 0)
		end
	end

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
	-- Squash and stretch about the bottom of the body, then grow about the ground (VisualRoot's
	-- origin is the point on the ground under the Bloblet).
	local function squashed(point: Vector3): Vector3
		return Vector3.new(point.X * sxz, BODY_BOTTOM + (point.Y - BODY_BOTTOM) * sy, point.Z * sxz) * grow
	end

	-- Whole upper body: bob, lean (about the feet) and belly-flop (about the body centre).
	local bob = (
		math.abs(math.sin(rig.Phase)) * 0.14 * rig.Stride
		+ math.abs(math.sin(now * 7 + rig.Seed)) * 0.55 * rig.Cheer -- happy hops
		+ emoteBob
	) * grow
	local bodyCenterY = BODY_CENTER_Y * grow
	local diveTilt = CFrame.new(0, bodyCenterY, 0)
		* CFrame.Angles(-1.35 * diveAmount + flip, 0, wheel)
		* CFrame.new(0, -bodyCenterY, 0)
	-- A kick leans the body back (so does pulling on a rope); a slap twists it round behind the
	-- swinging arm.
	rig.VisualRoot.Transform = CFrame.new(0, bob, 0)
		* CFrame.Angles(0, spinYaw - rig.Slap * 0.45, 0)
		* CFrame.Angles(rig.Pitch + rig.Kick * 0.22 + rig.Tug * (0.3 + heave * 0.22), 0, rig.Roll + emoteRoll)
		* diveTilt

	rig.BodyMesh.Scale = Vector3.new(sxz, sy, sxz) * grow
	rig.Body.Transform = CFrame.new(squashed(REST.Body) - REST.Body)

	-- Eyes: blink, widen when surprised, look where we're heading (or spin when dizzy).
	if now >= rig.NextBlink then
		rig.BlinkUntil = now + 0.11
		rig.NextBlink = now + random:NextNumber(1.8, 4.5)
	end
	local blink = if now < rig.BlinkUntil and not ragdolled then 0.1 else 1
	blink *= 1 - 0.5 * rig.Cheer -- squinty happy eyes
	local surprised = grabbed or ragdolled or (not grounded and velocity.Y < -60)
	local eyeSize = if surprised then 1.15 else 1
	local eyeStyle = model:GetAttribute("EyeStyle")
	local eyeShape, pupilShape = BlobletCosmetics.EyeScales(if typeof(eyeStyle) == "string" then eyeStyle else "")
	local eyeScale = Vector3.new(eyeSize, eyeSize * blink, 1) * eyeShape * grow
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
	local pupilScale = Vector3.new(pupilSize, pupilSize * blink, 1) * pupilShape * grow
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
		local pitch = swing * side + rig.Grab * 1.5 + diveAmount * 2.5 + holdShake - rig.Kick * 0.6
		local roll = side * (0.22 + flap * 0.9)
		if side > 0 then
			-- The right arm does the slapping: up to shoulder height and swept across the front.
			pitch += rig.Slap * 1.6
			roll -= rig.Slap * 1.2
		end
		if ragdolled or grabbed then
			pitch += math.sin(now * 13 + side) * 0.9
			roll += side * math.cos(now * 11 + side) * 0.5
		end
		-- Cheer: both arms up, waving.
		local wave = 2.8 + math.sin(now * 10 + side * 1.3) * 0.35
		pitch += (wave - pitch) * rig.Cheer
		roll += side * 0.35 * rig.Cheer
		-- Carrying: both arms straight up holding it over the head.
		pitch += (3.0 - pitch) * rig.Carry
		roll += (side * 0.2 - roll) * rig.Carry
		-- Emote arms.
		if emote > 0.01 then
			local emotePitch, emoteArmRoll = pitch, roll
			if emoteStyle == "Wave" and side > 0 then
				emotePitch = 2.7 + math.sin(et * 14) * 0.15
				emoteArmRoll = 0.3 + math.sin(et * 12) * 0.45
			elseif emoteStyle == "Spin" then
				emoteArmRoll = side * 1.2
			elseif emoteStyle == "Wiggle" then
				emotePitch = 1.8 + math.sin(et * 10 + side * math.pi / 2) * 0.9
				emoteArmRoll = side * 0.3
			elseif emoteStyle == "Backflip" then
				emotePitch = 2.9 -- arms up and over
				emoteArmRoll = side * 0.4
			elseif emoteStyle == "Cartwheel" then
				emotePitch = 1.6 -- arms out wide like a star
				emoteArmRoll = side * 1.3
			end
			pitch += (emotePitch - pitch) * emote
			roll += (emoteArmRoll - roll) * emote
		end
		-- The arm hangs below its shoulder; a grown arm hangs further.
		motor.Transform = CFrame.new(squashed(rest) - rest)
			* CFrame.Angles(pitch, 0, roll)
			* CFrame.new(0, -(grow - 1) * BlobletRig.ArmHang, 0)
	end
	arm(rig.ArmL, REST.ArmL, -1)
	arm(rig.ArmR, REST.ArmR, 1)

	-- Feet: floppy waddle, dangle in the air, trail behind during a dive, splay when squashed.
	local function foot(motor: Motor6D, rest: Vector3, side: number, phaseOffset: number)
		local phase = rig.Phase + phaseOffset
		local forward = -math.sin(phase) * 0.5 * rig.Stride + diveAmount * 0.9
		local lift = math.max(0, math.cos(phase)) * 0.38 * rig.Stride + diveAmount * 0.7
		local flopAngle = math.sin(phase) * 0.45 * rig.Stride + diveAmount * 1.0
		-- Belly flop emote: feet flutter.
		lift += math.sin(et * 20 + phaseOffset) * 0.3 * flop
		forward += rig.Air * math.sin(now * 12 + phaseOffset) * 0.2
		flopAngle += rig.Air * 0.35
		local splay = math.max(0, -rig.Squash) * 0.6 * side
		if side > 0 then
			-- The right foot does the kicking: out in front, up, toes raised.
			forward -= rig.Kick * 1.7
			lift += rig.Kick * 1.1
			flopAngle += rig.Kick * 0.9
		end
		-- Feet hang off the root; growing moves them out from the point on the ground under it.
		local grown = (rest + Vector3.new(0, ROOT_HEIGHT, 0)) * (grow - 1)
		motor.Transform = CFrame.new(grown + Vector3.new(splay, lift, forward) * grow) * CFrame.Angles(flopAngle, 0, 0)
	end
	foot(rig.FootL, REST.FootL, -1, 0)
	foot(rig.FootR, REST.FootR, 1, math.pi)

	-- Cosmetics follow the squash and stretch (and growth); propellers spin.
	if rig.CosmeticsDirty then
		refreshCosmetics(rig)
	end
	for _, piece in rig.Cosmetics do
		local offset = piece.C0:VectorToObjectSpace(squashed(piece.Rest) - piece.Rest)
		local transform = CFrame.new(offset)
		if piece.Spin ~= 0 then
			transform *= CFrame.Angles(0, (now * piece.Spin) % (math.pi * 2), 0)
		end
		piece.Motor.Transform = transform
		if resized then
			piece.Part.Size = piece.BaseSize * grow
		end
	end

	rig.PrevVelocity = velocity
	rig.WasGrounded = grounded
end

-- ViewportFrames don't run joints, so a preview's parts are placed here from its joints, root
-- outwards (each part after the part it hangs from).
local function placePreviewParts(rig: Rig)
	local joints: { JointInstance } = {}
	for _, descendant in rig.Model:GetDescendants() do
		if descendant:IsA("JointInstance") then
			table.insert(joints, descendant)
		end
	end
	local placed: { [BasePart]: boolean } = { [rig.Root] = true }
	local progress = true
	while progress do
		progress = false
		for _, joint in joints do
			local part0, part1 = joint.Part0, joint.Part1
			if part0 and part1 and placed[part0] and not placed[part1] then
				local transform = if joint:IsA("Motor6D") then joint.Transform else CFrame.identity
				part1.CFrame = part0.CFrame * joint.C0 * transform * joint.C1:Inverse()
				placed[part1] = true
				progress = true
			end
		end
	end
end

-- Whether a point is on screen (or near enough to an edge that part of a Bloblet could be).
local function isOnScreen(camera: Camera, position: Vector3, distance: number, viewport: Vector2): boolean
	if distance < ALWAYS_ON_SCREEN_DISTANCE then
		return true
	end
	local point = camera:WorldToViewportPoint(position)
	if point.Z <= 0 then
		return false -- behind the camera
	end
	local margin = viewport.X * SCREEN_MARGIN
	return point.X > -margin and point.X < viewport.X + margin and point.Y > -margin and point.Y < viewport.Y + margin
end

local function onStep(dt: number)
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end
	local cameraPosition = camera.CFrame.Position
	local viewport = camera.ViewportSize
	local now = os.clock()
	local serverNow = Workspace:GetServerTimeNow()
	local localCharacter = localPlayer.Character

	for model, rig in rigs do
		if not rig.Root.Parent then
			continue
		end
		if rig.Preview then
			animate(rig, math.min(dt, 0.1), now, serverNow, false)
			placePreviewParts(rig)
			continue
		end
		if model == localCharacter then
			animate(rig, math.min(dt, 0.1), now, serverNow, true)
			continue
		end
		local distance = (rig.Root.Position - cameraPosition).Magnitude
		if distance > MAX_ANIMATION_DISTANCE then
			continue
		end
		-- Every frame when close and on screen; less often when far away or out of sight.
		local every = if not isOnScreen(camera, rig.Root.Position, distance, viewport)
			then OFF_SCREEN_EVERY
			elseif distance > FULL_DETAIL_DISTANCE then REDUCED_DETAIL_EVERY
			else 1
		rig.FrameCounter += 1
		rig.PendingDt += dt
		if rig.FrameCounter < every then
			continue
		end
		local stepDt = rig.PendingDt
		rig.FrameCounter = 0
		rig.PendingDt = 0
		animate(rig, math.min(stepDt, 0.1), now, serverNow, false)
	end
end

local pending: { [Model]: number } = {} -- models whose parts haven't all arrived yet

local function tryRegister(model: Model): boolean
	local rig = buildRig(model)
	if not rig then
		return false
	end
	rigs[model] = rig
	watchCosmetics(rig)
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
		local rig = rigs[instance]
		if rig then
			for _, connection in rig.Connections do
				connection:Disconnect()
			end
			rigs[instance] = nil
			refreshRayFilter()
		end
	end
end

-- Animates a Bloblet that isn't in the world, such as the customise screen's preview: it stands
-- still, blinks and breathes, and plays whatever emote its Emote / EmoteAt attributes say.
function BlobletAnimator.AddPreview(model: Model): boolean
	if rigs[model] then
		return true
	end
	local rig = buildRig(model)
	if not rig then
		return false
	end
	rig.Preview = true
	rigs[model] = rig
	watchCosmetics(rig)
	return true
end

function BlobletAnimator.RemovePreview(model: Model)
	local rig = rigs[model]
	if rig and rig.Preview then
		for _, connection in rig.Connections do
			connection:Disconnect()
		end
		rigs[model] = nil
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
