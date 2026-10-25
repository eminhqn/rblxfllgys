--!strict
-- The customise screen (lobby only): try on and buy colours, patterns, eyes, hats, outfits and
-- emotes with Gumdrops, next to a preview of your Bloblet turning on a pedestal (drag it to spin
-- it yourself).
--
-- Picking a card tries the item on in the preview. The button underneath buys it (the server
-- checks the price and your Gumdrops) or wears it (the server checks you own it). Nothing here
-- changes your profile directly; it only asks the server (ShopService).

local ContextActionService = game:GetService("ContextActionService")
local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage.Shared
local BlobletRig = require(Shared.BlobletRig)
local Cosmetics = require(Shared.Cosmetics)
local Remotes = require(Shared.Remotes)
local Theme = require(Shared.Theme)
local Ui = require(Shared.Ui)

local Input = require(script.Parent.InputController)
local MatchClient = require(script.Parent.MatchClient)
local ProfileClient = require(script.Parent.ProfileClient)
local ResponsiveScale = require(script.Parent.ResponsiveScale)
local Sfx = require(script.Parent.Sfx)
local WalletHud = require(script.Parent.WalletHud)

local CustomiseController = {}

type Card = {
	Item: Cosmetics.Item,
	Button: TextButton,
	Status: TextLabel,
	PriceIcon: Frame,
	Stroke: UIStroke,
}

local WINDOW_SIZE = Vector2.new(900, 520)
local PREVIEW_WIDTH = 330
local CARD_SIZE = Vector2.new(116, 112)
local SPIN_SPEED = 0.6 -- radians per second
local DRAG_SPEED = 0.012 -- radians per pixel
local CLOSE_ACTION = "WobbleCloseCustomise"
local OPEN_ACTION = "WobbleOpenCustomise"

local WHITE = Color3.fromRGB(255, 255, 255)
local GREY = Color3.fromRGB(190, 184, 210)
local ERROR_COLOR = Color3.fromRGB(230, 60, 90)
local UPRIGHT = CFrame.Angles(0, 0, math.pi / 2)

local localPlayer = Players.LocalPlayer

local gui: ScreenGui
local openButton: TextButton
local windowPanel: Frame -- pops in when the screen opens
local grid: ScrollingFrame
local tabButtons: { [string]: TextButton } = {}
local viewport: ViewportFrame
local stage: Model
local itemName: TextLabel
local actionButton: TextButton
local actionLabel: TextLabel
local messageLabel: TextLabel
local coinsLabel: TextLabel
local statsLabel: TextLabel
local savingNote: TextLabel

local isOpen = false
local currentSlot = "Color"
local selectedId: string? = nil
local cards: { Card } = {}
local purchasing = false
local previewAngle = 0
local previewModel: Model? = nil
local previewKey = ""
local dragInput: InputObject? = nil
local dragLastX = 0

-------------------------------------------------------------------------------------------------
-- Preview
-------------------------------------------------------------------------------------------------

-- What you're wearing, with the selected card tried on.
local function previewAppearance(): BlobletRig.Appearance
	local equipped = table.clone(ProfileClient.GetEquipped())
	local selected = if selectedId then Cosmetics.Get(selectedId) else nil
	if selected and selected.Slot ~= "Emote" then
		Cosmetics.SetSlot(equipped, selected.Slot, selected.Id)
	end
	local colorItem = Cosmetics.Get(equipped.Color)
	return {
		BodyColor = if colorItem and colorItem.Color then colorItem.Color else WHITE,
		Pattern = equipped.Pattern,
		Eyes = equipped.Eyes,
		Hat = equipped.Hat,
		Outfit = equipped.Outfit,
	}
end

local function placePreview()
	local spin = CFrame.Angles(0, previewAngle, 0)
	stage:PivotTo(spin)
	local model = previewModel
	if model then
		model:PivotTo(CFrame.new(0, BlobletRig.Dimensions.RootHeight, 0) * spin)
	end
end

local function refreshPreview()
	local appearance = previewAppearance()
	local key = table.concat({
		appearance.BodyColor:ToHex(),
		appearance.Pattern,
		appearance.Eyes,
		appearance.Hat,
		appearance.Outfit,
	}, "|")
	if key == previewKey and previewModel then
		return
	end
	previewKey = key
	local old = previewModel
	if old then
		old:Destroy()
	end
	local model = BlobletRig.Build(appearance)
	model.Name = "Preview"
	model.Parent = viewport
	previewModel = model
	placePreview()
