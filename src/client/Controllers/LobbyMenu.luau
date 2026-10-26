--!strict
-- The lobby MENU: one button that drops down a list of COSMETIC SHOP, ITEMS, GET CROWNS, REWARDS,
-- CUSTOMISE and TUTORIAL, instead of a button for each on screen. On computers and controllers MENU sits on the
-- right side of the screen; on phones and tablets it's in the top-right row with your Crowns.
--
-- LT on a controller opens and closes it. While the list is open your Bloblet stands still and the
-- controller works the list instead: up / down (D-pad or left stick) picks, A opens, B (or LT)
-- closes. A mouse or finger clicks or taps an entry, or anywhere else to close the list. COSMETIC
-- SHOP says NEW! (and MENU gets a dot) until you've looked at today's shop. The old shortcuts still
-- work too: D-pad down for REWARDS, D-pad right for CUSTOMISE.

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Theme = require(Shared.Theme)
local Ui = require(Shared.Ui)

local CrownStoreController = require(script.Parent.CrownStoreController)
local CustomiseController = require(script.Parent.CustomiseController)
local Input = require(script.Parent.InputController)
local ItemStoreController = require(script.Parent.ItemStoreController)
local KeyIcon = require(script.Parent.KeyIcon)
local MatchClient = require(script.Parent.MatchClient)
local PartyController = require(script.Parent.PartyController)
local ProfileClient = require(script.Parent.ProfileClient)
local ResponsiveScale = require(script.Parent.ResponsiveScale)
local RewardTrackController = require(script.Parent.RewardTrackController)
local Sfx = require(script.Parent.Sfx)
local TutorialController = require(script.Parent.TutorialController)
local WalletHud = require(script.Parent.WalletHud)

local LobbyMenu = {}

type Entry = {
	Text: string,
	Note: string,
	Color: Color3,
	Open: () -> (),
	DrawIcon: (parent: Instance) -> (),
}

type Row = {
	Entry: Entry,
	Button: TextButton,
	Stroke: UIStroke,
	Badge: TextLabel?,
}

type MenuButton = {
	Button: TextButton,
	Label: TextLabel,
	Hint: ImageLabel,
	Dot: Frame,
}

local TOGGLE_ACTION = "WobbleLobbyMenu"
local NAVIGATE_ACTION = "WobbleLobbyMenuNavigate"
local CONFIRM_ACTION = "WobbleLobbyMenuConfirm"
local CLOSE_ACTION = "WobbleLobbyMenuClose"
local SWALLOW_ACTION = "WobbleLobbyMenuSwallow"
local LIST_ACTIONS = { NAVIGATE_ACTION, CONFIRM_ACTION, CLOSE_ACTION, SWALLOW_ACTION }
-- While the list is open these do nothing, so your Bloblet stays put.
local SWALLOWED_KEYS = {
	Enum.KeyCode.ButtonX,
	Enum.KeyCode.ButtonY,
	Enum.KeyCode.ButtonL1,
	Enum.KeyCode.ButtonR1,
	Enum.KeyCode.ButtonR2,
	Enum.KeyCode.ButtonL3,
	Enum.KeyCode.ButtonR3,
	Enum.KeyCode.ButtonSelect,
	Enum.KeyCode.DPadLeft,
	Enum.KeyCode.DPadRight,
	Enum.KeyCode.Thumbstick2,
}

local ROW_SIZE = Vector2.new(270, 58)
local ROW_GAP = 8
local LIST_PADDING = 10
local LIST_GAP = 8 -- between the MENU button and the list
local SCREEN_MARGIN = 8 -- the list keeps this far from the screen's edges
local STICK_THRESHOLD = 0.6
local STICK_REPEAT = 0.22
local BADGE_CHECK = 2
local WHITE = Theme.Colors.White
local ROW_COLOR = Theme.Colors.PanelTint
local FOCUS_COLOR = Theme.Colors.Yellow

local localPlayer = Players.LocalPlayer
local deskButton: MenuButton -- the right side of the screen (computers and controllers)
local touchButton: MenuButton -- the top-right row (phones and tablets)
local listGui: ScreenGui
local listHolder: Frame -- placed by the MENU button, and scaled to the screen
local listScale: UIScale
local list: Frame -- inside it; pops in
local rows: { Row } = {}
local isOpen = false
local focusIndex = 1
local lastStickMove = 0
local toggleBound = false

