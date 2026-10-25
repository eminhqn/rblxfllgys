--!strict
-- The daily challenges panel in the lobby (under your Crowns and Gumdrops): today's three
-- challenges with a progress bar each, the Gumdrops they pay, and how long until new ones. Tap or
-- click its title to fold it away (it starts folded on phones and tablets, where space is tight).
-- When you finish one (anywhere, even mid-round), a CHALLENGE DONE! pop-up shows; the server has
-- already added the Gumdrops. See Shared/Challenges.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local Challenges = require(Shared.Challenges)
local Remotes = require(Shared.Remotes)
local Theme = require(Shared.Theme)
local Ui = require(Shared.Ui)

local Hud = require(script.Parent.Hud)
local Input = require(script.Parent.InputController)
local MatchClient = require(script.Parent.MatchClient)
local ProfileClient = require(script.Parent.ProfileClient)
local RoundHud = require(script.Parent.RoundHud)
local Sfx = require(script.Parent.Sfx)
local WalletHud = require(script.Parent.WalletHud)

local ChallengesHud = {}

type Row = {
	Frame: Frame,
	Text: TextLabel,
	Fill: Frame,
	Count: TextLabel,
	Reward: TextLabel,
	Icon: Frame,
}

local PANEL_WIDTH = 400
local ROW_HEIGHT = 46
local EXPANDED_HEIGHT = 46 + ROW_HEIGHT * Challenges.PerDay + 8 * (Challenges.PerDay - 1) + 24
local FOLDED_HEIGHT = 50
local CLOCK_REFRESH = 20 -- seconds between updates of "NEW IN ..."

local DONE_COLOR = Theme.Colors.Lime
local TRACK_COLOR = Color3.fromRGB(226, 218, 246)

local panel: Ui.Panel
local titleLabel: TextLabel
local timerLabel: TextLabel
local list: Frame
local rows: { Row } = {}
local folded = false

local function formatWait(seconds: number): string
	local minutes = math.max(0, math.ceil(seconds / 60))
	if minutes >= 60 then
		return `{minutes // 60}H {minutes % 60}M`
	end
	return `{minutes}M`
end

local function refreshClock()
	local nextReset = ProfileClient.GetDaily().NextReset
	if nextReset <= 0 then
		timerLabel.Text = ""
		return
	end
	-- The server's clock decides the day, so count down with it.
	timerLabel.Text = `NEW IN {formatWait(nextReset - Workspace:GetServerTimeNow())}`
end

local function refresh()
	local daily = ProfileClient.GetDaily()
	panel.Root.Visible = ProfileClient.IsReady() and not MatchClient.IsInMatchFlow() and #daily.Challenges > 0
	local done = 0
	for _, entry in daily.Challenges do
		if entry.Done then
			done += 1
		end
	end
	-- Folded, the title says how many are done; the rows are hidden.
	titleLabel.Text = if folded then `DAILY CHALLENGES {done}/{#daily.Challenges} +` else "DAILY CHALLENGES -"
	list.Visible = not folded
	panel.Root.Size = UDim2.fromOffset(PANEL_WIDTH, if folded then FOLDED_HEIGHT else EXPANDED_HEIGHT)
	for index, row in rows do
		local entry = daily.Challenges[index]
		local def = if entry then Challenges.Get(entry.Id) else nil
		row.Frame.Visible = def ~= nil
		if entry and def then
			local progress = math.clamp(entry.Progress / def.Goal, 0, 1)
			row.Text.Text = def.Text
			row.Text.TextColor3 = if entry.Done then Theme.Colors.InkSoft else Theme.Colors.Ink
			row.Fill.Size = UDim2.fromScale(progress, 1)
			row.Fill.BackgroundColor3 = if entry.Done then DONE_COLOR else Theme.Colors.Pink
			row.Count.Text = `{math.min(entry.Progress, def.Goal)}/{def.Goal}`
			row.Reward.Text = if entry.Done then "DONE!" else `+{def.Reward}`
			row.Reward.TextColor3 = if entry.Done then DONE_COLOR else Theme.Colors.Ink
			row.Icon.Visible = not entry.Done
		end
	end
	refreshClock()
end

