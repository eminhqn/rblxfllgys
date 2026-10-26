--!strict
-- The settings screen: sound volume, camera moments (the round intro glide and the winner camera),
-- camera shake and the controls list in the corner. Changes apply straight away and are saved
-- with your profile (ClientSettings).
--
-- Open it with the gear button next to your Crowns and Gumdrops (any time, even mid-round) or
-- D-pad left on a controller. While it's open your Bloblet's controls are paused, so nothing you
-- press moves or turns anything but the menu. With a controller, up / down (or the left stick)
-- picks a row, left / right changes it, A toggles and B closes.

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local PlayerSettings = require(Shared.PlayerSettings)
local Theme = require(Shared.Theme)
local Ui = require(Shared.Ui)

local ClientSettings = require(script.Parent.ClientSettings)
local Input = require(script.Parent.InputController)
local KeyIcon = require(script.Parent.KeyIcon)
local ProfileClient = require(script.Parent.ProfileClient)
local ResponsiveScale = require(script.Parent.ResponsiveScale)
local Sfx = require(script.Parent.Sfx)
local WalletHud = require(script.Parent.WalletHud)

local SettingsController = {}

type ToggleKey = "CameraMoments" | "CameraShake" | "ControlsHint"

type Row = {
	Frame: Frame,
	Stroke: UIStroke,
	Change: (direction: number) -> (), -- left / right on a controller
	Activate: () -> (), -- A on a controller
	Refresh: () -> (),
}

local OPEN_ACTION = "WobbleSettingsOpen"
local CLOSE_ACTION = "WobbleSettingsClose"
local NAVIGATE_ACTION = "WobbleSettingsNavigate"
local CONFIRM_ACTION = "WobbleSettingsConfirm"
local SWALLOW_ACTION = "WobbleSettingsSwallow"
local GAMEPAD_ACTIONS = { CLOSE_ACTION, NAVIGATE_ACTION, CONFIRM_ACTION, SWALLOW_ACTION }
-- Every other controller input is swallowed while the menu is open (the right stick would
-- otherwise turn the camera).
local SWALLOWED_KEYS = {
	Enum.KeyCode.ButtonX,
	Enum.KeyCode.ButtonY,
	Enum.KeyCode.ButtonL1,
	Enum.KeyCode.ButtonR1,
	Enum.KeyCode.ButtonL2,
	Enum.KeyCode.ButtonR2,
	Enum.KeyCode.ButtonL3,
	Enum.KeyCode.ButtonR3,
	Enum.KeyCode.ButtonSelect,
	Enum.KeyCode.Thumbstick2,
}

local WINDOW_SIZE = Vector2.new(560, 440)
local ROW_HEIGHT = 70
local VOLUME_SEGMENTS = 10
local STICK_THRESHOLD = 0.6
local STICK_REPEAT = 0.25

local WHITE = Theme.Colors.White
local OFF_COLOR = Color3.fromRGB(206, 198, 226)

local localPlayer = Players.LocalPlayer
local gui: ScreenGui
local windowPanel: Frame
local openButton: TextButton
local openHint: ImageLabel
local rows: { Row } = {}
local selected = 1
local isOpen = false
local lastStickMove = 0

local function refreshAll()
	for index, row in rows do
		row.Refresh()
		row.Stroke.Enabled = isOpen and Input.GetScheme() == "Gamepad" and index == selected
	end
end

