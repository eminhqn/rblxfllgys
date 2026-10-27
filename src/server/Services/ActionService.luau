--!strict
-- Server authority for dive, grab, kick, slap, ragdoll and emotes.
--
-- The owning client plays an action instantly (prediction) and sends a request. The server checks
-- cooldowns and state, decides the outcome (for a grab: who, if anyone, gets grabbed) and publishes
-- the result as character attributes that every client animates from. Invalid requests are
-- rejected, and the client cancels its prediction.
--
-- Slaps (the SLAPS item) only work in a round where you picked SLAPS (so you hold your slapper),
-- and one is used up only when it lands. A SHIELD (ItemService) takes kicks, slaps and grabs
-- instead of its owner until it breaks.
--
-- Holding GRAB keeps reaching: until the button is let go, the server looks for something to grab
-- every Config.Grab.ReachInterval and grabs the first thing that comes in reach.
--
-- Bots (Server/Bots) press the same buttons through BotDive, BotGrab and BotKick, and are grabbed,
-- kicked and knocked over like players; their Bloblets are moved by the server (BotMotor), so a
-- knockdown goes there instead of to a client.
--
-- Rounds and the tutorial can listen in: Acted fires for every dive, grab, kick and slap the
-- server accepts, and SetGrabHook lets a round turn a grab into something else (Egg Scramble picks
-- up eggs with it, Tug of Wobble takes hold of the rope).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local Config = require(Shared.Config)
local Cosmetics = require(Shared.Cosmetics)
local Match = require(Shared.Match)
local MathUtil = require(Shared.MathUtil)
local Remotes = require(Shared.Remotes)
local Signal = require(Shared.Signal)

local Bots = require(script.Parent.Parent.Bots.Bots)
local DataService = require(script.Parent.DataService)
local ItemService = require(script.Parent.ItemService)
local PlayerState = require(script.Parent.PlayerState)
local RateLimiter = require(script.Parent.Parent.Util.RateLimiter)

local ActionService = {}

-- (player, action: "Dive" | "Grab" | "Kick" | "Slap") once the server has accepted it.
ActionService.Acted = Signal.new() :: Signal.Signal<Player, string>

-- Called before anyone is grabbed: once when GRAB is pressed (`pressed` is true), then again on
-- every reach while it's held. Returning true means it dealt with the grab (only the reach pose is
-- shown, and the reach ends). nil = none.
export type GrabHook = (player: Player, root: BasePart, pressed: boolean) -> boolean
local grabHook: GrabHook? = nil

function ActionService.SetGrabHook(hook: GrabHook?)
	grabHook = hook
end

-- Clients may run slightly ahead of the server clock; accept requests a little early.
local COOLDOWN_TOLERANCE = 0.8
local GRAB_CHECK_INTERVAL = 0.2

local diveLimiter = RateLimiter.new(3, 2)
local grabLimiter = RateLimiter.new(4, 4)
local releaseLimiter = RateLimiter.new(6, 6)
local endDiveLimiter = RateLimiter.new(4, 3)
local kickLimiter = RateLimiter.new(3, 2)
local slapLimiter = RateLimiter.new(3, 1)
local knockdownLimiter = RateLimiter.new(3, 2)
local emoteLimiter = RateLimiter.new(2, 1)

local activeGrabs: { [Player]: Player } = {} -- grabber -> victim
local grabWatcherRunning = false
local reaching: { [Player]: number } = {} -- holding GRAB with nothing grabbed yet -> when it began
local reachWatcherRunning = false

local function getCharacter(player: Player): (Model?, BasePart?)
	local character = player.Character
	if not character or not character.Parent then
		return nil, nil
	end
	local root = character.PrimaryPart
	if not root then
		return nil, nil
	end
	return character, root
end

-- Knocked out of the round but still in the arena for a moment (seeing the fall, or deciding on a
-- respawn): no knocking anyone else about.
local function isOut(player: Player): boolean
	return player:GetAttribute(Match.PlayerAttr.Status) == "Eliminated"
end

local function reject(player: Player, action: string)
	if Bots.Is(player) then
		return -- a bot just sees nothing happen
	end
	Remotes.Event("ActionRejected"):FireClient(player, action)
