--!strict
-- Runs the parkour tower in the lobby playground (built by PlaygroundBuilder).
--
-- Standing on the start pad gets you ready; the clock starts when you step off it. Checkpoints
-- count in order, and falling well below your last one puts you back on it (so does Reset).
-- Leaving the tower's area, quitting (the QUIT button) or joining a match ends the run. Reaching
-- the top after every checkpoint finishes it: your first finish ever pays
-- Config.Parkour.FirstFinishGumdrops, every finish can set a new best time (ever, and today), and
-- it goes on the FASTEST TODAY board (ParkourBoardService).
--
-- Clients own their Bloblet's physics, so progress is checked like a race's: a checkpoint only
-- counts if you could have got there from where you were a moment ago, and a finish faster than
-- Config.Parkour.MinTime isn't believed. Clients see the run through the ParkourStage and
-- ParkourStartedAt attributes (Shared/Match) and get ParkourFinished when they finish.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local BlobletRig = require(Shared.BlobletRig)
local Config = require(Shared.Config)
local Match = require(Shared.Match)
local MathUtil = require(Shared.MathUtil)
local Remotes = require(Shared.Remotes)

local CharacterService = require(script.Parent.CharacterService)
local DataService = require(script.Parent.DataService)
local LobbyService = require(script.Parent.LobbyService)
local ParkourBoardService = require(script.Parent.ParkourBoardService)
local PlayerState = require(script.Parent.PlayerState)
local PlaygroundBuilder = require(script.Parent.Parent.Builders.PlaygroundBuilder)
local RateLimiter = require(script.Parent.Parent.Util.RateLimiter)

local ParkourService = {}

type Zone = PlaygroundBuilder.Zone

type Run = {
	Stage: number, -- -1 = not running, 0 = started, n = reached checkpoint n
	StartedAt: number, -- server time the clock started, 0 = waiting on the start pad
	OnStart: boolean,
	SampleTime: number,
	SamplePosition: Vector3?,
	TeleportedAt: number,
}

local TICK = 0.2
local TELEPORT_SETTLE = 1.0 -- positions after a teleport aren't trusted for this long
local SPEED_SLACK = 1.2
local DISTANCE_SLACK = 15

local PlayerAttr = Match.PlayerAttr
local rules = Config.Parkour

local course: PlaygroundBuilder.ParkourCourse
local runs: { [Player]: Run } = {}
local quitLimiter = RateLimiter.new(3, 1)

local function serverNow(): number
	return Workspace:GetServerTimeNow()
end

local function inZone(zone: Zone, position: Vector3): boolean
	local localPoint = zone.CFrame:PointToObjectSpace(position)
	local half = zone.Size / 2
	return math.abs(localPoint.X) <= half.X and math.abs(localPoint.Y) <= half.Y and math.abs(localPoint.Z) <= half.Z
end

local function inArea(position: Vector3): boolean
	local localPoint = course.AreaCFrame:PointToObjectSpace(position)
	local half = course.AreaSize / 2
	return math.abs(localPoint.X) <= half.X and math.abs(localPoint.Y) <= half.Y and math.abs(localPoint.Z) <= half.Z
end

local function getRun(player: Player): Run
	local run = runs[player]
	if not run then
		run = {
			Stage = -1,
			StartedAt = 0,
			OnStart = false,
			SampleTime = 0,
			SamplePosition = nil,
			TeleportedAt = 0,
		}
		runs[player] = run
	end
	return run
end

local function publish(player: Player, run: Run)
	if player.Parent == Players then
		player:SetAttribute(PlayerAttr.ParkourStage, run.Stage)
		player:SetAttribute(PlayerAttr.ParkourStartedAt, run.StartedAt)
	end
end

local function stop(player: Player, run: Run)
	if run.Stage == -1 and run.StartedAt == 0 then
		return
	end
	run.Stage = -1
	run.StartedAt = 0
	run.OnStart = false
	run.SamplePosition = nil
	publish(player, run)
end

-- Puts the player back on a checkpoint.
local function teleport(player: Player, run: Run, zone: Zone)
	local character = player.Character
	local root = if character then character.PrimaryPart else nil
	if not character or not root then
		return
	end
	PlayerState.GrantTeleportGrace(player)
	character:PivotTo(zone.Spot + Vector3.new(0, BlobletRig.Dimensions.RootHeight + 0.3, 0))
	-- Tells the owner's client to drop its old momentum and stand up.
	character:SetAttribute("TeleportedAt", serverNow())
	run.TeleportedAt = os.clock()
	run.SamplePosition = nil
end

