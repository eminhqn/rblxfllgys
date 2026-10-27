--!strict
-- Moves bots' Bloblets. A player's own client simulates their Bloblet (MovementController); a
-- bot's is simulated by the server, and this does for it a simpler version of the same: run at
-- the bot's speed, jump (and fall faster than it rises), bounce off trampolines, get carried by
-- water slides and conveyors, dive and belly-slide, get knocked over and get back up, get dragged
-- by whoever grabs it, slow down while reaching, carrying an egg or holding someone, and hold a
-- rope (standing still facing along it, towed with it).
--
-- BotBrain says what a bot wants (SetMove, Jump, Dive); this works out how its Bloblet does it.
-- ActionService knocks bots over through Knock (via Bots.Knock).

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local BlobletRig = require(Shared.BlobletRig)
local Competitors = require(Shared.Competitors)
local Config = require(Shared.Config)
local MathUtil = require(Shared.MathUtil)
local Tags = require(Shared.Tags)

local ActionService = require(script.Parent.Parent.Services.ActionService)
local Bots = require(script.Parent.Bots)

local BotMotor = {}

type Mode = "Normal" | "Dive" | "Slide" | "Ragdoll" | "Recover"

type Body = {
	Bot: Player,
	Model: Model,
	Root: BasePart,
	Humanoid: Humanoid,
	FallForce: VectorForce?,
	Params: RaycastParams,
	Speed: number, -- running speed (studs/s), from the bot's skill
	Move: Vector3, -- flat, length 0 to 1: the share of its running speed it wants, and where
	JumpAt: number, -- os.clock() of the last jump asked for (buffered briefly)
	Mode: Mode,
	ModeStart: number,
	RagdollUntil: number,
	DiveDirection: Vector3,
	Grounded: boolean,
	GroundPart: BasePart?,
	GroundNormal: Vector3,
	LastGrounded: number,
	JumpLockUntil: number,
	LastBounce: number,
	ServerOwned: boolean, -- network ownership has been taken for this unanchored stretch
	Settled: any, -- the TeleportedAt value last dealt with
}

local GROUND_PROBE_RADIUS = 0.9
local GROUND_PROBE_EXTRA = 0.35
local BOUNCE_COOLDOWN = 0.25
local BOUNCE_GROUND_LOCK = 0.2
local DEFAULT_BOUNCE_POWER = 80
local JUMP_BUFFER = 0.15
local FLOW_STEER = 0.5
local SLIDE_DECAY = 6 -- per second: a belly slide's speed fades
local ROPE_TURN_RATE = 12
local GRAB_PULL_GAP = 3.6 -- a grabbed bot is dragged until this close to whoever has it

local bodies: { [Model]: Body } = {}
local byBot: { [Player]: Body } = {}

local function numberAttribute(instance: Instance, name: string): number
	local value = instance:GetAttribute(name)
	return if typeof(value) == "number" then value else 0
end

local function setMode(body: Body, mode: Mode, now: number)
	body.Mode = mode
	body.ModeStart = now
end

local function setFallForce(body: Body, enabled: boolean)
	local force = body.FallForce
	if not force then
		return
	end
	if enabled then
		local extra = Config.Movement.FallGravityMultiplier - 1
		force.Force = Vector3.new(0, -body.Root.AssemblyMass * Workspace.Gravity * extra, 0)
	end
	force.Enabled = enabled
end

-- Puts a bot's Bloblet under BotMotor's control (BotRoster, whenever it builds one).
function BotMotor.Attach(bot: Player, model: Model)
	local root = model.PrimaryPart
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if not root or not humanoid then
		return
	end
	local force = root:FindFirstChild("FallForce")
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { model }
	params.IgnoreWater = true
	params.RespectCanCollide = true
	params.CollisionGroup = Bots.CollisionGroup
	local info = Bots.Info(bot)
	local skill = if info then info.Skill else 0.5
	local body: Body = {
		Bot = bot,
		Model = model,
		Root = root,
		Humanoid = humanoid,
		FallForce = if force and force:IsA("VectorForce") then force else nil,
		Params = params,
		Speed = Config.Movement.RunSpeed * (0.86 + 0.14 * skill),
		Move = Vector3.zero,
		JumpAt = -math.huge,
		Mode = "Normal",
		ModeStart = os.clock(),
		RagdollUntil = 0,
		DiveDirection = Vector3.zAxis,
		Grounded = false,
		GroundPart = nil,
		GroundNormal = Vector3.yAxis,
		LastGrounded = -math.huge,
		JumpLockUntil = 0,
		LastBounce = -math.huge,
		ServerOwned = false,
		Settled = model:GetAttribute("TeleportedAt"),
	}
	humanoid.AutoRotate = true
	humanoid.JumpPower = Config.Movement.JumpVelocity
	bodies[model] = body
	byBot[bot] = body