end

-- Shows `action` to everyone for `duration` seconds (unless replaced sooner).
local function setAction(player: Player, character: Model, action: string, duration: number)
	local state = PlayerState.Get(player)
	state.ActionToken += 1
	local token = state.ActionToken
	character:SetAttribute("Action", action)
	task.delay(duration, function()
		if state.ActionToken == token and character.Parent then
			character:SetAttribute("Action", "None")
		end
	end)
end

local function clearAction(player: Player, character: Model)
	PlayerState.Get(player).ActionToken += 1
	character:SetAttribute("Action", "None")
end

local function release(grabber: Player)
	local victim = activeGrabs[grabber]
	activeGrabs[grabber] = nil
	local grabberCharacter = grabber.Character
	if grabberCharacter then
		grabberCharacter:SetAttribute("Grabbing", 0)
		if grabberCharacter:GetAttribute("Action") == "Grab" then
			clearAction(grabber, grabberCharacter)
		end
	end
	if victim then
		local victimCharacter = victim.Character
		if victimCharacter and victimCharacter:GetAttribute("GrabbedBy") == grabber.UserId then
			victimCharacter:SetAttribute("GrabbedBy", 0)
		end
	end
end

-- Ends any grab the player is part of, as grabber or as victim.
function ActionService.ReleaseInvolving(player: Player)
	reaching[player] = nil
	local grabbers: { Player } = {}
	for grabber, victim in activeGrabs do
		if grabber == player or victim == player then
			table.insert(grabbers, grabber)
		end
	end
	for _, grabber in grabbers do
		release(grabber)
	end
end

-- Only runs while at least one grab is active (no permanent server loop).
local function ensureGrabWatcher()
	if grabWatcherRunning then
		return
	end
	grabWatcherRunning = true
	task.spawn(function()
		while next(activeGrabs) ~= nil do
			task.wait(GRAB_CHECK_INTERVAL)
			for grabber, victim in table.clone(activeGrabs) do
				local _, grabberRoot = getCharacter(grabber)
				local _, victimRoot = getCharacter(victim)
				if
					not grabberRoot
					or not victimRoot
					or (grabberRoot.Position - victimRoot.Position).Magnitude > Config.Grab.BreakDistance
				then
					release(grabber)
				end
			end
		end
		grabWatcherRunning = false
	end)
end

-- The nearest other Bloblet within `maxDistance` and roughly in front of `root`.
local function findTargetInFront(
	attacker: Player,
	root: BasePart,
	maxDistance: number,
	frontDot: number,
	skipGrabbed: boolean
): Player?
	local look = MathUtil.flat(root.CFrame.LookVector)
	look = if look.Magnitude > 1e-3 then look.Unit else Vector3.zAxis

	local best: Player? = nil
	local bestDistance = math.huge
	local everyone = Players:GetPlayers()
	for _, bot in Bots.List() do
		table.insert(everyone, bot)
	end
	for _, other in everyone do
		if other == attacker then
			continue
		end
		local character, otherRoot = getCharacter(other)
		if not character or not otherRoot or otherRoot.Anchored then
			continue
		end
		if skipGrabbed and character:GetAttribute("GrabbedBy") ~= 0 then
			continue
		end
		local offset = otherRoot.Position - root.Position
		local distance = offset.Magnitude
		if distance > maxDistance or distance >= bestDistance then
			continue
		end
		local flatOffset = MathUtil.flat(offset)
		if flatOffset.Magnitude > 0.5 and flatOffset.Unit:Dot(look) < frontDot then
			continue
		end
		best = other
		bestDistance = distance
	end
	return best
end

local function setRagdolled(player: Player, character: Model, duration: number)
	local state = PlayerState.Get(player)
	state.RagdollToken += 1
	local token = state.RagdollToken
	ActionService.ReleaseInvolving(player)
	clearAction(player, character)
	character:SetAttribute("Ragdolled", true)
	task.delay(duration, function()
		if state.RagdollToken == token and character.Parent then
			character:SetAttribute("Ragdolled", false)
		end
	end)
end