end

local function buildStage()
	stage = Instance.new("Model")
	stage.Name = "Pedestal"
	local function part(name: string, shape: Enum.PartType, size: Vector3, cframe: CFrame, color: Color3)
		local piece = Instance.new("Part")
		piece.Name = name
		piece.Shape = shape
		piece.Size = size
		piece.CFrame = cframe
		piece.Color = color
		piece.Material = Enum.Material.SmoothPlastic
		piece.Anchored = true
		piece.Parent = stage
	end
	part("Base", Enum.PartType.Cylinder, Vector3.new(1.2, 7, 7), CFrame.new(0, -0.6, 0) * UPRIGHT, Theme.Colors.Pink)
	part("Top", Enum.PartType.Cylinder, Vector3.new(0.1, 6.4, 6.4), CFrame.new(0, 0.02, 0) * UPRIGHT, WHITE)
	-- Studs round the rim show it turning.
	for index = 1, 8 do
		local angle = index / 8 * math.pi * 2
		part(
			"Stud",
			Enum.PartType.Ball,
			Vector3.one * 0.6,
			CFrame.new(math.cos(angle) * 3.3, -0.1, math.sin(angle) * 3.3),
			if index % 2 == 0 then Theme.Colors.Yellow else Theme.Colors.Aqua
		)
	end
	stage.WorldPivot = CFrame.new()
	stage.Parent = viewport
end

-------------------------------------------------------------------------------------------------
-- Cards
-------------------------------------------------------------------------------------------------

local function isEquipped(entry: Cosmetics.Item): boolean
	return Cosmetics.InSlot(ProfileClient.GetEquipped(), entry.Slot) == entry.Id
end

local function refreshCards()
	for _, card in cards do
		local entry = card.Item
		local owned = ProfileClient.Owns(entry.Id)
		card.PriceIcon.Visible = false
		if isEquipped(entry) then
			card.Status.Text = if entry.Slot == "Emote" then "EQUIPPED" else "WEARING"
			card.Status.TextColor3 = Theme.Colors.Lime
		elseif owned then
			card.Status.Text = if entry.Price == 0 then "FREE" else "OWNED"
			card.Status.TextColor3 = Theme.Colors.InkSoft
		else
			card.Status.Text = tostring(entry.Price)
			card.Status.TextColor3 = Theme.Colors.Pink
			card.PriceIcon.Visible = true
		end
		local selected = entry.Id == selectedId
		card.Stroke.Thickness = if selected then 4 else 2
		card.Stroke.Color = if selected then Theme.Colors.Purple else GREY
		card.Button.BackgroundColor3 = if selected then WHITE else Theme.Colors.PanelTint
	end
end

local function refreshAction()
	local entry = if selectedId then Cosmetics.Get(selectedId) else nil
	if not entry then
		itemName.Text = ""
		actionButton.Visible = false
		return
	end
	itemName.Text = string.upper(entry.Name)
	actionButton.Visible = true
	local coins = ProfileClient.GetCoins()
	if purchasing then
		actionLabel.Text = "..."
		actionButton.BackgroundColor3 = GREY
	elseif isEquipped(entry) then
		actionLabel.Text = if entry.Slot == "Emote" then "EQUIPPED" else "WEARING"
		actionButton.BackgroundColor3 = GREY
	elseif ProfileClient.Owns(entry.Id) then
		actionLabel.Text = if entry.Slot == "Emote" then "EQUIP" else "WEAR"
		actionButton.BackgroundColor3 = Theme.Colors.Lime
	elseif coins >= entry.Price then
		actionLabel.Text = `BUY  {entry.Price}`
		actionButton.BackgroundColor3 = Theme.Colors.Yellow
	else
		actionLabel.Text = `NEED {entry.Price}`
		actionButton.BackgroundColor3 = GREY
	end
end

local function refreshHeader()
	coinsLabel.Text = tostring(ProfileClient.GetCoins())
	statsLabel.Text = `WINS {ProfileClient.GetStat("Wins")}  ·  MATCHES {ProfileClient.GetStat("Matches")}`
	savingNote.Visible = not ProfileClient.IsSaving()
end

