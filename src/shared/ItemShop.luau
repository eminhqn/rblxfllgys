--!strict
-- The item shop: which shop-only cosmetics (Shared/Cosmetics items with a Shop kind) are on sale.
--
-- The daily shop has DailyCount items and changes at midnight UTC (when the daily challenges
-- change); the weekly shop has WeeklyCount items and changes at midnight UTC going into Monday.
-- The picks come from the date alone, so every server (and every player's screen) shows the same
-- shop without saving anything. Each pool is worked through in a shuffled order, so an item only
-- comes back once the rest of its pool has had a turn.

local RunService = game:GetService("RunService")

local Config = require(script.Parent.Config)
local Cosmetics = require(script.Parent.Cosmetics)

local ItemShop = {}

ItemShop.DailyCount = 4
ItemShop.WeeklyCount = 2

local DAY = 86400
local WEEK = 7 * DAY
local MONDAY_OFFSET = 3 -- 1 January 1970 was a Thursday: days 0-3 belong to the week before Monday 5th

local dailyPool: { Cosmetics.Item } = {}
local weeklyPool: { Cosmetics.Item } = {}
for _, entry in Cosmetics.Items do
	if entry.Shop == "Daily" then
		table.insert(dailyPool, entry)
	elseif entry.Shop == "Weekly" then
		table.insert(weeklyPool, entry)
	end
end
for _, pool in { dailyPool, weeklyPool } do
	table.sort(pool, function(a: Cosmetics.Item, b: Cosmetics.Item): boolean
		return a.Id < b.Id
	end)
end

-- The time the shop goes by: the real time, or in Studio Config.Studio.ShopDaysAhead days ahead.
function ItemShop.Time(unixTime: number): number
	if RunService:IsStudio() then
		return unixTime + Config.Studio.ShopDaysAhead * DAY
	end
	return unixTime
end

function ItemShop.Day(unixTime: number): number
	return math.floor(unixTime / DAY)
end

function ItemShop.Week(unixTime: number): number
	return (ItemShop.Day(unixTime) + MONDAY_OFFSET) // 7
end

-- When the daily / weekly shop next changes (unix time).
function ItemShop.NextDaily(unixTime: number): number
	return (ItemShop.Day(unixTime) + 1) * DAY
end

function ItemShop.NextWeekly(unixTime: number): number
	return (ItemShop.Week(unixTime) + 1) * WEEK - MONDAY_OFFSET * DAY
end

-- The pool in a shuffled order that's the same everywhere for a given cycle.
local function shuffled(pool: { Cosmetics.Item }, cycle: number, salt: number): { Cosmetics.Item }
	local list = table.clone(pool)
	local random = Random.new(cycle * 7919 + salt)
	for index = #list, 2, -1 do
		local swap = random:NextInteger(1, index)
		list[index], list[swap] = list[swap], list[index]
	end
	return list
end

-- `count` items for a period: the next ones along in the pool's shuffled order.
local function pick(pool: { Cosmetics.Item }, period: number, count: number, salt: number): { Cosmetics.Item }
	local size = #pool
	local chosen: { Cosmetics.Item } = {}
	if size == 0 then
		return chosen
	end
	local seen: { [string]: boolean } = {}
	local orders: { [number]: { Cosmetics.Item } } = {}
	local slot = period * count
	while #chosen < math.min(count, size) do
		local cycle = slot // size
		local order = orders[cycle]
		if not order then
			order = shuffled(pool, cycle, salt)
			orders[cycle] = order
		end
		local entry = order[slot % size + 1]
		if not seen[entry.Id] then
			seen[entry.Id] = true
			table.insert(chosen, entry)
		end
		slot += 1
	end
	return chosen
end

-- Today's daily shop.
function ItemShop.Daily(unixTime: number): { Cosmetics.Item }
	return pick(dailyPool, ItemShop.Day(unixTime), ItemShop.DailyCount, 11)
end

-- This week's weekly shop.
function ItemShop.Weekly(unixTime: number): { Cosmetics.Item }
	return pick(weeklyPool, ItemShop.Week(unixTime), ItemShop.WeeklyCount, 23)
end

-- Is this item on sale in the shop right now?
function ItemShop.IsFeatured(itemId: string, unixTime: number): boolean
	local entry = Cosmetics.Get(itemId)
	if not entry or not entry.Shop then
		return false
	end
	local list: { Cosmetics.Item } = if entry.Shop == "Daily"
		then ItemShop.Daily(unixTime)
		else ItemShop.Weekly(unixTime)
	for _, featured in list do
		if featured.Id == itemId then
			return true
		end
	end
	return false
end

return table.freeze(ItemShop)
