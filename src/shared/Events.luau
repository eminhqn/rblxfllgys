--!strict
-- Timed events, worked out from the clock alone, so every server (and every player's screen)
-- agrees without saving anything:
--   DOUBLE XP WEEKEND - every week from Friday 18:00 to Monday 00:00 UTC (Config.Events.DoubleXP),
--   all XP is doubled, plus any extra windows listed there (holidays, launches).
-- Pass the current time as Workspace:GetServerTimeNow() (seconds, UTC), on the server or a client.

local RunService = game:GetService("RunService")

local Config = require(script.Parent.Config)

local Events = {}

local DAY = 86400
local WEEK = 7 * DAY
local FIRST_MONDAY = 4 * DAY -- 5 January 1970, the first Monday after Unix time 0

-- Is double XP on at `time`? If it is, also when it ends; if not, when the next one starts.
function Events.DoubleXP(time: number): (boolean, number)
	local rules = Config.Events.DoubleXP
	if RunService:IsStudio() then
		local forced = Config.Studio.DoubleXP
		if forced == "On" then
			return true, time + 2 * 3600 -- a pretend window, to see how it looks
		elseif forced == "Off" then
			return false, time + WEEK
		end
	end
	for _, window in rules.Extra do
		if time >= window.From and time < window.To then
			return true, window.To
		end
	end
	-- The most recent weekly window that has started.
	local weekStart = time - (time - FIRST_MONDAY) % WEEK
	local start = weekStart + (rules.StartDay - 1) * DAY + rules.StartHour * 3600
	if start > time then
		start -= WEEK
	end
	local finish = start + rules.Hours * 3600
	if time < finish then
		return true, finish
	end
	local nextStart = start + WEEK
	for _, window in rules.Extra do
		if window.From > time and window.From < nextStart then
			nextStart = window.From
		end
	end
	return false, nextStart
end

-- What XP earned at `time` is multiplied by.
function Events.XPMultiplier(time: number): number
	return if Events.DoubleXP(time) then Config.Events.DoubleXP.Multiplier else 1
end

-- "1D 4H", "3H 20M" or "12M": how long until `target`.
function Events.Countdown(time: number, target: number): string
	local left = math.max(target - time, 0)
	local days = math.floor(left / DAY)
	local hours = math.floor(left % DAY / 3600)
	local minutes = math.floor(left % 3600 / 60)
	if days > 0 then
		return `{days}D {hours}H`
	elseif hours > 0 then
		return `{hours}H {minutes}M`
	end
	return `{math.max(minutes, 1)}M`
end

return table.freeze(Events)
