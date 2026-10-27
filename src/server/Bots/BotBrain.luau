--!strict
-- What bots do while a round is on.
--
-- A few times a second each bot still in the round asks the round what it wants (the round's
-- BotGoal, see Match/Types) and works out how to do it; BotMotor then steers it there every frame
-- (easing off as it arrives, jumping walls, ledges and gaps on the way, or stopping at the edge
-- when the goal says to be careful). On top of that the brain:
--   * dodges hazards (BotWorld.Threat): jumps a spinning bar, steps out of a balloon's lane or
--     off a crate's target, waits for a hammer or spikes to pass (never for long), if it's sharp
--     enough to notice in time
--   * keeps an eye on whether it's getting any nearer where it's going. If not (stuck on
--     something, circling under a platform it fell off, waiting on something that never comes):
--     hop, then sidestep one way and the other, then reset (races put it back on its checkpoint)
--   * kicks someone right in front who isn't a team-mate now and then, or grabs them a moment
--
-- How sharp a bot is (its skill, Config.Bots) sets how often it notices hazards, how quickly it
-- reacts, how often it fluffs a jump and how fast it runs (BotMotor). Rounds without a BotGoal
-- get a wander round the middle of the arena that keeps away from the edges.
--
-- Config.Studio.ShowBotThoughts puts a line over each bot in Studio saying what it's doing.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage.Shared
local BlobletRig = require(Shared.BlobletRig)
local Config = require(Shared.Config)
local MathUtil = require(Shared.MathUtil)
local Teams = require(Shared.Teams)
local Theme = require(Shared.Theme)
local Ui = require(Shared.Ui)

local ActionService = require(script.Parent.Parent.Services.ActionService)
local Types = require(script.Parent.Parent.Match.Types)
local BotMotor = require(script.Parent.BotMotor)
local BotWorld = require(script.Parent.BotWorld)
local Bots = require(script.Parent.Bots)

local BotBrain = {}

type Mind = {
	Holding: boolean, -- GRAB is held
	FightGrabUntil: number, -- holding GRAB to grab someone until then
	-- Getting anywhere: the spot it's making for, the nearest it's been to it, and when.
	GoalAt: Vector3?,
	Best: number,
	BestAt: number,
	StuckStage: number, -- 0 fine, 1 hopped, 2 sidestepped, 3 sidestepped the other way
	SidestepSign: number,
	LastReset: number,
	ThreatKind: string?,
	ThreatSeen: number,
	Noticed: boolean, -- spotted the current threat (sharper bots more often)
	WaitingSince: number, -- 0: not waiting for a hazard to pass
	BlockedSince: number, -- 0: not stopped at an edge (BotMotor waiting for its moment to jump)
	IgnoreWaitsUntil: number, -- waited long enough: pushes on through for a moment
	WanderPoint: Vector3?,
	WanderUntil: number,
	Label: TextLabel?, -- Config.Studio.ShowBotThoughts
	LabelText: string,
}

type Round = {
	Context: Types.RoundContext,
	Game: Types.MiniGame,
	Reset: (bot: Player) -> (),
	Token: number,
}

local TICK = 1 / Config.Match.UpdateRate
local ROOT_HEIGHT = BlobletRig.Dimensions.RootHeight
local DODGE_TIME = 0.6
local WAIT_TIME = 0.35
local MAX_WAIT = 2.5 -- seconds it'll wait for one hazard before going anyway
local ARRIVED_HEIGHT = 4.5 -- within its goal's reach and this close in height: it's there
local GOAL_MOVED = 4 -- a goal that jumps further than this is a new goal
local PROGRESS = 1 -- getting this much nearer counts as getting somewhere
local STUCK_JUMP = 1.2 -- seconds without getting nearer before it hops
local STUCK_SIDESTEP = 2.5 -- ...sidesteps (and again the other way at twice this)
local STUCK_RESET = 8 -- ...resets
local UNDERNEATH_RESET = 3.5 -- ...resets, when it's right under where it should be (fell off)
local SIDESTEP_TIME = 0.9
local EDGE_PATIENCE = 12 -- seconds stopped at an edge (waiting for a jump to work) before that's stuck
local DEFAULT_WANDER = 18
-- Rolling balloons and gumdrops: how far ahead (seconds) and with how much room to spare (studs)
-- a bot plans its way through them, clumsiest to sharpest.
local ROLLER_HORIZON = { 0.9, 2.2 }
local ROLLER_MARGIN = { 0.6, 1.8 }
local SHOW_THOUGHTS = RunService:IsStudio() and Config.Studio.ShowBotThoughts == true

local random = Random.new()
local minds: { [Player]: Mind } = {}
local roundToken = 0

local function newMind(): Mind
	return {
		Holding = false,
		FightGrabUntil = 0,
		GoalAt = nil,
		Best = math.huge,
		BestAt = 0,
		StuckStage = 0,
		SidestepSign = if random:NextNumber() < 0.5 then -1 else 1,
		LastReset = 0,
		ThreatKind = nil,
		ThreatSeen = 0,
		Noticed = false,
		WaitingSince = 0,
		BlockedSince = 0,
		IgnoreWaitsUntil = 0,
		WanderPoint = nil,
		WanderUntil = 0,
		Label = nil,
		LabelText = "",
	}
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

