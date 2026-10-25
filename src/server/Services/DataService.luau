--!strict
-- Loads and saves each player's profile (Gumdrops, unlocked items, what they wear, stats) with
-- DataStoreService.
--
-- Keeping data safe:
--   * Retries: every DataStore call waits for request budget and is retried with growing pauses
--     (Config.Data.RetryDelays).
--   * Session locking: a saved profile records which server (JobId) has it open. If another server
--     loads it while that lock is fresh (say the player hopped servers and the old one is still
--     saving), it waits and tries again. Locks are refreshed on every autosave and released when
--     the player leaves, so the lock of a server that crashed expires after Config.Data.LockExpiry.
--   * A save never overwrites a profile that another server has taken over: that player is kicked
--     instead, so two servers can't both be changing their data.
--   * If a profile can't be loaded (DataStores down, a lock that won't clear, or Studio without
--     API access), the player gets a fresh profile for this session that is never saved, and the
--     UI tells them. In Studio that profile comes with plenty of Gumdrops for testing the shop.
--
-- Clients see their own profile through player attributes (Shared/Match PlayerAttr) and can only
-- change it through ShopService's validated remotes.

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage.Shared
local Config = require(Shared.Config)
local Cosmetics = require(Shared.Cosmetics)
local Match = require(Shared.Match)
local MathUtil = require(Shared.MathUtil)
local Signal = require(Shared.Signal)

export type Stats = {
	Matches: number,
	Wins: number,
	RoundsPlayed: number,
	RoundsQualified: number,
}

