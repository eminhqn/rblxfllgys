--!strict
-- The results card after a match: how far you got, the rounds you played and got through, the XP,
-- Gumdrops (and the friend bonus) and Crowns you earned (and any daily challenges you finished),
-- your level, and your totals. The
-- server sends it when the match ends; it shows once the winner's celebration is over and you're
-- back in the lobby. CONTINUE (or A / B on a controller) closes it, and it closes by itself after
-- a while or when your next match starts.

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Match = require(Shared.Match)
local Remotes = require(Shared.Remotes)
local Theme = require(Shared.Theme)
local Ui = require(Shared.Ui)

local MatchClient = require(script.Parent.MatchClient)
local ResponsiveScale = require(script.Parent.ResponsiveScale)
local Sfx = require(script.Parent.Sfx)
local WalletHud = require(script.Parent.WalletHud)

local ResultsController = {}

type Results = {
	Won: boolean,
	ReachedFinal: boolean,
	OutInRound: number,
	Rounds: number,
	RoundsPlayed: number,
	RoundsQualified: number,
	Gumdrops: number,
	Crowns: number,
	ChallengeGumdrops: number,
	Challenges: { string },
	TotalWins: number,
	TotalMatches: number,
	XP: number,
	LevelBefore: number,
	Level: number,
	FriendBonus: number, -- percent
	DoubleRewards: boolean, -- the DOUBLE REWARDS item doubled this match's Gumdrops and XP
}

local CLOSE_ACTION = "WobbleResultsClose"
local SHOW_DELAY = 0.8 -- after the Winner phase, so the wipe home has cleared
local AUTO_CLOSE = 30
local WINDOW_SIZE = Vector2.new(520, 516)
local WHITE = Theme.Colors.White
local GOLD = Color3.fromRGB(255, 205, 64)

local localPlayer = Players.LocalPlayer
local gui: ScreenGui
local windowPanel: Frame
local title: TextLabel
local subtitle: TextLabel
local playedValue: TextLabel
local throughValue: TextLabel
local gumdropValue: TextLabel
local gumdropCaption: TextLabel
local crownRow: Frame
local crownValue: TextLabel
local xpValue: TextLabel
local challengeList: Frame
local totalsLabel: TextLabel

local pending: Results? = nil
local isOpen = false
local openToken = 0

local function number(value: unknown): number
	return if typeof(value) == "number" and value == value then math.max(0, math.floor(value)) else 0
end

-- The server sent this, but check it anyway.
local function decode(raw: unknown): Results?
	if typeof(raw) ~= "table" then
		return nil
	end
	local data = raw :: any
	local challenges: { string } = {}
	if typeof(data.Challenges) == "table" then
		for _, text in data.Challenges do
			if typeof(text) == "string" then
				table.insert(challenges, text)
			end
		end
	end
	return {
		Won = data.Won == true,
		ReachedFinal = data.ReachedFinal == true,
		OutInRound = number(data.OutInRound),
		Rounds = number(data.Rounds),
		RoundsPlayed = number(data.RoundsPlayed),
		RoundsQualified = number(data.RoundsQualified),
		Gumdrops = number(data.Gumdrops),
		Crowns = number(data.Crowns),
		ChallengeGumdrops = number(data.ChallengeGumdrops),
		Challenges = challenges,
		TotalWins = number(data.TotalWins),
		TotalMatches = number(data.TotalMatches),
		XP = number(data.XP),
		LevelBefore = math.max(number(data.LevelBefore), 1),
		Level = math.max(number(data.Level), 1),
		FriendBonus = number(data.FriendBonus),
		DoubleRewards = data.DoubleRewards == true,
	}
end

local function headline(results: Results): (string, string, Color3)
	if results.Won then
		return "YOU WON!", "You're the Wobble Rush champion!", GOLD
	elseif results.OutInRound > 0 then
		local finalText = if results.ReachedFinal then " (the final!)" else ""
		return "MATCH OVER",
			`Knocked out in round {results.OutInRound} of {results.Rounds}{finalText}`,
			Theme.Colors.Purple
	elseif results.ReachedFinal then
		return "MATCH OVER", "You made it to the final!", Theme.Colors.Purple
	end
	return "MATCH OVER", "Thanks for playing!", Theme.Colors.Purple
end

local function setOpen(open: boolean)
	if open == isOpen then
		return
	end
	isOpen = open
	gui.Enabled = open
	openToken += 1
	if open then
		ContextActionService:BindActionAtPriority(
			CLOSE_ACTION,
			function(_name: string, state: Enum.UserInputState): Enum.ContextActionResult
				if state == Enum.UserInputState.Begin then
					setOpen(false)
				end
				return Enum.ContextActionResult.Sink
			end,
			false,
			Enum.ContextActionPriority.High.Value,
			Enum.KeyCode.ButtonA,
			Enum.KeyCode.ButtonB
		)
		Ui.popIn(windowPanel)
		local token = openToken
		task.delay(AUTO_CLOSE, function()
			if openToken == token then
				setOpen(false)
			end
		end)
	else
		ContextActionService:UnbindAction(CLOSE_ACTION)
	end
