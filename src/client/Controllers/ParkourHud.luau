--!strict
-- The parkour tower's on-screen bits (the server's ParkourService runs the course):
--   * on the start pad: "STEP OFF TO START" and what your first finish pays (or your best times,
--     today and ever)
--   * during a run: the clock, your checkpoint, your best time, and a QUIT button (press the right
--     stick on a controller)
--   * pop-ups for each checkpoint, for finishing (your time, any Gumdrops, a new best) and for
--     winning a day's FASTEST TODAY prize

local ContextActionService = game:GetService("ContextActionService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local Config = require(Shared.Config)
local Leaderboards = require(Shared.Leaderboards)
local Match = require(Shared.Match)
local Remotes = require(Shared.Remotes)
local Theme = require(Shared.Theme)
local Ui = require(Shared.Ui)

local Input = require(script.Parent.InputController)
local KeyIcon = require(script.Parent.KeyIcon)
local MatchClient = require(script.Parent.MatchClient)
local ResponsiveScale = require(script.Parent.ResponsiveScale)
local RoundHud = require(script.Parent.RoundHud)
local Sfx = require(script.Parent.Sfx)

local ParkourHud = {}

local QUIT_ACTION = "WobbleParkourQuit"
local WHITE = Theme.Colors.White

local PlayerAttr = Match.PlayerAttr
local localPlayer = Players.LocalPlayer

local holder: Frame
local titleLabel: TextLabel
local timeLabel: TextLabel
local infoLabel: TextLabel
local quitButton: TextButton
local quitHint: ImageLabel
local shownStage = -1
local quitBound = false

local function number(name: string): number
	local value = localPlayer:GetAttribute(name)
	return if typeof(value) == "number" then value else 0
end

-- 83.4 -> "1:23.4"
local function formatTime(seconds: number): string
	local tenths = math.max(0, math.floor(seconds * 10))
	local minutes = tenths // 600
	return string.format("%d:%04.1f", minutes, (tenths % 600) / 10)
end

-- Today's day number, as the FASTEST TODAY board counts days (-1 until it's known).
local function today(): number
	local raw = Leaderboards.GetFolder():GetAttribute(Leaderboards.ParkourToday.Id)
	if typeof(raw) ~= "string" or raw == "" then
		return -1
	end
	local ok, data = pcall(function(): any
		return HttpService:JSONDecode(raw)
	end)
	return if ok and typeof(data) == "table" and typeof(data.Day) == "number" then data.Day else -1
end

