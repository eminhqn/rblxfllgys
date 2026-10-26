--!strict
-- The ITEMS window (opened from the lobby's MENU): items for matches, sold for Robux only
-- (Shared/Items, Config.Items.Packs). Each card shows what the item does, how many you have, how
-- many one purchase gives (EACH BUY GIVES 10 SLAPS) and its Robux price. Whole-match items have an ON / OFF switch: ON ones are used when a match
-- starts. Buying shows Roblox's own purchase prompt; the server (PurchaseService) adds the items
-- once Roblox confirms it, and ItemHud says they've arrived. Packs whose product id isn't set up
-- yet say COMING SOON.
--
-- Controller: the D-pad or left stick picks a card, A buys, X switches ON / OFF, B closes.

local ContextActionService = game:GetService("ContextActionService")
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Config = require(Shared.Config)
local Items = require(Shared.Items)
local Remotes = require(Shared.Remotes)
local Theme = require(Shared.Theme)
local Ui = require(Shared.Ui)

local Input = require(script.Parent.InputController)
local MatchClient = require(script.Parent.MatchClient)
local KeyIcon = require(script.Parent.KeyIcon)
local ProfileClient = require(script.Parent.ProfileClient)
local ResponsiveScale = require(script.Parent.ResponsiveScale)
local RoundHud = require(script.Parent.RoundHud)
local Sfx = require(script.Parent.Sfx)

local ItemStoreController = {}

type Card = {
	Def: Items.Def,
	ProductId: number,
	Amount: number,
	Frame: Frame,
	Stroke: UIStroke,
	Owned: TextLabel,
	Buy: TextButton,
	BuyLabel: TextLabel,
	Toggle: TextButton?,
	ToggleLabel: TextLabel?,
	ToggleHint: ImageLabel?,
}

local CLOSE_ACTION = "WobbleItemsClose"
local NAVIGATE_ACTION = "WobbleItemsNavigate"
local BUY_ACTION = "WobbleItemsBuy"
local TOGGLE_ACTION = "WobbleItemsToggle"
local SWALLOW_ACTION = "WobbleItemsSwallow"
local GAMEPAD_ACTIONS = { CLOSE_ACTION, NAVIGATE_ACTION, BUY_ACTION, TOGGLE_ACTION, SWALLOW_ACTION }
local SWALLOWED_KEYS = {
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

local COLUMNS = 4
local CARD_SIZE = Vector2.new(176, 256)
local CARD_GAP = 10
local GRID_TOP = 92
local WINDOW_SIZE =
	Vector2.new(COLUMNS * CARD_SIZE.X + (COLUMNS - 1) * CARD_GAP + 56, GRID_TOP + 2 * CARD_SIZE.Y + CARD_GAP + 44)
local STICK_THRESHOLD = 0.6
local STICK_REPEAT = 0.22
local WHITE = Theme.Colors.White
local GREY = Color3.fromRGB(196, 190, 214)

local localPlayer = Players.LocalPlayer
local gui: ScreenGui
local windowPanel: Frame
local cards: { Card } = {}
local prices: { [number]: number } = {} -- product id -> Robux price
local isOpen = false
local focusIndex = 1
local lastStickMove = 0

-------------------------------------------------------------------------------------------------
-- Item pictures (drawn with frames)
-------------------------------------------------------------------------------------------------

local function bar(parent: Instance, size: UDim2, position: UDim2, rotation: number, color: Color3?): Frame
	local frame: Frame = Ui.new("Frame", {
		Size = size,
		Position = position,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Rotation = rotation,
		BackgroundColor3 = color or WHITE,
		BorderSizePixel = 0,
		ZIndex = 6,
		Parent = parent,
	})
	Ui.corner(frame, UDim.new(0.5, 0))
	return frame
end

local function glyph(parent: Instance, text: string)
	local label = Ui.label(
		parent,
		text,
		Theme.Fonts.Display,
		WHITE,
		UDim2.fromScale(0.72, 0.5),
		UDim2.fromScale(0.5, 0.5),
		Vector2.new(0.5, 0.5)
	)
	label.ZIndex = 6
	Ui.textOutline(label, Theme.Colors.Ink, 1.5)
end

-- A coloured disc with a white picture of the item on it.
local function drawIcon(parent: Instance, def: Items.Def): Frame
	local disc: Frame = Ui.new("Frame", {
		Name = "Icon",
		Size = UDim2.fromOffset(60, 60),
		Position = UDim2.new(0.5, 0, 0, 8),
		AnchorPoint = Vector2.new(0.5, 0),
		BackgroundColor3 = def.Color,
		BorderSizePixel = 0,
		ZIndex = 5,
		Parent = parent,
	})
	Ui.corner(disc, UDim.new(0.5, 0))
	Ui.stroke(disc, WHITE, 3)
	local id = def.Id
	if id == "Slap" then
		-- An open hand: palm, four fingers and a thumb.
		local palm = bar(disc, UDim2.fromOffset(22, 20), UDim2.fromOffset(31, 36), -12)
		Ui.corner(palm, UDim.new(0, 6))
		for index = 0, 3 do
			bar(disc, UDim2.fromOffset(6, 16), UDim2.fromOffset(21 + index * 6, 22 - (index % 3 == 0 and 0 or 2)), -12)
		end
		bar(disc, UDim2.fromOffset(6, 13), UDim2.fromOffset(43, 34), 40)
	elseif id == "Respawn" then
		glyph(disc, "1UP")
	elseif id == "Speed" then
		-- A ball racing along with speed lines behind it.
		local ball = bar(disc, UDim2.fromOffset(18, 18), UDim2.fromOffset(38, 30), 0)
		ball.ZIndex = 7
		for index = -1, 1 do
			bar(disc, UDim2.fromOffset(18 - math.abs(index) * 5, 4), UDim2.fromOffset(19, 30 + index * 7), 0)
		end
	elseif id == "Jump" then
		-- An arrow pointing up.
		bar(disc, UDim2.fromOffset(6, 26), UDim2.fromOffset(30, 34), 0)
		bar(disc, UDim2.fromOffset(6, 18), UDim2.fromOffset(25, 22), -45)
		bar(disc, UDim2.fromOffset(6, 18), UDim2.fromOffset(35, 22), 45)
	elseif id == "Slide" then
		-- A Bloblet on its belly, sliding.
		bar(disc, UDim2.fromOffset(28, 13), UDim2.fromOffset(36, 34), -6)
		bar(disc, UDim2.fromOffset(12, 4), UDim2.fromOffset(15, 30), 0)
		bar(disc, UDim2.fromOffset(9, 4), UDim2.fromOffset(17, 38), 0)
	elseif id == "Shield" then
		local bubble = bar(disc, UDim2.fromOffset(36, 36), UDim2.fromScale(0.5, 0.5), 0)
		bubble.BackgroundTransparency = 0.6
		Ui.stroke(bubble, WHITE, 3)
		bar(disc, UDim2.fromOffset(8, 8), UDim2.fromOffset(22, 22), 0).ZIndex = 7
	else
		glyph(disc, "2X")
	end
	return disc
end

-------------------------------------------------------------------------------------------------
-- Showing
-------------------------------------------------------------------------------------------------

local function refresh()
	local gamepad = Input.GetScheme() == "Gamepad"
	for index, card in cards do
		local ready = card.ProductId ~= 0
		local price = prices[card.ProductId]
		local priceText = if price then `R$ {price}` else "BUY"
		card.BuyLabel.Text = if ready then (if price then `BUY  ·  {priceText}` else priceText) else "COMING SOON"
		card.Buy.BackgroundColor3 = if ready then Theme.Colors.Lime else GREY
		local count = ProfileClient.GetItemCount(card.Def.Id)
		card.Owned.Text = `YOU HAVE {count}`
		card.Owned.TextColor3 = if count > 0 then Theme.Colors.Ink else Theme.Colors.InkSoft
		local toggle, toggleLabel = card.Toggle, card.ToggleLabel
		if toggle and toggleLabel then
			local on = ProfileClient.IsItemOn(card.Def.Id)
			toggleLabel.Text = if on then "ON" else "OFF"
			toggle.BackgroundColor3 = if on then Theme.Colors.Lime else GREY
		end
		local toggleHint = card.ToggleHint
		if toggleHint then
			toggleHint.Visible = gamepad and index == focusIndex and toggleHint.Image ~= ""
		end
		local focused = gamepad and index == focusIndex
		card.Stroke.Color = if focused then Theme.Colors.Yellow else card.Def.Color
		card.Stroke.Thickness = if focused then 6 else 3
	end
end

-- Looks up each pack's Robux price (once).
local function fetchPrices()
	for _, card in cards do
		local productId = card.ProductId
		if productId ~= 0 and not prices[productId] then
			task.spawn(function()
				local ok, info = pcall(function(): any
					return MarketplaceService:GetProductInfo(productId, Enum.InfoType.Product)
				end)
				if ok and typeof(info) == "table" and typeof(info.PriceInRobux) == "number" then
					prices[productId] = info.PriceInRobux
					refresh()
				end
			end)
		end
	end
end

local function buy(card: Card)
	Ui.pressBounce(card.Buy)
	Sfx.Play("UiClick")
	if card.ProductId == 0 then
		RoundHud.Toast("COMING SOON!", Theme.Colors.Orange)
		return
	end
	pcall(function()
		MarketplaceService:PromptProductPurchase(localPlayer, card.ProductId)
	end)
end

local function toggle(card: Card)
	local button = card.Toggle
	if not button then
		return
	end
	Ui.pressBounce(button)
	Sfx.Play("UiClick")
	Remotes.Event("RequestItemToggle"):FireServer(card.Def.Id, not ProfileClient.IsItemOn(card.Def.Id))
end

local setOpen: (open: boolean) -> ()

local function moveFocus(step: number)
	local nextIndex = math.clamp(focusIndex + step, 1, #cards)
	if nextIndex ~= focusIndex then
		focusIndex = nextIndex
		Sfx.Play("UiClick")
		refresh()
	end
end

local function bindGamepad()
	local high = Enum.ContextActionPriority.High.Value + 20
	local function onBegin(callback: () -> ())
		return function(_name: string, state: Enum.UserInputState): Enum.ContextActionResult
			if state == Enum.UserInputState.Begin then
				callback()
			end
			return Enum.ContextActionResult.Sink
		end
	end
	ContextActionService:BindActionAtPriority(
		CLOSE_ACTION,
		onBegin(function()
			setOpen(false)
		end),
		false,
		high,
		Enum.KeyCode.ButtonB,
		Enum.KeyCode.ButtonStart
	)
	ContextActionService:BindActionAtPriority(
		NAVIGATE_ACTION,
		function(_name: string, state: Enum.UserInputState, input: InputObject): Enum.ContextActionResult
			local key = input.KeyCode
			if key == Enum.KeyCode.Thumbstick1 then
				local now = os.clock()
				local position = input.Position
				if now - lastStickMove >= STICK_REPEAT then
					if math.abs(position.X) >= STICK_THRESHOLD and math.abs(position.X) >= math.abs(position.Y) then
						lastStickMove = now
						moveFocus(if position.X > 0 then 1 else -1)
					elseif math.abs(position.Y) >= STICK_THRESHOLD then
						lastStickMove = now
						moveFocus(if position.Y > 0 then -COLUMNS else COLUMNS)
					end
				end
			elseif state == Enum.UserInputState.Begin then
				if key == Enum.KeyCode.DPadLeft then
					moveFocus(-1)
				elseif key == Enum.KeyCode.DPadRight then
					moveFocus(1)
				elseif key == Enum.KeyCode.DPadUp then
					moveFocus(-COLUMNS)
				else
					moveFocus(COLUMNS)
				end
			end
			return Enum.ContextActionResult.Sink
		end,
		false,
		high,
		Enum.KeyCode.DPadLeft,
		Enum.KeyCode.DPadRight,
		Enum.KeyCode.DPadUp,
		Enum.KeyCode.DPadDown,
		Enum.KeyCode.Thumbstick1
	)
	ContextActionService:BindActionAtPriority(
		BUY_ACTION,
		onBegin(function()
			local card = cards[focusIndex]
			if card then
				buy(card)
			end
		end),
		false,
		high,
		Enum.KeyCode.ButtonA
	)
	ContextActionService:BindActionAtPriority(
		TOGGLE_ACTION,
		onBegin(function()
			local card = cards[focusIndex]
			if card then
				toggle(card)
			end
		end),
		false,
		high,
		Enum.KeyCode.ButtonX
	)
	ContextActionService:BindActionAtPriority(SWALLOW_ACTION, function(): Enum.ContextActionResult
		return Enum.ContextActionResult.Sink
	end, false, high, table.unpack(SWALLOWED_KEYS))
end

function setOpen(open: boolean)
	if open == isOpen then
		return
	end
	isOpen = open
	gui.Enabled = open
	Input.SetBlocked("ItemStore", open)
	if open then
		focusIndex = 1
		bindGamepad()
		fetchPrices()
		Ui.popIn(windowPanel)
		refresh()
	else
		for _, action in GAMEPAD_ACTIONS do
			ContextActionService:UnbindAction(action)
		end
	end
end

function ItemStoreController.Open()
	setOpen(true)
end

function ItemStoreController.IsOpen(): boolean
	return isOpen
end

-------------------------------------------------------------------------------------------------
-- Building
-------------------------------------------------------------------------------------------------

local function packFor(def: Items.Def): (number, number)
	for _, pack in Config.Items.Packs do
		if pack.Item == def.Id then
			return pack.ProductId, pack.Amount
		end
	end
	return 0, 1
end

local function buildCard(parent: Instance, def: Items.Def, order: number): Card
	local productId, amount = packFor(def)
	local frame: Frame = Ui.new("Frame", {
		Name = def.Id,
		BackgroundColor3 = Theme.Colors.PanelTint,
		BorderSizePixel = 0,
		LayoutOrder = order,
		ZIndex = 3,
		Parent = parent,
	})
	Ui.corner(frame, UDim.new(0, 18))
	local stroke = Ui.stroke(frame, def.Color, 3)
	drawIcon(frame, def)

	local name = Ui.label(
		frame,
		def.Name,
		Theme.Fonts.Display,
		def.Color,
		UDim2.new(1, -16, 0, 22),
		UDim2.new(0.5, 0, 0, 72),
		Vector2.new(0.5, 0)
	)
	name.ZIndex = 4
	Ui.textOutline(name, Theme.Colors.Ink, 1)
	local description: TextLabel = Ui.new("TextLabel", {
		Text = def.Description,
		FontFace = Theme.Fonts.Body,
		TextSize = 14,
		TextWrapped = true,
		TextColor3 = Theme.Colors.InkSoft,
		TextYAlignment = Enum.TextYAlignment.Top,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, -18, 0, 36),
		Position = UDim2.new(0.5, 0, 0, 96),
		AnchorPoint = Vector2.new(0.5, 0),
		ZIndex = 4,
		Parent = frame,
	})
	local owned =
		Ui.label(frame, "", Theme.Fonts.Display, Theme.Colors.Ink, UDim2.new(1, -18, 0, 16), UDim2.fromOffset(10, 134))
	owned.TextXAlignment = Enum.TextXAlignment.Left
	owned.ZIndex = 4

	-- Whole-match items: an ON / OFF switch. Use-one-at-a-time items: how you use one.
	local toggleButton: TextButton? = nil
	local toggleLabel: TextLabel? = nil
	local toggleHint: ImageLabel? = nil
	if def.Kind == "Match" then
		local caption = Ui.label(
			frame,
			"IN MATCHES",
			Theme.Fonts.Body,
			Theme.Colors.InkSoft,
			UDim2.fromOffset(64, 16),
			UDim2.fromOffset(10, 160)
		)
		caption.TextXAlignment = Enum.TextXAlignment.Left
		caption.ZIndex = 4
		local switch: TextButton = Ui.new("TextButton", {
			Name = "Toggle",
			Text = "",
			AutoButtonColor = false,
			Size = UDim2.fromOffset(62, 28),
			Position = UDim2.new(1, -10, 0, 154),
			AnchorPoint = Vector2.new(1, 0),
			BackgroundColor3 = Theme.Colors.Lime,
			BorderSizePixel = 0,
			ZIndex = 4,
			Parent = frame,
		})
		Ui.corner(switch, UDim.new(0.5, 0))
		Ui.stroke(switch, WHITE, 2)
		local switchLabel = Ui.label(
			switch,
			"ON",
			Theme.Fonts.Display,
			Theme.Colors.Ink,
			UDim2.new(1, -16, 1, -10),
			UDim2.fromScale(0.5, 0.5),
			Vector2.new(0.5, 0.5)
		)
		switchLabel.ZIndex = 5
		toggleHint = KeyIcon.new(Enum.KeyCode.ButtonX, {
			Size = UDim2.fromOffset(24, 24),
			Position = UDim2.new(0, -4, 0.5, 0),
			AnchorPoint = Vector2.new(1, 0.5),
			ZIndex = 5,
			Visible = false,
			Parent = switch,
		})
		toggleButton = switch
		toggleLabel = switchLabel
	else
		local howTo: TextLabel = Ui.new("TextLabel", {
			Text = def.HowTo,
			FontFace = Theme.Fonts.Body,
			TextSize = 13,
			TextWrapped = true,
			TextColor3 = Theme.Colors.InkSoft,
			BackgroundTransparency = 1,
			Size = UDim2.new(1, -18, 0, 30),
			Position = UDim2.new(0.5, 0, 0, 152),
			AnchorPoint = Vector2.new(0.5, 0),
			ZIndex = 4,
			Parent = frame,
		})
		howTo.TextXAlignment = Enum.TextXAlignment.Left
	end
	description.TextXAlignment = Enum.TextXAlignment.Left

	-- What one purchase gets you, right above its button.
	local gives: Frame = Ui.new("Frame", {
		Name = "Gives",
		Size = UDim2.new(1, -20, 0, 22),
		Position = UDim2.new(0.5, 0, 1, -48),
		AnchorPoint = Vector2.new(0.5, 1),
		BackgroundColor3 = def.Color,
		BorderSizePixel = 0,
		ZIndex = 4,
		Parent = frame,
	})
	Ui.corner(gives, UDim.new(0.5, 0))
	local givesLabel = Ui.label(
		gives,
		`EACH BUY GIVES {amount} {if amount == 1 then def.Unit else def.Units}`,
		Theme.Fonts.Display,
		WHITE,
		UDim2.new(1, -14, 1, -6),
		UDim2.fromScale(0.5, 0.5),
		Vector2.new(0.5, 0.5)
	)
	givesLabel.ZIndex = 5
	Ui.textOutline(givesLabel, Theme.Colors.Ink, 1)

	local button: TextButton = Ui.new("TextButton", {
		Name = "Buy",
		Text = "",
		AutoButtonColor = false,
		Size = UDim2.new(1, -20, 0, 34),
		Position = UDim2.new(0.5, 0, 1, -8),
		AnchorPoint = Vector2.new(0.5, 1),
		BackgroundColor3 = Theme.Colors.Lime,
		BorderSizePixel = 0,
		ZIndex = 4,
		Parent = frame,
	})
	Ui.corner(button, UDim.new(0.5, 0))
	Ui.stroke(button, WHITE, 3)
	local label = Ui.label(
		button,
		"",
		Theme.Fonts.Display,
		Theme.Colors.Ink,
		UDim2.new(1, -18, 1, -12),
		UDim2.fromScale(0.5, 0.5),
		Vector2.new(0.5, 0.5)
	)
	label.ZIndex = 5

	local card: Card = {
		Def = def,
		ProductId = productId,
		Amount = amount,
		Frame = frame,
		Stroke = stroke,
		Owned = owned,
		Buy = button,
		BuyLabel = label,
		Toggle = toggleButton,
		ToggleLabel = toggleLabel,
		ToggleHint = toggleHint,
	}
	button.Activated:Connect(function()
		focusIndex = order
		refresh()
		buy(card)
	end)
	if toggleButton then
		toggleButton.Activated:Connect(function()
			focusIndex = order
			toggle(card)
		end)
	end
	return card
end

local function build()
	gui = Ui.new("ScreenGui", {
		Name = "ItemStore",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		DisplayOrder = 33,
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
		BackgroundTransparency = 0.5,
		BorderSizePixel = 0,
		Parent = gui,
	})
	dim.Activated:Connect(function()
		setOpen(false)
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

	local title = Ui.label(
		body,
		"ITEMS",
		Theme.Fonts.Display,
		Theme.Colors.Purple,
		UDim2.fromOffset(400, 40),
		UDim2.fromOffset(28, 16)
	)
	title.TextXAlignment = Enum.TextXAlignment.Left
	local subtitle = Ui.label(
		body,
		"Power-ups for matches. Robux only: Crowns can't buy these.",
		Theme.Fonts.Body,
		Theme.Colors.InkSoft,
		UDim2.fromOffset(560, 20),
		UDim2.fromOffset(28, 56)
	)
	subtitle.TextXAlignment = Enum.TextXAlignment.Left
	local close: TextButton = Ui.new("TextButton", {
		Text = "",
		AutoButtonColor = false,
		Size = UDim2.fromOffset(42, 42),
		Position = UDim2.new(1, -18, 0, 18),
		AnchorPoint = Vector2.new(1, 0),
		BackgroundColor3 = Theme.Colors.Pink,
		BorderSizePixel = 0,
		ZIndex = 4,
		Parent = body,
	})
	Ui.corner(close, UDim.new(0.5, 0))
	Ui.stroke(close, WHITE, 3)
	local closeLabel = Ui.label(
		close,
		"X",
		Theme.Fonts.Display,
		WHITE,
		UDim2.new(1, -16, 1, -16),
		UDim2.fromScale(0.5, 0.5),
		Vector2.new(0.5, 0.5)
	)
	closeLabel.ZIndex = 5
	close.Activated:Connect(function()
		setOpen(false)
	end)

	local grid: Frame = Ui.new("Frame", {
		Name = "Cards",
		Size = UDim2.new(1, -56, 0, 2 * CARD_SIZE.Y + CARD_GAP),
		Position = UDim2.new(0.5, 0, 0, GRID_TOP),
		AnchorPoint = Vector2.new(0.5, 0),
		BackgroundTransparency = 1,
		Parent = body,
	}, {
		Ui.new("UIGridLayout", {
			CellSize = UDim2.fromOffset(CARD_SIZE.X, CARD_SIZE.Y),
			CellPadding = UDim2.fromOffset(CARD_GAP, CARD_GAP),
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	})
	for order, def in Items.List do
		table.insert(cards, buildCard(grid, def, order))
	end
	local note = Ui.label(
		body,
		"Purchases go through Roblox. In Studio they're test purchases and cost nothing.",
		Theme.Fonts.Body,
		Theme.Colors.InkSoft,
		UDim2.new(1, -56, 0, 18),
		UDim2.new(0.5, 0, 1, -14),
		Vector2.new(0.5, 1)
	)
	note.ZIndex = 3
end

function ItemStoreController.Init()
	build()
	-- A match starting (you were queued) closes it.
	MatchClient.LocalChanged:Connect(function()
		if isOpen and MatchClient.IsCompeting() then
			setOpen(false)
		end
	end)
	ProfileClient.Changed:Connect(function()
		if isOpen then
			refresh()
		end
	end)
	Input.SchemeChanged:Connect(function()
		if isOpen then
			refresh()
		end
	end)
end

return ItemStoreController