local function refreshAll()
	refreshHeader()
	refreshCards()
	refreshAction()
	refreshPreview()
end

local function selectItem(itemId: string)
	selectedId = itemId
	messageLabel.Text = ""
	Sfx.Play("UiClick")
	refreshAll()
end

local function buildCard(entry: Cosmetics.Item, order: number): Card
	local button: TextButton = Ui.new("TextButton", {
		Name = entry.Id,
		Text = "",
		AutoButtonColor = false,
		BackgroundColor3 = Theme.Colors.PanelTint,
		BorderSizePixel = 0,
		LayoutOrder = order,
		Parent = grid,
	})
	Ui.corner(button, UDim.new(0, 14))
	local stroke = Ui.stroke(button, GREY, 2)
	local swatch: Frame = Ui.new("Frame", {
		Size = UDim2.fromOffset(50, 50),
		Position = UDim2.new(0.5, 0, 0, 10),
		AnchorPoint = Vector2.new(0.5, 0),
		BackgroundColor3 = entry.Swatch,
		BorderSizePixel = 0,
		Parent = button,
	})
	Ui.corner(swatch, UDim.new(0.5, 0))
	Ui.stroke(swatch, WHITE, 3)
	local name = Ui.label(
		button,
		entry.Name,
		Theme.Fonts.Body,
		Theme.Colors.Ink,
		UDim2.new(1, -10, 0, 20),
		UDim2.new(0.5, 0, 0, 64),
		Vector2.new(0.5, 0)
	)
	Ui.new("UITextSizeConstraint", { MaxTextSize = 18, Parent = name })
	local status = Ui.label(
		button,
		"",
		Theme.Fonts.Display,
		Theme.Colors.InkSoft,
		UDim2.new(1, -40, 0, 18),
		UDim2.new(0.5, 8, 0, 87),
		Vector2.new(0.5, 0)
	)
	local priceIcon = WalletHud.GumdropIcon(button, 16, UDim2.fromOffset(18, 88), Vector2.zero)
	button.Activated:Connect(function()
		selectItem(entry.Id)
	end)
	return { Item = entry, Button = button, Status = status, PriceIcon = priceIcon, Stroke = stroke }
end

local function switchTab(slot: string)
	currentSlot = slot
	for tabSlot, tab in tabButtons do
		tab.BackgroundColor3 = if tabSlot == slot then Theme.Colors.Purple else Theme.Colors.PanelTint
		local label = tab:FindFirstChildOfClass("TextLabel")
		if label then
			label.TextColor3 = if tabSlot == slot then WHITE else Theme.Colors.Purple
		end
	end
	for _, card in cards do
		card.Button:Destroy()
	end
	table.clear(cards)
	for order, entry in Cosmetics.ForSlot(slot) do
		table.insert(cards, buildCard(entry, order))
	end
	grid.CanvasPosition = Vector2.zero
	selectedId = Cosmetics.InSlot(ProfileClient.GetEquipped(), slot)
	messageLabel.Text = ""
	refreshAll()
	if Input.GetScheme() == "Gamepad" and cards[1] then
		GuiService.SelectedObject = cards[1].Button
	end
end

-------------------------------------------------------------------------------------------------
-- Buying and wearing
-------------------------------------------------------------------------------------------------

local function showMessage(text: string, color: Color3)
	messageLabel.Text = text
	messageLabel.TextColor3 = color
end

local function onAction()
	local entry = if selectedId then Cosmetics.Get(selectedId) else nil
	if not entry or purchasing or isEquipped(entry) then
		return
	end
	if ProfileClient.Owns(entry.Id) then
		Remotes.Event("RequestEquip"):FireServer(entry.Slot, entry.Id)
		Sfx.Play("UiClick")
		return
	end
	if ProfileClient.GetCoins() < entry.Price then
		showMessage(`Not enough {Cosmetics.CurrencyName} yet. Play matches to earn more!`, ERROR_COLOR)
		return
	end
	purchasing = true
	refreshAction()
	task.spawn(function()
		local ok, success, message = pcall(function(): (any, any)
			return Remotes.Function("RequestPurchase"):InvokeServer(entry.Id)
		end)
		purchasing = false
		if ok and success == true then
			Remotes.Event("RequestEquip"):FireServer(entry.Slot, entry.Id)
			showMessage(`{entry.Name} unlocked!`, Theme.Colors.Lime)
			Sfx.Play("Unlock")
		else
			showMessage(
				if ok and typeof(message) == "string" then message else "Couldn't buy that. Try again!",
				ERROR_COLOR
			)
		end
		refreshAll()
	end)