local function buildRowFrame(parent: Instance, order: number, title: string, detail: string): (Frame, UIStroke)
	local frame: Frame = Ui.new("Frame", {
		Name = title,
		Size = UDim2.new(1, 0, 0, ROW_HEIGHT),
		BackgroundColor3 = Theme.Colors.PanelTint,
		BorderSizePixel = 0,
		LayoutOrder = order,
		ZIndex = 3,
		Parent = parent,
	})
	Ui.corner(frame, UDim.new(0, 14))
	local stroke = Ui.stroke(frame, Theme.Colors.Pink, 3)
	stroke.Enabled = false
	local titleLabel = Ui.label(
		frame,
		title,
		Theme.Fonts.Display,
		Theme.Colors.Ink,
		UDim2.new(0.55, 0, 0, 26),
		UDim2.fromOffset(16, 10)
	)
	titleLabel.TextXAlignment = Enum.TextXAlignment.Left
	titleLabel.ZIndex = 4
	local detailLabel = Ui.label(
		frame,
		detail,
		Theme.Fonts.Body,
		Theme.Colors.InkSoft,
		UDim2.new(0.55, 0, 0, 20),
		UDim2.fromOffset(16, 40)
	)
	detailLabel.TextXAlignment = Enum.TextXAlignment.Left
	detailLabel.ZIndex = 4
	return frame, stroke
end

local function smallButton(parent: Instance, text: string, position: UDim2): TextButton
	local button: TextButton = Ui.new("TextButton", {
		Text = "",
		AutoButtonColor = false,
		Size = UDim2.fromOffset(40, 40),
		Position = position,
		AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundColor3 = Theme.Colors.Purple,
		BorderSizePixel = 0,
		ZIndex = 4,
		Parent = parent,
	})
	Ui.corner(button, UDim.new(0.5, 0))
	local label = Ui.label(
		button,
		text,
		Theme.Fonts.Display,
		WHITE,
		UDim2.new(1, -12, 1, -12),
		UDim2.fromScale(0.5, 0.5),
		Vector2.new(0.5, 0.5)
	)
	label.ZIndex = 5
	return button
end

local function changeVolume(direction: number)
	local volume = ClientSettings.Get().Volume + direction * PlayerSettings.VolumeStep
	ClientSettings.Set({ Volume = math.clamp(volume, 0, 1) })
	Sfx.Play("UiClick") -- a sample at the new volume
end

local function buildVolumeRow(parent: Instance, order: number): Row
	local frame, stroke = buildRowFrame(parent, order, "SOUND VOLUME", "Every sound in the game")
	local minus = smallButton(frame, "-", UDim2.new(1, -262, 0.5, 0))
	local plus = smallButton(frame, "+", UDim2.new(1, -72, 0.5, 0))
	local bar: Frame = Ui.new("Frame", {
		Name = "Bar",
		Size = UDim2.fromOffset(140, 22),
		Position = UDim2.new(1, -167, 0.5, 0),
		AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundTransparency = 1,
		ZIndex = 4,
		Parent = frame,
	})
	Ui.new("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		Padding = UDim.new(0, 2),
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = bar,
	})
	local segments: { Frame } = {}
	for index = 1, VOLUME_SEGMENTS do
		local segment: Frame = Ui.new("Frame", {
			Size = UDim2.new(1 / VOLUME_SEGMENTS, -2, 1, 0),
			BackgroundColor3 = OFF_COLOR,
			BorderSizePixel = 0,
			LayoutOrder = index,
			ZIndex = 4,
			Parent = bar,
		})
		Ui.corner(segment, UDim.new(0, 4))
		segments[index] = segment
	end
	local value = Ui.label(
		frame,
		"",
		Theme.Fonts.Display,
		Theme.Colors.Purple,
		UDim2.fromOffset(52, 24),
		UDim2.new(1, -10, 0.5, 0),
		Vector2.new(1, 0.5)
	)
	value.ZIndex = 4
	minus.Activated:Connect(function()
		changeVolume(-1)
	end)
	plus.Activated:Connect(function()
		changeVolume(1)
	end)
	return {
		Frame = frame,
		Stroke = stroke,
		Change = changeVolume,
		Activate = function() end,
		Refresh = function()
			local volume = ClientSettings.Get().Volume
			local lit = math.round(volume * VOLUME_SEGMENTS)
			for index, segment in segments do
				segment.BackgroundColor3 = if index <= lit then Theme.Colors.Pink else OFF_COLOR
			end
			value.Text = `{math.round(volume * 100)}%`
		end,
	}
end