-------------------------------------------------------------------------------------------------
-- Icons (drawn with frames)
-------------------------------------------------------------------------------------------------

local function iconHolder(parent: Instance): Frame
	return Ui.new("Frame", {
		Name = "Icon",
		Size = UDim2.fromOffset(36, 36),
		Position = UDim2.new(0, 12, 0.5, 0),
		AnchorPoint = Vector2.new(0, 0.5),
		BackgroundTransparency = 1,
		ZIndex = 4,
		Parent = parent,
	})
end

-- A shopping bag with a handle.
local function drawBag(parent: Instance)
	local holder = iconHolder(parent)
	local handle: Frame = Ui.new("Frame", {
		Size = UDim2.fromOffset(16, 16),
		Position = UDim2.new(0.5, 0, 0, 8),
		AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundTransparency = 1,
		ZIndex = 4,
		Parent = holder,
	})
	Ui.corner(handle, UDim.new(0.5, 0))
	Ui.stroke(handle, Theme.Colors.Pink, 3)
	local bag: Frame = Ui.new("Frame", {
		Size = UDim2.fromOffset(30, 24),
		Position = UDim2.fromScale(0.5, 1),
		AnchorPoint = Vector2.new(0.5, 1),
		BackgroundColor3 = Theme.Colors.Pink,
		BorderSizePixel = 0,
		ZIndex = 5,
		Parent = holder,
	})
	Ui.corner(bag, UDim.new(0, 6))
end

-- A lightning bolt.
local function drawBolt(parent: Instance)
	local holder = iconHolder(parent)
	for _, piece in
		{
			{ Size = UDim2.fromOffset(8, 20), Position = UDim2.fromOffset(21, 10), Rotation = 25 },
			{ Size = UDim2.fromOffset(18, 7), Position = UDim2.fromOffset(18, 19), Rotation = -10 },
			{ Size = UDim2.fromOffset(8, 20), Position = UDim2.fromOffset(16, 28), Rotation = 25 },
		}
	do
		local frame: Frame = Ui.new("Frame", {
			Size = piece.Size,
			Position = piece.Position,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Rotation = piece.Rotation,
			BackgroundColor3 = Theme.Colors.Orange,
			BorderSizePixel = 0,
			ZIndex = 5,
			Parent = holder,
		})
		Ui.corner(frame, UDim.new(0, 3))
	end
end

local function drawCrown(parent: Instance)
	WalletHud.CrownIcon(iconHolder(parent), 34, UDim2.fromScale(0.5, 0.5), Vector2.new(0.5, 0.5))
end

-- A present with a ribbon.
local function drawGift(parent: Instance)
	local holder = iconHolder(parent)
	local box: Frame = Ui.new("Frame", {
		Size = UDim2.fromOffset(30, 26),
		Position = UDim2.fromScale(0.5, 1),
		AnchorPoint = Vector2.new(0.5, 1),
		BackgroundColor3 = Theme.Colors.Purple,
		BorderSizePixel = 0,
		ZIndex = 5,
		Parent = holder,
	})
	Ui.corner(box, UDim.new(0, 5))
	for _, size in { UDim2.new(0, 7, 1, 0), UDim2.new(1, 0, 0, 7) } do
		Ui.new("Frame", {
			Size = size,
			Position = UDim2.fromScale(0.5, 0.5),
			AnchorPoint = Vector2.new(0.5, 0.5),
			BackgroundColor3 = Theme.Colors.Yellow,
			BorderSizePixel = 0,
			ZIndex = 6,
			Parent = box,
		})
	end
	for _, side in { -1, 1 } do
		local loop: Frame = Ui.new("Frame", {
			Size = UDim2.fromOffset(12, 10),
			Position = UDim2.new(0.5, side * 6, 0, 6),
			AnchorPoint = Vector2.new(0.5, 0.5),
			Rotation = side * 25,
			BackgroundColor3 = Theme.Colors.Yellow,
			BorderSizePixel = 0,
			ZIndex = 6,
			Parent = holder,
		})
		Ui.corner(loop, UDim.new(0.5, 0))
	end
end

