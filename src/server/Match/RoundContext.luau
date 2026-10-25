--!strict
-- Builds the RoundContext a mini-game works with, plus the controls the round manager uses
-- (freeze/release players, end-of-round checks, the live counter).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local BlobletRig = require(ReplicatedStorage.Shared.BlobletRig)

local Services = script.Parent.Parent.Services
local CharacterService = require(Services.CharacterService)
local PlayerState = require(Services.PlayerState)
local Types = require(script.Parent.Types)

export type Hooks = {
	OnQualified: (player: Player) -> (),
	OnEliminated: (player: Player) -> (),
	OnChanged: () -> (), -- someone qualified, was eliminated or left
}

export type Control = {
	Context: Types.RoundContext,
	SetStarted: (serverTime: number) -> (),
	ReleaseAll: () -> (), -- unfreeze everyone still in the round
	FreezeAll: () -> (),
	IsDone: () -> boolean, -- the round's natural end condition has been reached
	GetCounterText: () -> string,
	RemovePlayer: (player: Player) -> (), -- they left the game
	HandleReset: (player: Player) -> (), -- they pressed reset
}

type FallenEntry = {
	Player: Player,
	Height: number,
}

local SPAWN_STREAM_TIMEOUT = 2
local SPAWN_WAIT_LIMIT = 3

local RoundContext = {}