-- Your best time today (0 if you haven't finished today).
local function todayBest(): number
	return if number(PlayerAttr.ParkourDay) == today() then number(PlayerAttr.ParkourDayBest) else 0
end

local function quit()
	Remotes.Event("RequestParkour"):FireServer("Quit")
end

local function setQuitBinding(bound: boolean)
	if bound == quitBound then
		return
	end
	quitBound = bound
	if bound then
		ContextActionService:BindAction(
			QUIT_ACTION,
			function(_name: string, state: Enum.UserInputState): Enum.ContextActionResult
				if state == Enum.UserInputState.Begin then
					quit()
				end
				return Enum.ContextActionResult.Sink
			end,
			false,
			Enum.KeyCode.ButtonR3
		)
	else
		ContextActionService:UnbindAction(QUIT_ACTION)
	end
end

local function refresh()
	local stage = localPlayer:GetAttribute(PlayerAttr.ParkourStage)
	local current = if typeof(stage) == "number" then stage else -1
	local startedAt = number(PlayerAttr.ParkourStartedAt)
	local running = current >= 0 and startedAt > 0
	holder.Visible = current >= 0 and MatchClient.GetStatus() == "None"
	quitButton.Visible = running
	quitHint.Visible = running and Input.GetScheme() == "Gamepad" and quitHint.Image ~= ""
	setQuitBinding(running and holder.Visible)

	local checkpoints = math.max(MatchClient.GetNumber(Match.Attr.ParkourCheckpoints), 1)
	local best = number(PlayerAttr.ParkourBest)
	if current >= 0 and not running then
		titleLabel.Text = "PARKOUR TOWER"
		timeLabel.Text = "STEP OFF TO START"
		if localPlayer:GetAttribute(PlayerAttr.ParkourDone) == true and best > 0 then
			local bestToday = todayBest()
			local todayText = if bestToday > 0 then Leaderboards.FormatTime(bestToday) else "--"
			infoLabel.Text = `BEST TODAY {todayText}  ·  EVER {Leaderboards.FormatTime(best)}`
		else
			infoLabel.Text = `FIRST FINISH: +{Config.Parkour.FirstFinishGumdrops} GUMDROPS`
		end
	elseif running then
		titleLabel.Text = "PARKOUR TOWER"
		local where = if current >= checkpoints then "LAST STRETCH!" else `CHECKPOINT {current} / {checkpoints}`
		infoLabel.Text = if best > 0 then `{where}  ·  BEST {Leaderboards.FormatTime(best)}` else where
	end

	-- A pop-up each time you reach a new checkpoint.
	if running and current > shownStage and current > 0 then
		RoundHud.Toast(`CHECKPOINT {current}!`, Theme.Colors.Aqua)
		Sfx.Play("Checkpoint")
	end
	shownStage = current
end

local function onFinished(seconds: unknown, gumdrops: unknown, best: unknown, bestToday: unknown)
	if typeof(seconds) ~= "number" then
		return
	end
	RoundHud.Toast(`PARKOUR DONE! {Leaderboards.FormatTime(seconds)}`, Theme.Colors.Yellow)
	Sfx.Play("Qualify")
	local function follow(text: string, color: Color3, sound: string)
		task.delay(1.4, function()
			RoundHud.Toast(text, color)
			Sfx.Play(sound)
		end)
	end
	if typeof(gumdrops) == "number" and gumdrops > 0 then
		follow(`+{gumdrops} GUMDROPS!`, Theme.Colors.Pink, "Gumdrops")
	elseif typeof(best) == "number" and math.abs(best - seconds) < 1e-3 then
		follow("NEW BEST TIME!", Theme.Colors.Lime, "Unlock")
	elseif typeof(bestToday) == "number" and math.abs(bestToday - seconds) < 1e-3 then
		follow("YOUR BEST TODAY!", Theme.Colors.Aqua, "Unlock")
	end
end

-- You were the fastest on the parkour when a day ended.
local function onPrize(gumdrops: unknown)
	if typeof(gumdrops) ~= "number" then
		return
	end
	RoundHud.Toast("FASTEST ON THE PARKOUR!", Theme.Colors.Yellow)
	Sfx.Play("Crown")
	task.delay(1.6, function()
		RoundHud.Toast(`+{gumdrops} GUMDROPS!`, Theme.Colors.Pink)
		Sfx.Play("Gumdrops")
	end)
end

local function build()
	local gui: ScreenGui = Ui.new("ScreenGui", {
		Name = "ParkourHud",
		ResetOnSpawn = false,
		IgnoreGuiInset = false,
		DisplayOrder = 4,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		Parent = localPlayer:WaitForChild("PlayerGui"),
	})
	holder = Ui.new("Frame", {
		Name = "Parkour",
		Size = UDim2.fromOffset(330, 104),
		Position = UDim2.new(0.5, 0, 0, 10),
		AnchorPoint = Vector2.new(0.5, 0),
		BackgroundTransparency = 1,
		Visible = false,
		Parent = gui,
	})
	ResponsiveScale.Attach(holder, "Hud")
	local panel = Ui.panel(holder, UDim2.new(1, 0, 0, 96), UDim2.new(), Vector2.zero)
	local body = panel.Body
	titleLabel = Ui.label(
		body,
		"PARKOUR TOWER",
		Theme.Fonts.Display,
		Theme.Colors.Purple,
		UDim2.new(1, -110, 0, 22),
		UDim2.fromOffset(16, 10)
	)
	titleLabel.TextXAlignment = Enum.TextXAlignment.Left
	timeLabel =
		Ui.label(body, "", Theme.Fonts.Display, Theme.Colors.Ink, UDim2.new(1, -110, 0, 34), UDim2.fromOffset(16, 32))
	timeLabel.TextXAlignment = Enum.TextXAlignment.Left
	infoLabel =
		Ui.label(body, "", Theme.Fonts.Body, Theme.Colors.InkSoft, UDim2.new(1, -32, 0, 18), UDim2.fromOffset(16, 70))
	infoLabel.TextXAlignment = Enum.TextXAlignment.Left

	quitButton = Ui.new("TextButton", {
		Name = "Quit",
		Text = "",
		AutoButtonColor = false,
		Size = UDim2.fromOffset(84, 40),
		Position = UDim2.new(1, -12, 0, 12),
		AnchorPoint = Vector2.new(1, 0),
		BackgroundColor3 = Theme.Colors.Pink,
		BorderSizePixel = 0,
		ZIndex = 3,
		Parent = body,
	})
	Ui.corner(quitButton, UDim.new(0.5, 0))
	Ui.stroke(quitButton, WHITE, 3)
	local quitLabel = Ui.label(
		quitButton,
		"QUIT",
		Theme.Fonts.Display,
		WHITE,
		UDim2.new(1, -24, 1, -16),
		UDim2.fromScale(0.5, 0.5),
		Vector2.new(0.5, 0.5)
	)
	quitLabel.ZIndex = 4
	quitHint = KeyIcon.new(Enum.KeyCode.ButtonR3, {
		Name = "GamepadHint",
		Size = UDim2.fromOffset(26, 26),
		Position = UDim2.new(0, -6, 1, 4),
		AnchorPoint = Vector2.new(0, 1),
		Visible = false,
		ZIndex = 5,
		Parent = quitButton,
	})
	quitButton.Activated:Connect(function()
		Ui.pressBounce(quitButton)
		quit()
	end)
end

function ParkourHud.Init()
	build()
	MatchClient.LocalChanged:Connect(function(name: string)
		if
			name == PlayerAttr.ParkourStage
			or name == PlayerAttr.ParkourStartedAt
			or name == PlayerAttr.ParkourBest
			or name == PlayerAttr.ParkourDayBest
			or name == PlayerAttr.Status
		then
			refresh()
		end
	end)
	Input.SchemeChanged:Connect(refresh)
	Remotes.Event("ParkourFinished").OnClientEvent:Connect(onFinished)
	Remotes.Event("ParkourPrize").OnClientEvent:Connect(onPrize)
	-- A new day clears today's best.
	Leaderboards.GetFolder():GetAttributeChangedSignal(Leaderboards.ParkourToday.Id):Connect(refresh)
	refresh()

	-- The clock.
	RunService.Heartbeat:Connect(function()
		if not holder.Visible then
			return
		end
		local startedAt = number(PlayerAttr.ParkourStartedAt)
		if startedAt > 0 then
			timeLabel.Text = formatTime(Workspace:GetServerTimeNow() - startedAt)
		end
	end)
end

return ParkourHud