end

function BotMotor.Detach(model: Model)
	local body = bodies[model]
	if not body then
		return
	end
	bodies[model] = nil
	if byBot[body.Bot] == body then
		byBot[body.Bot] = nil
	end
end

-------------------------------------------------------------------------------------------------
-- What a bot wants (BotBrain)
-------------------------------------------------------------------------------------------------

-- Walk this way: a flat vector, length 0 (stand still) to 1 (full speed).
function BotMotor.SetMove(bot: Player, move: Vector3)
	local body = byBot[bot]
	if not body then
		return
	end
	local flat = MathUtil.flat(move)
	body.Move = if flat.Magnitude > 1 then flat.Unit else flat
end

-- Jump as soon as it can (a press is remembered for a moment, like a player's).
function BotMotor.Jump(bot: Player)
	local body = byBot[bot]
	if body then
		body.JumpAt = os.clock()
	end
end

-- Dives (if ActionService allows it) in `direction`. True if it went.
function BotMotor.Dive(bot: Player, direction: Vector3): boolean
	local body = byBot[bot]
	if not body or body.Mode ~= "Normal" or body.Root.Anchored then
		return false
	end
	local flat = MathUtil.flat(direction)
	if flat.Magnitude < 1e-3 then
		flat = MathUtil.flat(body.Root.CFrame.LookVector)
	end
	if flat.Magnitude < 1e-3 then
		return false
	end
	flat = flat.Unit
	if not ActionService.BotDive(bot, flat) then
		return false
	end
	local dive = Config.Dive
	local velocity = body.Root.AssemblyLinearVelocity
	local lift = if body.Grounded then dive.GroundLift else math.max(velocity.Y, 0) * 0.4 + dive.AirLift
	body.Root.AssemblyLinearVelocity = flat * dive.Speed + Vector3.new(0, lift, 0)
	body.DiveDirection = flat
	body.JumpLockUntil = os.clock() + dive.MinAirTime
	setMode(body, "Dive", os.clock())
	return true
end

function BotMotor.IsGrounded(bot: Player): boolean
	local body = byBot[bot]
	return body ~= nil and body.Grounded
end

-- What it's standing on, if anything.
function BotMotor.GroundPart(bot: Player): BasePart?
	local body = byBot[bot]
	return if body and body.Grounded then body.GroundPart else nil
end

-- Busy: knocked over, getting up or flying through a dive (it can't do much else just now). A
-- belly slide isn't busy: it can jump out of one.
function BotMotor.IsBusy(bot: Player): boolean
	local body = byBot[bot]
	return body ~= nil and (body.Mode == "Ragdoll" or body.Mode == "Recover" or body.Mode == "Dive")
end

-- How fast it runs, studs/s.
function BotMotor.RunSpeed(bot: Player): number
	local body = byBot[bot]
	return if body then body.Speed else Config.Movement.RunSpeed
end

-------------------------------------------------------------------------------------------------
-- Knockdowns
-------------------------------------------------------------------------------------------------

-- Knocked over (a kick, a slap, a hazard): tumbles for `duration` seconds, then gets up.
function BotMotor.Knock(bot: Player, impulse: Vector3, duration: number)
	local body = byBot[bot]
	if not body or body.Root.Anchored then
		return
	end
	local now = os.clock()
	setMode(body, "Ragdoll", now)
	body.RagdollUntil = now + duration
	setFallForce(body, false)
	body.Humanoid:Move(Vector3.zero, false)
	body.Humanoid:ChangeState(Enum.HumanoidStateType.Physics)
	local root = body.Root
	root.AssemblyLinearVelocity = root.AssemblyLinearVelocity * 0.3 + impulse
	local push = MathUtil.flat(impulse)
	local rollAxis = Vector3.new(push.Z, 0, -push.X)
	rollAxis = if rollAxis.Magnitude > 1e-3 then rollAxis.Unit else Vector3.xAxis
	root.AssemblyAngularVelocity = rollAxis * 12
end

local function getUp(body: Body, now: number)
	local root = body.Root
	local position = root.Position + Vector3.new(0, 0.6, 0)
	local look = MathUtil.flat(root.CFrame.LookVector)
	look = if look.Magnitude > 1e-3 then look.Unit else Vector3.new(0, 0, -1)
	root.AssemblyAngularVelocity = Vector3.zero
	root.CFrame = CFrame.lookAt(position, position + look)
	body.Humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
	root.AssemblyLinearVelocity = Vector3.new(0, Config.Ragdoll.GetUpHop, 0)
	body.JumpLockUntil = now + 0.1
	setMode(body, "Recover", now)
end

-------------------------------------------------------------------------------------------------
-- Every frame
-------------------------------------------------------------------------------------------------

-- The server just placed it somewhere new: forget its old momentum and stand it up.
local function settle(body: Body, now: number)
	body.Settled = body.Model:GetAttribute("TeleportedAt")
	if body.Mode == "Ragdoll" then
		body.Humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
	end
	setMode(body, "Normal", now)
	setFallForce(body, false)
	body.JumpAt = -math.huge
	local root = body.Root
	if not root.Anchored then
		root.AssemblyLinearVelocity = Vector3.zero
		root.AssemblyAngularVelocity = Vector3.zero
	end
end

local function probeGround(body: Body): RaycastResult?
	local distance = BlobletRig.Dimensions.RootHeight - GROUND_PROBE_RADIUS + GROUND_PROBE_EXTRA
	return Workspace:Spherecast(body.Root.Position, GROUND_PROBE_RADIUS, Vector3.new(0, -distance, 0), body.Params)
end

local function doJump(body: Body, now: number)
	if body.Mode == "Slide" then
		setMode(body, "Normal", now)
		ActionService.BotEndDive(body.Bot)
	end
	body.Humanoid.JumpPower = Config.Movement.JumpVelocity
	body.Humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
	local velocity = body.Root.AssemblyLinearVelocity
	body.Root.AssemblyLinearVelocity = Vector3.new(velocity.X, Config.Movement.JumpVelocity, velocity.Z)
	body.JumpLockUntil = now + Config.Movement.JumpGroundLock
	body.LastGrounded = -math.huge
	body.JumpAt = -math.huge
end

local function bounce(body: Body, pad: BasePart, now: number)
	local attribute = pad:GetAttribute("Power")
	local power = if typeof(attribute) == "number" then attribute else DEFAULT_BOUNCE_POWER
	local velocity = body.Root.AssemblyLinearVelocity
	body.Humanoid.JumpPower = power
	body.Humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
	body.Root.AssemblyLinearVelocity = Vector3.new(velocity.X, power, velocity.Z)
	body.LastBounce = now
	body.JumpLockUntil = now + BOUNCE_GROUND_LOCK
	body.LastGrounded = -math.huge
	if body.Mode == "Dive" or body.Mode == "Slide" then
		setMode(body, "Normal", now)
		ActionService.BotEndDive(body.Bot)
	end
end

-- Slower while reaching, carrying an egg, holding someone or being held.
local function speedMultiplier(body: Body): number
	local model = body.Model
	local grab = Config.Grab
	local multiplier = 1
	if numberAttribute(model, "GrabbedBy") ~= 0 then
		multiplier = math.min(multiplier, grab.VictimSpeedMultiplier)
	end
	if model:GetAttribute("Carrying") == true then
		multiplier = math.min(multiplier, grab.CarrySpeedMultiplier)
	end
	if numberAttribute(model, "Grabbing") ~= 0 then
		multiplier = math.min(multiplier, grab.GrabberSpeedMultiplier)
	elseif ActionService.IsReaching(body.Bot) then
		multiplier = math.min(multiplier, grab.ReachSpeedMultiplier)
	end
	return multiplier
end

-- Grabbed: dragged towards whoever has hold of it.
local function grabPull(body: Body): Vector3
	local grabberId = numberAttribute(body.Model, "GrabbedBy")
	if grabberId == 0 then
		return Vector3.zero
	end
	local grabber = Competitors.CharacterOf(grabberId)
	local grabberRoot = if grabber then grabber.PrimaryPart else nil
	if not grabberRoot then
		return Vector3.zero
	end
	local offset = MathUtil.flat(grabberRoot.Position - body.Root.Position)
	if offset.Magnitude < GRAB_PULL_GAP then
		return Vector3.zero
	end
	return offset.Unit * Config.Grab.VictimPullSpeed
end

local function flowUnder(body: Body): Vector3?
	local floor = body.GroundPart
	if not body.Grounded or not floor then
		return nil
	end
	local flow = floor:GetAttribute("Flow")
	if typeof(flow) ~= "Vector3" or flow.Magnitude < 0.1 then
		return nil
	end
	return MathUtil.flat(flow)
end

local function faceAlong(body: Body, facing: Vector3, dt: number)
	local root = body.Root
	local look = MathUtil.flat(root.CFrame.LookVector)
	look = if look.Magnitude > 1e-3 then look.Unit else facing
	if look:Dot(facing) > 0.999 then
		return
	end
	local turned = look:Lerp(facing, math.min(dt * ROPE_TURN_RATE, 1))
	turned = if turned.Magnitude > 1e-3 then turned.Unit else facing
	local position = root.Position
	root.CFrame = CFrame.lookAt(position, position + turned)
end

local function stepBody(body: Body, dt: number, now: number)
	local root, humanoid = body.Root, body.Humanoid
	if body.Model:GetAttribute("TeleportedAt") ~= body.Settled then
		settle(body, now)
	end
	if root.Anchored then
		-- Frozen (waiting for GO, or a respawn offer): ownership is taken again once it's free.
		body.ServerOwned = false
		return
	end
	if not body.ServerOwned then
		-- The server simulates bots; nobody's client should.
		body.ServerOwned = pcall(function()
			root:SetNetworkOwner(nil)
		end)
	end

	local velocity = root.AssemblyLinearVelocity
	local hit = if body.Mode == "Ragdoll" then nil else probeGround(body)
	body.Grounded = hit ~= nil and now >= body.JumpLockUntil and velocity.Y < 12
	local hitInstance = if hit then hit.Instance else nil
	body.GroundPart = if body.Grounded and hitInstance and hitInstance:IsA("BasePart") then hitInstance else nil
	body.GroundNormal = if body.Grounded and hit then hit.Normal else Vector3.yAxis
	if body.Grounded then
		body.LastGrounded = now
	end

	if body.Mode == "Ragdoll" then
		setFallForce(body, false)
		if now >= body.RagdollUntil then
			getUp(body, now)
		end
		return
	end

	local pad = body.GroundPart
	if pad and now - body.LastBounce > BOUNCE_COOLDOWN and CollectionService:HasTag(pad, Tags.BouncePad) then
		bounce(body, pad, now)
		return
	end
	setFallForce(body, not body.Grounded and velocity.Y < 0)

	-- Dive -> belly slide -> back on its feet.
	local dive = Config.Dive
	if body.Mode == "Dive" then
		local airTime = now - body.ModeStart
		if (body.Grounded and airTime > dive.MinAirTime) or airTime > dive.MaxAirTime then
			setMode(body, "Slide", now)
		end
	elseif body.Mode == "Slide" then
		if now - body.ModeStart >= dive.SlideTime and not flowUnder(body) then
			setMode(body, "Normal", now)
			ActionService.BotEndDive(body.Bot)
		end
	elseif body.Mode == "Recover" then
		if now - body.ModeStart >= Config.Ragdoll.GetUpRecoverTime then
			setMode(body, "Normal", now)
		end
	end

	local movement = Config.Movement
	if
		now - body.JumpAt <= JUMP_BUFFER
		and (body.Mode == "Normal" or body.Mode == "Slide")
		and now - body.LastGrounded <= movement.CoyoteTime
	then
		doJump(body, now)
	end

	-- Where it's heading this frame.
	local rope = body.Model:GetAttribute("OnRope")
	local target: Vector3
	if typeof(rope) == "Vector3" and body.Mode == "Normal" then
		-- Holding a rope: no walking; it goes wherever the rope goes, facing along it.
		local tow = body.Model:GetAttribute("Tow")
		target = if typeof(tow) == "Vector3" then MathUtil.flat(tow) else Vector3.zero
		local facing = MathUtil.flat(rope)
		if facing.Magnitude > 0.1 then
			faceAlong(body, facing.Unit, dt)
		end
	elseif body.Mode == "Dive" then
		target = body.DiveDirection * dive.Speed
	elseif body.Mode == "Slide" then
		local flow = flowUnder(body)
		if flow then
			target = flow * 1.15
		else
			target = MathUtil.flat(velocity) * math.exp(-SLIDE_DECAY * dt)
		end
	elseif body.Mode == "Recover" then
		target = Vector3.zero
	else
		local wanted = body.Move * body.Speed * speedMultiplier(body)
		local flow = flowUnder(body)
		if flow then
			-- A water slide carries it along; it only steers across.
			local along = flow.Unit
			local steer = body.Move * body.Speed * FLOW_STEER
			target = along * math.max(flow.Magnitude, flow.Magnitude + steer:Dot(along))
				+ (steer - along * steer:Dot(along))
		else
			target = wanted + grabPull(body)
		end
	end

	humanoid.AutoRotate = typeof(rope) ~= "Vector3"
	local speed = target.Magnitude
	if speed > 0.05 then
		humanoid.WalkSpeed = speed
		humanoid:Move(target / speed, false)
	else
		humanoid.WalkSpeed = 0
		humanoid:Move(Vector3.zero, false)
	end
	if velocity.Y < -movement.MaxFallSpeed then
		root.AssemblyLinearVelocity = Vector3.new(velocity.X, -movement.MaxFallSpeed, velocity.Z)
	end
end

local function step(dt: number)
	if next(bodies) == nil then
		return
	end
	local now = os.clock()
	for model, body in bodies do
		if not model.Parent or not body.Root.Parent then
			BotMotor.Detach(model)
			continue
		end
		local ok, err = pcall(function(): any
			stepBody(body, dt, now)
			return nil
		end)
		if not ok then
			warn(`[BotMotor] {body.Bot.Name}: {err}`)
		end
	end
end

function BotMotor.Init()
	Bots.SetKnocker(BotMotor.Knock)
	RunService.Heartbeat:Connect(step)
end

return BotMotor