-- Server-initiated knockdown (used by server-run obstacles in later milestones).
function ActionService.Ragdoll(player: Player, impulse: Vector3, strength: number)
	local character = getCharacter(player)
	if not character or ItemService.ShieldHit(player) then
		return -- a SHIELD took it
	end
	local duration = Config.RagdollDuration(strength)
	setRagdolled(player, character, duration)
	if Bots.Is(player) then
		Bots.Knock(player, impulse, duration)
	else
		Remotes.Event("ApplyRagdoll"):FireClient(player, impulse, duration)
	end
end

local function onRequestDive(player: Player, direction: unknown)
	if not diveLimiter:Allow(player) then
		return
	end
	if typeof(direction) ~= "Vector3" or not MathUtil.isFiniteVector(direction) then
		return
	end
	local character = getCharacter(player)
	if not character then
		return
	end
	local state = PlayerState.Get(player)
	local now = os.clock()
	if
		character:GetAttribute("Ragdolled") == true
		or now - state.LastDive < Config.Dive.Cooldown * COOLDOWN_TOLERANCE
	then
		reject(player, "Dive")
		return
	end
	state.LastDive = now
	if activeGrabs[player] then
		release(player)
	end
	setAction(player, character, "Dive", Config.Dive.PoseTime)
	ActionService.Acted:Fire(player, "Dive")
end

-- One try at grabbing: the round's hook first (an egg, the rope), then a player in front. True
-- once something has been grabbed (or the hook dealt with it, or a shield took it).
local function attemptGrab(player: Player, character: Model, root: BasePart, pressed: boolean): boolean
	local hook = grabHook
	if hook and hook(player, root, pressed) then
		setAction(player, character, "Grab", Config.Grab.PoseTime)
		return true
	end

	local victim =
		findTargetInFront(player, root, Config.Grab.Range + Config.Grab.RangeSlack, Config.Grab.FrontDot, true)
	local victimCharacter = if victim then victim.Character else nil
	if not victim or not victimCharacter then
		return false
	end
	if ItemService.ShieldHit(victim) then
		setAction(player, character, "Grab", Config.Grab.PoseTime) -- the shield took it
		return true
	end

	local state = PlayerState.Get(player)
	activeGrabs[player] = victim
	character:SetAttribute("Grabbing", victim.UserId)
	victimCharacter:SetAttribute("GrabbedBy", player.UserId)
	setAction(player, character, "Grab", Config.Grab.MaxHoldTime)

	state.GrabToken += 1
	local token = state.GrabToken
	task.delay(Config.Grab.MaxHoldTime, function()
		if state.GrabToken == token and activeGrabs[player] == victim then
			release(player)
		end
	end)
	ensureGrabWatcher()
	return true
end

-- Only runs while someone is holding GRAB with nothing in hand (no permanent server loop).
local function ensureReachWatcher()
	if reachWatcherRunning then
		return
	end
	reachWatcherRunning = true
	task.spawn(function()
		while next(reaching) ~= nil do
			task.wait(Config.Grab.ReachInterval)
			local now = os.clock()
			for player, began in table.clone(reaching) do
				local character, root = getCharacter(player)
				if
					not character
					or not root
					or now - began > Config.Grab.MaxReachTime
					or isOut(player)
					or activeGrabs[player]
					or character:GetAttribute("Ragdolled") == true
					or character:GetAttribute("Action") ~= "Grab" -- dived, kicked or slapped since
				then
					reaching[player] = nil
					continue
				end
				local ok, grabbed = pcall(attemptGrab, player, character, root, false)
				if not ok then
					warn(`[ActionService] {grabbed}`)
					reaching[player] = nil
				elseif grabbed then
					reaching[player] = nil
				end
			end
		end
		reachWatcherRunning = false
	end)
end

function ActionService.IsReaching(player: Player): boolean
	return reaching[player] ~= nil
end