export type Profile = {
	Coins: number,
	Owned: { [string]: boolean }, -- bought items (free items aren't listed)
	Equipped: Cosmetics.Equipped,
	Stats: Stats,
}

export type StatName = "Matches" | "Wins" | "RoundsPlayed" | "RoundsQualified"

type Session = {
	Profile: Profile,
	Saving: boolean, -- false: a temporary profile that is never written
}

local DataService = {}

DataService.Loaded = Signal.new() :: Signal.Signal<Player> -- the player's profile is ready

local DATA_VERSION = 1
local STUDIO_TEST_COINS = 5000
local SHUTDOWN_WAIT = 25
local PlayerAttr = Match.PlayerAttr

local rules = Config.Data
local store: DataStore? = nil
local storeDisabled = false
local sessions: { [Player]: Session } = {}

local function keyFor(player: Player): string
	return `Player_{player.UserId}`
end

local function newStats(): Stats
	return { Matches = 0, Wins = 0, RoundsPlayed = 0, RoundsQualified = 0 }
end

local function newProfile(): Profile
	local equipped = table.clone(Cosmetics.Defaults)
	local free = Cosmetics.FreeColors()
	if #free > 0 then
		equipped.Color = free[math.random(#free)].Id -- everyone starts a different colour
	end
	return { Coins = Config.Economy.StartingCoins, Owned = {}, Equipped = equipped, Stats = newStats() }
end

local function owns(profile: Profile, itemId: string): boolean
	local entry = Cosmetics.Get(itemId)
	return entry ~= nil and (entry.Price == 0 or profile.Owned[itemId] == true)
end

local function wholeNumber(value: unknown): number?
	if typeof(value) ~= "number" or not MathUtil.isFiniteNumber(value) then
		return nil
	end
	return math.max(0, math.floor(value))
end

-- Turns whatever is stored (possibly old or damaged) into a valid profile.
local function sanitize(raw: unknown): Profile
	local profile = newProfile()
	if typeof(raw) ~= "table" then
		return profile
	end
	local data = raw :: any
	profile.Coins = math.min(wholeNumber(data.Coins) or profile.Coins, Config.Economy.MaxCoins)
	if typeof(data.Owned) == "table" then
		for _, id in data.Owned do
			if typeof(id) == "string" and Cosmetics.Get(id) then
				profile.Owned[id] = true
			end
		end
	end
	if typeof(data.Equipped) == "table" then
		for _, slot in Cosmetics.AllSlots() do
			local id = data.Equipped[slot]
			local entry = if typeof(id) == "string" then Cosmetics.Get(id) else nil
			if entry and entry.Slot == slot and owns(profile, entry.Id) then
				Cosmetics.SetSlot(profile.Equipped, slot, entry.Id)
			end
		end
	end
	if typeof(data.Stats) == "table" then
		for name in profile.Stats do
			local value = wholeNumber(data.Stats[name])
			if value then
				(profile.Stats :: any)[name] = value
			end
		end
	end
	return profile
end

-- The plain table written to the DataStore (without the session lock).
local function serialize(profile: Profile): { [string]: any }
	local owned: { string } = {}
	for id in profile.Owned do
		table.insert(owned, id)
	end
	table.sort(owned)
	return {
		Version = DATA_VERSION,
		Coins = profile.Coins,
		Owned = owned,
		Equipped = table.clone(profile.Equipped),
		Stats = table.clone(profile.Stats),
	}
end

local function disableStore(reason: string)
	if storeDisabled then
		return
	end
	storeDisabled = true
	if RunService:IsStudio() then
		warn(
			"[DataService] Data won't save in this Studio session: publish the place and turn on "
				.. "Game Settings > Security > Enable Studio Access to API Services. ("
				.. reason
				.. ")"
		)
	else
		warn(`[DataService] DataStores unavailable, data won't save: {reason}`)
	end
end

local function getStore(): DataStore?
	if storeDisabled then
		return nil
	end
	local existing = store
	if existing then
		return existing
	end
	local ok, result = pcall(function(): DataStore
		return DataStoreService:GetDataStore(rules.StoreName)
	end)
	if not ok then
		disableStore(tostring(result))
		return nil
	end
	store = result
	return result
end

-- Errors that retrying won't fix (Studio without API access, an unpublished place).
local function isPermanent(message: string): boolean
	return string.find(message, "StudioAccessToApisNotAllowed", 1, true) ~= nil
		or string.find(message, "API Services", 1, true) ~= nil
		or string.find(message, "publish", 1, true) ~= nil
end

local function waitForBudget()
	local deadline = os.clock() + 10
	while
		DataStoreService:GetRequestBudgetForRequestType(Enum.DataStoreRequestType.UpdateAsync) <= 0
		and os.clock() < deadline
	do
		task.wait(1)
	end
end

-- Runs a DataStore call, retrying with growing pauses. Returns whether it succeeded.
local function withRetries(label: string, callback: () -> ()): boolean
	local delays = rules.RetryDelays
	for attempt = 1, #delays + 1 do
		if storeDisabled then
			return false
		end
		waitForBudget()
		local ok, err = pcall(function(): any
			callback()
			return nil
		end)
		if ok then
			return true
		end
		local message = tostring(err)
		if isPermanent(message) then
			disableStore(message)
			return false
		end
		warn(`[DataService] {label} failed (try {attempt}): {message}`)
		local pause = delays[attempt]
		if pause then
			task.wait(pause)
		end
	end
	return false
end

-- Loads a profile and takes its session lock. Returns nil if it couldn't (see the header).
local function loadProfile(player: Player): Profile?
	local dataStore = getStore()
	if not dataStore then
		return nil
	end
	local key = keyFor(player)
	for attempt = 1, rules.LockWaitAttempts do
		local loaded: Profile? = nil
		local lockedElsewhere = false
		local ok = withRetries(`Loading {player.Name}`, function()
			loaded = nil
			lockedElsewhere = false
			dataStore:UpdateAsync(key, function(current: any): any
				local now = os.time()
				local lock = if typeof(current) == "table" then current.Session else nil
				if
					typeof(lock) == "table"
					and lock.JobId ~= game.JobId
					and typeof(lock.Time) == "number"
					and now - lock.Time < rules.LockExpiry
				then
					lockedElsewhere = true
					return nil -- leave it alone
				end
				local profile = sanitize(current)
				loaded = profile
				local out = serialize(profile)
				out.Session = { JobId = game.JobId, Time = now }
				return out
			end)
		end)
		if not ok then
			return nil
		end
		if loaded then
			return loaded
		end
		if not lockedElsewhere or player.Parent ~= Players then
			return nil
		end
		if attempt < rules.LockWaitAttempts then
			task.wait(rules.LockWaitDelay)
		end
	end
	warn(`[DataService] {player.Name}'s data is still open on another server; not saving this session`)
	return nil
end

-- Writes a profile. `release` gives up the session lock (the player is leaving).
local function saveSession(player: Player, session: Session, release: boolean): boolean
	if not session.Saving then
		return true
	end
	local dataStore = getStore()
	if not dataStore then
		return false
	end
	local snapshot = serialize(session.Profile)
	local takenOver = false
	local ok = withRetries(`Saving {player.Name}`, function()
		takenOver = false
		dataStore:UpdateAsync(keyFor(player), function(current: any): any
			local lock = if typeof(current) == "table" then current.Session else nil
			if typeof(lock) == "table" and lock.JobId ~= game.JobId then
				takenOver = true
				return nil -- another server owns it now: don't overwrite their changes
			end
			local out = table.clone(snapshot)
			out.Session = if release then nil else { JobId = game.JobId, Time = os.time() }
			return out
		end)
	end)
	if takenOver then
		session.Saving = false
		warn(`[DataService] {player.Name}'s data was opened by another server; stopped saving here`)
		if player.Parent == Players and not release then
			player:Kick("Your Wobble Rush data was opened on another server. Please rejoin.")
		end
		return false
	end
	return ok
end

-- Mirrors the profile into player attributes for the player's own UI.
local function publish(player: Player, session: Session)
	local profile = session.Profile
	local owned: { string } = {}
	for id in profile.Owned do
		table.insert(owned, id)
	end
	player:SetAttribute(PlayerAttr.Coins, profile.Coins)
	player:SetAttribute(PlayerAttr.Owned, HttpService:JSONEncode(owned))
	player:SetAttribute(PlayerAttr.Equipped, HttpService:JSONEncode(profile.Equipped))
	player:SetAttribute(PlayerAttr.Stats, HttpService:JSONEncode(profile.Stats))
	player:SetAttribute(PlayerAttr.DataSaving, session.Saving)
	player:SetAttribute(PlayerAttr.DataReady, true)
end

local function onPlayerAdded(player: Player)
	player:SetAttribute(PlayerAttr.DataReady, false)
	local loaded = loadProfile(player)
	local profile: Profile
	if loaded then
		profile = loaded
	else
		profile = newProfile()
		if RunService:IsStudio() then
			profile.Coins = STUDIO_TEST_COINS -- try the shop without playing for hours
		end
	end
	local session: Session = { Profile = profile, Saving = loaded ~= nil }
	if player.Parent ~= Players then
		-- Left while we were loading: give the lock back.
		saveSession(player, session, true)
		return
	end
	sessions[player] = session
	publish(player, session)
	DataService.Loaded:Fire(player)
end

local function onPlayerRemoving(player: Player)
	local session = sessions[player]
	if not session then
		return
	end
	saveSession(player, session, true)
	sessions[player] = nil
end

-- The player's profile, or nil while it's loading. Treat it as read-only; change it with Update.
function DataService.Get(player: Player): Profile?
	local session = sessions[player]
	return if session then session.Profile else nil
end

function DataService.Owns(profile: Profile, itemId: string): boolean
	return owns(profile, itemId)
end

-- Changes a loaded profile. Saved on the next autosave or when the player leaves.
function DataService.Update(player: Player, mutate: (profile: Profile) -> ()): boolean
	local session = sessions[player]
	if not session then
		return false
	end
	mutate(session.Profile)
	publish(player, session)
	return true
end

function DataService.AddCoins(player: Player, amount: number)
	if amount <= 0 or not MathUtil.isFiniteNumber(amount) then
		return
	end
	DataService.Update(player, function(profile: Profile)
		profile.Coins = math.min(profile.Coins + math.floor(amount), Config.Economy.MaxCoins)
	end)
end

function DataService.AddStat(player: Player, stat: StatName, amount: number)
	DataService.Update(player, function(profile: Profile)
		profile.Stats[stat] += amount
	end)
end

function DataService.Init()
	Players.PlayerAdded:Connect(onPlayerAdded)
	for _, player in Players:GetPlayers() do
		task.spawn(onPlayerAdded, player)
	end
	Players.PlayerRemoving:Connect(onPlayerRemoving)

	-- Autosave (also keeps every session lock fresh). One UpdateAsync per player per interval.
	task.spawn(function()
		while true do
			task.wait(rules.AutosaveInterval)
			for player, session in sessions do
				if session.Saving and player.Parent == Players then
					task.spawn(saveSession, player, session, false)
				end
			end
		end
	end)

	-- Server shutting down: save everyone and release their locks before it goes.
	game:BindToClose(function()
		local pending = 0
		for player, session in sessions do
			pending += 1
			task.spawn(function()
				saveSession(player, session, true)
				pending -= 1
			end)
		end
		local deadline = os.clock() + SHUTDOWN_WAIT
		while pending > 0 and os.clock() < deadline do
			task.wait(0.2)
		end
	end)
end

return DataService
