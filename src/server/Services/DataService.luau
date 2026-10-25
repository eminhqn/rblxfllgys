--!strict
-- Loads and saves each player's profile (Crowns, Gumdrops, unlocked items, what they wear, stats,
-- XP and reward track progress, settings, daily challenges and the lobby parkour) with
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
--     UI tells them. In Studio that profile comes with plenty of Crowns and Gumdrops for testing.
--
-- Clients see their own profile through player attributes (Shared/Match PlayerAttr) and can only
-- change it through ShopService's validated remotes.

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage.Shared
local Challenges = require(Shared.Challenges)
local Config = require(Shared.Config)
local Cosmetics = require(Shared.Cosmetics)
local Match = require(Shared.Match)
local MathUtil = require(Shared.MathUtil)
local PlayerSettings = require(Shared.PlayerSettings)
local Signal = require(Shared.Signal)

export type Stats = {
	Matches: number,
	Wins: number,
	RoundsPlayed: number,
	RoundsQualified: number,
	GumdropsEarned: number, -- every Gumdrop ever received (spending doesn't lower it)
	TimeSurvived: number, -- seconds spent still in survival rounds and finals
}

-- Today's daily challenges (Shared/Challenges). Day 0 = not picked yet.
export type Daily = {
	Day: number,
	Challenges: { Challenges.Progress },
}

export type Profile = {
	Crowns: number, -- spent on items
	Gumdrops: number, -- earned by playing; 500 trade for a Crown
	Owned: { [string]: boolean }, -- bought items (free items aren't listed)
	Equipped: Cosmetics.Equipped,
	Stats: Stats,
	Settings: PlayerSettings.Settings,
	Daily: Daily,
	XP: number, -- total XP; the level comes from it (Shared/Progression)
	TrackClaimed: number, -- the highest level whose reward track reward has been paid out
	ParkourDone: boolean, -- has finished the lobby parkour (its Gumdrops are paid once)
	ParkourBest: number, -- best parkour time in seconds, 0 = never finished
	ParkourDay: number, -- the day ParkourDayBest was set (Challenges.DayNumber)
	ParkourDayBest: number, -- best parkour time that day in seconds, 0 = none
	ParkourPrizeDays: { number }, -- days whose fastest-of-the-day prize has been paid (recent ones)
}

export type StatName = "Matches" | "Wins" | "RoundsPlayed" | "RoundsQualified" | "GumdropsEarned" | "TimeSurvived"

type Session = {
	Profile: Profile,
	Saving: boolean, -- false: a temporary profile that is never written
}

local DataService = {}

DataService.Loaded = Signal.new() :: Signal.Signal<Player> -- the player's profile is ready

local DATA_VERSION = 1
local STUDIO_TEST_CROWNS = 20
local STUDIO_TEST_GUMDROPS = 5000
local MAX_PRIZE_DAYS = 30 -- ParkourPrizeDays only needs to cover Config.Parkour.PrizeDays
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
	return {
		Matches = 0,
		Wins = 0,
		RoundsPlayed = 0,
		RoundsQualified = 0,
		GumdropsEarned = 0,
		TimeSurvived = 0,
	}
end

local function newProfile(): Profile
	local equipped = table.clone(Cosmetics.Defaults)
	local free = Cosmetics.FreeColors()
	if #free > 0 then
		equipped.Color = free[math.random(#free)].Id -- everyone starts a different colour
	end
	local economy = Config.Economy
	return {
		Crowns = economy.StartingCrowns,
		Gumdrops = economy.StartingGumdrops,
		Owned = {},
		Equipped = equipped,
		Stats = newStats(),
		Settings = table.clone(PlayerSettings.Defaults),
		Daily = { Day = 0, Challenges = {} },
		XP = 0,
		TrackClaimed = 1, -- everyone starts at level 1, which has no reward
		ParkourDone = false,
		ParkourBest = 0,
		ParkourDay = 0,
		ParkourDayBest = 0,
		ParkourPrizeDays = {},
	}
end

-- Gives the profile today's challenges if it has another day's (or none). Returns true if it
-- changed anything.
local function refreshDaily(profile: Profile, userId: number): boolean
	local today = Challenges.DayNumber(os.time())
	if profile.Daily.Day == today then
		return false
	end
	local fresh: { Challenges.Progress } = {}
	for _, def in Challenges.PickFor(userId, today) do
		table.insert(fresh, { Id = def.Id, Progress = 0, Done = false })
	end
	profile.Daily = { Day = today, Challenges = fresh }
	return true
end

local function owns(profile: Profile, itemId: string): boolean
	local entry = Cosmetics.Get(itemId)
	return entry ~= nil and (Cosmetics.IsFree(entry) or profile.Owned[itemId] == true)
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
	local cap = Config.Economy.MaxCurrency
	profile.Crowns = math.min(wholeNumber(data.Crowns) or profile.Crowns, cap)
	-- Profiles saved before Crowns existed called Gumdrops "Coins".
	profile.Gumdrops = math.min(wholeNumber(data.Gumdrops) or wholeNumber(data.Coins) or profile.Gumdrops, cap)
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
	-- Profiles from before Gumdrops collected was counted start from what they have now.
	if typeof(data.Stats) ~= "table" or data.Stats.GumdropsEarned == nil then
		profile.Stats.GumdropsEarned = profile.Gumdrops
	end
	profile.Settings = PlayerSettings.Sanitize(data.Settings)
	profile.XP = math.min(wholeNumber(data.XP) or 0, cap)
	profile.TrackClaimed = math.max(wholeNumber(data.TrackClaimed) or 1, 1)
	profile.ParkourDone = data.ParkourDone == true
	local best = data.ParkourBest
	profile.ParkourBest = if typeof(best) == "number" and MathUtil.isFiniteNumber(best) and best > 0 then best else 0
	local dayBest = data.ParkourDayBest
	profile.ParkourDay = wholeNumber(data.ParkourDay) or 0
	profile.ParkourDayBest = if typeof(dayBest) == "number"
			and MathUtil.isFiniteNumber(dayBest)
			and dayBest > 0
		then dayBest
		else 0
	if typeof(data.ParkourPrizeDays) == "table" then
		for _, day in data.ParkourPrizeDays do
			local whole = wholeNumber(day)
			if whole and #profile.ParkourPrizeDays < MAX_PRIZE_DAYS then
				table.insert(profile.ParkourPrizeDays, whole)
			end
		end
	end
	-- Saved challenges are kept only if all of them are still valid; otherwise new ones are picked.
	local daily = data.Daily
	if typeof(daily) == "table" and typeof(daily.Challenges) == "table" then
		local day = wholeNumber(daily.Day)
		local kept: { Challenges.Progress } = {}
		for _, entry in daily.Challenges do
			local def = if typeof(entry) == "table" and typeof(entry.Id) == "string"
				then Challenges.Get(entry.Id)
				else nil
			if def then
				local progress = math.min(wholeNumber(entry.Progress) or 0, def.Goal)
				table.insert(kept, { Id = def.Id, Progress = progress, Done = entry.Done == true })
			end
		end
		if day and #kept == Challenges.PerDay then
			profile.Daily = { Day = day, Challenges = kept }
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
		Crowns = profile.Crowns,
		Gumdrops = profile.Gumdrops,
		Owned = owned,
		Equipped = table.clone(profile.Equipped),
		Stats = table.clone(profile.Stats),
		Settings = table.clone(profile.Settings),
		Daily = profile.Daily,
		XP = profile.XP,
		TrackClaimed = profile.TrackClaimed,
		ParkourDone = profile.ParkourDone,
		ParkourBest = profile.ParkourBest,
		ParkourDay = profile.ParkourDay,
		ParkourDayBest = profile.ParkourDayBest,
		ParkourPrizeDays = table.clone(profile.ParkourPrizeDays),
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
	player:SetAttribute(PlayerAttr.Crowns, profile.Crowns)
	player:SetAttribute(PlayerAttr.Gumdrops, profile.Gumdrops)
	player:SetAttribute(PlayerAttr.Owned, HttpService:JSONEncode(owned))
	player:SetAttribute(PlayerAttr.Equipped, HttpService:JSONEncode(profile.Equipped))
	player:SetAttribute(PlayerAttr.Stats, HttpService:JSONEncode(profile.Stats))
	player:SetAttribute(PlayerAttr.Settings, HttpService:JSONEncode(profile.Settings))
	player:SetAttribute(PlayerAttr.XP, profile.XP)
	player:SetAttribute(PlayerAttr.ParkourDone, profile.ParkourDone)
	player:SetAttribute(PlayerAttr.ParkourBest, profile.ParkourBest)
	player:SetAttribute(PlayerAttr.ParkourDay, profile.ParkourDay)
	player:SetAttribute(PlayerAttr.ParkourDayBest, profile.ParkourDayBest)
	player:SetAttribute(
		PlayerAttr.Daily,
		HttpService:JSONEncode({
			Day = profile.Daily.Day,
			NextReset = Challenges.NextReset(os.time()),
			Challenges = profile.Daily.Challenges,
		})
	)
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
			-- Try the shop without playing for hours.
			profile.Crowns = STUDIO_TEST_CROWNS
			profile.Gumdrops = STUDIO_TEST_GUMDROPS
		end
	end
	refreshDaily(profile, player.UserId)
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

-- Adds Gumdrops the player has earned to a profile inside an Update, counting them towards
-- Gumdrops collected (the leaderboard). Spending and trades change profile.Gumdrops directly.
function DataService.GiveGumdrops(profile: Profile, amount: number)
	if amount <= 0 or not MathUtil.isFiniteNumber(amount) then
		return
	end
	local cap = Config.Economy.MaxCurrency
	local whole = math.floor(amount)
	profile.Gumdrops = math.min(profile.Gumdrops + whole, cap)
	profile.Stats.GumdropsEarned = math.min(profile.Stats.GumdropsEarned + whole, cap)
end

function DataService.AddGumdrops(player: Player, amount: number)
	if amount <= 0 or not MathUtil.isFiniteNumber(amount) then
		return
	end
	DataService.Update(player, function(profile: Profile)
		DataService.GiveGumdrops(profile, amount)
	end)
end

function DataService.AddCrowns(player: Player, amount: number)
	if amount <= 0 or not MathUtil.isFiniteNumber(amount) then
		return
	end
	DataService.Update(player, function(profile: Profile)
		profile.Crowns = math.min(profile.Crowns + math.floor(amount), Config.Economy.MaxCurrency)
	end)
end

-- Swaps in today's daily challenges if the day has changed since they were picked.
function DataService.RefreshDaily(player: Player)
	local session = sessions[player]
	if session and refreshDaily(session.Profile, player.UserId) then
		publish(player, session)
	end
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
