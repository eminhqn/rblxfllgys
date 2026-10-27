--!strict
-- How much server time the bots take (Studio only, with Config.Studio.ProfileBots on).
--
-- The bot systems wrap their work in Begin/End: BotMotor (moving every bot, every frame), BotWorld
-- (the copies of moving platforms bots stand on, and hazard hits) and BotBrain (deciding, a few
-- times a second), with BotBrain's goal, gumdrop and hazard checks broken out. Every
-- REPORT_EVERY seconds the Output gets a summary: milliseconds each takes per frame (a frame is
-- 16.7 ms at 60 fps), raycasts a second, how many bots there are and the server's frame rate. The
-- top-level sections are also labelled for the MicroProfiler (Ctrl+F6, then the server's view).
--
-- With the setting off, every call returns straight away.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Shared.Config)

local Bots = require(script.Parent.Bots)

local BotProfiler = {}

local REPORT_EVERY = 10
local FRAME_MS = 1000 / 60

local enabled = RunService:IsStudio() and Config.Studio.ProfileBots == true
local totals: { [string]: number } = {}
local starts: { [string]: number } = {}
local counts: { [string]: number } = {}
local frames = 0
local windowStart = os.clock()

-- Starts timing `name`. Top-level names (no ".") are also MicroProfiler labels.
function BotProfiler.Begin(name: string)
	if not enabled then
		return
	end
	starts[name] = os.clock()
	if not string.find(name, ".", 1, true) then
		debug.profilebegin(name)
	end
end

function BotProfiler.End(name: string)
	if not enabled then
		return
	end
	local started = starts[name]
	if not started then
		return
	end
	starts[name] = nil
	totals[name] = (totals[name] or 0) + os.clock() - started
	if not string.find(name, ".", 1, true) then
		debug.profileend()
	end
end

-- Adds to a running count (e.g. raycasts).
function BotProfiler.Count(name: string, amount: number?)
	if not enabled then
		return
	end
	counts[name] = (counts[name] or 0) + (amount or 1)
end

function BotProfiler.IsEnabled(): boolean
	return enabled
end

local function report()
	local seconds = os.clock() - windowStart
	if seconds <= 0 or frames == 0 then
		return
	end
	local lines = {
		string.format(
			"[BotProfiler] %d bots · server %.1f fps · physics %.1f fps · over %.0fs",
			Bots.Count(),
			frames / seconds,
			Workspace:GetRealPhysicsFPS(),
			seconds
		),
	}
	local names: { string } = {}
	for name in totals do
		table.insert(names, name)
	end
	table.sort(names)
	local overall = 0
	for _, name in names do
		local perFrame = totals[name] * 1000 / frames
		if not string.find(name, ".", 1, true) then
			overall += perFrame
		end
		local indent = if string.find(name, ".", 1, true) then "      " else "  "
		table.insert(
			lines,
			string.format(
				"%s%-22s %6.3f ms/frame (%4.1f%% of a frame)",
				indent,
				name,
				perFrame,
				perFrame / FRAME_MS * 100
			)
		)
	end
	table.insert(
		lines,
		string.format("  %-22s %6.3f ms/frame (%4.1f%% of a frame)", "all bots", overall, overall / FRAME_MS * 100)
	)
	local countNames: { string } = {}
	for name in counts do
		table.insert(countNames, name)
	end
	table.sort(countNames)
	for _, name in countNames do
		table.insert(lines, string.format("  %-22s %8.0f a second", name, counts[name] / seconds))
	end
	print(table.concat(lines, "\n"))
	table.clear(totals)
	table.clear(counts)
	frames = 0
	windowStart = os.clock()
end

function BotProfiler.Init()
	if not enabled then
		return
	end
	print("[BotProfiler] On: a summary of the bots' server time every " .. REPORT_EVERY .. " seconds.")
	RunService.Heartbeat:Connect(function()
		frames += 1
		if os.clock() - windowStart >= REPORT_EVERY then
			if Bots.Count() > 0 then
				report()
			else
				table.clear(totals)
				table.clear(counts)
				frames = 0
				windowStart = os.clock()
			end
		end
	end)
end

return BotProfiler
