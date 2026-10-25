--!strict
-- The lobby menu: a big PLAY button that joins the matchmaking queue (it turns into CANCEL while
-- you're queued) and a line saying what's happening: players still needed, the countdown, or the
-- match currently in progress. Beside PLAY are PARTY (the party screen; LB) and INVITE
-- (Roblox's invite-a-friend screen), and a sticker shows the friend bonus when your friends are
-- here. Hidden while you're taking part in a match.

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage.Shared
local Config = require(Shared.Config)
local Match = require(Shared.Match)
local Remotes = require(Shared.Remotes)
local Theme = require(Shared.Theme)
local Ui = require(Shared.Ui)

local Hud = require(script.Parent.Hud)
local Input = require(script.Parent.InputController)
local MatchClient = require(script.Parent.MatchClient)
local PartyController = require(script.Parent.PartyController)

local MenuController = {}

local QUEUE_ACTION = "WobbleToggleQueue"
local REQUEST_COOLDOWN = 0.6
local REFRESH_INTERVAL = 0.25

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
}

local localPlayer = Players.LocalPlayer
local widgets: Widgets? = nil
local waitingForServer = false
local gamepadBound = false

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
	if not visible then
		return
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

local function build()
	local panel = Ui.panel(Hud.GetTopStack(), UDim2.fromOffset(380, 132), UDim2.new(), Vector2.zero)
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
	local partyHint: ImageLabel = Ui.new("ImageLabel", {
		Name = "GamepadHint",
		Image = UserInputService:GetImageForKeyCode(Enum.KeyCode.ButtonL1),
		Size = UDim2.fromOffset(22, 22),
		Position = UDim2.new(0, -6, 0.5, 0),
		AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundTransparency = 1,
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
	}
end

function MenuController.Init()
	build()
	MatchClient.Changed:Connect(refresh)
	MatchClient.LocalChanged:Connect(refresh)
	Input.SchemeChanged:Connect(refresh)
	PartyController.Changed:Connect(refresh)
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
