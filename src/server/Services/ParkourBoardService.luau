--!strict
-- The parkour tower's FASTEST TODAY board, and the prize for topping it.
--
-- Each day (midnight to midnight UTC, the same days as the daily challenges) has its own ordered
-- DataStore holding everyone's fastest finish that day, in hundredths of a second. The board shows
-- the quickest Config.Parkour.BoardRows, read every BoardRefresh seconds, with this server's own
-- finishes added straight away. A new day starts an empty board.
--
-- Once a day is over (plus a couple of minutes for late saves), its fastest player wins
-- Config.Parkour.DailyPrize Gumdrops. Every server looks up the winners of the last PrizeDays days
-- and pays a winner who's playing there; the profile remembers which days it's been paid for, so
-- it's never paid twice. A winner who isn't playing gets it next time they join (within PrizeDays).
--
-- In Studio without API access the board and prize only count this server. For testing,
-- Config.Studio.ParkourDayMinutes makes days a few minutes long (and then nothing is saved).

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local Config = require(Shared.Config)
local Leaderboards = require(Shared.Leaderboards)
local Remotes = require(Shared.Remotes)

local DataService = require(script.Parent.DataService)
local UserNames = require(script.Parent.Parent.Util.UserNames)

local ParkourBoardService = {}

type Time = {
	UserId: number,
	Name: string,
	Hundredths: number,
}

local rules = Config.Parkour
local REAL_DAY = 86400
local LATE_SAVE_GRACE = 120 -- seconds after a day ends before its winner is looked up
local TEST_REFRESH = 5
local STORE_PREFIX = "WobbleRush_ParkourDay_v1_"
local KEEP_PAID_DAYS = 20

local testMinutes = if RunService:IsStudio() then Config.Studio.ParkourDayMinutes else 0
local testing = testMinutes > 0
local dayLength = if testing then testMinutes * 60 else REAL_DAY

local storesWorking = not testing
local stores: { [number]: OrderedDataStore } = {}
local localTimes: { [number]: { [number]: Time } } = {} -- day -> user id -> best finish in this server
local saved: { Time } = {} -- the day's top times as last read
local savedDay = -1
local winners: { [number]: number } = {} -- finished day -> winner's user id (0 = nobody finished)
local testPaid: { [Player]: { [number]: boolean } } = {} -- test days already paid (not saved)
local published = ""

local function serverNow(): number
	return Workspace:GetServerTimeNow()
end

-- Today's day number (Challenges.DayNumber, unless test days are on).
function ParkourBoardService.Today(): number
	return math.floor(serverNow() / dayLength)
end

local function storeFailed(reason: string)
	-- In Studio that's almost always "no API access": stop trying and count this server only.
	-- Live servers just try again later.
	if RunService:IsStudio() then
		if storesWorking then
			storesWorking = false
			warn(`[ParkourBoardService] The parkour board can't be saved here, showing this server only: {reason}`)
		end
	else
		warn(`[ParkourBoardService] {reason}`)
	end
end

local function storeFor(day: number): OrderedDataStore?
	if not storesWorking then
		return nil
	end
	local existing = stores[day]
	if existing then
		return existing
	end
	local ok, result = pcall(function(): OrderedDataStore
		return DataStoreService:GetOrderedDataStore(STORE_PREFIX .. day)
	end)
	if not ok then
		storeFailed(tostring(result))
		return nil
	end
	stores[day] = result
	return result
end

local function waitForBudget(requestType: Enum.DataStoreRequestType)
	local deadline = os.clock() + 30
	while DataStoreService:GetRequestBudgetForRequestType(requestType) <= 0 and os.clock() < deadline do
		task.wait(2)
	end
end

-- The fastest `count` saved times for a day, or nil if they couldn't be read.
local function readTop(day: number, count: number): { Time }?
	local store = storeFor(day)
	if not store then
		return nil
	end
	waitForBudget(Enum.DataStoreRequestType.GetSortedAsync)
	local ok, result = pcall(function(): { any }
		return store:GetSortedAsync(true, count):GetCurrentPage()
	end)
	if not ok then
		storeFailed(tostring(result))
		return nil
	end
	local times: { Time } = {}
	local ids: { number } = {}
	for _, row in result do
		local userId = tonumber(row.key)
		if userId and typeof(row.value) == "number" then
			table.insert(times, { UserId = userId, Name = "", Hundredths = row.value })
			table.insert(ids, userId)
		end
	end
	UserNames.Fetch(ids)
	for _, entry in times do
		entry.Name = UserNames.Get(entry.UserId)
	end
	return times
end

-- The day's board: the saved times with this server's own finishes mixed in, fastest first.
local function boardFor(day: number): { Time }
	local byUser: { [number]: Time } = {}
	if savedDay == day then
		for _, entry in saved do
			byUser[entry.UserId] = table.clone(entry)
		end
	end
	local mine = localTimes[day]
	if mine then
		for userId, entry in mine do
			local existing = byUser[userId]
			if not existing or entry.Hundredths < existing.Hundredths then
				byUser[userId] = table.clone(entry)
			end
		end
	end
	local list: { Time } = {}
	for _, entry in byUser do
		table.insert(list, entry)
	end
	table.sort(list, function(a: Time, b: Time): boolean
		if a.Hundredths ~= b.Hundredths then
			return a.Hundredths < b.Hundredths
		end
		return a.UserId < b.UserId
	end)
	while #list > rules.BoardRows do
		table.remove(list)
	end
	return list
end

