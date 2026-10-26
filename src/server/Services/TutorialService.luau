--!strict
-- Runs the tutorial (Shared/Tutorial) on the tutorial island (TutorialBuilder).
--
-- New players are offered it once (TutorialOffered); anyone can start it again from the lobby
-- MENU. Starting puts you on the island's start pad. Each step is checked here: reaching the
-- step's zone (walk, jump, dive, bounce), or a grab / kick the server accepted next to the right
-- dummy (ActionService.Acted, or walking up to the grab dummy while holding GRAB). Fall off and you're put back at the start of the step. Finishing
-- pays Config.Tutorial.Reward Gumdrops the first time, then takes you back to the lobby. Leaving
-- (LEAVE, a Reset, walking away) or being pulled into a match ends it. Clients only ask to start,
-- leave or say "no thanks"; they see their step in the TutorialStep attribute.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local BlobletRig = require(Shared.BlobletRig)
local Config = require(Shared.Config)
local Match = require(Shared.Match)
local Remotes = require(Shared.Remotes)
local Tutorial = require(Shared.Tutorial)

local ActionService = require(script.Parent.ActionService)
local DataService = require(script.Parent.DataService)
local LobbyService = require(script.Parent.LobbyService)
local PlayerState = require(script.Parent.PlayerState)
local RateLimiter = require(script.Parent.Parent.Util.RateLimiter)
local TutorialBuilder = require(script.Parent.Parent.Builders.TutorialBuilder)

local TutorialService = {}

local TICK = 0.2
local FALL_DEPTH = 12 -- this far below the island's start pad counts as fallen off
local AREA_RADIUS = 170 -- further than this from the island's middle: you've left
local DUMMY_REACH = 9 -- a grab or kick this close to a dummy counts
local FINISHED_STAY = 4 -- seconds on the finish before going back to the lobby

local PlayerAttr = Match.PlayerAttr
local STEP_COUNT = #Tutorial.Steps

local course: TutorialBuilder.Course
local steps: { [Player]: number } = {} -- 1..STEP_COUNT, STEP_COUNT + 1 = finished
local limiter = RateLimiter.new(4, 2)

local function setStep(player: Player, step: number)
	if step <= 0 then
		steps[player] = nil
	else
		steps[player] = step
	end
	if player.Parent == Players then
		player:SetAttribute(PlayerAttr.TutorialStep, step)
	end
end

local function send(player: Player, kind: string, step: number, reward: number)
	Remotes.Event("TutorialEvent"):FireClient(player, kind, step, reward)
end

-- Moves a player's Bloblet to stand at `spot`, dropping its old momentum.
local function teleport(player: Player, spot: CFrame)
	local character = player.Character
	if not character or not character.PrimaryPart then
		return
	end
	PlayerState.GrantTeleportGrace(player)
	character:PivotTo(spot + Vector3.new(0, BlobletRig.Dimensions.RootHeight + 0.3, 0))
	character:SetAttribute("TeleportedAt", Workspace:GetServerTimeNow())
end

local function inZone(zone: TutorialBuilder.Zone, position: Vector3): boolean
	local localPoint = zone.CFrame:PointToObjectSpace(position)
	local half = zone.Size / 2
	return math.abs(localPoint.X) <= half.X and math.abs(localPoint.Y) <= half.Y and math.abs(localPoint.Z) <= half.Z
end

local function markOffered(player: Player)
	local profile = DataService.Get(player)
	if profile and not profile.TutorialOffered then
		DataService.Update(player, function(updated: DataService.Profile)
			updated.TutorialOffered = true
		end)
	end
end

local function leave(player: Player, toLobby: boolean)
	if not steps[player] then
		return
	end
	setStep(player, 0)
	if toLobby then
		teleport(player, LobbyService.GetSpawnCFrame())
	end
	send(player, "Left", 0, 0)
end