local function buildRow(parent: Instance, order: number): Row
	local frame: Frame = Ui.new("Frame", {
		Name = `Challenge{order}`,
		Size = UDim2.new(1, 0, 0, ROW_HEIGHT),
		BackgroundTransparency = 1,
		LayoutOrder = order,
		ZIndex = 3,
		Parent = parent,
	})
	local text =
		Ui.label(frame, "", Theme.Fonts.Body, Theme.Colors.Ink, UDim2.new(1, -96, 0, 20), UDim2.fromOffset(0, 2))
	text.TextXAlignment = Enum.TextXAlignment.Left
	local track: Frame = Ui.new("Frame", {
		Name = "Track",
		Size = UDim2.new(1, -150, 0, 12),
		Position = UDim2.fromOffset(0, 28),
		BackgroundColor3 = TRACK_COLOR,
		BorderSizePixel = 0,
		ZIndex = 3,
		Parent = frame,
	})
	Ui.corner(track, UDim.new(0.5, 0))
	local fill: Frame = Ui.new("Frame", {
		Name = "Fill",
		Size = UDim2.fromScale(0, 1),
		BackgroundColor3 = Theme.Colors.Pink,
		BorderSizePixel = 0,
		ZIndex = 4,
		Parent = track,
	})
	Ui.corner(fill, UDim.new(0.5, 0))
	local count = Ui.label(
		frame,
		"",
		Theme.Fonts.Display,
		Theme.Colors.InkSoft,
		UDim2.fromOffset(52, 18),
		UDim2.new(1, -142, 0, 25)
	)
	count.TextXAlignment = Enum.TextXAlignment.Left
	local reward = Ui.label(
		frame,
		"",
		Theme.Fonts.Display,
		Theme.Colors.Ink,
		UDim2.fromOffset(62, 24),
		UDim2.new(1, -30, 0.5, 0),
		Vector2.new(1, 0.5)
	)
	reward.TextXAlignment = Enum.TextXAlignment.Right
	local icon = WalletHud.GumdropIcon(frame, 22, UDim2.fromScale(1, 0.5), Vector2.new(1, 0.5))
	return { Frame = frame, Text = text, Fill = fill, Count = count, Reward = reward, Icon = icon }
end

local function build()
	panel = Ui.panel(Hud.GetTopStack(), UDim2.fromOffset(PANEL_WIDTH, EXPANDED_HEIGHT), UDim2.new(), Vector2.zero)
	panel.Root.LayoutOrder = Hud.TopOrder.Challenges
	panel.Root.Visible = false
	Hud.MoveRightOnTouch(panel.Root) -- clear of the thumbstick on phones and tablets
	local body = panel.Body
	Ui.padding(body, 12)
	titleLabel = Ui.label(
		body,
		"DAILY CHALLENGES",
		Theme.Fonts.Display,
		Theme.Colors.Purple,
		UDim2.new(0.6, 0, 0, 26),
		UDim2.new()
	)
	titleLabel.TextXAlignment = Enum.TextXAlignment.Left
	-- The whole title row folds and unfolds the panel.
	local header: TextButton = Ui.new("TextButton", {
		Name = "Fold",
		Text = "",
		Size = UDim2.new(1, 0, 0, 28),
		BackgroundTransparency = 1,
		ZIndex = 5,
		Parent = body,
	})
	header.Activated:Connect(function()
		folded = not folded
		refresh()
	end)
	timerLabel = Ui.label(
		body,
		"",
		Theme.Fonts.Display,
		Theme.Colors.InkSoft,
		UDim2.new(0.4, 0, 0, 18),
		UDim2.new(1, 0, 0, 4),
		Vector2.new(1, 0)
	)
	timerLabel.TextXAlignment = Enum.TextXAlignment.Right
	list = Ui.new("Frame", {
		Name = "Rows",
		Size = UDim2.new(1, 0, 1, -36),
		Position = UDim2.fromOffset(0, 36),
		BackgroundTransparency = 1,
		ZIndex = 3,
		Parent = body,
	})
	Ui.new("UIListLayout", {
		Padding = UDim.new(0, 8),
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = list,
	})
	for index = 1, Challenges.PerDay do
		rows[index] = buildRow(list, index)
	end
end

local function onChallengeCompleted(id: unknown)
	local def = if typeof(id) == "string" then Challenges.Get(id) else nil
	if not def then
		return
	end
	RoundHud.Toast(`CHALLENGE DONE! +{def.Reward}`, DONE_COLOR)
	Sfx.Play("Unlock")
end

function ChallengesHud.Init()
	build()
	folded = Input.GetScheme() == "Touch"
	ProfileClient.Changed:Connect(refresh)
	MatchClient.LocalChanged:Connect(refresh)
	Remotes.Event("ChallengeCompleted").OnClientEvent:Connect(onChallengeCompleted)
	refresh()
	task.spawn(function()
		while true do
			task.wait(CLOCK_REFRESH)
			if panel.Root.Visible then
				refreshClock()
			end
		end
	end)
end

return ChallengesHud