end

local function show(results: Results)
	local heading, line, color = headline(results)
	title.Text = heading
	title.TextColor3 = color
	subtitle.Text = line
	playedValue.Text = tostring(results.RoundsPlayed)
	throughValue.Text = tostring(results.RoundsQualified)
	gumdropValue.Text = `+{results.Gumdrops + results.ChallengeGumdrops}`
	local extras: { string } = {}
	if results.DoubleRewards then
		table.insert(extras, "2X")
	end
	if results.FriendBonus > 0 then
		table.insert(extras, `+{results.FriendBonus}% FRIENDS`)
	end
	gumdropCaption.Text = if #extras > 0 then `GUMDROPS ({table.concat(extras, ", ")})` else "GUMDROPS EARNED"
	xpValue.Text = `+{results.XP}`
	crownRow.Visible = results.Crowns > 0
	crownValue.Text = `+{results.Crowns}`
	for _, child in challengeList:GetChildren() do
		if child:IsA("TextLabel") then
			child:Destroy()
		end
	end
	for index, text in results.Challenges do
		local label = Ui.label(
			challengeList,
			`CHALLENGE DONE: {text}`,
			Theme.Fonts.Body,
			Theme.Colors.Lime:Lerp(Theme.Colors.Ink, 0.35),
			UDim2.new(1, 0, 0, 20)
		)
		label.LayoutOrder = index
		label.TextXAlignment = Enum.TextXAlignment.Left
	end
	challengeList.Visible = #results.Challenges > 0
	local levelText = if results.Level > results.LevelBefore
		then `LEVEL UP! {results.LevelBefore} > {results.Level}`
		else `LEVEL {results.Level}`
	totalsLabel.Text = `{levelText}  ·  WINS {results.TotalWins}  ·  MATCHES {results.TotalMatches}`
	setOpen(true)
	Sfx.Play(if results.Won then "Crown" else "Gumdrops")
end

-- Shows the waiting results once the match (and its celebration) is over.
local function tryShow()
	local results = pending
	local phase = MatchClient.GetPhase()
	if not results or phase == "Winner" then
		return
	end
	pending = nil
	task.delay(SHOW_DELAY, function()
		show(results)
	end)
end

local function stat(parent: Instance, order: number, caption: string): TextLabel
	local box: Frame = Ui.new("Frame", {
		Name = caption,
		Size = UDim2.new(0.5, -6, 1, 0),
		BackgroundColor3 = Theme.Colors.PanelTint,
		BorderSizePixel = 0,
		LayoutOrder = order,
		ZIndex = 3,
		Parent = parent,
	})
	Ui.corner(box, UDim.new(0, 14))
	local value = Ui.label(
		box,
		"0",
		Theme.Fonts.Display,
		Theme.Colors.Purple,
		UDim2.new(1, -16, 0, 36),
		UDim2.new(0.5, 0, 0, 8),
		Vector2.new(0.5, 0)
	)
	value.ZIndex = 4
	local label = Ui.label(
		box,
		caption,
		Theme.Fonts.Body,
		Theme.Colors.InkSoft,
		UDim2.new(1, -16, 0, 18),
		UDim2.new(0.5, 0, 1, -8),
		Vector2.new(0.5, 1)
	)
	label.ZIndex = 4
	return value
end

-- A round purple "XP" badge, the same shape as the currency icons.
local function xpIcon(parent: Instance, size: number, position: UDim2, anchor: Vector2): Frame
	local icon: Frame = Ui.new("Frame", {
		Name = "XP",
		Size = UDim2.fromOffset(size, size),
		Position = position,
		AnchorPoint = anchor,
		BackgroundColor3 = Theme.Colors.Purple,
		BorderSizePixel = 0,
		ZIndex = 3,
		Parent = parent,
	})
	Ui.corner(icon, UDim.new(0.5, 0))
	Ui.stroke(icon, Theme.Colors.Yellow, 2)
	local label = Ui.label(
		icon,
		"XP",
		Theme.Fonts.Display,
		WHITE,
		UDim2.fromScale(0.7, 0.6),
		UDim2.fromScale(0.5, 0.5),
		Vector2.new(0.5, 0.5)
	)
	label.ZIndex = 4
	return icon
end