local function finish(player: Player)
	setStep(player, STEP_COUNT + 1)
	local reward = 0
	local profile = DataService.Get(player)
	if profile and not profile.TutorialDone then
		reward = Config.Tutorial.Reward
		DataService.Update(player, function(updated: DataService.Profile)
			updated.TutorialDone = true
			DataService.GiveGumdrops(updated, reward)
		end)
	end
	send(player, "Finished", STEP_COUNT + 1, reward)
	task.delay(FINISHED_STAY, function()
		if steps[player] == STEP_COUNT + 1 then
			leave(player, true)
		end
	end)
end

local function advance(player: Player)
	local step = steps[player]
	if not step or step > STEP_COUNT then
		return
	end
	if step == STEP_COUNT then
		finish(player)
		return
	end
	setStep(player, step + 1)
	send(player, "Step", step + 1, 0)
end

local function start(player: Player)
	if player:GetAttribute(PlayerAttr.Status) ~= "None" or player:GetAttribute(PlayerAttr.InMatch) == true then
		return -- in a match
	end
	markOffered(player)
	setStep(player, 1)
	teleport(player, course.Spots[1])
	send(player, "Started", 1, 0)
end

local function update(player: Player)
	local step = steps[player]
	if not step then
		return
	end
	if player:GetAttribute(PlayerAttr.Status) ~= "None" then
		setStep(player, 0) -- pulled into a match
		return
	end
	local character = player.Character
	local root = if character then character.PrimaryPart else nil
	if not root then
		return
	end
	local position = root.Position
	if (position - course.Center).Magnitude > AREA_RADIUS then
		leave(player, false) -- reset or wandered off
		return
	end
	if step > STEP_COUNT then
		return -- finished: waiting to go back
	end
	if position.Y < course.Spots[1].Position.Y - FALL_DEPTH then
		teleport(player, course.Spots[step])
		return
	end
	local zone = course.Zones[step]
	local reachedDummy = Tutorial.Steps[step].Action == "Grab"
		and ActionService.IsReaching(player) -- holding GRAB, and walked up to the dummy
		and (position - course.GrabDummy).Magnitude <= DUMMY_REACH
	if (zone and inZone(zone, position)) or reachedDummy then
		advance(player)
	end
end

-- Grabs and kicks next to the right dummy finish those steps.
local function onActed(player: Player, action: string)
	local step = steps[player]
	if not step or step > STEP_COUNT then
		return
	end
	local wanted = Tutorial.Steps[step].Action
	if action ~= wanted then
		return
	end
	local dummy = if wanted == "Grab" then course.GrabDummy elseif wanted == "Kick" then course.KickDummy else nil
	local character = player.Character
	local root = if character then character.PrimaryPart else nil
	if dummy and root and (root.Position - dummy).Magnitude <= DUMMY_REACH then
		advance(player)
	end
end

local function onRequest(player: Player, action: unknown)
	if not limiter:Allow(player) then
		return
	end
	if action == "Start" then
		if not steps[player] then
			start(player)
		end
	elseif action == "Leave" then
		leave(player, true)
	elseif action == "Decline" then
		markOffered(player)
	end
end

function TutorialService.Init()
	course = TutorialBuilder.Build(Workspace)
	Remotes.Event("RequestTutorial").OnServerEvent:Connect(onRequest)
	ActionService.Acted:Connect(onActed)
	local function onPlayerAdded(player: Player)
		player:SetAttribute(PlayerAttr.TutorialStep, 0)
	end
	Players.PlayerAdded:Connect(onPlayerAdded)
	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end
	Players.PlayerRemoving:Connect(function(player: Player)
		steps[player] = nil
	end)
	task.spawn(function()
		while true do
			task.wait(TICK)
			for player in table.clone(steps) do
				local ok, err = pcall(function(): any
					update(player)
					return nil
				end)
				if not ok then
					warn(`[TutorialService] {err}`)
				end
			end
		end
	end)
end

return TutorialService