function RoundContext.new(
	info: Types.MiniGameInfo,
	players: { Player },
	qualifyTarget: number,
	arena: Model,
	origin: CFrame,
	hooks: Hooks
): Control
	local inRound: { [Player]: boolean } = {}
	for _, player in players do
		inRound[player] = true
	end
	local qualified: { [Player]: boolean } = {}
	local eliminated: { [Player]: boolean } = {}
	local eliminationOrder: { Player } = {}
	local startCount = #players
	local startTime = 0
	local resetHandler: ((player: Player) -> ())? = nil

	local function getRoot(player: Player): BasePart?
		local character = player.Character
		local root = if character then character.PrimaryPart else nil
		return if root and root.Parent then root else nil
	end

	local function isAlive(player: Player): boolean
		return inRound[player] == true and not eliminated[player] and player.Parent == Players
	end

	local function getAlive(): { Player }
		local alive: { Player } = {}
		for _, player in players do
			if isAlive(player) then
				table.insert(alive, player)
			end
		end
		return alive
	end

	local function qualify(player: Player)
		if not isAlive(player) or qualified[player] then
			return
		end
		qualified[player] = true
		hooks.OnQualified(player)
		hooks.OnChanged()
	end

	local function eliminate(player: Player)
		if not isAlive(player) then
			return
		end
		eliminated[player] = true
		qualified[player] = nil
		table.insert(eliminationOrder, player)
		hooks.OnEliminated(player)
		hooks.OnChanged()
	end

	local function eliminateBelow(height: number)
		local alive = getAlive()
		local fallen: { FallenEntry } = {}
		for _, player in alive do
			if qualified[player] then
				continue -- finishers are safe
			end
			local root = getRoot(player)
			local y = if root then root.Position.Y else -math.huge
			if y < height then
				table.insert(fallen, { Player = player, Height = y })
			end
		end
		if #fallen == 0 then
			return
		end
		if info.Type == "Final" and startCount >= 2 and #fallen == #alive then
			-- Everyone left went over at once: whoever is highest was the last one on.
			table.sort(fallen, function(a: FallenEntry, b: FallenEntry)
				return a.Height > b.Height
			end)
			table.remove(fallen, 1)
		end
		for _, entry in fallen do
			eliminate(entry.Player)
		end
	end

	local function spawnAt(player: Player, groundCFrame: CFrame)
		if not inRound[player] or player.Parent ~= Players then
			return
		end
		local character = player.Character
		if not character or not character.Parent or not character.PrimaryPart then
			CharacterService.Spawn(player)
			character = player.Character
		end
		local root = if character then character.PrimaryPart else nil
		if not character or not root then
			return
		end
		PlayerState.GrantTeleportGrace(player)
		root.Anchored = startTime == 0 -- frozen until the round starts
		character:PivotTo(groundCFrame + Vector3.new(0, BlobletRig.Dimensions.RootHeight + 0.3, 0))
		-- Tells the owner's client to drop its old momentum, stand up and turn the camera round.
		character:SetAttribute("TeleportedAt", Workspace:GetServerTimeNow())
		if startTime ~= 0 then
			pcall(function()
				root:SetNetworkOwner(player)
			end)
		end
	end

	local function spawnAll(spots: { CFrame })
		if #spots == 0 then
			warn(`[RoundContext] {info.Id} gave SpawnAll no spots`)
			return
		end
		local pending = 0
		for index, player in players do
			if not isAlive(player) then
				continue
			end
			local spot = spots[(index - 1) % #spots + 1]
			pending += 1
			task.spawn(function()
				-- Load the arena around the spot first so nobody lands in unloaded space.
				pcall(function()
					player:RequestStreamAroundAsync(spot.Position, SPAWN_STREAM_TIMEOUT)
				end)
				spawnAt(player, spot)
				pending -= 1
			end)
		end
		local deadline = os.clock() + SPAWN_WAIT_LIMIT
		while pending > 0 and os.clock() < deadline do
			task.wait()
		end
	end

	local function highestOf(list: { Player }): Player?
		local best: Player? = nil
		local bestHeight = -math.huge
		for _, player in list do
			local root = getRoot(player)
			local height = if root then root.Position.Y else -math.huge
			if height > bestHeight then
				best = player
				bestHeight = height
			end
		end
		return best
	end

	local function qualifiedAlive(): { Player }
		local list: { Player } = {}
		for _, player in getAlive() do
			if qualified[player] then
				table.insert(list, player)
			end
		end
		return list
	end

	local function defaultQualified(): { Player }
		local alive = getAlive()
		if info.Type == "Race" then
			return qualifiedAlive()
		elseif info.Type == "Survival" then
			-- If enough players already qualified early (e.g. reached a goal), only they go through.
			local safe = qualifiedAlive()
			if info.QualifyByGoalOnly or (#safe > 0 and #safe >= qualifyTarget) then
				return safe
			end
			return alive
		elseif info.Type == "Final" then
			if #alive >= 1 then
				-- Usually one player; if time ran out with several, the highest one wins.
				local winner = highestOf(alive)
				return if winner then { winner } else {}
			end
			for index = #eliminationOrder, 1, -1 do
				local player = eliminationOrder[index]
				if player.Parent == Players then
					return { player }
				end
			end
			return {}
		end
		return alive
	end

	local context: Types.RoundContext = {
		Info = info,
		Players = table.clone(players),
		QualifyTarget = qualifyTarget,
		Arena = arena,
		Origin = origin,
		Teams = nil,
		Random = Random.new(),

		IsAlive = isAlive,
		IsQualified = function(player: Player): boolean
			return qualified[player] == true
		end,
		GetAlive = getAlive,
		GetRoot = getRoot,
		GetServerTime = function(): number
			return Workspace:GetServerTimeNow()
		end,
		GetStartTime = function(): number
			return startTime
		end,

		Qualify = qualify,
		Eliminate = eliminate,
		EliminateBelow = eliminateBelow,
		SpawnAt = spawnAt,
		SpawnAll = spawnAll,
		OnResetRequested = function(handler: (player: Player) -> ())
			resetHandler = handler
		end,
		DefaultQualified = defaultQualified,
	}

	local function setAnchored(anchored: boolean)
		for _, player in getAlive() do
			local root = getRoot(player)
			if root then
				root.Anchored = anchored
				if not anchored then
					pcall(function()
						root:SetNetworkOwner(player)
					end)
				end
			end
		end
	end

	local function isDone(): boolean
		local alive = getAlive()
		if #alive == 0 then
			return true
		end
		local finished = #qualifiedAlive()
		if info.Type == "Race" then
			return finished >= qualifyTarget or finished >= #alive
		elseif info.Type == "Survival" then
			if finished > 0 and finished >= qualifyTarget then
				return true -- every spot has been taken early
			end
			if info.QualifyByGoalOnly then
				return finished >= #alive -- everyone still in has reached the goal
			end
			return startCount > qualifyTarget and #alive <= qualifyTarget
		elseif info.Type == "Final" then
			return startCount >= 2 and #alive <= 1
		end
		return false -- Team rounds end on their own or on time
	end

	local function getCounterText(): string
		local alive = getAlive()
		local finished = #qualifiedAlive()
		if info.Type == "Race" then
			return `QUALIFIED {finished} / {qualifyTarget}`
		elseif info.Type == "Survival" then
			if finished > 0 or info.QualifyByGoalOnly then
				return `QUALIFIED {finished} / {qualifyTarget} · {#alive} LEFT`
			end
			return `{#alive} LEFT · TOP {qualifyTarget} QUALIFY`
		end
		return `{#alive} LEFT`
	end

	return {
		Context = context,
		SetStarted = function(serverTime: number)
			startTime = serverTime
		end,
		ReleaseAll = function()
			setAnchored(false)
		end,
		FreezeAll = function()
			setAnchored(true)
		end,
		IsDone = isDone,
		GetCounterText = getCounterText,
		RemovePlayer = function(player: Player)
			if inRound[player] then
				inRound[player] = nil
				hooks.OnChanged()
			end
		end,
		HandleReset = function(player: Player)
			local handler = resetHandler
			if handler and isAlive(player) then
				handler(player)
			end
		end,
	}
end

return RoundContext
