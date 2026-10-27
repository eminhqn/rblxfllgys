--!strict
-- What bots do while a round is on.
--
-- A few times a second each bot still in the round asks the round what it wants (the round's
-- BotGoal, see Match/Types) and works out how to do it:
--   * walk to the spot, jumping onto ledges and over walls in the way
--   * at the edge of a gap, jump it (and dive too if it's wide). A "careful" goal stops at the
--     edge instead, unless the spot is down below.
--   * hazards (BotWorld.Threat): jump a spinning bar, step out of a balloon's lane or off a
--     crate's target, wait for a hammer or spikes to pass, if it's sharp enough to notice in time
--   * stuck against something: hop, then try sideways; still stuck, reset (races put it back on
--     its checkpoint)
--   * someone right in front who isn't a team-mate: now and then a kick, or a grab held a moment
--
-- How sharp a bot is (its skill, Config.Bots) sets how often it notices hazards, how quickly it
-- reacts, how often it fluffs a jump and how fast it runs (BotMotor). Rounds without a BotGoal
-- get a wander round the middle of the arena that keeps away from the edges.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local BlobletRig = require(Shared.BlobletRig)
local Config = require(Shared.Config)
local MathUtil = require(Shared.MathUtil)
local Teams = require(Shared.Teams)

local ActionService = require(script.Parent.Parent.Services.ActionService)
local Types = require(script.Parent.Parent.Match.Types)
local BotMotor = require(script.Parent.BotMotor)
local BotWorld = require(script.Parent.BotWorld)
local Bots = require(script.Parent.Bots)

local BotBrain = {}

type Mind = {
	Holding: boolean, -- GRAB is held
	FightGrabUntil: number, -- holding GRAB to grab someone until then
	ProgressFrom: Vector3?, -- where it was when it last got somewhere
	ProgressAt: number,
	StuckJumped: boolean,
	SidestepUntil: number,
	Sidestep: Vector3,
	DodgeUntil: number,
	Dodge: Vector3?, -- stepping this way while dodging (nil: waiting)
	ThreatKind: string?,
	ThreatSeen: number,
	Noticed: boolean, -- spotted the current threat (sharper bots more often)
	AtGap: boolean,
	Fluff: boolean, -- going to miss this jump
	DiveAt: number?, -- dive now (mid-jump over a wide gap)
	WanderPoint: Vector3?,
	WanderUntil: number,
	LastReset: number,
}

type Round = {
	Context: Types.RoundContext,
	Game: Types.MiniGame,
	Reset: (bot: Player) -> (),
	Token: number,
}

local TICK = 1 / Config.Match.UpdateRate
local ROOT_HEIGHT = BlobletRig.Dimensions.RootHeight
local WALL_PROBE = 3.2 -- studs ahead it looks for a wall
local GAP_PROBE = 3.5 -- studs ahead it looks for the floor
local WIDE_GAP_PROBE = 9 -- no floor this far ahead either: a wide gap, so dive
local GAP_DROP = 4 -- the floor this far below its feet (or none) counts as a gap
local CLIMB = 2.5 -- a goal this much higher than its feet, close by, means jump
local DIVE_DELAY = 0.22 -- seconds into a jump over a wide gap that it dives
local DODGE_TIME = 0.6
local WAIT_TIME = 0.35
local STUCK_DISTANCE = 2
local STUCK_JUMP = 1.2 -- seconds without getting anywhere before it hops
local STUCK_SIDESTEP = 3
local STUCK_RESET = 9
local SIDESTEP_TIME = 0.8
local DEFAULT_WANDER = 18

local random = Random.new()
local minds: { [Player]: Mind } = {}
local roundToken = 0

local function newMind(): Mind
	return {
		Holding = false,
		FightGrabUntil = 0,
		ProgressFrom = nil,
		ProgressAt = 0,
		StuckJumped = false,
		SidestepUntil = 0,
		Sidestep = Vector3.zero,
		DodgeUntil = 0,
		Dodge = nil,
		ThreatKind = nil,
		ThreatSeen = 0,
		Noticed = false,
		AtGap = false,
		Fluff = false,
		DiveAt = nil,
		WanderPoint = nil,
		WanderUntil = 0,
		LastReset = 0,
	}
end

local function skillOf(bot: Player): number
	local info = Bots.Info(bot)
	return if info then info.Skill else 0.5
end

local function randomFlat(radius: number): Vector3
	local angle = random:NextNumber(0, math.pi * 2)
	local distance = math.sqrt(random:NextNumber()) * radius
	return Vector3.new(math.cos(angle) * distance, 0, math.sin(angle) * distance)
end

local function setGrab(bot: Player, mind: Mind, held: boolean)
	if held ~= mind.Holding then
		mind.Holding = held
		ActionService.BotGrab(bot, held)
	end
end

-- Someone just in front of it to kick or grab (not on its team).
local function opponentInFront(bot: Player, root: BasePart, context: Types.RoundContext): Player?
	local look = MathUtil.flat(root.CFrame.LookVector)
	if look.Magnitude < 1e-3 then
		return nil
	end
	look = look.Unit
	local ownTeam = Teams.FromPlayer(bot)
	local reach = Config.Kick.Range + 0.5
	for _, other in context.GetAlive() do
		if other == bot then
			continue
		end
		if ownTeam and Teams.FromPlayer(other) == ownTeam then
			continue
		end
		local otherRoot = context.GetRoot(other)
		local character = other.Character
		if not otherRoot or not character or character:GetAttribute("Ragdolled") == true then
			continue
		end
		local offset = otherRoot.Position - root.Position
		local flat = MathUtil.flat(offset)
		if offset.Magnitude <= reach and flat.Magnitude > 0.5 and flat.Unit:Dot(look) > 0.35 then
			return other
		end
	end
	return nil
end

-- Bots in rounds that don't say: drift round the middle, away from the edges.
local function defaultGoal(context: Types.RoundContext): Types.BotGoal
	return {
		MoveTo = context.Origin.Position,
		Wander = DEFAULT_WANDER,
		Careful = context.Info.Type ~= "Race",
	}
end

local function raycastParams(character: Model): RaycastParams
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { character }
	params.RespectCanCollide = true
	params.CollisionGroup = Bots.CollisionGroup
	return params
end

local function think(current: Round, bot: Player, mind: Mind)
	local context = current.Context
	local character = bot.Character
	local root = if character then character.PrimaryPart else nil
	if not character or not root or root.Anchored then
		return
	end
	local now = os.clock()
	local skill = skillOf(bot)

	local goal: Types.BotGoal? = nil
	local getGoal = current.Game.BotGoal
	if getGoal then
		local ok, result = pcall(getGoal, bot)
		if ok then
			goal = result
		else
			warn(`[BotBrain] {context.Info.Id}.BotGoal failed: {result}`)
		end
	end
	local wanted: Types.BotGoal = goal or defaultGoal(context)

	-- Kicks and grabs at whoever's in front, now and then.
	local carrying = character:GetAttribute("Carrying") == true
	local onRope = typeof(character:GetAttribute("OnRope")) == "Vector3"
	if not wanted.Calm and not carrying and not onRope and not BotMotor.IsBusy(bot) then
		if opponentInFront(bot, root, context) then
			if random:NextNumber() < Config.Bots.KickRate * TICK then
				ActionService.BotKick(bot)
			elseif random:NextNumber() < Config.Bots.GrabRate * TICK and not mind.Holding then
				mind.FightGrabUntil = now + random:NextNumber(0.8, 1.6)
			end
		end
	end
	setGrab(bot, mind, wanted.Grab == true or now < mind.FightGrabUntil)

	if BotMotor.IsBusy(bot) then
		return -- tumbling, getting up, diving or sliding
	end
	if wanted.Stop then
		BotMotor.SetMove(bot, Vector3.zero)
		if wanted.Jump then
			BotMotor.Jump(bot)
		end
		return
	end

	-- Where to.
	local position = root.Position
	local feetY = position.Y - ROOT_HEIGHT
	local target = wanted.MoveTo
	local wander = wanted.Wander
	if target and wander then
		local point = mind.WanderPoint
		if not point or now > mind.WanderUntil or MathUtil.flat(point - position).Magnitude < 2.5 then
			point = target + randomFlat(wander)
			mind.WanderPoint = point
			mind.WanderUntil = now + random:NextNumber(2, 4.5)
		end
		target = point
	end
	if not target then
		BotMotor.SetMove(bot, Vector3.zero)
		return
	end
	local offset = MathUtil.flat(target - position)
	local distance = offset.Magnitude
	local direction = if distance > (wanted.Within or 2) then offset.Unit else Vector3.zero

	-- Hazards about to hit it: a sharp bot notices more often, and sooner.
	local velocity = root.AssemblyLinearVelocity
	local threat = BotWorld.Threat(position, MathUtil.flat(velocity))
	if threat then
		if mind.ThreatKind ~= threat.Kind then
			mind.ThreatKind = threat.Kind
			mind.ThreatSeen = now
			mind.Noticed = random:NextNumber() < 0.25 + 0.7 * skill
		end
		if mind.Noticed and now - mind.ThreatSeen >= 0.25 - 0.2 * skill then
			if threat.Jump then
				BotMotor.Jump(bot)
			end
			if threat.Away then
				mind.Dodge = threat.Away
				mind.DodgeUntil = now + DODGE_TIME
			elseif threat.Wait then
				mind.Dodge = nil
				mind.DodgeUntil = now + WAIT_TIME
			end
		end
	else
		mind.ThreatKind = nil
	end
	if now < mind.DodgeUntil then
		direction = mind.Dodge or Vector3.zero
	elseif now < mind.SidestepUntil then
		direction = mind.Sidestep
	end

	-- Walls, ledges and gaps in the way.
	local jump = wanted.Jump == true
	if BotMotor.IsGrounded(bot) and direction.Magnitude > 0 then
		local params = raycastParams(character)
		local knee = position - Vector3.new(0, ROOT_HEIGHT - 1.2, 0)
		local wall = Workspace:Raycast(knee, direction * WALL_PROBE, params)
		if wall and wall.Normal.Y < 0.6 then
			jump = true
		end
		if target.Y - feetY > CLIMB and distance < 12 then
			jump = true
		end
		local down = Vector3.new(0, -(GAP_DROP + 10), 0)
		local floor = Workspace:Raycast(position + direction * GAP_PROBE + Vector3.new(0, 1, 0), down, params)
		local drop = if floor then feetY - floor.Position.Y else math.huge
		local targetBelow = target.Y < feetY - 3
		if drop > GAP_DROP and not targetBelow then
			if not mind.AtGap then
				mind.AtGap = true
				-- Clumsy bots sometimes don't jump in time.
				mind.Fluff = random:NextNumber() < (1 - skill) * 0.15
			end
			if wanted.Careful then
				direction = Vector3.zero -- stay on this side
			elseif not mind.Fluff then
				jump = true
				local far =
					Workspace:Raycast(position + direction * WIDE_GAP_PROBE + Vector3.new(0, 1, 0), down, params)
				if not far or feetY - far.Position.Y > GAP_DROP then
					mind.DiveAt = now + DIVE_DELAY
				end
			end
		else
			mind.AtGap = false
		end
	end

	-- Getting nowhere: hop, then sidestep, then reset.
	if direction.Magnitude > 0 then
		local from = mind.ProgressFrom
		if not from or MathUtil.flat(position - from).Magnitude > STUCK_DISTANCE then
			mind.ProgressFrom = position
			mind.ProgressAt = now
			mind.StuckJumped = false
		else
			local stuckFor = now - mind.ProgressAt
			if stuckFor > STUCK_RESET and now - mind.LastReset > STUCK_RESET then
				mind.LastReset = now
				mind.ProgressFrom = nil
				current.Reset(bot)
			elseif stuckFor > STUCK_SIDESTEP and now > mind.SidestepUntil then
				local side = Vector3.new(-direction.Z, 0, direction.X) * (if random:NextNumber() < 0.5 then -1 else 1)
				mind.Sidestep = (side + direction * 0.3).Unit
				mind.SidestepUntil = now + SIDESTEP_TIME
			elseif stuckFor > STUCK_JUMP and not mind.StuckJumped then
				mind.StuckJumped = true
				jump = true
			end
		end
	else
		mind.ProgressFrom = nil
	end

	BotMotor.SetMove(bot, direction)
	if jump then
		BotMotor.Jump(bot)
	end
	local diveAt = mind.DiveAt
	if wanted.Dive or (diveAt and now >= diveAt) then
		mind.DiveAt = nil
		BotMotor.Dive(bot, if direction.Magnitude > 0 then direction else offset)
	end
end

local function stopBot(bot: Player, mind: Mind)
	setGrab(bot, mind, false)
	BotMotor.SetMove(bot, Vector3.zero)
end

-- The round has gone live: bots start playing it. `reset` is what pressing reset does in it.
function BotBrain.BeginRound(context: Types.RoundContext, miniGame: Types.MiniGame, reset: (bot: Player) -> ())
	roundToken += 1
	local token = roundToken
	local current: Round = { Context = context, Game = miniGame, Reset = reset, Token = token }
	table.clear(minds)
	task.spawn(function()
		while roundToken == token do
			task.wait(TICK)
			if roundToken ~= token then
				break
			end
			for _, bot in Bots.All() do
				local mind = minds[bot]
				if not context.IsAlive(bot) then
					if mind then
						stopBot(bot, mind)
						minds[bot] = nil
					end
					continue
				end
				if not mind then
					mind = newMind()
					minds[bot] = mind
				end
				local ok, err = pcall(function(): any
					think(current, bot, mind)
					return nil
				end)
				if not ok then
					warn(`[BotBrain] {bot.Name}: {err}`)
				end
			end
		end
	end)
end

-- The round's over: bots stop and let go of everything.
function BotBrain.EndRound()
	roundToken += 1
	for bot, mind in minds do
		stopBot(bot, mind)
	end
	table.clear(minds)
end

return BotBrain
