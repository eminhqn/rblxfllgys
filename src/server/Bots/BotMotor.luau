--!strict
-- Moves bots' Bloblets. A player's own client simulates their Bloblet (MovementController); a
-- bot's is simulated by the server, and this does for it what MovementController does for a
-- player, with the same speeds and acceleration: run (speeding up, turning and slowing down like
-- a player), jump (and fall faster than it rises), bounce off trampolines, get carried by water
-- slides, dive and belly-slide, get knocked over and get back up, get dragged by whoever grabs
-- it, slow down while reaching, carrying an egg or holding someone, hold a rope (standing still
-- facing along it, towed with it), and float and swim in water (BotWorld.WaterSurfaceAt), jumping
-- out of it like a player can.
--
-- BotBrain says where a bot is going (Steer) a few times a second; this steers it there every
-- frame, easing off as it arrives so it doesn't overshoot and circle round the spot, and does the
-- quick reactions a player would: jump at a wall, jump up onto a ledge or platform early enough to
-- clear its edge, jump the gap at an edge (diving over a wide one, unless it's jumping up onto
-- something, at the moment that brings it down just onto the far side, then stopping its belly
-- slide before it carries it off a small platform), or stop at the edge if told to be careful.
--
-- On a water slide, where there's no stopping, it leans into side currents to stay on, belly-slides
-- (faster than the water), jumps the gaps and ramp lips, and times a jump over each hammer swinging
-- across (BotWorld.HammerJump).
--
-- Moving platforms (a Steer with Track, or anything it jumps to from a moving platform) get a jump
-- planned the way a good player times it: it waits at the edge until a jump right now would bring
-- it down on the spot (where the platform will be at that very moment, from the same maths that
-- moves it), jumps, and steers in the air to land right on it. ActionService knocks bots over
-- through Knock (via Bots.Knock).

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
local BotProfiler = require(script.Parent.BotProfiler)
local BotWorld = require(script.Parent.BotWorld)
local Bots = require(script.Parent.Bots)

local BotMotor = {}

type Mode = "Normal" | "Dive" | "Slide" | "Ragdoll" | "Recover"

-- Where something will be at a given server time (a spot on a moving platform).
export type Aim = (serverTime: number) -> Vector3

-- Where BotBrain wants a bot to go.
export type Steer = {
	Target: Vector3?, -- head for this point (nil: stand still)
	Track: Aim?, -- or this moving spot (Target is then where it is now)
	Then: Vector3?, -- once within Within of Target, carry on towards this without stopping
	Within: number?, -- close enough to Target (flat studs, default 2)
	Careful: boolean?, -- stop at an edge rather than jump it (unless Target is down below)
	NoDive: boolean?, -- never dive over a gap (small platforms: the belly slide would carry it off)
}