local function publish()
	local day = ParkourBoardService.Today()
	local rows = {}
	for _, entry in boardFor(day) do
		table.insert(rows, { U = entry.UserId, N = entry.Name, V = entry.Hundredths })
	end
	local json = HttpService:JSONEncode({
		Saved = storesWorking,
		Day = day,
		NextReset = (day + 1) * dayLength,
		Prize = rules.DailyPrize,
		Entries = rows,
	})
	if json ~= published then
		published = json
		Leaderboards.GetFolder():SetAttribute(Leaderboards.ParkourToday.Id, json)
	end
end

-- A checked finish: goes on today's board if it's the player's fastest today.
function ParkourBoardService.Submit(player: Player, seconds: number)
	local day = ParkourBoardService.Today()
	local hundredths = math.max(1, math.floor(seconds * 100 + 0.5))
	local dayTimes = localTimes[day]
	if not dayTimes then
		dayTimes = {}
		localTimes[day] = dayTimes
	end
	local existing = dayTimes[player.UserId]
	if existing and existing.Hundredths <= hundredths then
		return
	end
	dayTimes[player.UserId] = { UserId = player.UserId, Name = player.DisplayName, Hundredths = hundredths }
	publish()
	local store = storeFor(day)
	if not store then
		return
	end
	task.spawn(function()
		local ok, err = pcall(function()
			-- Keeps the faster time if another server saved one for this player today (returning
			-- nil leaves it alone, which the type for this callback doesn't allow for).
			local keepFastest = function(old: any): number?
				if typeof(old) == "number" and old <= hundredths then
					return nil
				end
				return hundredths
			end
			store:UpdateAsync(tostring(player.UserId), keepFastest :: any)
		end)
		if not ok then
			storeFailed(tostring(err))
		end
	end)
end

-- Who was fastest on a finished day (0 = nobody finished), or nil if that can't be known yet.
local function winnerOf(day: number): number?
	if storesWorking then
		local top = readTop(day, 1)
		if top then
			return if top[1] then top[1].UserId else 0
		end
		if storesWorking then
			return nil -- try again later
		end
	end
	if not RunService:IsStudio() then
		return nil -- a live server never pays from its own times alone
	end
	local best: Time? = nil
	local dayTimes = localTimes[day]
	if dayTimes then
		for _, entry in dayTimes do
			if not best or entry.Hundredths < best.Hundredths then
				best = entry
			end
		end
	end
	return if best then best.UserId else 0
end

local function resolveWinners()
	local today = ParkourBoardService.Today()
	local grace = if testing then 2 else LATE_SAVE_GRACE
	for day = today - 1, today - rules.PrizeDays, -1 do
		if winners[day] == nil and serverNow() >= (day + 1) * dayLength + grace then
			local winner = winnerOf(day)
			if winner then
				winners[day] = winner
			end
		end
	end
	for day in winners do
		if day < today - rules.PrizeDays then
			winners[day] = nil
		end
	end
	for day in localTimes do
		if day < today - rules.PrizeDays then
			localTimes[day] = nil
		end
	end
end

-- Pays the player for any recent day they were fastest on and haven't been paid for.
local function payPrizes(player: Player)
	local profile = DataService.Get(player)
	if not profile then
		return
	end
	local today = ParkourBoardService.Today()
	local paidTest = testPaid[player]
	if not paidTest then
		paidTest = {}
		testPaid[player] = paidTest
	end
	local due: { number } = {}
	for day, winner in winners do
		local alreadyPaid = if testing then paidTest[day] == true else table.find(profile.ParkourPrizeDays, day) ~= nil
		if winner == player.UserId and day >= today - rules.PrizeDays and not alreadyPaid then
			table.insert(due, day)
		end
	end
	if #due == 0 then
		return
	end
	local paid = 0
	DataService.Update(player, function(current: DataService.Profile)
		for _, day in due do
			if testing then
				paidTest[day] = true
			elseif table.find(current.ParkourPrizeDays, day) then
				continue
			else
				table.insert(current.ParkourPrizeDays, day)
			end
			DataService.GiveGumdrops(current, rules.DailyPrize)
			paid += rules.DailyPrize
		end
		-- Only recent days matter, newest first.
		table.sort(current.ParkourPrizeDays, function(a: number, b: number): boolean
			return a > b
		end)
		while #current.ParkourPrizeDays > KEEP_PAID_DAYS do
			table.remove(current.ParkourPrizeDays)
		end
	end)
	if paid > 0 then
		Remotes.Event("ParkourPrize"):FireClient(player, paid)
	end
end

local function refresh()
	local today = ParkourBoardService.Today()
	if storesWorking then
		local top = readTop(today, rules.BoardRows)
		if top then
			saved = top
			savedDay = today
		end
	end
	publish()
	resolveWinners()
	for _, player in Players:GetPlayers() do
		payPrizes(player)
	end
end

function ParkourBoardService.Init()
	publish()
	DataService.Loaded:Connect(payPrizes)
	Players.PlayerRemoving:Connect(function(player: Player)
		testPaid[player] = nil
	end)
	task.spawn(function()
		while true do
			local ok, err = pcall(function(): any
				refresh()
				return nil
			end)
			if not ok then
				warn(`[ParkourBoardService] {err}`)
			end
			-- Next refresh, or just after midnight so the new day's board shows straight away.
			local untilReset = (ParkourBoardService.Today() + 1) * dayLength - serverNow() + 1
			task.wait(math.clamp(untilReset, 1, if testing then TEST_REFRESH else rules.BoardRefresh))
		end
	end)
end

return ParkourBoardService