local function earnedRow(
	parent: Instance,
	order: number,
	icon: (Instance, number, UDim2, Vector2) -> Frame,
	caption: string
): (Frame, TextLabel, TextLabel)
	local row: Frame = Ui.new("Frame", {
		Name = caption,
		Size = UDim2.new(1, 0, 0, 34),
		BackgroundTransparency = 1,
		LayoutOrder = order,
		ZIndex = 3,
		Parent = parent,
	})
	icon(row, 30, UDim2.fromScale(0, 0.5), Vector2.new(0, 0.5))
	local label = Ui.label(
		row,
		caption,
		Theme.Fonts.Display,
		Theme.Colors.Ink,
		UDim2.new(0.6, 0, 0, 24),
		UDim2.new(0, 42, 0.5, 0),
		Vector2.new(0, 0.5)
	)
	label.TextXAlignment = Enum.TextXAlignment.Left
	local value = Ui.label(
		row,
		"+0",
		Theme.Fonts.Display,
		Theme.Colors.Lime:Lerp(Theme.Colors.Ink, 0.2),
		UDim2.fromOffset(120, 28),
		UDim2.fromScale(1, 0.5),
		Vector2.new(1, 0.5)
	)
	value.TextXAlignment = Enum.TextXAlignment.Right
	return row, value, label
end

local function build()
	gui = Ui.new("ScreenGui", {
		Name = "Results",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		DisplayOrder = 28,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		Enabled = false,
		Parent = localPlayer:WaitForChild("PlayerGui"),
	})
	local window: Frame = Ui.new("Frame", {
		Name = "Window",
		Size = UDim2.fromOffset(WINDOW_SIZE.X, WINDOW_SIZE.Y),
		Position = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundTransparency = 1,
		Parent = gui,
	})
	ResponsiveScale.Attach(window, "Hud")
	local panel = Ui.panel(window, UDim2.fromScale(1, 1), UDim2.new(), Vector2.zero)
	windowPanel = panel.Root
	local body = panel.Body
	Ui.padding(body, 20)
	local layout: Frame = Ui.new("Frame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		ZIndex = 3,
		Parent = body,
	})
	Ui.new("UIListLayout", {
		Padding = UDim.new(0, 10),
		SortOrder = Enum.SortOrder.LayoutOrder,
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
		Parent = layout,
	})

	title = Ui.label(layout, "MATCH OVER", Theme.Fonts.Display, Theme.Colors.Purple, UDim2.new(1, 0, 0, 44))
	title.LayoutOrder = 1
	Ui.stroke(title, WHITE, 3)
	subtitle = Ui.label(layout, "", Theme.Fonts.Body, Theme.Colors.Ink, UDim2.new(1, 0, 0, 24))
	subtitle.LayoutOrder = 2

	local stats: Frame = Ui.new("Frame", {
		Name = "Stats",
		Size = UDim2.new(1, 0, 0, 78),
		BackgroundTransparency = 1,
		LayoutOrder = 3,
		ZIndex = 3,
		Parent = layout,
	})
	Ui.new("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		Padding = UDim.new(0, 12),
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = stats,
	})
	playedValue = stat(stats, 1, "ROUNDS PLAYED")
	throughValue = stat(stats, 2, "GOT THROUGH")

	local _, xp = earnedRow(layout, 4, xpIcon, "XP EARNED")
	xpValue = xp
	local _, gumdrops, gumdropsCaption = earnedRow(layout, 5, WalletHud.GumdropIcon, "GUMDROPS EARNED")
	gumdropValue = gumdrops
	gumdropCaption = gumdropsCaption
	crownRow, crownValue = earnedRow(layout, 6, WalletHud.CrownIcon, "CROWNS EARNED")

	challengeList = Ui.new("Frame", {
		Name = "Challenges",
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		LayoutOrder = 7,
		ZIndex = 3,
		Parent = layout,
	})
	Ui.new("UIListLayout", {
		Padding = UDim.new(0, 4),
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = challengeList,
	})

	totalsLabel = Ui.label(layout, "", Theme.Fonts.Display, Theme.Colors.InkSoft, UDim2.new(1, 0, 0, 20))
	totalsLabel.LayoutOrder = 8

	local continueButton: TextButton = Ui.new("TextButton", {
		Name = "Continue",
		Text = "",
		AutoButtonColor = false,
		Size = UDim2.fromOffset(220, 50),
		BackgroundColor3 = Theme.Colors.Pink,
		BorderSizePixel = 0,
		LayoutOrder = 9,
		ZIndex = 3,
		Parent = layout,
	})
	Ui.corner(continueButton, UDim.new(0.5, 0))
	Ui.stroke(continueButton, WHITE, 3)
	local continueLabel = Ui.label(
		continueButton,
		"CONTINUE",
		Theme.Fonts.Display,
		WHITE,
		UDim2.new(1, -24, 1, -16),
		UDim2.fromScale(0.5, 0.5),
		Vector2.new(0.5, 0.5)
	)
	continueLabel.ZIndex = 4
	continueButton.Activated:Connect(function()
		setOpen(false)
	end)
end

function ResultsController.Init()
	build()
	Remotes.Event("MatchResults").OnClientEvent:Connect(function(raw: unknown)
		pending = decode(raw)
		tryShow()
	end)
	MatchClient.Changed:Connect(function(name: string)
		if name ~= Match.Attr.Phase then
			return
		end
		tryShow()
		-- Out of the way when the next match starts.
		if isOpen and MatchClient.GetPhase() == "Loading" and MatchClient.IsInMatchFlow() then
			setOpen(false)
		end
	end)
end

return ResultsController