local function buildToggleRow(parent: Instance, order: number, key: ToggleKey, title: string, detail: string): Row
	local frame, stroke = buildRowFrame(parent, order, title, detail)
	local pill: TextButton = Ui.new("TextButton", {
		Name = "Toggle",
		Text = "",
		AutoButtonColor = false,
		Size = UDim2.fromOffset(110, 40),
		Position = UDim2.new(1, -16, 0.5, 0),
		AnchorPoint = Vector2.new(1, 0.5),
		BackgroundColor3 = Theme.Colors.Lime,
		BorderSizePixel = 0,
		ZIndex = 4,
		Parent = frame,
	})
	Ui.corner(pill, UDim.new(0.5, 0))
	local knob: Frame = Ui.new("Frame", {
		Size = UDim2.fromOffset(32, 32),
		Position = UDim2.new(1, -4, 0.5, 0),
		AnchorPoint = Vector2.new(1, 0.5),
		BackgroundColor3 = WHITE,
		BorderSizePixel = 0,
		ZIndex = 5,
		Parent = pill,
	})
	Ui.corner(knob, UDim.new(0.5, 0))
	local text = Ui.label(
		pill,
		"ON",
		Theme.Fonts.Display,
		WHITE,
		UDim2.fromOffset(56, 24),
		UDim2.new(0, 14, 0.5, 0),
		Vector2.new(0, 0.5)
	)
	text.ZIndex = 5

	local function isOn(): boolean
		return (ClientSettings.Get() :: any)[key] == true
	end
	local function set(on: boolean)
		if on ~= isOn() then
			ClientSettings.Set({ [key] = on })
		end
	end
	pill.Activated:Connect(function()
		Ui.pressBounce(pill)
		set(not isOn())
	end)
	return {
		Frame = frame,
		Stroke = stroke,
		Change = function(direction: number)
			set(direction > 0)
		end,
		Activate = function()
			Ui.pressBounce(pill)
			set(not isOn())
			Sfx.Play("UiClick")
		end,
		Refresh = function()
			local on = isOn()
			pill.BackgroundColor3 = if on then Theme.Colors.Lime else OFF_COLOR
			text.Text = if on then "ON" else "OFF"
			text.Position = if on then UDim2.new(0, 14, 0.5, 0) else UDim2.new(1, -14, 0.5, 0)
			text.AnchorPoint = if on then Vector2.new(0, 0.5) else Vector2.new(1, 0.5)
			text.TextXAlignment = if on then Enum.TextXAlignment.Left else Enum.TextXAlignment.Right
			knob.Position = if on then UDim2.new(1, -4, 0.5, 0) else UDim2.new(0, 4, 0.5, 0)
			knob.AnchorPoint = if on then Vector2.new(1, 0.5) else Vector2.new(0, 0.5)
		end,
	}
end

local setOpen: (open: boolean) -> ()

local function onPress(callback: (input: InputObject) -> ())
	return function(_name: string, state: Enum.UserInputState, input: InputObject): Enum.ContextActionResult
		if state == Enum.UserInputState.Begin then
			callback(input)
		end
		return Enum.ContextActionResult.Sink
	end
end