end

-------------------------------------------------------------------------------------------------
-- Opening and closing
-------------------------------------------------------------------------------------------------

local function canOpen(): boolean
	return MatchClient.GetStatus() == "None" and ProfileClient.IsReady()
end

local setOpen: (open: boolean) -> ()

local function bindClose()
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
		Enum.KeyCode.ButtonB
	)
end

function setOpen(open: boolean)
	if open == isOpen or (open and not canOpen()) then
		return
	end
	isOpen = open
	gui.Enabled = open
	Input.SetEnabled(not open)
	if open then
		bindClose()
		Ui.popIn(windowPanel)
		switchTab(currentSlot)
	else
		ContextActionService:UnbindAction(CLOSE_ACTION)
		dragInput = nil
		if GuiService.SelectedObject and GuiService.SelectedObject:IsDescendantOf(gui) then
			GuiService.SelectedObject = nil
		end
	end
end

function CustomiseController.IsOpen(): boolean
	return isOpen
end

local function refreshOpenButton()
	local available = canOpen()
	openButton.Visible = available
	if isOpen and not available then
		setOpen(false)
	end
	if available then
		ContextActionService:BindAction(
			OPEN_ACTION,
			function(_name: string, state: Enum.UserInputState): Enum.ContextActionResult
				if state == Enum.UserInputState.Begin then
					setOpen(not isOpen)
				end
				return Enum.ContextActionResult.Sink
			end,
			false,
			Enum.KeyCode.ButtonSelect
		)
	else
		ContextActionService:UnbindAction(OPEN_ACTION)
	end
end

-------------------------------------------------------------------------------------------------
-- Building
-------------------------------------------------------------------------------------------------

local function buildOpenButton()
	openButton = Ui.new("TextButton", {
		Name = "CustomiseButton",
		Text = "",
		AutoButtonColor = false,
		Size = UDim2.fromOffset(160, 40),
		BackgroundColor3 = Theme.Colors.Purple,
		BorderSizePixel = 0,
		LayoutOrder = 2,
		Visible = false,
		Parent = WalletHud.GetRow(),
	})
	Ui.corner(openButton, UDim.new(0.5, 0))
	Ui.stroke(openButton, WHITE, 3)
	Ui.label(
		openButton,
		"CUSTOMISE",
		Theme.Fonts.Display,
		WHITE,
		UDim2.new(1, -20, 1, -12),
		UDim2.fromScale(0.5, 0.5),
		Vector2.new(0.5, 0.5)
	)
	openButton.Activated:Connect(function()
		Ui.pressBounce(openButton)
		setOpen(true)
	end)
end

local function buildPreview(body: Frame)
	viewport = Ui.new("ViewportFrame", {
		Name = "Preview",
		Size = UDim2.new(0, PREVIEW_WIDTH, 1, -70),
		Position = UDim2.fromOffset(20, 20),
		BackgroundColor3 = Color3.fromRGB(214, 236, 255),
		BorderSizePixel = 0,
		Ambient = Color3.fromRGB(200, 190, 225),
		LightColor = WHITE,
		LightDirection = Vector3.new(-0.5, -1, -0.6),
		Parent = body,
	})
	Ui.corner(viewport, UDim.new(0, 18))
	Ui.new("UIGradient", {
		Color = ColorSequence.new(Color3.fromRGB(255, 236, 248), Color3.fromRGB(205, 232, 255)),
		Rotation = 90,
		Parent = viewport,
	})
	local camera = Instance.new("Camera")
	camera.FieldOfView = 38
	camera.CFrame = CFrame.lookAt(Vector3.new(0, 4.4, -11), Vector3.new(0, 2.4, 0))
	camera.Parent = viewport
	viewport.CurrentCamera = camera
	buildStage()

	itemName = Ui.label(
		body,
		"",
		Theme.Fonts.Display,
		Theme.Colors.Ink,
		UDim2.fromOffset(PREVIEW_WIDTH, 34),
		UDim2.new(0, 20, 1, -44),
		Vector2.zero
	)

	-- Drag the preview to spin it.
	viewport.InputBegan:Connect(function(input: InputObject)
		local inputType = input.UserInputType
		if inputType == Enum.UserInputType.MouseButton1 or inputType == Enum.UserInputType.Touch then
			dragInput = input
			dragLastX = input.Position.X
		end
	end)
	UserInputService.InputChanged:Connect(function(input: InputObject)
		local drag = dragInput
		if not drag then
			return
		end
		local moved = input == drag
			or (
				drag.UserInputType == Enum.UserInputType.MouseButton1
				and input.UserInputType == Enum.UserInputType.MouseMovement
			)
		if moved then
			previewAngle += (input.Position.X - dragLastX) * DRAG_SPEED
			dragLastX = input.Position.X
		end
	end)
	UserInputService.InputEnded:Connect(function(input: InputObject)
		if input == dragInput then
			dragInput = nil
		end
	end)
