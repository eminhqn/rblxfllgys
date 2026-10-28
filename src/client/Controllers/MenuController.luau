--!strict
-- The lobby menu: a big PLAY button that joins the matchmaking queue (it turns into CANCEL while
-- you're queued) and a line saying what's happening: players still needed, the countdown, or the
-- match currently in progress. Beside PLAY are PARTY (the party screen; LB) and INVITE
-- (Roblox's invite-a-friend screen), and a sticker shows the friend bonus when your friends are
-- here. Knocked out of a match that's still on, a row below lets you WATCH MATCH again (D-pad
-- left) or REVIVE for its next round (D-pad right; ReviveClient). Hidden while you're taking part
-- in a match.

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Config = require(Shared.Config)
local Match = require(Shared.Match)
local Remotes = require(Shared.Remotes)
local Theme = require(Shared.Theme)
local Ui = require(Shared.Ui)

local Hud = require(script.Parent.Hud)
local Input = require(script.Parent.InputController)
local KeyIcon = require(script.Parent.KeyIcon)
local MatchClient = require(script.Parent.MatchClient)
local PartyController = require(script.Parent.PartyController)
local ReviveClient = require(script.Parent.ReviveClient)

local MenuController = {}

local QUEUE_ACTION = "WobbleToggleQueue"
local WATCH_ACTION = "WobbleWatchMatch"
local REVIVE_ACTION = "WobbleLobbyRevive"
local REQUEST_COOLDOWN = 0.6
local REFRESH_INTERVAL = 0.25
local PANEL_WIDTH = 380
local PANEL_HEIGHT = 132
local OUT_ROW_HEIGHT = 56 -- the WATCH MATCH / REVIVE row

local Attr = Match.Attr

type Widgets = {
	Panel: Ui.Panel,
	Button: TextButton,
	ButtonLabel: TextLabel,
	GamepadHint: TextLabel,
	Status: TextLabel,
	PartyLabel: TextLabel,
	PartyHint: ImageLabel,
	Sticker: Frame,
	StickerLabel: TextLabel,
	OutRow: Frame,
	Watch: TextButton,
	WatchHint: ImageLabel,
	Revive: TextButton,
	ReviveLabel: TextLabel,
	ReviveHint: ImageLabel,
}

local localPlayer = Players.LocalPlayer
local widgets: Widgets? = nil
local waitingForServer = false
local gamepadBound = false
local outBound = false
local lastWatch = -math.huge

local function formatSeconds(seconds: number): string
	local whole = math.max(0, math.ceil(seconds))
	return string.format("%d:%02d", whole // 60, whole % 60)
end

local function statusText(): string
	local phase = MatchClient.GetPhase()
	local queued = MatchClient.IsQueued()
	local count = MatchClient.GetNumber(Attr.QueueCount)
	local minimum = math.max(1, MatchClient.GetNumber(Attr.QueueMin))
	local maximum = MatchClient.GetNumber(Attr.QueueMax)

	if phase == "Queue" then
		return `Match starts in {formatSeconds(MatchClient.TimeLeft())} · {count} / {maximum} players`
	elseif phase == "Idle" then
		if count == 0 then
			return "Press PLAY to join the next match"
		end
		local needed = math.max(0, minimum - count)
		if needed == 0 then
			return "Starting soon..."
		end
		return `Waiting for {needed} more player{if needed == 1 then "" else "s"} · {count} queued`
	elseif phase == "Winner" then
		return "Match over!"
	end
	local round = MatchClient.GetNumber(Attr.RoundNumber)
	local name = MatchClient.GetString(Attr.RoundName)
	if queued then
		return `Match in progress (round {round}: {name}). You're in the next one!`
	end
	return `Match in progress (round {round}: {name}). Press PLAY for the next one`
end

local function toggleQueue()
	local ui = widgets
	if waitingForServer or not ui then
		return
	end
	waitingForServer = true
	Ui.pressBounce(ui.Button)
	Remotes.Event("RequestQueue"):FireServer(not MatchClient.IsQueued())
	task.delay(REQUEST_COOLDOWN, function()
		waitingForServer = false
	end)
end

-- Knocked out of the match that's on (and back here in the lobby).
local function outOfMatch(): boolean
	local phase = MatchClient.GetPhase()
	return MatchClient.GetStatus() == "None"
		and localPlayer:GetAttribute(Match.PlayerAttr.KnockedOut) == true
		and (phase == "Loading" or phase == "Intro" or phase == "Playing" or phase == "RoundOver")
end

local function watchMatch()
	local now = os.clock()
	if now - lastWatch < REQUEST_COOLDOWN or not outOfMatch() then
		return
	end
	lastWatch = now
	local ui = widgets
	if ui then
		Ui.pressBounce(ui.Watch)
	end
	Remotes.Event("RequestWatchMatch"):FireServer()
end

local function reviveFromLobby()
	local ui = widgets
	if not ui or not outOfMatch() or not ReviveClient.Available() then
		return
	end
	Ui.pressBounce(ui.Revive)
	ReviveClient.Revive()
end

-- D-pad left / right for WATCH MATCH and REVIVE while that row shows.
local function setOutBinding(bound: boolean)
	if bound == outBound then
		return
	end
	outBound = bound
	if not bound then
		ContextActionService:UnbindAction(WATCH_ACTION)
		ContextActionService:UnbindAction(REVIVE_ACTION)
		return
	end
	local function handler(callback: () -> ())
		return function(_: string, state: Enum.UserInputState): Enum.ContextActionResult
			if state == Enum.UserInputState.Begin then
				callback()
			end
			return Enum.ContextActionResult.Sink
		end
	end
	ContextActionService:BindAction(WATCH_ACTION, handler(watchMatch), false, Enum.KeyCode.DPadLeft)
	ContextActionService:BindAction(REVIVE_ACTION, handler(reviveFromLobby), false, Enum.KeyCode.DPadRight)
end

local function setGamepadBinding(bound: boolean)
	if bound == gamepadBound then
		return
	end
	gamepadBound = bound
	if bound then
		ContextActionService:BindAction(
			QUEUE_ACTION,
			function(_: string, state: Enum.UserInputState): Enum.ContextActionResult
				if state == Enum.UserInputState.Begin then
					toggleQueue()
				end
				return Enum.ContextActionResult.Sink
			end,
			false,
			Enum.KeyCode.ButtonY
		)
	else
		ContextActionService:UnbindAction(QUEUE_ACTION)
	end
end

local function refresh()
	local ui = widgets
	if not ui then
		return
	end
	local visible = MatchClient.GetStatus() == "None"
	ui.Panel.Root.Visible = visible
	setGamepadBinding(visible)
	local out = visible and outOfMatch()
	setOutBinding(out)
	if not visible then
		return
	end
	ui.OutRow.Visible = out
	ui.Panel.Root.Size = UDim2.fromOffset(PANEL_WIDTH, PANEL_HEIGHT + (if out then OUT_ROW_HEIGHT else 0))
	if out then
		local canRevive, reviveText = ReviveClient.Available()
		ui.Revive.Visible = canRevive
		ui.ReviveLabel.Text = reviveText
		ui.Watch.Size = UDim2.new(if canRevive then 0.5 else 1, if canRevive then -5 else 0, 1, 0)
		local gamepad = Input.GetScheme() == "Gamepad"
		ui.WatchHint.Visible = gamepad and ui.WatchHint.Image ~= ""
		ui.ReviveHint.Visible = gamepad and ui.ReviveHint.Image ~= ""
	end
	local queued = MatchClient.IsQueued()
	ui.ButtonLabel.Text = if queued then "CANCEL" else "PLAY"
	ui.ButtonLabel.TextColor3 = if queued then Theme.Colors.White else Theme.Colors.Ink
	ui.Button.BackgroundColor3 = if queued then Theme.Colors.Pink else Theme.Colors.Yellow
	local gamepad = Input.GetScheme() == "Gamepad"
	ui.GamepadHint.Visible = gamepad
	ui.PartyHint.Visible = gamepad and ui.PartyHint.Image ~= ""
	ui.Status.Text = statusText()
	local partySize = PartyController.GetPartySize()
	ui.PartyLabel.Text = if partySize > 0 then `PARTY {partySize}/{Config.Social.PartyMaxSize}` else "PARTY"
	-- The friend bonus you'd get if your friends here play in the same match.
	local friends = localPlayer:GetAttribute(Match.PlayerAttr.FriendsHere)
	local friendCount = if typeof(friends) == "number" then friends else 0
	ui.Sticker.Visible = friendCount > 0
	local bonus = if friendCount >= 2 then Config.Social.FriendBonusMore else Config.Social.FriendBonusOne
	ui.StickerLabel.Text = `+{math.floor(bonus * 100 + 0.5)}% FRIEND BONUS`
end

-- A small rounded button with a white rim, beside PLAY.
local function sideButton(parent: Instance, text: string, y: number, color: Color3): (TextButton, TextLabel)
	local button: TextButton = Ui.new("TextButton", {
		Text = "",
		AutoButtonColor = false,
		Size = UDim2.fromOffset(122, 31),
		Position = UDim2.new(1, -18, 0, y),
		AnchorPoint = Vector2.new(1, 0),
		BackgroundColor3 = color,
		BorderSizePixel = 0,
		ZIndex = 3,
		Parent = parent,
	})
	Ui.corner(button, UDim.new(0.5, 0))
	Ui.stroke(button, Theme.Colors.White, 2)
	local label = Ui.label(
		button,
		text,
		Theme.Fonts.Display,
		Theme.Colors.White,
		UDim2.new(1, -20, 1, -10),
		UDim2.fromScale(0.5, 0.5),
		Vector2.new(0.5, 0.5)
	)
	label.ZIndex = 4
	return button, label
end

-- A button in the WATCH MATCH / REVIVE row, with its D-pad picture for controllers.
local function outButton(
	parent: Instance,
	text: string,
	color: Color3,
	keyCode: Enum.KeyCode
): (TextButton, TextLabel, ImageLabel)
	local button: TextButton = Ui.new("TextButton", {
		Text = "",
		AutoButtonColor = false,
		Size = UDim2.new(0.5, -5, 1, 0),
		BackgroundColor3 = color,
		BorderSizePixel = 0,
		ZIndex = 3,
		Parent = parent,
	})
	Ui.corner(button, UDim.new(0, 14))
	Ui.stroke(button, Theme.Colors.White, 2)
	local label = Ui.label(
		button,
		text,
		Theme.Fonts.Display,
		Theme.Colors.White,
		UDim2.new(1, -44, 1, -14),
		UDim2.new(0.5, 10, 0.5, 0),
		Vector2.new(0.5, 0.5)
	)
	label.ZIndex = 4
	Ui.textOutline(label, Theme.Colors.Ink, 1.5)
	local hint = KeyIcon.new(keyCode, {
		Size = UDim2.fromOffset(24, 24),
		Position = UDim2.new(0, 8, 0.5, 0),
		AnchorPoint = Vector2.new(0, 0.5),
		Visible = false,
		ZIndex = 5,
		Parent = button,
	})
	return button, label, hint
end

local function build()
	local panel = Ui.panel(Hud.GetTopStack(), UDim2.fromOffset(PANEL_WIDTH, PANEL_HEIGHT), UDim2.new(), Vector2.zero)
	panel.Root.LayoutOrder = Hud.TopOrder.Menu
	local status = Ui.label(
		panel.Body,
		"",
		Theme.Fonts.Body,
		Theme.Colors.InkSoft,
		UDim2.new(1, -28, 0, 24),
		UDim2.new(0.5, 0, 0, 12),
		Vector2.new(0.5, 0)
	)

	local button: TextButton = Ui.new("TextButton", {
		Name = "PlayButton",
		Text = "",
		AutoButtonColor = false,
		Size = UDim2.fromOffset(212, 66),
		Position = UDim2.fromOffset(18, 48),
		BackgroundColor3 = Theme.Colors.Yellow,
		BorderSizePixel = 0,
		ZIndex = 3,
		Parent = panel.Body,
	})
	Ui.corner(button, UDim.new(0, 20))
	Ui.stroke(button, Theme.Colors.White, 3)
	local buttonLabel = Ui.label(
		button,
		"PLAY",
		Theme.Fonts.Display,
		Theme.Colors.Ink,
		UDim2.new(1, -40, 1, -18),
		UDim2.fromScale(0.5, 0.5),
		Vector2.new(0.5, 0.5)
	)
	buttonLabel.ZIndex = 4
	local gamepadHint = Ui.label(
		button,
		"Y",
		Theme.Fonts.Display,
		Theme.Colors.White,
		UDim2.fromOffset(30, 30),
		UDim2.new(1, -12, 0.5, 0),
		Vector2.new(1, 0.5)
	)
	gamepadHint.ZIndex = 4
	gamepadHint.BackgroundTransparency = 0
	gamepadHint.BackgroundColor3 = Theme.Colors.Ink
	Ui.corner(gamepadHint, UDim.new(0.5, 0))

	button.Activated:Connect(toggleQueue)

	local partyButton, partyLabel = sideButton(panel.Body, "PARTY", 48, Theme.Colors.Purple)
	partyButton.Activated:Connect(function()
		Ui.pressBounce(partyButton)
		PartyController.Open()
	end)
	local partyHint = KeyIcon.new(Enum.KeyCode.ButtonL1, {
		Name = "GamepadHint",
		Size = UDim2.fromOffset(24, 24),
		Position = UDim2.new(0, -6, 0.5, 0),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Visible = false,
		ZIndex = 5,
		Parent = partyButton,
	})
	local inviteButton = sideButton(panel.Body, "INVITE", 84, Theme.Colors.Aqua)
	inviteButton.Activated:Connect(function()
		Ui.pressBounce(inviteButton)
		PartyController.PromptGameInvite()
	end)

	-- A sticker on the corner when your friends are here.
	local sticker: Frame = Ui.new("Frame", {
		Name = "FriendBonus",
		Size = UDim2.fromOffset(172, 28),
		Position = UDim2.new(1, 8, 0, -4),
		AnchorPoint = Vector2.new(1, 0.5),
		Rotation = 4,
		BackgroundColor3 = Theme.Colors.Lime,
		BorderSizePixel = 0,
		Visible = false,
		ZIndex = 6,
		Parent = panel.Body,
	})
	sticker:SetAttribute("TouchTransparency", 0)
	Ui.corner(sticker, UDim.new(0.5, 0))
	Ui.stroke(sticker, Theme.Colors.White, 2)
	local stickerLabel = Ui.label(
		sticker,
		"",
		Theme.Fonts.Display,
		Theme.Colors.Ink,
		UDim2.new(1, -18, 1, -8),
		UDim2.fromScale(0.5, 0.5),
		Vector2.new(0.5, 0.5)
	)
	stickerLabel.ZIndex = 7

	-- Knocked out of the match that's on: watch it again, or revive.
	local outRow: Frame = Ui.new("Frame", {
		Name = "OutOfMatch",
		Size = UDim2.new(1, -36, 0, OUT_ROW_HEIGHT - 12),
		Position = UDim2.fromOffset(18, PANEL_HEIGHT - 6),
		BackgroundTransparency = 1,
		Visible = false,
		ZIndex = 3,
		Parent = panel.Body,
	})
	local watch, _, watchHint = outButton(outRow, "WATCH MATCH", Theme.Colors.Purple, Enum.KeyCode.DPadLeft)
	watch.Activated:Connect(watchMatch)
	local reviveButton, reviveLabel, reviveHint =
		outButton(outRow, "REVIVE", ReviveClient.Color, Enum.KeyCode.DPadRight)
	reviveButton.Position = UDim2.fromScale(1, 0)
	reviveButton.AnchorPoint = Vector2.new(1, 0)
	reviveButton.Visible = false
	reviveButton.Activated:Connect(reviveFromLobby)

	Ui.popIn(panel.Root, 0.25)
	widgets = {
		Panel = panel,
		Button = button,
		ButtonLabel = buttonLabel,
		GamepadHint = gamepadHint,
		Status = status,
		PartyLabel = partyLabel,
		PartyHint = partyHint,
		Sticker = sticker,
		StickerLabel = stickerLabel,
		OutRow = outRow,
		Watch = watch,
		WatchHint = watchHint,
		Revive = reviveButton,
		ReviveLabel = reviveLabel,
		ReviveHint = reviveHint,
	}
end

function MenuController.Init()
	build()
	MatchClient.Changed:Connect(refresh)
	MatchClient.LocalChanged:Connect(refresh)
	Input.SchemeChanged:Connect(refresh)
	PartyController.Changed:Connect(refresh)
	ReviveClient.Changed:Connect(refresh)
	refresh()

	-- Keeps the countdown ticking.
	task.spawn(function()
		while true do
			task.wait(REFRESH_INTERVAL)
			local ui = widgets
			if ui and ui.Panel.Root.Visible then
				ui.Status.Text = statusText()
			end
		end
	end)
end

return MenuController