local function move(direction: Vector2)
	if direction.Y ~= 0 then
		selected = math.clamp(selected + direction.Y, 1, #rows)
		Sfx.Play("UiClick")
	elseif direction.X ~= 0 then
		rows[selected].Change(direction.X)
	end
	refreshAll()
end

local function onNavigate(_name: string, state: Enum.UserInputState, input: InputObject): Enum.ContextActionResult
	if input.KeyCode == Enum.KeyCode.Thumbstick1 then
		local stick = input.Position
		local now = os.clock()
		if Vector2.new(stick.X, stick.Y).Magnitude < STICK_THRESHOLD or now - lastStickMove < STICK_REPEAT then
			return Enum.ContextActionResult.Sink
		end
		lastStickMove = now
		if math.abs(stick.X) > math.abs(stick.Y) then
			move(Vector2.new(math.sign(stick.X), 0))
		else
			move(Vector2.new(0, -math.sign(stick.Y))) -- stick up = previous row
		end
		return Enum.ContextActionResult.Sink
	end
	if state ~= Enum.UserInputState.Begin then
		return Enum.ContextActionResult.Sink
	end
	local key = input.KeyCode
	if key == Enum.KeyCode.DPadUp then
		move(Vector2.new(0, -1))
	elseif key == Enum.KeyCode.DPadDown then
		move(Vector2.new(0, 1))
	elseif key == Enum.KeyCode.DPadLeft then
		move(Vector2.new(-1, 0))
	elseif key == Enum.KeyCode.DPadRight then
		move(Vector2.new(1, 0))
	end
	return Enum.ContextActionResult.Sink
end

-- While the screen is open these sit above everything else, so the D-pad, the left stick, A and B
-- work the menu and every other button does nothing.
local function bindGamepad()
	local high = Enum.ContextActionPriority.High.Value + 10 -- above the customise screen's
	ContextActionService:BindActionAtPriority(
		CLOSE_ACTION,
		onPress(function()
			setOpen(false)
		end),
		false,
		high,
		Enum.KeyCode.ButtonB,
		Enum.KeyCode.ButtonStart
	)
	ContextActionService:BindActionAtPriority(
		NAVIGATE_ACTION,
		onNavigate,
		false,
		high,
		Enum.KeyCode.DPadLeft,
		Enum.KeyCode.DPadRight,
		Enum.KeyCode.DPadUp,
		Enum.KeyCode.DPadDown,
		Enum.KeyCode.Thumbstick1
	)
	ContextActionService:BindActionAtPriority(
		CONFIRM_ACTION,
		onPress(function()
			rows[selected].Activate()
			refreshAll()
		end),
		false,
		high,
		Enum.KeyCode.ButtonA
	)
	ContextActionService:BindActionAtPriority(SWALLOW_ACTION, function(): Enum.ContextActionResult
		return Enum.ContextActionResult.Sink
	end, false, high, table.unpack(SWALLOWED_KEYS))
end

function setOpen(open: boolean)
	if open == isOpen or (open and not ProfileClient.IsReady()) then
		return
	end
	isOpen = open
	gui.Enabled = open
	-- Your Bloblet's controls pause while the menu is open.
	Input.SetBlocked("Settings", open)
	if open then
		selected = 1
		bindGamepad()
		Ui.popIn(windowPanel)
	else
		for _, action in GAMEPAD_ACTIONS do
			ContextActionService:UnbindAction(action)
		end
	end
	refreshAll()
end

function SettingsController.IsOpen(): boolean
	return isOpen
end

-- A little gear drawn with frames: teeth round a ring, with a hole in the middle.
local function buildGear(parent: Instance)
	local holder: Frame = Ui.new("Frame", {
		Size = UDim2.fromOffset(24, 24),
		Position = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundTransparency = 1,
		ZIndex = 4,
		Parent = parent,
	})
	for index = 0, 3 do
		local tooth: Frame = Ui.new("Frame", {
			Size = UDim2.fromOffset(6, 24),
			Position = UDim2.fromScale(0.5, 0.5),
			AnchorPoint = Vector2.new(0.5, 0.5),
			Rotation = index * 45,
			BackgroundColor3 = WHITE,
			BorderSizePixel = 0,
			ZIndex = 4,
			Parent = holder,
		})
		Ui.corner(tooth, UDim.new(0, 2))
	end
	local ring: Frame = Ui.new("Frame", {
		Size = UDim2.fromOffset(17, 17),
		Position = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundColor3 = WHITE,
		BorderSizePixel = 0,
		ZIndex = 5,
		Parent = holder,
	})
	Ui.corner(ring, UDim.new(0.5, 0))
	local hole: Frame = Ui.new("Frame", {
		Size = UDim2.fromOffset(7, 7),
		Position = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundColor3 = Theme.Colors.Aqua,
		BorderSizePixel = 0,
		ZIndex = 6,
		Parent = holder,
	})
	Ui.corner(hole, UDim.new(0.5, 0))
end

local function buildOpenButton()
	openButton = Ui.new("TextButton", {
		Name = "SettingsButton",
		Text = "",
		AutoButtonColor = false,
		Size = UDim2.fromOffset(40, 40),
		BackgroundColor3 = Theme.Colors.Aqua,
		BorderSizePixel = 0,
		LayoutOrder = 6, -- after the MENU button (phones and tablets) and the NOT SAVING pill
		Parent = WalletHud.GetRow(),
	})
	Ui.corner(openButton, UDim.new(0.5, 0))
	Ui.stroke(openButton, WHITE, 3)
	buildGear(openButton)
	openHint = KeyIcon.new(Enum.KeyCode.DPadLeft, {
		Name = "GamepadHint",
		Size = UDim2.fromOffset(22, 22),
		Position = UDim2.new(1, 4, 1, 4),
		AnchorPoint = Vector2.new(1, 1),
		Visible = false,
		ZIndex = 6,
		Parent = openButton,
	})
	openButton.Activated:Connect(function()
		Ui.pressBounce(openButton)
		setOpen(not isOpen)
	end)
end

local function buildScreen()
	gui = Ui.new("ScreenGui", {
		Name = "Settings",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		DisplayOrder = 32,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		Enabled = false,
		Parent = localPlayer:WaitForChild("PlayerGui"),
	})
	local dim: TextButton = Ui.new("TextButton", {
		Name = "Dim",
		Text = "",
		AutoButtonColor = false,
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Theme.Colors.Shadow,
		BackgroundTransparency = 0.55,
		BorderSizePixel = 0,
		Parent = gui,
	})
	dim.Activated:Connect(function()
		setOpen(false) -- clicking outside the window closes it
	end)
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
	Ui.padding(body, 18)

	local title = Ui.label(
		body,
		"SETTINGS",
		Theme.Fonts.Display,
		Theme.Colors.Purple,
		UDim2.new(1, -60, 0, 36),
		UDim2.fromOffset(0, 0)
	)
	title.TextXAlignment = Enum.TextXAlignment.Left
	local close = smallButton(body, "X", UDim2.new(1, -20, 0, 18))
	close.BackgroundColor3 = Theme.Colors.Pink
	close.Activated:Connect(function()
		setOpen(false)
	end)

	local list: Frame = Ui.new("Frame", {
		Name = "Rows",
		Size = UDim2.new(1, 0, 1, -50),
		Position = UDim2.fromOffset(0, 50),
		BackgroundTransparency = 1,
		ZIndex = 3,
		Parent = body,
	})
	Ui.new("UIListLayout", {
		Padding = UDim.new(0, 12),
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = list,
	})
	rows = {
		buildVolumeRow(list, 1),
		buildToggleRow(list, 2, "CameraMoments", "CAMERA MOMENTS", "Round intro glide and winner camera"),
		buildToggleRow(list, 3, "CameraShake", "CAMERA SHAKE", "When you're bumped or land hard"),
		buildToggleRow(list, 4, "ControlsHint", "CONTROLS LIST", "The keys and buttons in the corner"),
	}
end

local function refreshOpenButton()
	openHint.Visible = Input.GetScheme() == "Gamepad" and openHint.Image ~= ""
	refreshAll()
end

function SettingsController.Init()
	buildScreen()
	buildOpenButton()

	-- D-pad left opens it (while it's open, the D-pad moves round the menu instead).
	ContextActionService:BindAction(
		OPEN_ACTION,
		function(_name: string, state: Enum.UserInputState): Enum.ContextActionResult
			if state == Enum.UserInputState.Begin and ProfileClient.IsReady() then
				setOpen(true)
				return Enum.ContextActionResult.Sink
			end
			return Enum.ContextActionResult.Pass
		end,
		false,
		Enum.KeyCode.DPadLeft
	)
	ClientSettings.Changed:Connect(refreshAll)
	Input.SchemeChanged:Connect(refreshOpenButton)
	refreshOpenButton()
end

return SettingsController