type Body = {
	Bot: Player,
	Model: Model,
	Root: BasePart,
	Humanoid: Humanoid,
	FallForce: VectorForce?,
	Params: RaycastParams,
	Skill: number,
	Speed: number, -- running speed (studs/s), from the bot's skill
	-- Where it's going (BotBrain), and a direction that overrides it for a moment (dodging,
	-- sidestepping; zero holds it still).
	Target: Vector3?,
	Track: Aim?,
	Then: Vector3?,
	Within: number,
	Careful: boolean,
	NoDive: boolean,
	Leap: Aim?, -- where the jump it's in the middle of is meant to land
	LeapAt: number,
	FarSide: Vector3?, -- across the gap it's at: the nearest floor to land on
	FarSideAt: number,
	FarSideFrom: Vector3, -- where it was when it looked
	FarSideReach: number, -- and how far ahead
	Edge: number, -- waiting at an edge: how far off it is (studs, the way it's going)
	EdgeAt: number,
	EdgeFrom: Vector3,
	EdgeWay: Vector3,
	LeapReadyAt: number, -- a jump will work from now (it reacts a moment later)
	Override: Vector3,
	OverrideUntil: number,
	Blocked: boolean, -- stopped at an edge it was told not to jump
	AtGap: boolean,
	Fluff: boolean, -- going to miss the jump at this gap
	DiveAt: number?, -- dive now (mid-jump over a wide gap)
	JumpAt: number, -- os.clock() of the last jump asked for (buffered briefly)
	Mode: Mode,
	ModeStart: number,
	RagdollUntil: number,
	DiveDirection: Vector3,
	Grounded: boolean,
	InWater: boolean,
	OnFlow: boolean, -- touching a water slide (going up a ramp's too steep to count as standing)
	FlowAt: number, -- last time it was
	DiveReadyAt: number, -- its dive cooldown is over
	SlideTryAt: number, -- next look for the chance to belly-slide
	GroundPart: BasePart?,
	GroundNormal: Vector3,
	LastGrounded: number,
	JumpLockUntil: number,
	LastBounce: number,
	ServerOwned: boolean, -- network ownership has been taken for this unanchored stretch
	OwnerCheckAt: number,
	Settled: any, -- the TeleportedAt value last dealt with
}

local ROOT_HEIGHT = BlobletRig.Dimensions.RootHeight
local GROUND_PROBE_RADIUS = 0.9
local GROUND_PROBE_EXTRA = 0.35
local BOUNCE_COOLDOWN = 0.25
local BOUNCE_GROUND_LOCK = 0.2
local DEFAULT_BOUNCE_POWER = 80
local JUMP_BUFFER = Config.Movement.JumpBufferTime
-- Water slides, as for a player (MovementController).
local FLOW_STEER = 0.5 -- share of running speed the stick adds on a water slide
local FLOW_ACCELERATION = 70
local FLOW_CARRY_TIME = 1.5 -- seconds after leaving a water slide that it keeps its speed in the air
local FLOW_SLIDE_SPEEDUP = 1.15 -- a belly slide down a water slide goes this much faster than the water
local FLOW_MOMENTUM_DRAG = 4 -- studs/s^2: extra speed on a water slide (from a dive) fades this slowly
local FLOW_BRAKE_DRAG = 30 -- studs/s^2 when it holds back against the water
local FLOW_GRACE = 0.25 -- seconds off the water (a bump) that a belly slide carries on through
local FLOW_GAP_PROBE_MAX = 4.5 -- on a water slide it looks a little further ahead for the end
local SLIDE_DIVE_CLEAR = { 6, 12 } -- studs ahead that must be plain slide before it dives onto it
local SLIDE_DIVE_EVERY = 0.4 -- seconds between looks for the chance to start a belly slide
local ROPE_TURN_RATE = 12
local GRAB_PULL_GAP = 3.6 -- a grabbed bot is dragged until this close to whoever has it
local ARRIVE_EASE = 6 -- studs short of its spot that it starts easing off
local ARRIVE_MIN = 0.25 -- share of its speed it keeps right at the spot
local WALL_PROBE = 2.4 -- studs past its edge it looks for a wall
local KNEE = 1.2 -- height above its feet of the wall check
local CLIMB = 2.5 -- a spot this much higher than its feet...
local CLIMB_REACH = 2.5 -- ...this close (flat) means jump up to it
local LEDGE_RISE = 1.5 -- a target this much higher than its feet: look out for the edge to jump up
local LEDGE_CLEARANCE = 0.4 -- how far over the edge its feet should be as it gets there
local GAP_LEAD = 0.07 -- seconds before the edge that it jumps
local GAP_PROBE_MIN, GAP_PROBE_MAX = 1.8, 3.6 -- studs ahead it looks for the floor
local GAP_DROP = 4 -- the floor this far below its feet (or none) counts as a gap
local GAP_SEARCH = 30 -- studs down it looks for the floor beyond an edge
-- A target this far below its feet, with floor ahead down at about its height: it means to drop
-- down there, so it doesn't jump.
local DOWN_BELOW = 3
local OWNER_CHECK_EVERY = 0.5
local LEAD_MAX = 1 -- seconds ahead it aims at a moving spot while running to it
-- Share of its air steering a planned jump is checked with: sharp bots keep more in hand, clumsy
-- ones chance harder jumps (and react later).
local LEAP_BUDGET_SHARP, LEAP_BUDGET_CLUMSY = 0.75, 0.95
local LEAP_REACTION = 0.25 -- seconds the clumsiest bot takes to go once a jump will work
local LEAP_CHECK_STEP = 0.025 -- seconds per step when it flies a jump in its head
local LAND_TOLERANCE = 3 -- coming down this close to the spot is landing on it
local FAR_SIDE_SCAN = 14 -- studs ahead it looks for the floor beyond a gap
local FAR_SIDE_SCAN_DIVE = 24 -- or this far, when it may dive (a jump + dive carries it 21 to 23)
local FAR_SIDE_IN = 2.5 -- and aims this far onto it
local FAR_SIDE_FAN = 4 -- directions either side of straight on that it looks along
local FAR_SIDE_FAN_STEP = math.rad(15)
local FAR_SIDE_EVERY = 0.2 -- seconds between looks (the floor it's riding moves on)
local FAR_SIDE_STILL_FAN = 2 -- across an ordinary gap it only looks near the way it's going
-- Across a gap too wide to jump, it dives partway through the jump, at the moment (from these)
-- that brings it down closest to its spot on the far side, and no more than DIVE_SHORT short of it.
local DIVE_EARLIEST, DIVE_LATEST, DIVE_STEP = 0.16, 0.48, 0.02
local DIVE_SHORT = 1
local FLIGHT_STEP = 1 / 60 -- seconds per step when it flies a jump + dive in its head
local SLIDE_BRAKE_ROOM = 2 -- studs of floor it keeps in front of it when it stops a belly slide
local EDGE_SCAN = 6 -- studs it looks ahead for the edge while waiting
local EDGE_BACK = 1 -- and stops this short of it
local EDGE_CREEP = 0.6 -- share of its speed it edges up at
local EDGE_EVERY = 0.15 -- seconds it trusts its measure of the edge while standing still

local random = Random.new()
local bodies: { [Model]: Body } = {}
local byBot: { [Player]: Body } = {}

-- Workspace:Raycast, counted for BotProfiler.
local function cast(origin: Vector3, direction: Vector3, params: RaycastParams): RaycastResult?
	BotProfiler.Count("raycasts")
	return Workspace:Raycast(origin, direction, params)
end

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
	local skill = Bots.SkillOf(bot)
	local body: Body = {
		Bot = bot,
		Model = model,
		Root = root,
		Humanoid = humanoid,
		FallForce = if force and force:IsA("VectorForce") then force else nil,
		Params = params,
		Skill = skill,
		Speed = Config.Movement.RunSpeed * (0.9 + 0.1 * skill),
		Target = nil,
		Track = nil,
		Then = nil,
		Within = 2,
		Careful = false,
		NoDive = false,
		Leap = nil,
		LeapAt = 0,
		FarSide = nil,
		FarSideAt = 0,
		FarSideFrom = Vector3.zero,
		FarSideReach = 0,
		Edge = 0,
		EdgeAt = 0,
		EdgeFrom = Vector3.zero,
		EdgeWay = Vector3.zero,
		LeapReadyAt = 0,
		Override = Vector3.zero,
		OverrideUntil = 0,
		Blocked = false,
		AtGap = false,
		Fluff = false,
		DiveAt = nil,
		JumpAt = -math.huge,
		Mode = "Normal",
		ModeStart = os.clock(),
		RagdollUntil = 0,
		DiveDirection = Vector3.zAxis,
		Grounded = false,
		InWater = false,
		OnFlow = false,
		FlowAt = -math.huge,
		DiveReadyAt = 0,
		SlideTryAt = 0,
		GroundPart = nil,
		GroundNormal = Vector3.yAxis,
		LastGrounded = -math.huge,
		JumpLockUntil = 0,
		LastBounce = -math.huge,
		ServerOwned = false,
		OwnerCheckAt = 0,
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

-- Where to go (see Steer). Steered towards every frame until the next call.
function BotMotor.Steer(bot: Player, steer: Steer)
	local body = byBot[bot]
	if not body then
		return
	end
	body.Target = steer.Target
	body.Track = steer.Track
	body.Then = steer.Then
	body.Within = steer.Within or 2
	body.Careful = steer.Careful == true
	body.NoDive = steer.NoDive == true
end

-- Go this way instead for `duration` seconds (a flat direction; zero stands still): dodging,
-- sidestepping, waiting for a hazard to pass.
function BotMotor.Override(bot: Player, direction: Vector3, duration: number)
	local body = byBot[bot]
	if not body then
		return
	end
	local flat = MathUtil.flat(direction)
	body.Override = if flat.Magnitude > 1e-3 then flat.Unit else Vector3.zero
	body.OverrideUntil = os.clock() + duration
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
	body.DiveReadyAt = os.clock() + dive.Cooldown
	setMode(body, "Dive", os.clock())
	return true
end

-- Riding a water slide (where it can't stop, and times hammers itself).
function BotMotor.IsOnWaterSlide(bot: Player): boolean
	local body = byBot[bot]
	return body ~= nil and body.OnFlow
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

-- Stopped at an edge it was told not to jump (a careful Steer).
function BotMotor.IsBlocked(bot: Player): boolean
	local body = byBot[bot]
	return body ~= nil and body.Blocked
end

-- What it's doing ("Normal", "Dive", "Slide", "Ragdoll", "Recover"), for the debug label.
function BotMotor.ModeOf(bot: Player): string
	local body = byBot[bot]
	return if body then body.Mode else "None"
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
	body.DiveAt = nil
	body.Leap = nil
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
	body.DiveAt = nil
	body.AtGap = false
	body.Leap = nil
	local root = body.Root
	if not root.Anchored then
		root.AssemblyLinearVelocity = Vector3.zero
		root.AssemblyAngularVelocity = Vector3.zero
	end
end

-- The server simulates bots; nobody's client should. Taken once it's unanchored, and checked now
-- and then in case anything handed it back to automatic ownership.
local function keepOwnership(body: Body, now: number)
	local root = body.Root
	if not body.ServerOwned then
		body.ServerOwned = pcall(function()
			root:SetNetworkOwner(nil)
		end)
		body.OwnerCheckAt = now + OWNER_CHECK_EVERY
		return
	end
	if now < body.OwnerCheckAt then
		return
	end
	body.OwnerCheckAt = now + OWNER_CHECK_EVERY
	pcall(function()
		if root:GetNetworkOwner() ~= nil or root:GetNetworkOwnershipAuto() then
			root:SetNetworkOwner(nil)
		end
	end)
end

local function probeGround(body: Body): RaycastResult?
	local distance = ROOT_HEIGHT - GROUND_PROBE_RADIUS + GROUND_PROBE_EXTRA
	BotProfiler.Count("spherecasts")
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

-- A water slide's flow (its Flow attribute, flattened), or nil for anything else.
local function flowOf(part: Instance?): Vector3?
	local flow = if part then part:GetAttribute("Flow") else nil
	if typeof(flow) ~= "Vector3" or flow.Magnitude < 0.1 then
		return nil
	end
	return MathUtil.flat(flow)
end

-- The water slide it's standing on (nil if it isn't).
local function flowUnder(body: Body): Vector3?
	return if body.Grounded then flowOf(body.GroundPart) else nil
end

-- Where a water slide takes it, as it does a player (MovementController): along its flow at
-- `least` speed (plus or minus the stick), keeping any extra speed it brings (a dive, a belly
-- slide), fading slowly. The sideways part of the stick steers across the slide.
local function flowTarget(flow: Vector3, current: Vector3, least: number, steer: Vector3, dt: number): Vector3
	local direction = flow.Unit
	local steerAlong = steer:Dot(direction)
	local drag = if steerAlong < 0 then FLOW_BRAKE_DRAG else FLOW_MOMENTUM_DRAG
	local speed = math.max(least + steerAlong, current:Dot(direction) - drag * dt)
	return direction * speed + (steer - direction * steerAlong)
end

-- The stick to hold on a water slide to actually go the way `move` points (`most` is a full
-- stick): lean across against the water as much as it takes (a side current shoves it off the
-- slide otherwise, and pointing the stick where it wants to go doesn't lean nearly enough), and
-- push on downhill with what's left, as a good player does. Going back up the slide (or nowhere):
-- just `move`.
local function flowSteer(
	flow: Vector3,
	move: Vector3,
	current: Vector3,
	least: number,
	most: number,
	dt: number
): Vector3
	if move.Magnitude < 0.05 then
		return Vector3.zero
	end
	local along = flow.Unit
	local across = Vector3.new(-along.Z, 0, along.X)
	local heading = move.Unit
	local forward = heading:Dot(along)
	if forward < 0.3 then
		return move * most
	end
	-- Sideways speed it needs for each stud/s it goes down the slide.
	local slope = heading:Dot(across) / forward
	local carried = current:Dot(along) - FLOW_MOMENTUM_DRAG * dt
	-- The most it can push on while still leaning enough: pushing on is faster, which needs more
	-- lean, so halve the range till it's found.
	local low, high = 0, most
	for _ = 1, 8 do
		local push = (low + high) / 2
		if math.abs(math.max(least + push, carried) * slope) <= math.sqrt(most * most - push * push) then
			low = push
		else
			high = push
		end
	end
	local lean = math.clamp(math.max(least + low, carried) * slope, -most, most)
	return along * low + across * lean
end

local function floorGrip(body: Body): number
	local floor = body.GroundPart
	local grip = if body.Grounded and floor then floor:GetAttribute("Grip") else nil
	return if typeof(grip) == "number" then math.clamp(grip, 0.05, 1) else 1
end

-- Same as a player's (MovementController): quick to speed up, quicker to stop or turn round.
local function pickAcceleration(body: Body, current: Vector3, target: Vector3): number
	local movement = Config.Movement
	if not body.Grounded then
		return if target.Magnitude < 0.01 then movement.AirDeceleration else movement.AirAcceleration
	end
	if target.Magnitude < 0.01 then
		return movement.GroundDeceleration
	end
	if current.Magnitude > 1 and current.Unit:Dot(target.Unit) < 0.5 then
		return movement.TurnAcceleration
	end
	return if target.Magnitude >= current.Magnitude then movement.GroundAcceleration else movement.GroundDeceleration
end

-- Seconds after jumping until its feet are `height` up (or at the top of the jump, if that's
-- higher than it can go).
local function timeToRise(height: number): number
	local speed = Config.Movement.JumpVelocity
	local gravity = Workspace.Gravity
	local left = speed * speed - 2 * gravity * height
	if left <= 0 then
		return speed / gravity
	end
	return (speed - math.sqrt(left)) / gravity
end

-- A Bloblet's part (someone in the way is no wall to jump).
local function isBloblet(part: Instance): boolean
	local model = part:FindFirstAncestorOfClass("Model")
	return model ~= nil and CollectionService:HasTag(model, Tags.Bloblet)
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

-- Which way (and how hard, 0 to 1) it wants to go this frame: towards its target, easing off as
-- it gets there; on to the next point once there; or a dodge/sidestep for now.
-- Gone past `target` on the way to `after` (so it should just carry on), and not left below it.
-- (RaceKit moves it on to the next point the same way, a moment later.)
local function passed(position: Vector3, target: Vector3, after: Vector3?): boolean
	local beyond = MathUtil.flat(position - target)
	return after ~= nil
		and beyond.Magnitude < 20
		and target.Y - (position.Y - ROOT_HEIGHT) < LEDGE_RISE
		and beyond:Dot(MathUtil.flat(after - target)) > 0
end

local function wantedMove(body: Body, now: number, serverTime: number): Vector3
	local track = body.Track
	if track then
		body.Target = track(serverTime)
	end
	-- (Holding still to let a hazard pass is no use on a water slide: it can't stop there.)
	if now < body.OverrideUntil and not (body.OnFlow and body.Override.Magnitude < 0.05) then
		return body.Override
	end
	local target = body.Target
	if not target then
		return Vector3.zero
	end
	local position = body.Root.Position
	if track then
		-- A moving spot: run to where it'll be by the time it gets there.
		local lead = math.min(MathUtil.flat(target - position).Magnitude / body.Speed, LEAD_MAX)
		target = track(serverTime + lead)
	end
	local offset = MathUtil.flat(target - position)
	local distance = offset.Magnitude
	if distance <= body.Within or passed(position, target, body.Then) then
		local after = body.Then
		if after then
			local onward = MathUtil.flat(after - position)
			if onward.Magnitude > 0.5 then
				return onward.Unit
			end
		end
		-- Right by a ledge it means to be up on: keep at it (it jumps, below).
		if target.Y - (position.Y - ROOT_HEIGHT) > CLIMB and distance > 0.3 then
			return offset.Unit
		end
		return Vector3.zero
	end
	if body.Then then
		return offset.Unit
	end
	local ease = math.clamp((distance - body.Within) / ARRIVE_EASE, 0, 1)
	return offset.Unit * (ARRIVE_MIN + (1 - ARRIVE_MIN) * ease)
end

local function jumpHeight(): number
	return Config.Movement.JumpVelocity ^ 2 / (2 * Workspace.Gravity)
end

-- Seconds until its feet come down to `rise` studs above where they are now (negative: below),
-- going up at `vy` now and falling faster than it rises, like everyone. nil if it can't get up
-- that high.
local function landingTime(rise: number, vy: number): number?
	local gravity = Workspace.Gravity
	local fall = gravity * Config.Movement.FallGravityMultiplier
	local up = math.max(vy, 0)
	local apex = up * up / (2 * gravity)
	if rise > apex then
		return nil
	end
	local down = math.max(-vy, 0)
	return up / gravity + (math.sqrt(down * down + 2 * fall * (apex - rise)) - down) / fall
end

-- When and where it comes down on `aimAt` (a spot that may be moving), from vertical speed `vy`.
local function landing(aimAt: Aim, feet: number, vy: number, serverTime: number): (number?, Vector3?)
	local t = landingTime(aimAt(serverTime + 0.4).Y - feet, vy)
	for _ = 1, 3 do
		if not t then
			return nil, nil
		end
		t = landingTime(aimAt(serverTime + t).Y - feet, vy)
	end
	if not t then
		return nil, nil
	end
	return t, aimAt(serverTime + t)
end

-- Whether jumping right now would bring it down on `aimAt`: flies the jump the way it would steer
-- in the air (with `budget`, a share of its air steering, to leave some to spare) and sees if it
-- comes down within LAND_TOLERANCE of the spot.
local function leapWorks(body: Body, aimAt: Aim, serverTime: number, budget: number): boolean
	local root = body.Root
	local position = root.Position
	local t, spot = landing(aimAt, position.Y - ROOT_HEIGHT, Config.Movement.JumpVelocity, serverTime)
	if not t or not spot or t < 0.15 then
		return false
	end
	local goal = MathUtil.flat(spot)
	local at = MathUtil.flat(position)
	local velocity = MathUtil.flat(root.AssemblyLinearVelocity)
	local steer = Config.Movement.AirAcceleration * budget
	local flown = 0
	while flown < t - 1e-6 do
		local step = math.min(LEAP_CHECK_STEP, t - flown)
		local wanted = MathUtil.clampMagnitude((goal - at) / (t - flown), body.Speed)
		velocity = MathUtil.moveTowards(velocity, wanted, steer * step)
		at += velocity * step
		flown += step
	end
	return (goal - at).Magnitude <= LAND_TOLERANCE
end

-- Across the gap ahead, the nearest bit of floor it could land on (looking along `direction` and
-- up to `fan` steps of 15 degrees either side, as the shortest jump is often straight across, and
-- `reach` studs ahead), a little way onto it. nil if there's none in range.
local function farSide(body: Body, direction: Vector3, fan: number, reach: number): Vector3?
	local position = body.Root.Position
	local feet = position.Y - ROOT_HEIGHT
	local top = feet + jumpHeight() + 0.5
	local down = Vector3.new(0, -(jumpHeight() + 0.5 + GAP_DROP), 0)
	local base = math.atan2(direction.Z, direction.X)
	local best: Vector3? = nil
	local bestStep = math.huge
	for turn = -fan, fan do
		local angle = base + turn * FAR_SIDE_FAN_STEP
		local way = Vector3.new(math.cos(angle), 0, math.sin(angle))
		local pastEdge = false
		for step = 1, math.min(reach, bestStep - 1) do
			local hit = cast(Vector3.new(position.X, top, position.Z) + way * step, down, body.Params)
			if not hit or isBloblet(hit.Instance) then
				pastEdge = true
			elseif pastEdge then
				best = hit.Position + way * FAR_SIDE_IN
				bestStep = step
				break
			end
		end
	end
	return best
end

-- The far side of the gap ahead (see farSide), looked for again now and then or once it has moved.
local function nearFarSide(body: Body, direction: Vector3, fan: number, now: number, reach: number): Vector3?
	local position = body.Root.Position
	if now >= body.FarSideAt or (position - body.FarSideFrom).Magnitude > 1.5 or reach ~= body.FarSideReach then
		body.FarSideAt = now + FAR_SIDE_EVERY
		body.FarSideFrom = position
		body.FarSideReach = reach
		body.FarSide = farSide(body, direction, fan, reach)
	end
	return body.FarSide
end

-- How far (flat) a jump right now, diving `diveAfter` seconds in, carries it by the time its feet
-- are back down `drop` below where they are now, setting off at `speed`. Flown the way it flies:
-- running speed in the air (or faster, fading) and falling faster than it rises, then the dive's
-- speed and lift (BotMotor.Dive).
local function jumpReach(body: Body, speed: number, diveAfter: number, drop: number): number
	local movement = Config.Movement
	local dive = Config.Dive
	local gravity = Workspace.Gravity
	local turn = movement.AirAcceleration * FLIGHT_STEP
	local distance, height, rising, flat, t = 0, 0, movement.JumpVelocity, speed, 0
	local dived = false
	while t < 2 do
		if not dived and t >= diveAfter then
			dived = true
			rising = math.max(rising, 0) * 0.4 + dive.AirLift
			flat = dive.Speed
		elseif not dived then
			local wanted = body.Speed
			if flat > wanted then
				wanted = math.max(wanted, flat - movement.AirMomentumDrag * FLIGHT_STEP)
			end
			flat += math.clamp(wanted - flat, -turn, turn)
		end
		rising -= gravity * (if rising < 0 then movement.FallGravityMultiplier else 1) * FLIGHT_STEP
		distance += flat * FLIGHT_STEP
		height += rising * FLIGHT_STEP
		t += FLIGHT_STEP
		if t > 0.1 and height <= -drop then
			break
		end
	end
	return distance
end

-- When to dive, jumping right now, to come down on `spot` across a gap too wide to jump (seconds
-- into the jump), or nil if no dive reaches it.
local function diveMoment(body: Body, spot: Vector3): number?
	local root = body.Root
	local position = root.Position
	local towards = MathUtil.flat(spot - position)
	local distance = towards.Magnitude
	if distance < 0.1 then
		return nil
	end
	local speed = math.max(MathUtil.flat(root.AssemblyLinearVelocity):Dot(towards / distance), 0)
	local drop = position.Y - ROOT_HEIGHT - spot.Y
	local best: number? = nil
	local bestMiss = math.huge
	for step = 0, math.floor((DIVE_LATEST - DIVE_EARLIEST) / DIVE_STEP + 0.5) do
		local after = DIVE_EARLIEST + step * DIVE_STEP
		local reach = jumpReach(body, speed, after, drop)
		local miss = math.abs(reach - distance)
		if reach >= distance - DIVE_SHORT and miss < bestMiss then
			best, bestMiss = after, miss
		end
	end
	return best
end

-- The spot it's actually heading for: its target, or once there, the point after.
local function aimPoint(body: Body, position: Vector3): Vector3?
	local target = body.Target
	local after = body.Then
	if
		target
		and after
		and (MathUtil.flat(target - position).Magnitude <= body.Within or passed(position, target, after))
	then
		return after
	end
	return target
end

-- Waiting at an edge for the moment to jump: edge up to a stud short of it (measured the way it
-- wants to go, so drifting along the edge after a moving platform never takes it over).
local function edgeUp(body: Body, direction: Vector3, now: number): Vector3
	local position = body.Root.Position
	-- (Measured again only once it has moved, turned, or a moment has passed.)
	if now >= body.EdgeAt or (position - body.EdgeFrom).Magnitude > 0.3 or direction:Dot(body.EdgeWay) < 0.98 then
		local feet = position.Y - ROOT_HEIGHT
		local down = Vector3.new(0, -(GAP_DROP + 2), 0)
		local edge = EDGE_SCAN
		for step = 0, EDGE_SCAN, 0.5 do
			local hit = cast(position + direction * step + Vector3.new(0, 1, 0), down, body.Params)
			if not hit or feet - hit.Position.Y > GAP_DROP then
				edge = step
				break
			end
		end
		body.Edge = edge
		body.EdgeAt = now + EDGE_EVERY
		body.EdgeFrom = position
		body.EdgeWay = direction
	end
	local room = body.Edge - EDGE_BACK
	return direction * (math.clamp(room / 3, 0, 1) * EDGE_CREEP)
end

-- Jumping onto a moving platform, or off one: wait at the edge until a jump right now would come
-- down on the spot, then go. Returns the move (edging up to the edge while it waits).
local function plannedLeap(body: Body, move: Vector3, now: number, serverTime: number): Vector3
	local root = body.Root
	local position = root.Position
	local feet = position.Y - ROOT_HEIGHT
	local target = body.Target
	if not target or move.Magnitude < 0.05 then
		body.LeapReadyAt = 0
		return move
	end
	local direction = move.Unit
	local radius = BlobletRig.Dimensions.RootDiameter / 2
	local speed = MathUtil.flat(root.AssemblyLinearVelocity).Magnitude
	local ahead = math.clamp(speed * GAP_LEAD + radius * 0.5, GAP_PROBE_MIN, GAP_PROBE_MAX)
	local floor = cast(position + direction * ahead + Vector3.new(0, 1, 0), Vector3.new(0, -GAP_SEARCH, 0), body.Params)
	local drop = if floor then feet - floor.Position.Y else math.huge
	local track = body.Track
	-- Going somewhere still: floor ahead at about its height means it's there (or right by it).
	local reached = not track and floor ~= nil and math.abs(floor.Position.Y - target.Y) < 1.5 and drop <= GAP_DROP + 4
	local gapAhead = drop > GAP_DROP and not reached
	-- Going for a moving platform: hop on (never just walk on, it may slide away mid-step).
	local onto = track ~= nil and floor ~= nil and floor.Instance ~= body.GroundPart
	local above = target.Y - feet > LEDGE_RISE
	if not gapAhead and not onto and not above then
		body.LeapReadyAt = 0
		return move
	end
	local aimAt: Aim? = track
	if not aimAt then
		-- Off a moving platform towards somewhere still: the nearest floor across the gap.
		local spot = nearFarSide(body, direction, FAR_SIDE_FAN, now, FAR_SIDE_SCAN)
		if spot then
			local towards = MathUtil.flat(spot - position)
			if towards.Magnitude > 0.1 then
				direction = towards.Unit
			end
			aimAt = function(_serverTime: number): Vector3
				return spot
			end
		end
	end
	local budget = LEAP_BUDGET_SHARP + (LEAP_BUDGET_CLUMSY - LEAP_BUDGET_SHARP) * (1 - body.Skill)
	if aimAt and leapWorks(body, aimAt, serverTime, budget) then
		if body.LeapReadyAt == 0 then
			body.LeapReadyAt = now + random:NextNumber(0, LEAP_REACTION) * (1 - body.Skill)
		end
		if now >= body.LeapReadyAt then
			body.JumpAt = now
			body.Leap = aimAt
			body.LeapAt = now
			body.LeapReadyAt = 0
			return move
		end
	else
		body.LeapReadyAt = 0
	end
	if gapAhead then
		body.Blocked = true
		return edgeUp(body, direction, now)
	end
	return move
end

-- In the air: come down right on the spot it's going for, if it's in reach (a moving platform
-- where it'll be by then). Also says whether it's steering for a landing (so it lets go of extra
-- speed).
local function airGuide(body: Body, move: Vector3, serverTime: number): (Vector3, boolean)
	local aimAt = body.Leap or body.Track
	local target = aimPoint(body, body.Root.Position)
	if not aimAt and target then
		aimAt = function(_serverTime: number): Vector3
			return target
		end
	end
	if not aimAt then
		return move, false
	end
	local root = body.Root
	local position = root.Position
	local t, spot = landing(aimAt, position.Y - ROOT_HEIGHT, root.AssemblyLinearVelocity.Y, serverTime)
	if not t or not spot or t < 0.04 then
		return move, false
	end
	local wanted = MathUtil.flat(spot - position) / t
	if wanted.Magnitude > body.Speed * 1.3 then
		return move, false -- out of reach: just go for it
	end
	return wanted / body.Speed, true
end

-- A player's quick reactions, for a bot running along the ground: jump a wall or up a ledge in
-- the way, jump the gap at an edge (and dive if it's wide; clumsy bots sometimes miss it), or stop
-- at the edge when being careful. Returns the move, which a careful stop cancels.
local function reflexes(body: Body, move: Vector3, now: number, serverTime: number, planned: boolean): Vector3
	if move.Magnitude < 0.05 then
		body.AtGap = false
		body.LeapReadyAt = 0
		return move
	end
	local root = body.Root
	local position = root.Position
	local feet = position.Y - ROOT_HEIGHT
	local direction = move.Unit
	local radius = BlobletRig.Dimensions.RootDiameter / 2
	local speed = MathUtil.flat(root.AssemblyLinearVelocity).Magnitude

	-- (The side of a moving platform it's going for isn't a wall: that jump gets planned.)
	local knee = Vector3.new(position.X, feet + KNEE, position.Z)
	local wall = if body.Track then nil else cast(knee, direction * (radius + WALL_PROBE), body.Params)
	if wall and wall.Normal.Y < 0.6 and not isBloblet(wall.Instance) then
		body.JumpAt = now
	end
	if planned and not body.InWater then
		body.AtGap = false
		return plannedLeap(body, move, now, serverTime)
	end
	local target = aimPoint(body, position)
	local rise = if target and now >= body.OverrideUntil then target.Y - feet else 0
	if target and rise > LEDGE_RISE then
		-- Going up onto something: jump while its edge is still far enough off that its feet will
		-- be over the top by the time it gets there. Already too close for its speed: ease off
		-- first, then jump.
		local height = math.clamp(rise - 0.4, KNEE, jumpHeight() - 0.3)
		local needed = speed * timeToRise(rise + LEDGE_CLEARANCE)
		local reach = radius + 0.6 + needed
		local edge = cast(Vector3.new(position.X, feet + height, position.Z), direction * reach, body.Params)
		if edge and edge.Normal.Y < 0.6 and not isBloblet(edge.Instance) then
			if speed > 1 and edge.Distance - radius < needed - 0.1 then
				body.AtGap = false
				return Vector3.zero
			end
			body.JumpAt = now
		end
		if rise > CLIMB and MathUtil.flat(target - position).Magnitude < CLIMB_REACH then
			body.JumpAt = now
		end
	end
	if body.InWater then
		body.AtGap = false
		return move -- swimming: no edges to mind
	end

	local ahead = math.clamp(speed * GAP_LEAD + radius * 0.5, GAP_PROBE_MIN, GAP_PROBE_MAX)
	local down = Vector3.new(0, -GAP_SEARCH, 0)
	local floor = cast(position + direction * ahead + Vector3.new(0, 1, 0), down, body.Params)
	local drop = if floor then feet - floor.Position.Y else math.huge
	local goingDown = target ~= nil
		and floor ~= nil
		and now >= body.OverrideUntil
		and target.Y < feet - DOWN_BELOW
		and floor.Position.Y >= target.Y - DOWN_BELOW
	if drop <= GAP_DROP or goingDown then
		body.AtGap = false
		return move
	end
	-- Dodging or sidestepping never takes it over an edge.
	local careful = body.Careful or now < body.OverrideUntil
	if not body.AtGap then
		body.AtGap = true
		body.Fluff = not careful and random:NextNumber() < (1 - body.Skill) * 0.1
	end
	if careful then
		body.Blocked = true
		return edgeUp(body, direction, now) -- stay on this side
	end
	if body.Fluff then
		return move -- a clumsy bot that's going to miss this one
	end
	-- Only jump a gap with somewhere to land across it (a drop into nothing is just an edge), and
	-- only dive when a plain jump won't reach (never when jumping up onto something: it'd fly
	-- straight past it), at the moment that brings it down just onto the far side. In the air it
	-- steers to come down on that spot.
	local spot =
		nearFarSide(body, direction, FAR_SIDE_STILL_FAN, now, if body.NoDive then FAR_SIDE_SCAN else FAR_SIDE_SCAN_DIVE)
	if not spot then
		body.Blocked = true
		return edgeUp(body, direction, now)
	end
	local function landOn(_serverTime: number): Vector3
		return spot
	end
	if leapWorks(body, landOn, serverTime, LEAP_BUDGET_CLUMSY) then
		body.JumpAt = now
		body.Leap = landOn
		body.LeapAt = now
		return move
	end
	local diveAfter = if not body.NoDive and rise <= 1 then diveMoment(body, spot) else nil
	if not diveAfter then
		body.Blocked = true
		return edgeUp(body, direction, now) -- too far to make it
	end
	body.JumpAt = now
	body.DiveAt = now + diveAfter
	return move
end

-- Its reflexes on a water slide, where there's no stopping: jump at the end of the slide (a gap to
-- jump, or a ramp's lip: jumping there carries it much further than just flying off), jump a
-- hammer swinging across at just the moment that sails it over the head, and otherwise
-- belly-slide (dive onto the water: quicker than the water, all the way down). Touching the water
-- counts as standing on it for jumping, even going up a ramp too fast to count as standing.
local function slideReflex(body: Body, flow: Vector3?, now: number, serverTime: number)
	local root = body.Root
	local position = root.Position
	local velocity = root.AssemblyLinearVelocity
	local flat = MathUtil.flat(velocity)
	local feet = position.Y - ROOT_HEIGHT
	-- (Looking the way it means to go, not the way a side current is pushing it, which would see
	-- the side of the slide as an edge.)
	local target = aimPoint(body, position)
	local way = if target then MathUtil.flat(target - position) else flat
	if way.Magnitude < 0.5 then
		way = flat
	end
	if way.Magnitude < 0.5 then
		return
	end
	local direction = way.Unit
	local down = Vector3.new(0, -GAP_SEARCH, 0)
	local function dropAt(distance: number): number
		local floor = cast(position + direction * distance + Vector3.new(0, 1, 0), down, body.Params)
		return if floor then feet - floor.Position.Y else math.huge
	end

	local radius = BlobletRig.Dimensions.RootDiameter / 2
	local ahead = math.clamp(flat.Magnitude * GAP_LEAD + radius * 0.5, GAP_PROBE_MIN, FLOW_GAP_PROBE_MAX)
	local threatened, overHammer = BotWorld.HammerJump(position, velocity, serverTime)
	if overHammer or dropAt(ahead) > GAP_DROP then
		body.JumpAt = now
		body.LastGrounded = now
		return
	end

	if
		body.Mode ~= "Normal"
		or not flow
		or body.NoDive
		or threatened
		or now < body.DiveReadyAt
		or now < body.SlideTryAt
		or now < body.OverrideUntil
	then
		return
	end
	body.SlideTryAt = now + SLIDE_DIVE_EVERY
	if direction:Dot(flow.Unit) < 0.8 or random:NextNumber() > body.Skill then
		return
	end
	-- Only onto plain slide: not just before a gap, or a ramp (it'd still be diving off the lip).
	for _, distance in SLIDE_DIVE_CLEAR do
		local drop = dropAt(distance)
		if drop > GAP_DROP or drop < -0.5 then
			return
		end
	end
	BotMotor.Dive(body.Bot, direction)
end

-- Belly-sliding on the ground (not down a water slide): stop, as a player does by pulling back on
-- the stick, when the slide would carry it off an edge (landing a dive on a small platform) or it
-- wants to go back the other way.
local function slideBrake(body: Body, current: Vector3, move: Vector3): boolean
	local speed = current.Magnitude
	if not body.Grounded or speed < 1 then
		return false
	end
	local along = current / speed
	if move.Magnitude > 0.3 and move.Unit:Dot(along) < -0.3 then
		return true
	end
	local position = body.Root.Position
	local ahead = speed * speed / (2 * Config.Dive.SlideBrake) + SLIDE_BRAKE_ROOM
	local floor = cast(position + along * ahead + Vector3.new(0, 1, 0), Vector3.new(0, -GAP_SEARCH, 0), body.Params)
	return not floor or position.Y - ROOT_HEIGHT - floor.Position.Y > GAP_DROP
end

local function isConveyor(part: BasePart): boolean
	local model = part.Parent
	return model ~= nil and CollectionService:HasTag(model, Tags.Conveyor)
end

-- How to run on a belt (relative to it) to go `desired` over the ground, as a player would. At
-- full speed: lean into the belt's sideways push so it doesn't carry it off the side, and run on
-- with what's left (a belt going its way speeds it up, one against it slows it down). Slowing to
-- a stop or standing: exactly what it takes, so it stays put on a moving belt.
local function againstBelt(desired: Vector3, belt: Vector3, maxSpeed: number): Vector3
	local speed = desired.Magnitude
	if speed < maxSpeed * 0.95 then
		return MathUtil.clampMagnitude(desired - belt, maxSpeed)
	end
	local along = desired / speed
	local across = belt - along * belt:Dot(along)
	local acrossSpeed = across.Magnitude
	if acrossSpeed >= maxSpeed then
		return -across / acrossSpeed * maxSpeed
	end
	return along * math.sqrt(maxSpeed * maxSpeed - acrossSpeed * acrossSpeed) - across
end

-- In the air on the way up onto something: don't push into its side until its feet are above it.
local function holdOffLedge(body: Body, move: Vector3, now: number): Vector3
	local target = body.Target
	if not target or move.Magnitude < 0.05 or now < body.OverrideUntil then
		return move
	end
	local position = body.Root.Position
	if position.Y - ROOT_HEIGHT > target.Y + 0.1 then
		return move
	end
	local radius = BlobletRig.Dimensions.RootDiameter / 2
	local side = cast(Vector3.new(position.X, target.Y - 0.4, position.Z), move.Unit * (radius + 0.5), body.Params)
	if side and side.Normal.Y < 0.6 and not isBloblet(side.Instance) then
		return Vector3.zero
	end
	return move
end

local function stepBody(body: Body, dt: number, now: number, serverTime: number)
	local root, humanoid = body.Root, body.Humanoid
	if body.Model:GetAttribute("TeleportedAt") ~= body.Settled then
		settle(body, now)
	end
	if root.Anchored then
		-- Frozen (waiting for GO): ownership is taken again once it's free.
		body.ServerOwned = false
		return
	end
	keepOwnership(body, now)

	local velocity = root.AssemblyLinearVelocity
	local hit = if body.Mode == "Ragdoll" then nil else probeGround(body)
	body.Grounded = hit ~= nil and now >= body.JumpLockUntil and velocity.Y < 12
	local hitInstance = if hit then hit.Instance else nil
	body.GroundPart = if body.Grounded and hitInstance and hitInstance:IsA("BasePart") then hitInstance else nil
	body.GroundNormal = if body.Grounded and hit then hit.Normal else Vector3.yAxis
	body.OnFlow = hit ~= nil and now >= body.JumpLockUntil and flowOf(hitInstance) ~= nil
	if body.OnFlow then
		body.FlowAt = now
	end
	if body.Grounded then
		body.LastGrounded = now
		if body.Leap and now - body.LeapAt > 0.25 then
			body.Leap = nil -- landed
		end
	end
	body.Blocked = false

	-- Water: float at the surface (like a player's client does), and it can jump from it.
	local water = Config.Water
	local surface = BotWorld.WaterSurfaceAt(root.Position, serverTime)
	body.InWater = surface ~= nil and root.Position.Y < surface + water.EnterMargin
	if body.InWater and surface then
		local floatY = surface + water.FloatHeight
		if root.Position.Y < floatY + 0.15 and velocity.Y < 12 then
			velocity = Vector3.new(velocity.X, math.clamp((floatY - root.Position.Y) * 7, -6, 14), velocity.Z)
			root.AssemblyLinearVelocity = velocity
		end
		if body.Mode == "Normal" then
			body.LastGrounded = now
		end
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
	setFallForce(body, not body.Grounded and not body.InWater and velocity.Y < 0)

	-- Dive -> belly slide -> back on its feet.
	local dive = Config.Dive
	if body.Mode == "Dive" then
		local airTime = now - body.ModeStart
		if ((body.Grounded or body.OnFlow) and airTime > dive.MinAirTime) or airTime > dive.MaxAirTime then
			setMode(body, "Slide", now)
		end
	elseif body.Mode == "Slide" then
		-- (Down a water slide the belly slide lasts as long as it's on the water.)
		if now - body.ModeStart >= dive.SlideTime and now - body.FlowAt >= FLOW_GRACE then
			setMode(body, "Normal", now)
			ActionService.BotEndDive(body.Bot)
		end
	elseif body.Mode == "Recover" then
		if now - body.ModeStart >= Config.Ragdoll.GetUpRecoverTime then
			setMode(body, "Normal", now)
		end
	end

	-- What it's standing on: a moving platform means planning any jump off it.
	local floor = body.GroundPart
	local floorMotion = if floor then floor:GetVelocityAtPosition(root.Position) else Vector3.zero
	local floorVelocity = MathUtil.flat(floorMotion)
	local onBelt = floor ~= nil and floorVelocity.Magnitude > 0.5 and isConveyor(floor)
	local onMover = floor ~= nil and floorMotion.Magnitude > 0.5 and not onBelt -- (lifts go up and down)
	local flow = flowUnder(body)

	-- Where it wants to go, and its reflexes on the way.
	local rope = body.Model:GetAttribute("OnRope")
	local onRope = typeof(rope) == "Vector3"
	local move = wantedMove(body, now, serverTime)
	local guided = false
	if body.OnFlow and (body.Mode == "Normal" or body.Mode == "Slide") and not body.InWater and not onRope then
		slideReflex(body, flow, now, serverTime)
	elseif body.Mode == "Normal" and (body.Grounded or body.InWater) and not onRope then
		move = reflexes(body, move, now, serverTime, body.Track ~= nil or onMover)
	elseif body.Mode == "Normal" and not onRope then
		move, guided = airGuide(body, move, serverTime)
		move = holdOffLedge(body, move, now)
	end
	local diveAt = body.DiveAt
	if diveAt and now >= diveAt then
		body.DiveAt = nil
		if body.Mode == "Normal" and not body.Grounded then
			BotMotor.Dive(body.Bot, if move.Magnitude > 0.05 then move else MathUtil.flat(velocity))
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

	-- The speed it's after this frame, reached with a player's acceleration. Like a player's, it's
	-- measured against whatever it's standing on (a belt, a moving platform), as that's what its
	-- running is relative to.
	local current = MathUtil.flat(root.AssemblyLinearVelocity) - floorVelocity
	local sliding = body.Mode == "Slide"
	local riding = body.Mode == "Normal" or sliding -- (what a water slide carries along)
	local target: Vector3
	local acceleration: number
	if onRope and body.Mode == "Normal" then
		-- Holding a rope: no walking; it goes wherever the rope goes, facing along it.
		local tow = body.Model:GetAttribute("Tow")
		target = if typeof(tow) == "Vector3" then MathUtil.flat(tow) else Vector3.zero
		acceleration = pickAcceleration(body, current, target)
		local facing = MathUtil.flat(rope :: Vector3)
		if facing.Magnitude > 0.1 then
			faceAlong(body, facing.Unit, dt)
		end
	elseif body.Mode == "Dive" then
		target = body.DiveDirection * dive.Speed
		acceleration = dive.AirSteerAcceleration
	elseif flow and riding and not body.InWater then
		-- A water slide carries it along (a belly slide a little faster than the water); it leans
		-- into side currents and pushes on downhill (flowSteer).
		local least = flow.Magnitude * (if sliding then FLOW_SLIDE_SPEEDUP else 1)
		local steer = flowSteer(flow, move, current, least, body.Speed * FLOW_STEER, dt)
		target = flowTarget(flow, current, least, steer, dt)
		acceleration = FLOW_ACCELERATION
	elseif riding and not body.Grounded and not body.InWater and now - body.FlowAt < FLOW_CARRY_TIME then
		-- Flying off a water slide (a jump, a ramp): it keeps the slide's speed, as a player does;
		-- steering only bends its path.
		local speed = current.Magnitude
		target = current
		if speed > 1 then
			local steer = move * body.Speed * FLOW_STEER
			local sideways = steer - current * (steer:Dot(current) / (speed * speed))
			target = (current + sideways).Unit * speed
		end
		acceleration = movement.AirAcceleration
	elseif body.Mode == "Slide" then
		if slideBrake(body, current, move) then
			target = Vector3.zero
			acceleration = dive.SlideBrake
		else
			target = move * movement.RunSpeed * dive.SlideControl
			acceleration = dive.SlideFriction
		end
	elseif body.Mode == "Recover" then
		target = Vector3.zero
		acceleration = if body.Grounded then movement.GroundDeceleration else 0
	elseif body.InWater then
		-- Swimming: slower, but it can still steer to a plank and jump out.
		target = move * body.Speed * Config.Water.SwimSpeedMultiplier * speedMultiplier(body) + grabPull(body)
		acceleration = Config.Water.SwimAcceleration
	else
		local run = move * body.Speed * speedMultiplier(body)
		if onBelt then
			run = againstBelt(run, floorVelocity, body.Speed * speedMultiplier(body))
		end
		target = run + grabPull(body)
		if not body.Grounded and not guided and target.Magnitude > 0.01 and current.Magnitude > target.Magnitude then
			if current:Dot(target) > 0 then
				-- Faster than running (a dive, a bounce): keep that speed in the air, fading.
				target = target.Unit * math.max(target.Magnitude, current.Magnitude - movement.AirMomentumDrag * dt)
			end
		end
		acceleration = pickAcceleration(body, current, target)
		local grip = floorGrip(body)
		if grip < 1 then
			target += MathUtil.flat(body.GroundNormal) * movement.SlipperySlopeSlide * (1 - grip)
			acceleration *= grip
		end
	end

	local newVelocity = MathUtil.moveTowards(current, target, acceleration * dt)
	local speed = newVelocity.Magnitude
	if body.Mode == "Dive" and speed > 1 then
		body.DiveDirection = newVelocity / speed
	end
	humanoid.AutoRotate = not onRope
	if speed > 0.05 then
		humanoid.WalkSpeed = speed
		humanoid:Move(newVelocity / speed, false)
	else
		humanoid.WalkSpeed = 0
		humanoid:Move(Vector3.zero, false)
	end
	local fall = root.AssemblyLinearVelocity
	if fall.Y < -movement.MaxFallSpeed then
		root.AssemblyLinearVelocity = Vector3.new(fall.X, -movement.MaxFallSpeed, fall.Z)
	end
end

local function step(dt: number)
	if next(bodies) == nil then
		return
	end
	BotProfiler.Begin("BotMotor")
	local now = os.clock()
	local serverTime = Workspace:GetServerTimeNow()
	for model, body in bodies do
		if not model.Parent or not body.Root.Parent then
			BotMotor.Detach(model)
			continue
		end
		local ok, err = pcall(function(): any
			stepBody(body, dt, now, serverTime)
			return nil
		end)
		if not ok then
			warn(`[BotMotor] {body.Bot.Name}: {err}`)
		end
	end
	BotProfiler.End("BotMotor")
end

function BotMotor.Init()
	Bots.SetKnocker(BotMotor.Knock)
	RunService.Heartbeat:Connect(step)
end

return BotMotor
