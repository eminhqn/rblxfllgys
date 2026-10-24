--!strict
-- Server authority for dive, grab and ragdoll.
--
-- The owning client plays an action instantly (prediction) and sends a request. The server checks
-- cooldowns and state, decides the outcome (for a grab: who, if anyone, gets grabbed) and publishes
-- the result as character attributes that every client animates from. Invalid requests are
-- rejected, and the client cancels its prediction.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Config = require(Shared.Config)
local MathUtil = require(Shared.MathUtil)
local Remotes = require(Shared.Remotes)

local PlayerState = require(script.Parent.PlayerState)
local RateLimiter = require(script.Parent.Parent.Util.RateLimiter)

local ActionService = {}

-- Clients may run slightly ahead of the server clock; accept requests a little early.
local COOLDOWN_TOLERANCE = 0.8
local GRAB_CHECK_INTERVAL = 0.2

local diveLimiter = RateLimiter.new(3, 2)
local grabLimiter = RateLimiter.new(4, 4)
local releaseLimiter = RateLimiter.new(6, 6)
local knockdownLimiter = RateLimiter.new(3, 2)

local activeGrabs: { [Player]: Player } = {} -- grabber -> victim
local grabWatcherRunning = false

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

local function reject(player: Player, action: string)
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

local function findGrabTarget(grabber: Player, root: BasePart): Player?
	local look = MathUtil.flat(root.CFrame.LookVector)
	look = if look.Magnitude > 1e-3 then look.Unit else Vector3.zAxis
	local maxDistance = Config.Grab.Range + Config.Grab.RangeSlack

	local best: Player? = nil
	local bestDistance = math.huge
	for _, other in Players:GetPlayers() do
		if other == grabber then
			continue
		end
		local character, otherRoot = getCharacter(other)
		if not character or not otherRoot then
			continue
		end
		if character:GetAttribute("GrabbedBy") ~= 0 then
			continue
		end
		local offset = otherRoot.Position - root.Position
		local distance = offset.Magnitude
		if distance > maxDistance or distance >= bestDistance then
			continue
		end
		local flatOffset = MathUtil.flat(offset)
		if flatOffset.Magnitude > 0.5 and flatOffset.Unit:Dot(look) < Config.Grab.FrontDot then
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
	if not character then
		return
	end
	local duration = Config.RagdollDuration(strength)
	setRagdolled(player, character, duration)
	Remotes.Event("ApplyRagdoll"):FireClient(player, impulse, duration)
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
		character:GetAttribute("Ragdolled") == true
		or character:GetAttribute("Action") == "Dive"
		or activeGrabs[player]
		or now - state.LastGrab < Config.Grab.Cooldown * COOLDOWN_TOLERANCE
	then
		reject(player, "Grab")
		return
	end
	state.LastGrab = now

	local victim = findGrabTarget(player, root)
	local victimCharacter = if victim then victim.Character else nil
	if not victim or not victimCharacter then
		-- A whiff: others still see the reach.
		setAction(player, character, "Grab", Config.Grab.PoseTime)
		return
	end

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
end

local function onRequestRelease(player: Player)
	if not releaseLimiter:Allow(player) then
		return
	end
	if activeGrabs[player] then
		release(player)
	else
		local character = player.Character
		if character and character:GetAttribute("Action") == "Grab" then
			clearAction(player, character)
		end
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

function ActionService.Init()
	Remotes.Event("RequestDive").OnServerEvent:Connect(onRequestDive)
	Remotes.Event("RequestGrab").OnServerEvent:Connect(onRequestGrab)
	Remotes.Event("RequestRelease").OnServerEvent:Connect(onRequestRelease)
	Remotes.Event("ReportKnockdown").OnServerEvent:Connect(onReportKnockdown)

	Players.PlayerRemoving:Connect(ActionService.ReleaseInvolving)
end

return ActionService