-- Config.Studio.ShowBotThoughts: a line of text over the bot.
local function showThought(bot: Player, mind: Mind, root: BasePart, text: string)
	if text == mind.LabelText and mind.Label and mind.Label.Parent then
		return
	end
	mind.LabelText = text
	local label = mind.Label
	if not label or not label:IsDescendantOf(root) then
		local gui: BillboardGui = Ui.new("BillboardGui", {
			Name = "BotThoughts",
			Size = UDim2.fromOffset(320, 22),
			StudsOffset = Vector3.new(0, 5, 0),
			MaxDistance = 120,
			LightInfluence = 0,
			AlwaysOnTop = true,
			Adornee = root,
			Parent = root,
		})
		local made: TextLabel = Ui.new("TextLabel", {
			Size = UDim2.fromScale(1, 1),
			BackgroundColor3 = Theme.Colors.Ink,
			BackgroundTransparency = 0.35,
			TextColor3 = Theme.Colors.White,
			Font = Enum.Font.GothamMedium,
			TextSize = 13,
			Parent = gui,
		})
		label = made
		mind.Label = made
	end
	(label :: TextLabel).Text = `{bot.DisplayName}: {text}`
end

local function think(current: Round, bot: Player, mind: Mind)
	local context = current.Context
	local character = bot.Character
	local root = if character then character.PrimaryPart else nil
	if not character or not root or root.Anchored then
		return
	end
	local now = os.clock()
	local skill = Bots.SkillOf(bot)

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
	local note = wanted.Note or (if goal then "" else "wandering (no goal)")

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
		-- Tumbling, getting up or diving: nothing to decide, and no time lost getting nowhere.
		mind.BestAt = now
		if SHOW_THOUGHTS then
			showThought(bot, mind, root, `{note} [{BotMotor.ModeOf(bot)}]`)
		end
		return
	end
	if wanted.Stop then
		BotMotor.Steer(bot, { Target = nil })
		if wanted.Jump then
			BotMotor.Jump(bot)
		end
		mind.BestAt = now
		if SHOW_THOUGHTS then
			showThought(bot, mind, root, `{note} [holding still]`)
		end
		return
	end

	-- Where to.
	local position = root.Position
	local target = wanted.MoveTo
	local wander = wanted.Wander
	if target and wander then
		local point = mind.WanderPoint
		if
			not point
			or now > mind.WanderUntil
			or MathUtil.flat(point - position).Magnitude < 2.5
			or BotMotor.IsBlocked(bot)
		then
			point = target + randomFlat(wander)
			mind.WanderPoint = point
			mind.WanderUntil = now + random:NextNumber(2, 4.5)
		end
		target = point
	end
	if not target then
		BotMotor.Steer(bot, { Target = nil })
		mind.BestAt = now
		return
	end
	local within = wanted.Within or 2
	BotMotor.Steer(bot, {
		Target = target,
		Track = if wander then nil else wanted.Track,
		Then = wanted.Then,
		Within = within,
		Careful = wanted.Careful,
		-- Dives only in races: everywhere else the platforms are small and the belly slide after a
		-- dive would carry it off.
		NoDive = context.Info.Type ~= "Race",
	})
	if wanted.Jump then
		BotMotor.Jump(bot)
	end
	if wanted.Dive then
		BotMotor.Dive(bot, MathUtil.flat(target - position))
	end

	-- Rolling balloons and gumdrops: take a line none of them will run into (knowing where each one
	-- will be; sharp bots look further ahead and leave more room).
	local dodging = false
	local heading = MathUtil.flat(target - position)
	heading = if heading.Magnitude > 0.1 then heading.Unit else MathUtil.flat(root.CFrame.LookVector)
	if heading.Magnitude > 0.1 then
		heading = heading.Unit
		local dodge = BotWorld.RollerDodge(
			position,
			heading,
			MathUtil.flat(root.AssemblyLinearVelocity),
			BotMotor.RunSpeed(bot),
			ROLLER_HORIZON[1] + (ROLLER_HORIZON[2] - ROLLER_HORIZON[1]) * skill,
			ROLLER_MARGIN[1] + (ROLLER_MARGIN[2] - ROLLER_MARGIN[1]) * skill
		)
		if dodge then
			dodging = true
			local across = dodge.Offset
			local way = if across.Magnitude > 0.5 then across.Unit * 0.8 else Vector3.zero
			if not dodge.Hold and across.Magnitude > 0.5 then
				way += heading * 0.55
			end
			BotMotor.Override(bot, way, TICK * 1.6)
		end
	end

	-- Hazards about to hit it: a sharp bot notices more often, and sooner.
	local waiting = false
	local hazardWait = false
	local threat = BotWorld.Threat(position, MathUtil.flat(root.AssemblyLinearVelocity))
	if threat then
		if mind.ThreatKind ~= threat.Kind then
			mind.ThreatKind = threat.Kind
			mind.ThreatSeen = now
			mind.Noticed = random:NextNumber() < 0.3 + 0.7 * skill
		end
		if mind.Noticed and now - mind.ThreatSeen >= 0.25 - 0.2 * skill then
			if threat.Jump then
				BotMotor.Jump(bot)
			end
			if threat.Away then
				BotMotor.Override(bot, threat.Away, DODGE_TIME)
			elseif threat.Wait and now >= mind.IgnoreWaitsUntil then
				if mind.WaitingSince == 0 then
					mind.WaitingSince = now
				end
				if now - mind.WaitingSince > MAX_WAIT then
					-- It isn't going to clear: go for it.
					mind.IgnoreWaitsUntil = now + 1.5
					mind.WaitingSince = 0
				else
					BotMotor.Override(bot, Vector3.zero, WAIT_TIME)
					waiting = true
					hazardWait = true
				end
			end
		end
	else
		mind.ThreatKind = nil
	end
	if not waiting then
		mind.WaitingSince = 0
	end
	-- Stopped at an edge, waiting for the moment to jump (a moving platform): fine, for a while.
	if BotMotor.IsBlocked(bot) then
		if mind.BlockedSince == 0 then
			mind.BlockedSince = now
		end
		if now - mind.BlockedSince < EDGE_PATIENCE then
			waiting = true
		end
	else
		mind.BlockedSince = 0
	end
	if wanted.Waiting then
		waiting = true
	end

	-- Getting any nearer? (Measured from its feet, as goals are spots on the ground.)
	local toGoal = target - (position - Vector3.new(0, ROOT_HEIGHT, 0))
	local flatGap = MathUtil.flat(toGoal).Magnitude
	local gap = toGoal.Magnitude
	local there = flatGap <= within + 0.5 and math.abs(toGoal.Y) <= ARRIVED_HEIGHT
	local goalAt = mind.GoalAt
	if not goalAt or (target - goalAt).Magnitude > GOAL_MOVED then
		mind.GoalAt = target
		mind.Best = gap
		mind.BestAt = now
		mind.StuckStage = 0
	elseif there or waiting or dodging or gap < mind.Best - PROGRESS then
		mind.GoalAt = target
		mind.Best = math.min(mind.Best, gap)
		mind.BestAt = now
		mind.StuckStage = 0
	end

	-- Not getting anywhere: hop, sidestep one way, then the other, then reset.
	local stuckFor = now - mind.BestAt
	local underneath = toGoal.Y > 6 and flatGap < 10
	if stuckFor > (if underneath then UNDERNEATH_RESET else STUCK_RESET) and now - mind.LastReset > 3 then
		mind.LastReset = now
		mind.GoalAt = nil
		mind.StuckStage = 0
		mind.WanderPoint = nil
		current.Reset(bot)
		-- (Outside races a reset does nothing: wander off a little and try again.)
		BotMotor.Override(bot, randomFlat(1), 1.2)
	elseif mind.StuckStage == 0 and stuckFor > STUCK_JUMP then
		mind.StuckStage = 1
		BotMotor.Jump(bot)
	elseif mind.StuckStage >= 1 and mind.StuckStage <= 2 and stuckFor > STUCK_SIDESTEP * mind.StuckStage then
		local towards = MathUtil.flat(toGoal)
		towards = if towards.Magnitude > 0.1 then towards.Unit else MathUtil.flat(root.CFrame.LookVector)
		if towards.Magnitude > 0.1 then
			local side = Vector3.new(-towards.Z, 0, towards.X) * mind.SidestepSign
			BotMotor.Override(bot, side + towards * 0.3, SIDESTEP_TIME)
			BotMotor.Jump(bot)
		end
		mind.SidestepSign = -mind.SidestepSign
		mind.StuckStage += 1
	end

	if SHOW_THOUGHTS then
		local parts = { if note ~= "" then note else "going" }
		table.insert(parts, `{math.floor(flatGap + 0.5)} away`)
		if math.abs(toGoal.Y) >= 2 then
			table.insert(
				parts,
				if toGoal.Y > 0 then `{math.floor(toGoal.Y + 0.5)} up` else `{math.floor(-toGoal.Y + 0.5)} down`
			)
		end
		if hazardWait then
			table.insert(parts, `waiting for {threat and threat.Kind or "hazard"}`)
		end
		if BotMotor.IsBlocked(bot) then
			table.insert(parts, "at an edge")
		end
		if dodging then
			table.insert(parts, "dodging a roller")
		end
		if stuckFor > STUCK_JUMP then
			table.insert(parts, `stuck {math.floor(stuckFor * 10) / 10}s`)
		end
		showThought(bot, mind, root, table.concat(parts, " · "))
	end
end

local function stopBot(bot: Player, mind: Mind)
	setGrab(bot, mind, false)
	BotMotor.Steer(bot, { Target = nil })
	local label = mind.Label
	if label then
		local gui = label.Parent
		if gui then
			gui:Destroy()
		end
	end
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
						minds[bot] = nil
						pcall(stopBot, bot, mind)
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
		pcall(stopBot, bot, mind)
	end
	table.clear(minds)
end

return BotBrain