local function onRequestGrab(player: Player)
	if not grabLimiter:Allow(player) then
		return
	end
	local character, root = getCharacter(player)
	if not character or not root then
		return
	end
	local state = PlayerState.Get(player)
	local now = os.clock()
	if
		isOut(player)
		or character:GetAttribute("Ragdolled") == true
		or character:GetAttribute("Action") == "Dive"
		or activeGrabs[player]
		or now - state.LastGrab < Config.Grab.Cooldown * COOLDOWN_TOLERANCE
	then
		reject(player, "Grab")
		return
	end
	state.LastGrab = now
	ActionService.Acted:Fire(player, "Grab")
	if attemptGrab(player, character, root, true) then
		return
	end
	-- Nothing in reach yet: keep reaching (others see the reach pose) while GRAB is held.
	reaching[player] = now
	setAction(player, character, "Grab", Config.Grab.MaxReachTime)
	ensureReachWatcher()
end

local function onRequestRelease(player: Player)
	if not releaseLimiter:Allow(player) then
		return
	end
	reaching[player] = nil
	if activeGrabs[player] then
		release(player)
	else
		local character = player.Character
		if character and character:GetAttribute("Action") == "Grab" then
			clearAction(player, character)
		end
	end
end

-- Kick: the server decides who (if anyone) is hit and knocks them over with a push.
local function onRequestKick(player: Player)
	if not kickLimiter:Allow(player) then
		return
	end
	local character, root = getCharacter(player)
	if not character or not root or root.Anchored then
		return
	end
	local state = PlayerState.Get(player)
	local now = os.clock()
	if
		isOut(player)
		or character:GetAttribute("Ragdolled") == true
		or character:GetAttribute("Action") == "Dive"
		or now - state.LastKick < Config.Kick.Cooldown * COOLDOWN_TOLERANCE
	then
		reject(player, "Kick")
		return
	end
	state.LastKick = now
	if activeGrabs[player] then
		release(player)
	end
	setAction(player, character, "Kick", Config.Kick.PoseTime)
	ActionService.Acted:Fire(player, "Kick")

	local kick = Config.Kick
	local victim = findTargetInFront(player, root, kick.Range + kick.RangeSlack, kick.FrontDot, false)
	if not victim then
		return -- a whiff: others still see the kick
	end
	local _, victimRoot = getCharacter(victim)
	if not victimRoot then
		return
	end
	local push = MathUtil.flat(victimRoot.Position - root.Position)
	push = if push.Magnitude > 0.1 then push.Unit else MathUtil.flat(root.CFrame.LookVector).Unit
	ActionService.Ragdoll(victim, push * kick.Knockback + Vector3.new(0, kick.Lift, 0), kick.Strength)
end

-- Slap: a stronger kick, for players holding a slapper (they picked SLAPS for this round). A slap
-- is only used up if it lands on someone (a shield that blocks it still counts).
local function onRequestSlap(player: Player)
	if not slapLimiter:Allow(player) then
		return
	end
	local character, root = getCharacter(player)
	if not character or not root or root.Anchored then
		return
	end
	local state = PlayerState.Get(player)
	local now = os.clock()
	local playing = Match.GetFolder():GetAttribute(Match.Attr.Phase) == "Playing"
		and player:GetAttribute(Match.PlayerAttr.InMatch) == true
	if
		not playing
		or not ItemService.IsActive(player, "Slap")
		or ItemService.Count(player, "Slap") <= 0
		or character:GetAttribute("Ragdolled") == true
		or character:GetAttribute("Action") == "Dive"
		or now - state.LastSlap < Config.Slap.Cooldown * COOLDOWN_TOLERANCE
	then
		reject(player, "Slap")
		return
	end
	state.LastSlap = now
	if activeGrabs[player] then
		release(player)
	end
	setAction(player, character, "Slap", Config.Slap.PoseTime)
	ActionService.Acted:Fire(player, "Slap")

	local slap = Config.Slap
	local victim = findTargetInFront(player, root, slap.Range + slap.RangeSlack, slap.FrontDot, false)
	if not victim then
		return -- a whiff costs nothing
	end
	local _, victimRoot = getCharacter(victim)
	if not victimRoot or not ItemService.UseSlap(player) then
		return
	end
	Remotes.Event("ItemEffect"):FireAllClients("Slap", victimRoot.Position)
	local push = MathUtil.flat(victimRoot.Position - root.Position)
	push = if push.Magnitude > 0.1 then push.Unit else MathUtil.flat(root.CFrame.LookVector).Unit
	ActionService.Ragdoll(victim, push * slap.Knockback + Vector3.new(0, slap.Lift, 0), slap.Strength)
