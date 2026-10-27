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
-- something), or stop at the edge if told to be careful. ActionService knocks bots over
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
local BotWorld = require(script.Parent.BotWorld)
local Bots = require(script.Parent.Bots)

local BotMotor = {}

type Mode = "Normal" | "Dive" | "Slide" | "Ragdoll" | "Recover"

-- Where BotBrain wants a bot to go.
export type Steer = {
	Target: Vector3?, -- head for this point (nil: stand still)
	Then: Vector3?, -- once within Within of Target, carry on towards this without stopping
	Within: number?, -- close enough to Target (flat studs, default 2)
	Careful: boolean?, -- stop at an edge rather than jump it (unless Target is down below)
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
	Then: Vector3?,
	Within: number,
	Careful: boolean,
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
local FLOW_STEER = 0.5
local FLOW_ACCELERATION = 70
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
local WIDE_GAP = 11 -- no floor this far ahead either: dive as well
local DIVE_DELAY = 0.24 -- seconds into a jump over a wide gap that it dives
-- A target this far below its feet, with floor ahead down at about its height: it means to drop
-- down there, so it doesn't jump.
local DOWN_BELOW = 3
local OWNER_CHECK_EVERY = 0.5

local random = Random.new()
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
		Then = nil,
		Within = 2,
		Careful = false,
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
	body.Then = steer.Then
	body.Within = steer.Within or 2
	body.Careful = steer.Careful == true
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
local function wantedMove(body: Body, now: number): Vector3
	if now < body.OverrideUntil then
		return body.Override
	end
	local target = body.Target
	if not target then
		return Vector3.zero
	end
	local position = body.Root.Position
	local offset = MathUtil.flat(target - position)
	local distance = offset.Magnitude
	if distance <= body.Within then
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

-- A player's quick reactions, for a bot running along the ground: jump a wall or up a ledge in
-- the way, jump the gap at an edge (and dive if it's wide; clumsy bots sometimes miss it), or stop
-- at the edge when being careful. Returns the move, which a careful stop cancels.
local function reflexes(body: Body, move: Vector3, now: number): Vector3
	if move.Magnitude < 0.05 then
		body.AtGap = false
		return move
	end
	local root = body.Root
	local position = root.Position
	local feet = position.Y - ROOT_HEIGHT
	local direction = move.Unit
	local radius = BlobletRig.Dimensions.RootDiameter / 2
	local speed = MathUtil.flat(root.AssemblyLinearVelocity).Magnitude

	local knee = Vector3.new(position.X, feet + KNEE, position.Z)
	local wall = Workspace:Raycast(knee, direction * (radius + WALL_PROBE), body.Params)
	if wall and wall.Normal.Y < 0.6 and not isBloblet(wall.Instance) then
		body.JumpAt = now
	end
	local target = body.Target
	local rise = if target and now >= body.OverrideUntil then target.Y - feet else 0
	if target and rise > LEDGE_RISE then
		-- Going up onto something: jump while its edge is still far enough off that its feet will
		-- be over the top by the time it gets there. Already too close for its speed: ease off
		-- first, then jump.
		local jumpHeight = Config.Movement.JumpVelocity ^ 2 / (2 * Workspace.Gravity)
		local height = math.clamp(rise - 0.4, KNEE, jumpHeight - 0.3)
		local needed = speed * timeToRise(rise + LEDGE_CLEARANCE)
		local reach = radius + 0.6 + needed
		local edge =
			Workspace:Raycast(Vector3.new(position.X, feet + height, position.Z), direction * reach, body.Params)
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
	local floor = Workspace:Raycast(position + direction * ahead + Vector3.new(0, 1, 0), down, body.Params)
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
		return Vector3.zero -- stay on this side
	end
	if not body.Fluff then
		body.JumpAt = now
		-- (Never a dive when jumping up onto something: it'd fly straight past it.)
		local far = Workspace:Raycast(position + direction * WIDE_GAP + Vector3.new(0, 1, 0), down, body.Params)
		if rise <= 1 and (not far or feet - far.Position.Y > GAP_DROP) then
			body.DiveAt = now + DIVE_DELAY
		end
	end
	return move
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
	local side =
		Workspace:Raycast(Vector3.new(position.X, target.Y - 0.4, position.Z), move.Unit * (radius + 0.5), body.Params)
	if side and side.Normal.Y < 0.6 and not isBloblet(side.Instance) then
		return Vector3.zero
	end
	return move
end

local function stepBody(body: Body, dt: number, now: number)
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
	if body.Grounded then
		body.LastGrounded = now
	end
	body.Blocked = false

	-- Water: float at the surface (like a player's client does), and it can jump from it.
	local water = Config.Water
	local surface = BotWorld.WaterSurfaceAt(root.Position)
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

	-- Where it wants to go, and its reflexes on the way.
	local rope = body.Model:GetAttribute("OnRope")
	local onRope = typeof(rope) == "Vector3"
	local move = wantedMove(body, now)
	if body.Mode == "Normal" and (body.Grounded or body.InWater) and not onRope then
		move = reflexes(body, move, now)
	elseif body.Mode == "Normal" and not onRope then
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

	-- The speed it's after this frame, reached with a player's acceleration.
	local current = MathUtil.flat(root.AssemblyLinearVelocity)
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
	elseif body.Mode == "Slide" then
		local flow = flowUnder(body)
		if flow then
			target = flow * 1.15
			acceleration = FLOW_ACCELERATION
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
		local flow = flowUnder(body)
		if flow then
			-- A water slide carries it along; it only steers across.
			local along = flow.Unit
			local steer = move * body.Speed * FLOW_STEER
			target = along * math.max(flow.Magnitude, flow.Magnitude + steer:Dot(along))
				+ (steer - along * steer:Dot(along))
			acceleration = FLOW_ACCELERATION
		else
			target = move * body.Speed * speedMultiplier(body) + grabPull(body)
			if not body.Grounded and target.Magnitude > 0.01 and current.Magnitude > target.Magnitude then
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