end

local function buildShop(body: Frame)
	local left = PREVIEW_WIDTH + 40
	local width = WINDOW_SIZE.X - left - 20

	local title = Ui.label(
		body,
		"CUSTOMISE",
		Theme.Fonts.Display,
		Theme.Colors.Purple,
		UDim2.fromOffset(220, 40),
		UDim2.fromOffset(left, 16),
		Vector2.zero
	)
	title.TextXAlignment = Enum.TextXAlignment.Left
	statsLabel = Ui.label(
		body,
		"",
		Theme.Fonts.Body,
		Theme.Colors.InkSoft,
		UDim2.fromOffset(260, 18),
		UDim2.fromOffset(left, 56),
		Vector2.zero
	)
	statsLabel.TextXAlignment = Enum.TextXAlignment.Left

	-- Gumdrops, then the close button, in the top right.
	local coinsHolder: Frame = Ui.new("Frame", {
		Size = UDim2.fromOffset(130, 38),
		Position = UDim2.new(1, -70, 0, 18),
		AnchorPoint = Vector2.new(1, 0),
		BackgroundColor3 = Theme.Colors.PanelTint,
		BorderSizePixel = 0,
		Parent = body,
	})
	Ui.corner(coinsHolder, UDim.new(0.5, 0))
	WalletHud.GumdropIcon(coinsHolder, 24, UDim2.new(0, 8, 0.5, 0), Vector2.new(0, 0.5))
	coinsLabel = Ui.label(
		coinsHolder,
		"0",
		Theme.Fonts.Display,
		Theme.Colors.Ink,
		UDim2.new(1, -46, 1, -10),
		UDim2.new(0, 40, 0.5, 0),
		Vector2.new(0, 0.5)
	)
	coinsLabel.TextXAlignment = Enum.TextXAlignment.Left

	local closeButton: TextButton = Ui.new("TextButton", {
		Name = "Close",
		Text = "",
		AutoButtonColor = false,
		Size = UDim2.fromOffset(40, 40),
		Position = UDim2.new(1, -18, 0, 17),
		AnchorPoint = Vector2.new(1, 0),
		BackgroundColor3 = Theme.Colors.Pink,
		BorderSizePixel = 0,
		Parent = body,
	})
	Ui.corner(closeButton, UDim.new(0.5, 0))
	Ui.label(
		closeButton,
		"X",
		Theme.Fonts.Display,
		WHITE,
		UDim2.new(1, -12, 1, -12),
		UDim2.fromScale(0.5, 0.5),
		Vector2.new(0.5, 0.5)
	)
	closeButton.Activated:Connect(function()
		setOpen(false)
	end)

	savingNote = Ui.label(
		body,
		"Progress won't save this session",
		Theme.Fonts.Body,
		Theme.Colors.Orange,
		UDim2.fromOffset(260, 18),
		UDim2.new(1, -18, 0, 62),
		Vector2.new(1, 0)
	)
	savingNote.TextXAlignment = Enum.TextXAlignment.Right

	-- Category tabs.
	local tabs: Frame = Ui.new("Frame", {
		Name = "Tabs",
		Size = UDim2.fromOffset(width, 34),
		Position = UDim2.fromOffset(left, 88),
		BackgroundTransparency = 1,
		Parent = body,
	}, {
		Ui.new("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, 6),
		}),
	})
	local tabWidth = (width - 6 * (#Cosmetics.AllSlots() - 1)) / #Cosmetics.AllSlots()
	for order, slot in Cosmetics.AllSlots() do
		local tab: TextButton = Ui.new("TextButton", {
			Name = slot,
			Text = "",
			AutoButtonColor = false,
			Size = UDim2.fromOffset(tabWidth, 34),
			BackgroundColor3 = Theme.Colors.PanelTint,
			BorderSizePixel = 0,
			LayoutOrder = order,
			Parent = tabs,
		})
		Ui.corner(tab, UDim.new(0.5, 0))
		Ui.label(
			tab,
			Cosmetics.SlotLabels[slot],
			Theme.Fonts.Display,
			Theme.Colors.Purple,
			UDim2.new(1, -12, 1, -12),
			UDim2.fromScale(0.5, 0.5),
			Vector2.new(0.5, 0.5)
		)
		tab.Activated:Connect(function()
			Sfx.Play("UiClick")
			switchTab(slot)
		end)
		tabButtons[slot] = tab
	end

	-- Item cards.
	grid = Ui.new("ScrollingFrame", {
		Name = "Items",
		Size = UDim2.fromOffset(width, 270),
		Position = UDim2.fromOffset(left, 132),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 6,
		ScrollBarImageColor3 = Theme.Colors.Purple,
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(),
		ScrollingDirection = Enum.ScrollingDirection.Y,
		Parent = body,
	}, {
		Ui.new("UIGridLayout", {
			CellSize = UDim2.fromOffset(CARD_SIZE.X, CARD_SIZE.Y),
			CellPadding = UDim2.fromOffset(10, 10),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
		Ui.new("UIPadding", {
			PaddingTop = UDim.new(0, 4),
			PaddingLeft = UDim.new(0, 4),
			PaddingRight = UDim.new(0, 10),
			PaddingBottom = UDim.new(0, 4),
		}),
	})

	-- Buy / wear.
	actionButton = Ui.new("TextButton", {
		Name = "Action",
		Text = "",
		AutoButtonColor = false,
		Size = UDim2.fromOffset(240, 54),
		Position = UDim2.new(0, left, 1, -74),
		BackgroundColor3 = Theme.Colors.Yellow,
		BorderSizePixel = 0,
		Parent = body,
	})
	Ui.corner(actionButton, UDim.new(0, 18))
	Ui.stroke(actionButton, WHITE, 3)
	actionLabel = Ui.label(
		actionButton,
		"",
		Theme.Fonts.Display,
		Theme.Colors.Ink,
		UDim2.new(1, -30, 1, -16),
		UDim2.fromScale(0.5, 0.5),
		Vector2.new(0.5, 0.5)
	)
	actionButton.Activated:Connect(function()
		Ui.pressBounce(actionButton)
		onAction()
	end)
	messageLabel = Ui.label(
		body,
		"",
		Theme.Fonts.Body,
		Theme.Colors.Lime,
		UDim2.fromOffset(width - 256, 44),
		UDim2.new(0, left + 256, 1, -69),
		Vector2.zero
	)
	messageLabel.TextWrapped = true
	messageLabel.TextXAlignment = Enum.TextXAlignment.Left
	Ui.new("UITextSizeConstraint", { MaxTextSize = 20, Parent = messageLabel })
end

local function buildScreen()
	gui = Ui.new("ScreenGui", {
		Name = "Customise",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		DisplayOrder = 30,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		Enabled = false,
		Parent = localPlayer:WaitForChild("PlayerGui"),
	})
	Ui.new("Frame", {
		Name = "Dim",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Theme.Colors.Shadow,
		BackgroundTransparency = 0.45,
		BorderSizePixel = 0,
		Active = true, -- clicks behind the window don't reach the world
		Parent = gui,
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
	buildPreview(panel.Body)
	buildShop(panel.Body)
end

function CustomiseController.Init()
	buildScreen()
	buildOpenButton()

	ProfileClient.Changed:Connect(function()
		refreshOpenButton()
		if isOpen then
			refreshAll()
		end
	end)
	MatchClient.LocalChanged:Connect(refreshOpenButton)
	refreshOpenButton()

	RunService.RenderStepped:Connect(function(dt: number)
		if not isOpen then
			return
		end
		if not dragInput then
			previewAngle += dt * SPIN_SPEED
		end
		placePreview()
	end)
end

return CustomiseController