-- A question mark in a bubble.
local function drawQuestion(parent: Instance)
	local holder = iconHolder(parent)
	local bubble: Frame = Ui.new("Frame", {
		Size = UDim2.fromOffset(30, 30),
		Position = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundColor3 = Theme.Colors.Lime,
		BorderSizePixel = 0,
		ZIndex = 5,
		Parent = holder,
	})
	Ui.corner(bubble, UDim.new(0.5, 0))
	local mark = Ui.label(
		bubble,
		"?",
		Theme.Fonts.Display,
		Theme.Colors.White,
		UDim2.fromScale(0.8, 0.8),
		UDim2.fromScale(0.5, 0.5),
		Vector2.new(0.5, 0.5)
	)
	mark.ZIndex = 6
end

-- A little Bloblet face.
local function drawBloblet(parent: Instance)
	local holder = iconHolder(parent)
	local body: Frame = Ui.new("Frame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Theme.Colors.Aqua,
		BorderSizePixel = 0,
		ZIndex = 5,
		Parent = holder,
	})
	Ui.corner(body, UDim.new(0.5, 0))
	Ui.stroke(body, WHITE, 2)
	for _, side in { -1, 1 } do
		local eye: Frame = Ui.new("Frame", {
			Size = UDim2.fromOffset(9, 11),
			Position = UDim2.new(0.5, side * 7, 0.4, 0),
			AnchorPoint = Vector2.new(0.5, 0.5),
			BackgroundColor3 = WHITE,
			BorderSizePixel = 0,
			ZIndex = 6,
			Parent = body,
		})
		Ui.corner(eye, UDim.new(0.5, 0))
		local pupil: Frame = Ui.new("Frame", {
			Size = UDim2.fromOffset(5, 6),
			Position = UDim2.fromScale(0.5, 0.6),
			AnchorPoint = Vector2.new(0.5, 0.5),
			BackgroundColor3 = Theme.Colors.Ink,
			BorderSizePixel = 0,
			ZIndex = 7,
			Parent = eye,
		})
		Ui.corner(pupil, UDim.new(0.5, 0))
	end
end

local ENTRIES: { Entry } = {
	{
		Text = "COSMETIC SHOP",
		Note = "New looks every day",
		Color = Theme.Colors.Pink,
		Open = CustomiseController.OpenShop,
		DrawIcon = drawBag,
	},
	{
		Text = "ITEMS",
		Note = "Slaps, respawns, boosts",
		Color = Color3.fromRGB(230, 110, 40),
		Open = ItemStoreController.Open,
		DrawIcon = drawBolt,
	},
	{
		Text = "GET CROWNS",
		Note = "Crown packs",
		Color = Color3.fromRGB(226, 160, 30),
		Open = CrownStoreController.Open,
		DrawIcon = drawCrown,
	},
	{
		Text = "REWARDS",
		Note = "Your level rewards",
		Color = Theme.Colors.Purple,
		Open = RewardTrackController.Open,
		DrawIcon = drawGift,
	},
	{
		Text = "CUSTOMISE",
		Note = "Dress up your Bloblet",
		Color = Color3.fromRGB(30, 170, 190),
		Open = CustomiseController.Open,
		DrawIcon = drawBloblet,
	},
	{
		Text = "TUTORIAL",
		Note = "Learn the moves",
		Color = Color3.fromRGB(80, 170, 60),
		Open = TutorialController.Open,
		DrawIcon = drawQuestion,
	},
}

-------------------------------------------------------------------------------------------------
-- Opening and closing
-------------------------------------------------------------------------------------------------

-- The menu works in the lobby, when no other screen is open.
local function available(): boolean
	return CustomiseController.CanOpen()
		and not CustomiseController.IsOpen()
		and not RewardTrackController.IsOpen()
		and not CrownStoreController.IsOpen()
		and not ItemStoreController.IsOpen()
		and not PartyController.IsOpen()
end

local function showFocus()
	for index, row in rows do
		local focused = index == focusIndex
		row.Stroke.Color = if focused then FOCUS_COLOR else WHITE
		row.Stroke.Thickness = if focused then 5 else 2
		row.Button.BackgroundColor3 = if focused then WHITE else ROW_COLOR
	end
end

-- Drops the list down under whichever MENU button is showing. On a short screen it slides up
-- just enough for the last entry to fit, instead of flipping above the button.
local function placeList()
	local anchor = if touchButton.Button.Visible then touchButton.Button else deskButton.Button
	local listHeight = listHolder.Size.Y.Offset * listScale.Scale
	local right = anchor.AbsolutePosition.X + anchor.AbsoluteSize.X
	local below = anchor.AbsolutePosition.Y + anchor.AbsoluteSize.Y + LIST_GAP
	local lowest = listGui.AbsoluteSize.Y - SCREEN_MARGIN - listHeight
	listHolder.AnchorPoint = Vector2.new(1, 0)
	listHolder.Position = UDim2.fromOffset(right, math.max(math.min(below, lowest), SCREEN_MARGIN))
