--!strict
-- The DOUBLE XP WEEKEND banner in the lobby (Shared/Events): "2X XP WEEKEND!" with how long is
-- left while it's on, and a smaller heads-up during the day before the next one starts. The server
-- doubles the XP itself (ProgressService); this only shows it.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local Events = require(Shared.Events)
local Theme = require(Shared.Theme)
local Ui = require(Shared.Ui)

local Hud = require(script.Parent.Hud)
local MatchClient = require(script.Parent.MatchClient)

local EventHud = {}

local PANEL_SIZE = Vector2.new(300, 58)
local HEADS_UP = 24 * 3600 -- seconds before a weekend starts that the banner says so
local GOLD = Color3.fromRGB(255, 190, 40)

local panel: Ui.Panel
local title: TextLabel
local detail: TextLabel

local function refresh()
	local now = Workspace:GetServerTimeNow()
	local active, at = Events.DoubleXP(now)
	local soon = not active and at - now <= HEADS_UP
	panel.Root.Visible = (active or soon) and not MatchClient.IsInMatchFlow()
	if active then
		title.Text = "2X XP WEEKEND!"
		title.TextColor3 = GOLD
		detail.Text = `ALL XP DOUBLED  ·  ENDS IN {Events.Countdown(now, at)}`
	elseif soon then
		title.Text = "2X XP WEEKEND SOON"
		title.TextColor3 = Theme.Colors.Purple
		detail.Text = `STARTS IN {Events.Countdown(now, at)}`
	end
end

local function build()
	panel = Ui.panel(Hud.GetTopStack(), UDim2.fromOffset(PANEL_SIZE.X, PANEL_SIZE.Y), UDim2.new(), Vector2.zero)
	panel.Root.LayoutOrder = Hud.TopOrder.Event
	panel.Root.Visible = false
	Hud.MoveRightOnTouch(panel.Root)
	title = Ui.label(
		panel.Body,
		"",
		Theme.Fonts.Display,
		GOLD,
		UDim2.new(1, -20, 0, 26),
		UDim2.new(0.5, 0, 0, 6),
		Vector2.new(0.5, 0)
	)
	title.ZIndex = 3
	Ui.textOutline(title, Theme.Colors.Ink, 1.5)
	detail = Ui.label(
		panel.Body,
		"",
		Theme.Fonts.Display,
		Theme.Colors.InkSoft,
		UDim2.new(1, -20, 0, 16),
		UDim2.new(0.5, 0, 0, 34),
		Vector2.new(0.5, 0)
	)
	detail.ZIndex = 3
end

function EventHud.Init()
	build()
	MatchClient.LocalChanged:Connect(refresh)
	refresh()
	task.spawn(function()
		while true do
			task.wait(10)
			refresh()
		end
	end)
end

return EventHud