end

-- The client's slide ended (or was jump-cancelled) before the pose timer ran out. This only
-- clears the player's own dive pose, so it just needs rate-limiting.
local function onEndDive(player: Player)
	if not endDiveLimiter:Allow(player) then
		return
	end
	local character = player.Character
	if character and character:GetAttribute("Action") == "Dive" then
		clearAction(player, character)
	end
end

-- The client was hit by a client-animated hazard. Being knocked down only hurts the reporter,
-- so this just needs sanity checks (rate, range) before telling everyone else.
local function onReportKnockdown(player: Player, strength: unknown)
	if not knockdownLimiter:Allow(player) then
		return
	end
	if typeof(strength) ~= "number" or not MathUtil.isFiniteNumber(strength) then
		return
	end
	local character = getCharacter(player)
	if not character then
		return
	end
	local state = PlayerState.Get(player)
	local now = os.clock()
	if now - state.LastKnockdown < Config.Ragdoll.MinReportInterval then
		return
	end
	state.LastKnockdown = now
	setRagdolled(player, character, Config.RagdollDuration(strength))
end

-- Plays the emote the player has equipped (the client can't pick one it doesn't own). Everyone
-- animates it from the Emote / EmoteAt attributes.
local function onRequestEmote(player: Player)
	if not emoteLimiter:Allow(player) then
		return
	end
	local character, root = getCharacter(player)
	if not character or not root or root.Anchored or character:GetAttribute("Ragdolled") == true then
		return
	end
	local profile = DataService.Get(player)
	local emoteId = if profile then profile.Equipped.Emote else Cosmetics.Defaults.Emote
	local entry = Cosmetics.Get(emoteId)
	local duration = if entry and entry.Duration then entry.Duration else 1.5
	local state = PlayerState.Get(player)
	local now = os.clock()
	if now - state.LastEmote < duration * COOLDOWN_TOLERANCE then
		return
	end
	state.LastEmote = now
	character:SetAttribute("Emote", emoteId)
	character:SetAttribute("EmoteAt", Workspace:GetServerTimeNow())
end

-------------------------------------------------------------------------------------------------
-- Bots press buttons through these (BotBrain): exactly the checks and results a player's request
-- gets, without the remote.
-------------------------------------------------------------------------------------------------

-- True if the dive was allowed (the bot's Bloblet then launches itself: BotMotor).
function ActionService.BotDive(bot: Player, direction: Vector3): boolean
	onRequestDive(bot, direction)
	local character = bot.Character
	return character ~= nil and character:GetAttribute("Action") == "Dive"
end

function ActionService.BotEndDive(bot: Player)
	onEndDive(bot)
end

-- Holding GRAB (true) or letting go (false).
function ActionService.BotGrab(bot: Player, held: boolean)
	if held then
		onRequestGrab(bot)
	else
		onRequestRelease(bot)
	end
end

function ActionService.BotKick(bot: Player)
	onRequestKick(bot)
end

function ActionService.Init()
	Remotes.Event("RequestDive").OnServerEvent:Connect(onRequestDive)
	Remotes.Event("RequestGrab").OnServerEvent:Connect(onRequestGrab)
	Remotes.Event("RequestRelease").OnServerEvent:Connect(onRequestRelease)
	Remotes.Event("EndDive").OnServerEvent:Connect(onEndDive)
	Remotes.Event("RequestKick").OnServerEvent:Connect(onRequestKick)
	Remotes.Event("RequestSlap").OnServerEvent:Connect(onRequestSlap)
	Remotes.Event("ReportKnockdown").OnServerEvent:Connect(onReportKnockdown)
	Remotes.Event("RequestEmote").OnServerEvent:Connect(onRequestEmote)

	Players.PlayerRemoving:Connect(ActionService.ReleaseInvolving)
	Bots.Removing:Connect(ActionService.ReleaseInvolving)
end

return ActionService