end

local setOpen: (open: boolean) -> ()

local function choose(index: number)
	local row = rows[index]
	if not row then
		return
	end
	Ui.pressBounce(row.Button)
	Sfx.Play("UiClick")
	setOpen(false)
	row.Entry.Open()
end

local function moveFocus(step: number)
	local nextIndex = math.clamp(focusIndex + step, 1, #rows)
	if nextIndex ~= focusIndex then
		focusIndex = nextIndex
		Sfx.Play("UiClick")
		showFocus()
	end
end

-- While the list is open the controller works the list (above everything else in the lobby).
local function bindList()
	local high = Enum.ContextActionPriority.High.Value + 15
	ContextActionService:BindActionAtPriority(
		NAVIGATE_ACTION,
		function(_name: string, state: Enum.UserInputState, input: InputObject): Enum.ContextActionResult
			if input.KeyCode == Enum.KeyCode.Thumbstick1 then
				local now = os.clock()
				if math.abs(input.Position.Y) >= STICK_THRESHOLD and now - lastStickMove >= STICK_REPEAT then
					lastStickMove = now
					moveFocus(if input.Position.Y > 0 then -1 else 1)
				end
			elseif state == Enum.UserInputState.Begin then
				moveFocus(if input.KeyCode == Enum.KeyCode.DPadUp then -1 else 1)
			end
			return Enum.ContextActionResult.Sink
		end,
		false,
		high,
		Enum.KeyCode.DPadUp,
		Enum.KeyCode.DPadDown,
		Enum.KeyCode.Thumbstick1
	)
	ContextActionService:BindActionAtPriority(
		CONFIRM_ACTION,
		function(_name: string, state: Enum.UserInputState): Enum.ContextActionResult
			if state == Enum.UserInputState.Begin then
				choose(focusIndex)
			end
			return Enum.ContextActionResult.Sink
		end,
		false,
		high,
		Enum.KeyCode.ButtonA
	)
	ContextActionService:BindActionAtPriority(
		CLOSE_ACTION,
		function(_name: string, state: Enum.UserInputState): Enum.ContextActionResult
			if state == Enum.UserInputState.Begin then
				setOpen(false)
			end
			return Enum.ContextActionResult.Sink
		end,
		false,
		high,
		Enum.KeyCode.ButtonB,
		Enum.KeyCode.ButtonL2,
		Enum.KeyCode.ButtonStart
	)
	ContextActionService:BindActionAtPriority(SWALLOW_ACTION, function(): Enum.ContextActionResult
		return Enum.ContextActionResult.Sink
	end, false, high, table.unpack(SWALLOWED_KEYS))
end

function setOpen(open: boolean)
	if open == isOpen or (open and not available()) then
		return
	end
	isOpen = open
	listGui.Enabled = open
	Input.SetBlocked("LobbyMenu", open)
	if open then
		focusIndex = 1
		placeList()
		bindList()
		showFocus()
		Ui.popIn(list)
		Sfx.Play("UiClick")
	else
		for _, action in LIST_ACTIONS do
			ContextActionService:UnbindAction(action)
		end
	end
end

function LobbyMenu.IsOpen(): boolean
	return isOpen
end

-------------------------------------------------------------------------------------------------
-- Refreshing
-------------------------------------------------------------------------------------------------

-- LT opens the list anywhere in the lobby.
local function setToggleBinding(bound: boolean)
	if bound == toggleBound then
		return
	end
	toggleBound = bound
	if bound then
		ContextActionService:BindAction(
			TOGGLE_ACTION,
			function(_name: string, state: Enum.UserInputState): Enum.ContextActionResult
				if state == Enum.UserInputState.Begin then
					setOpen(not isOpen)
				end
				return Enum.ContextActionResult.Sink
			end,
			false,
			Enum.KeyCode.ButtonL2
		)
	else
		ContextActionService:UnbindAction(TOGGLE_ACTION)
	end
end

local function refresh()
	local inLobby = CustomiseController.CanOpen()
	local scheme = Input.GetScheme()
	deskButton.Button.Visible = inLobby and scheme ~= "Touch"
	touchButton.Button.Visible = inLobby and scheme == "Touch"
	setToggleBinding(inLobby)
	if isOpen and not inLobby then
		setOpen(false) -- a match pulled you in
	end
	local gamepad = scheme == "Gamepad"
	for _, button in { deskButton, touchButton } do
		button.Hint.Visible = gamepad and button.Hint.Image ~= ""
	end
	local shopNew = CustomiseController.IsShopNew()
	deskButton.Dot.Visible = shopNew
	touchButton.Dot.Visible = shopNew
	for _, row in rows do
		local badge = row.Badge
		if badge then
			badge.Visible = shopNew
		end
	end
end

-------------------------------------------------------------------------------------------------
-- Building
-------------------------------------------------------------------------------------------------

-- Three white bars.
local function drawBars(parent: Instance, x: number)
	for index = -1, 1 do
		local bar: Frame = Ui.new("Frame", {
			Size = UDim2.fromOffset(20, 4),
			Position = UDim2.new(0, x, 0.5, index * 7),
			AnchorPoint = Vector2.new(0, 0.5),
			BackgroundColor3 = WHITE,
			BorderSizePixel = 0,
			ZIndex = 4,
			Parent = parent,
		})
		Ui.corner(bar, UDim.new(0.5, 0))
	end
end

local function buildMenuButton(parent: Instance, size: Vector2, layoutOrder: number?): MenuButton
	local button: TextButton = Ui.new("TextButton", {
		Name = "MenuButton",
		Text = "",
		AutoButtonColor = false,
		Size = UDim2.fromOffset(size.X, size.Y),
		BackgroundColor3 = Theme.Colors.Purple,
		BorderSizePixel = 0,
		LayoutOrder = layoutOrder or 0,
		Visible = false,
		ZIndex = 3,
		Parent = parent,
	})
	Ui.corner(button, UDim.new(0.5, 0))
	Ui.stroke(button, WHITE, 3)
	drawBars(button, 16)
	local label = Ui.label(
		button,
		"MENU",
		Theme.Fonts.Display,
		WHITE,
		UDim2.new(1, -86, 1, -16),
		UDim2.new(0, 44, 0.5, 0),
		Vector2.new(0, 0.5)
	)
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.ZIndex = 4
	Ui.textOutline(label, Theme.Colors.Ink, 2)
	local hint = KeyIcon.new(Enum.KeyCode.ButtonL2, {
		Name = "GamepadHint",
		Size = UDim2.fromOffset(30, 30),
		Position = UDim2.new(1, -8, 0.5, 0),
		AnchorPoint = Vector2.new(1, 0.5),
		Visible = false,
		ZIndex = 5,
		Parent = button,
	})
	-- A yellow dot while there's a new cosmetic shop to look at.
	local dot: Frame = Ui.new("Frame", {
		Size = UDim2.fromOffset(16, 16),
		Position = UDim2.fromOffset(4, 2),
		AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundColor3 = Theme.Colors.Yellow,
		BorderSizePixel = 0,
		Visible = false,
		ZIndex = 6,
		Parent = button,
	})
	Ui.corner(dot, UDim.new(0.5, 0))
	Ui.stroke(dot, WHITE, 2)
	button.Activated:Connect(function()
		Ui.pressBounce(button)
		setOpen(not isOpen)
	end)
	return { Button = button, Label = label, Hint = hint, Dot = dot }
end

local function buildRow(entry: Entry, index: number): Row
	local button: TextButton = Ui.new("TextButton", {
		Name = entry.Text,
		Text = "",
		AutoButtonColor = false,
		Size = UDim2.fromOffset(ROW_SIZE.X, ROW_SIZE.Y),
		BackgroundColor3 = ROW_COLOR,
		BorderSizePixel = 0,
		LayoutOrder = index,
		ZIndex = 3,
		Parent = list,
	})
	Ui.corner(button, UDim.new(0, 16))
	local stroke = Ui.stroke(button, WHITE, 2)
	entry.DrawIcon(button)
	local title = Ui.label(
		button,
		entry.Text,
		Theme.Fonts.Display,
		entry.Color,
		UDim2.new(1, -70, 0, 26),
		UDim2.fromOffset(60, 6)
	)
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.ZIndex = 4
	local note = Ui.label(
		button,
		entry.Note,
		Theme.Fonts.Body,
		Theme.Colors.InkSoft,
		UDim2.new(1, -70, 0, 16),
		UDim2.fromOffset(60, 34)
	)
	note.TextXAlignment = Enum.TextXAlignment.Left
	note.ZIndex = 4
	local badge: TextLabel? = nil
	if entry.Open == CustomiseController.OpenShop then
		title.Size = UDim2.new(1, -124, 0, 26) -- leaves room for the NEW! tag
		local tag = Ui.label(
			button,
			"NEW!",
			Theme.Fonts.Display,
			Theme.Colors.Ink,
			UDim2.fromOffset(48, 20),
			UDim2.new(1, -8, 0, 8),
			Vector2.new(1, 0)
		)
		tag.BackgroundTransparency = 0
		tag.BackgroundColor3 = Theme.Colors.Yellow
		tag.Rotation = 6
		tag.ZIndex = 5
		tag.Visible = false
		Ui.corner(tag, UDim.new(0.5, 0))
		Ui.new("UIPadding", { PaddingTop = UDim.new(0, 3), PaddingBottom = UDim.new(0, 3), Parent = tag })
		badge = tag
	end
	button.MouseEnter:Connect(function()
		focusIndex = index
		showFocus()
	end)
	button.Activated:Connect(function()
		choose(index)
	end)
	return { Entry = entry, Button = button, Stroke = stroke, Badge = badge }
end

local function build()
	local playerGui = localPlayer:WaitForChild("PlayerGui")

	-- Computers and controllers: MENU on the right side, a bit over a quarter of the way down
	-- (under Roblox's player list in the top right), leaving room for the list to drop below it.
	local deskGui: ScreenGui = Ui.new("ScreenGui", {
		Name = "LobbyMenuButton",
		ResetOnSpawn = false,
		IgnoreGuiInset = false,
		DisplayOrder = 2,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		Parent = playerGui,
	})
	local holder: Frame = Ui.new("Frame", {
		Size = UDim2.fromOffset(170, 56),
		Position = UDim2.new(1, -16, 0.28, 0),
		AnchorPoint = Vector2.new(1, 0.5),
		BackgroundTransparency = 1,
		Parent = deskGui,
	})
	ResponsiveScale.Attach(holder, "Hud")
	deskButton = buildMenuButton(holder, Vector2.new(170, 56), nil)

	-- Phones and tablets: MENU in the top-right row, after your Crowns and Gumdrops.
	touchButton = buildMenuButton(WalletHud.GetRow(), Vector2.new(130, 40), 3)

	-- The list, drawn over the HUD. Clicking anywhere else closes it.
	listGui = Ui.new("ScreenGui", {
		Name = "LobbyMenu",
		ResetOnSpawn = false,
		IgnoreGuiInset = false,
		DisplayOrder = 27,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		Enabled = false,
		Parent = playerGui,
	})
	local catcher: TextButton = Ui.new("TextButton", {
		Name = "CloseCatcher",
		Text = "",
		AutoButtonColor = false,
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Parent = listGui,
	})
	catcher.Activated:Connect(function()
		setOpen(false)
	end)
	local height = LIST_PADDING * 2 + #ENTRIES * ROW_SIZE.Y + (#ENTRIES - 1) * ROW_GAP
	listHolder = Ui.new("Frame", {
		Name = "ListHolder",
		Size = UDim2.fromOffset(ROW_SIZE.X + LIST_PADDING * 2, height),
		BackgroundTransparency = 1,
		Parent = listGui,
	})
	listScale = ResponsiveScale.Attach(listHolder, "Hud")
	list = Ui.new("Frame", {
		Name = "List",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = WHITE,
		BorderSizePixel = 0,
		ZIndex = 2,
		Parent = listHolder,
	}, {
		Ui.new("UIListLayout", {
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, ROW_GAP),
		}),
	})
	Ui.corner(list, UDim.new(0, 20))
	Ui.stroke(list, Theme.Colors.Purple, 3)
	Ui.padding(list, LIST_PADDING)
	for index, entry in ENTRIES do
		table.insert(rows, buildRow(entry, index))
	end
end

function LobbyMenu.Init()
	build()
	ProfileClient.Changed:Connect(refresh)
	MatchClient.LocalChanged:Connect(refresh)
	Input.SchemeChanged:Connect(function()
		refresh()
		if isOpen then
			placeList()
		end
	end)
	refresh()
	task.spawn(function()
		while true do
			task.wait(BADGE_CHECK)
			refresh()
		end
	end)
end

return LobbyMenu