-- Could they really have got here from where they were a moment ago?
local function plausible(player: Player, run: Run, position: Vector3, now: number): boolean
	local last = run.SamplePosition
	if not last then
		return true
	end
	local allowed = Config.Validation.MaxHorizontalSpeed * SPEED_SLACK * (now - run.SampleTime) + DISTANCE_SLACK
	local distance = MathUtil.flat(position - last).Magnitude
	if distance <= allowed then
		return true
	end
	warn(`[ParkourService] {player.Name} moved {math.floor(distance)} studs too quickly`)
	return false
end

local function finish(player: Player, run: Run)
	local seconds = serverNow() - run.StartedAt
	stop(player, run)
	if seconds < rules.MinTime then
		warn(`[ParkourService] {player.Name} finished in {string.format("%.1f", seconds)} s; not counted`)
		return
	end
	local reward = 0
	local best = seconds
	local todayBest = seconds
	local today = ParkourBoardService.Today()
	DataService.Update(player, function(profile: DataService.Profile)
		if not profile.ParkourDone then
			profile.ParkourDone = true
			reward = rules.FirstFinishGumdrops
			DataService.GiveGumdrops(profile, reward)
		end
		if profile.ParkourBest <= 0 or seconds < profile.ParkourBest then
			profile.ParkourBest = seconds
		end
		if profile.ParkourDay ~= today or profile.ParkourDayBest <= 0 or seconds < profile.ParkourDayBest then
			profile.ParkourDay = today
			profile.ParkourDayBest = seconds
		end
		best = profile.ParkourBest
		todayBest = profile.ParkourDayBest
	end)
	Remotes.Event("ParkourFinished"):FireClient(player, seconds, reward, best, todayBest)
	ParkourBoardService.Submit(player, seconds)
end

local function update(player: Player, now: number)
	local run = getRun(player)
	local character = player.Character
	local root = if character then character.PrimaryPart else nil
	local inLobby = player:GetAttribute(PlayerAttr.Status) == "None"
	if not root or not inLobby then
		stop(player, run)
		return
	end
	local position = root.Position

	-- On the start pad: ready to go, and the clock starts as you step off.
	if inZone(course.Start, position) then
		if run.Stage ~= 0 or run.StartedAt ~= 0 then
			run.Stage = 0
			run.StartedAt = 0
			publish(player, run)
		end
		run.OnStart = true
		run.SamplePosition = position
		run.SampleTime = now
		return
	end
	if run.OnStart then
		run.OnStart = false
		if run.Stage == 0 then
			run.StartedAt = serverNow()
			publish(player, run)
		end
	end
	if run.Stage < 0 or run.StartedAt == 0 then
		return
	end
	if not inArea(position) then
		stop(player, run) -- wandered off
		return
	end
	if now - run.TeleportedAt < TELEPORT_SETTLE then
		run.SamplePosition = position
		run.SampleTime = now
		return
	end

	local checkpoints = course.Checkpoints
	if run.Stage >= #checkpoints and inZone(course.Finish, position) then
		if plausible(player, run, position, now) then
			finish(player, run)
		else
			stop(player, run)
		end
		return
	end
	local nextZone = checkpoints[run.Stage + 1]
	if nextZone and inZone(nextZone, position) then
		if plausible(player, run, position, now) then
			run.Stage += 1
			publish(player, run)
		else
			stop(player, run)
			return
		end
	end
	local reached = checkpoints[run.Stage]
	if reached and position.Y < reached.FloorY - rules.FallDrop then
		teleport(player, run, reached)
		return
	end
	run.SamplePosition = position
	run.SampleTime = now
end

-- Reset in the lobby during a run: back to your checkpoint instead of the decks.
local function onLobbyReset(player: Player): boolean
	local run = runs[player]
	local reached = if run and run.StartedAt ~= 0 then course.Checkpoints[run.Stage] else nil
	if not run or not reached then
		return false
	end
	teleport(player, run, reached)
	return true
end

function ParkourService.Init()
	course = LobbyService.GetParkour()
	Match.GetFolder():SetAttribute(Match.Attr.ParkourCheckpoints, #course.Checkpoints)
	local function onPlayerAdded(player: Player)
		publish(player, getRun(player))
	end
	Players.PlayerAdded:Connect(onPlayerAdded)
	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end
	Players.PlayerRemoving:Connect(function(player: Player)
		runs[player] = nil
	end)
	CharacterService.SetLobbyResetHandler(onLobbyReset)
	Remotes.Event("RequestParkour").OnServerEvent:Connect(function(player: Player, action: unknown)
		if quitLimiter:Allow(player) and action == "Quit" then
			stop(player, getRun(player))
		end
	end)
	task.spawn(function()
		while true do
			task.wait(TICK)
			local now = os.clock()
			for _, player in Players:GetPlayers() do
				local ok, err = pcall(function(): any
					update(player, now)
					return nil
				end)
				if not ok then
					warn(`[ParkourService] {err}`)
				end
			end
		end
	end)
end

return ParkourService
