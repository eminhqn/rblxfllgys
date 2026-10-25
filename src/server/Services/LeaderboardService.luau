--!strict
-- The lobby leaderboards (Shared/Leaderboards): most wins, Gumdrops collected and time survived.
--
-- Each board has an ordered DataStore of everyone's score. Players' scores are saved every
-- Config.Leaderboards.WriteInterval seconds (only when they've changed) and when they leave; the
-- top players are read every RefreshInterval seconds, with their display names. Every
-- LiveInterval seconds this server's own players' latest scores are mixed in, so a win shows up
-- on the board straight away. The result goes to clients as attributes (see Shared/Leaderboards).
--
-- If the ordered DataStores can't be used (Studio without API access, or DataStores down) the
-- boards still work, showing the players in this server.

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserService = game:GetService("UserService")

local Shared = ReplicatedStorage.Shared
local Config = require(Shared.Config)
local Leaderboards = require(Shared.Leaderboards)
local Match = require(Shared.Match)

local DataService = require(script.Parent.DataService)

local LeaderboardService = {}

type Entry = Leaderboards.Entry

local rules = Config.Leaderboards
local stores: { [string]: OrderedDataStore } = {}
local storesWorking = true
local saved: { [string]: { Entry } } = {} -- each board's top players as last read
local written: { [Player]: { [string]: number } } = {} -- the scores last saved for each player
local names: { [number]: string } = {} -- display names by user id
local published: { [string]: string } = {}

local function statOf(player: Player, board: Leaderboards.Board): number
	local profile = DataService.Get(player)
	if not profile then
		return 0
	end
	local value = (profile.Stats :: any)[board.Stat]
	return if typeof(value) == "number" then math.floor(value) else 0
end

local function stopUsingStores(reason: string)
	if storesWorking then
		storesWorking = false
		warn(`[LeaderboardService] Leaderboards can't be saved here, showing this server only: {reason}`)
	end
end

local function getStore(board: Leaderboards.Board): OrderedDataStore?
	if not storesWorking then
		return nil
	end
	local existing = stores[board.Id]
	if existing then
		return existing
	end
	local ok, result = pcall(function(): OrderedDataStore
		return DataStoreService:GetOrderedDataStore(`WobbleRush_{board.Id}_v{rules.StoreVersion}`)
	end)
	if not ok then
		stopUsingStores(tostring(result))
		return nil
	end
	stores[board.Id] = result
	return result
end

-- Saves the player's scores that changed since they were last saved.
local function writePlayer(player: Player)
	if not DataService.Get(player) or player:GetAttribute(Match.PlayerAttr.DataSaving) ~= true then
		return -- nothing loaded, or a temporary profile that isn't saved
	end
	local last = written[player]
	if not last then
		last = {}
		written[player] = last
	end
	-- Read every score before saving any: the profile goes away while a leaving player is saved.
	local values: { [string]: number } = {}
	for _, board in Leaderboards.List do
		values[board.Id] = statOf(player, board)
	end
	for _, board in Leaderboards.List do
		local value = values[board.Id]
		local store = getStore(board)
		if value <= 0 or last[board.Id] == value or not store then
			continue
		end
		local ok, err = pcall(function()
			store:SetAsync(tostring(player.UserId), value)
		end)
		if ok then
			last[board.Id] = value
		else
			stopUsingStores(tostring(err))
		end
	end
end

-- Display names for these user ids, asked for in one go (and remembered).
local function fetchNames(userIds: { number })
	local missing: { number } = {}
	for _, userId in userIds do
		if not names[userId] then
			local player = Players:GetPlayerByUserId(userId)
			if player then
				names[userId] = player.DisplayName
			else
				table.insert(missing, userId)
			end
		end
	end
	if #missing == 0 then
		return
	end
	local ok, infos = pcall(function(): { any }
		return UserService:GetUserInfosByUserIdsAsync(missing)
	end)
	if ok then
		for _, info in infos do
			if typeof(info.Id) == "number" and typeof(info.DisplayName) == "string" then
				names[info.Id] = info.DisplayName
			end
		end
	end
end

local function readBoard(board: Leaderboards.Board)
	local store = getStore(board)
	if not store then
		return
	end
	local ok, result = pcall(function(): { { key: string, value: number } }
		local pages = store:GetSortedAsync(false, rules.Rows)
		return pages:GetCurrentPage()
	end)
	if not ok then
		stopUsingStores(tostring(result))
		return
	end
	local entries: { Entry } = {}
	local ids: { number } = {}
	for _, row in result do
		local userId = tonumber(row.key)
		if userId and typeof(row.value) == "number" then
			table.insert(entries, { UserId = userId, Name = "", Value = row.value })
			table.insert(ids, userId)
		end
	end
	fetchNames(ids)
	for _, entry in entries do
		entry.Name = names[entry.UserId] or "Wobbler"
	end
	saved[board.Id] = entries
end

-- The saved top players with this server's latest scores mixed in, best first.
local function mergedEntries(board: Leaderboards.Board): { Entry }
	local byUser: { [number]: Entry } = {}
	local top = saved[board.Id]
	if top then
		for _, entry in top do
			byUser[entry.UserId] = table.clone(entry)
		end
	end
	for _, player in Players:GetPlayers() do
		local value = statOf(player, board)
		if value > 0 then
			local entry = byUser[player.UserId]
			if entry then
				entry.Value = math.max(entry.Value, value)
				entry.Name = player.DisplayName
			else
				byUser[player.UserId] = { UserId = player.UserId, Name = player.DisplayName, Value = value }
			end
		end
	end
	local list: { Entry } = {}
	for _, entry in byUser do
		table.insert(list, entry)
	end
	table.sort(list, function(a: Entry, b: Entry): boolean
		if a.Value ~= b.Value then
			return a.Value > b.Value
		end
		return a.UserId < b.UserId
	end)
	while #list > rules.Rows do
		table.remove(list)
	end
	return list
end

local function publishAll()
	local folder = Leaderboards.GetFolder()
	for _, board in Leaderboards.List do
		local rows = {}
		for _, entry in mergedEntries(board) do
			table.insert(rows, { U = entry.UserId, N = entry.Name, V = entry.Value })
		end
		local json = HttpService:JSONEncode({ Saved = storesWorking, Entries = rows })
		if published[board.Id] ~= json then
			published[board.Id] = json
			folder:SetAttribute(board.Id, json)
		end
	end
end

local function every(seconds: number, callback: () -> ())
	task.spawn(function()
		while true do
			task.wait(seconds)
			local ok, err = pcall(function(): any
				callback()
				return nil
			end)
			if not ok then
				warn(`[LeaderboardService] {err}`)
			end
		end
	end)
end

function LeaderboardService.Init()
	Leaderboards.GetFolder()
	publishAll()

	-- The saved boards, read once at startup and then every RefreshInterval.
	task.spawn(function()
		for _, board in Leaderboards.List do
			readBoard(board)
		end
		publishAll()
	end)
	every(rules.RefreshInterval, function()
		for _, board in Leaderboards.List do
			readBoard(board)
		end
		publishAll()
	end)
	every(rules.WriteInterval, function()
		for _, player in Players:GetPlayers() do
			writePlayer(player)
		end
	end)
	every(rules.LiveInterval, publishAll)

	DataService.Loaded:Connect(function()
		publishAll()
	end)
	Players.PlayerRemoving:Connect(function(player: Player)
		writePlayer(player)
		written[player] = nil
		task.defer(publishAll)
	end)
	game:BindToClose(function()
		for _, player in Players:GetPlayers() do
			task.spawn(writePlayer, player)
		end
		task.wait(2)
	end)
end

return LeaderboardService
