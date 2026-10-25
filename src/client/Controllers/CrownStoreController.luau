--!strict
-- The GET CROWNS window: the Crown packs sold for Robux (Config.CrownPacks), with their Robux
-- prices. Opened with the "+" on your Crowns (in the lobby and in the customise screen). Buying
-- shows Roblox's own purchase prompt; the server (PurchaseService) adds the Crowns once Roblox
-- confirms the purchase, and a pop-up says they've arrived. Packs whose product id isn't set up
-- yet say COMING SOON.
--
-- Controller: left / right picks a pack, A buys, B closes.

local ContextActionService = game:GetService("ContextActionService")
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Config = require(Shared.Config)
local Remotes = require(Shared.Remotes)
local Theme = require(Shared.Theme)
local Ui = require(Shared.Ui)

local Input = require(script.Parent.InputController)
local ResponsiveScale = require(script.Parent.ResponsiveScale)
local RoundHud = require(script.Parent.RoundHud)
local Sfx = require(script.Parent.Sfx)
local WalletHud = require(script.Parent.WalletHud)

local CrownStoreController = {}

type PackCard = {
	ProductId: number,
	Crowns: number,
	Frame: Frame,
	Stroke: UIStroke,
	Buy: TextButton,
	BuyLabel: TextLabel,
}

local CLOSE_ACTION = "WobbleCrownsClose"
local NAVIGATE_ACTION = "WobbleCrownsNavigate"
local BUY_ACTION = "WobbleCrownsBuy"
local SWALLOW_ACTION = "WobbleCrownsSwallow"
local GAMEPAD_ACTIONS = { CLOSE_ACTION, NAVIGATE_ACTION, BUY_ACTION, SWALLOW_ACTION }
local SWALLOWED_KEYS = {
	Enum.KeyCode.ButtonX,
	Enum.KeyCode.ButtonY,
	Enum.KeyCode.ButtonL1,
	Enum.KeyCode.ButtonR1,
	Enum.KeyCode.ButtonL2,
	Enum.KeyCode.ButtonR2,
	Enum.KeyCode.ButtonSelect,
	Enum.KeyCode.DPadUp,
	Enum.KeyCode.DPadDown,
	Enum.KeyCode.Thumbstick2,
}

local WINDOW_SIZE = Vector2.new(760, 390)
local CARD_SIZE = Vector2.new(132, 222)
local CARD_GAP = 10
local STICK_THRESHOLD = 0.6
local STICK_REPEAT = 0.25
local WHITE = Theme.Colors.White
local GREY = Color3.fromRGB(196, 190, 214)
local RIBBONS: { [number]: string } = { [100] = "POPULAR", [500] = "BEST VALUE" }

local localPlayer = Players.LocalPlayer
local gui: ScreenGui
local windowPanel: Frame
local cards: { PackCard } = {}
local prices: { [number]: number } = {} -- product id -> Robux price
local isOpen = false
local focusIndex = 1
local lastStickMove = 0

local function refresh()
	local gamepad = Input.GetScheme() == "Gamepad"
	for index, card in cards do
		local ready = card.ProductId ~= 0
		local price = prices[card.ProductId]
		card.BuyLabel.Text = if not ready then "COMING SOON" elseif price then `R$ {price}` else "BUY"
		card.Buy.BackgroundColor3 = if ready then Theme.Colors.Lime else GREY
		local focused = gamepad and index == focusIndex
		card.Stroke.Color = if focused then Theme.Colors.Yellow else Color3.fromRGB(255, 205, 64)
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

local function buy(card: PackCard)
	Ui.pressBounce(card.Buy)
	if card.ProductId == 0 then
		Sfx.Play("UiClick")
		RoundHud.Toast("COMING SOON!", Theme.Colors.Orange)
		return
	end
	Sfx.Play("UiClick")
	pcall(function()
		MarketplaceService:PromptProductPurchase(localPlayer, card.ProductId)
	end)
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

-- While it's open these sit above every other screen (it can open on top of customise).
local function bindGamepad()
	local high = Enum.ContextActionPriority.High.Value + 20
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
		Enum.KeyCode.ButtonStart
	)
	ContextActionService:BindActionAtPriority(
		NAVIGATE_ACTION,
		function(_name: string, state: Enum.UserInputState, input: InputObject): Enum.ContextActionResult
			if input.KeyCode == Enum.KeyCode.Thumbstick1 then
				local now = os.clock()
				if math.abs(input.Position.X) >= STICK_THRESHOLD and now - lastStickMove >= STICK_REPEAT then
					lastStickMove = now
					moveFocus(if input.Position.X > 0 then 1 else -1)
				end
			elseif state == Enum.UserInputState.Begin then
				moveFocus(if input.KeyCode == Enum.KeyCode.DPadRight then 1 else -1)
			end
			return Enum.ContextActionResult.Sink
		end,
		false,
		high,
		Enum.KeyCode.DPadLeft,
		Enum.KeyCode.DPadRight,
		Enum.KeyCode.Thumbstick1
	)
	ContextActionService:BindActionAtPriority(
		BUY_ACTION,
		function(_name: string, state: Enum.UserInputState): Enum.ContextActionResult
			local card = cards[focusIndex]
			if state == Enum.UserInputState.Begin and card then
				buy(card)
			end
			return Enum.ContextActionResult.Sink
		end,
		false,
		high,
		Enum.KeyCode.ButtonA
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
	Input.SetBlocked("CrownStore", open)
	if open then
		focusIndex = math.min(2, #cards)
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

function CrownStoreController.Open()
	setOpen(true)
end

function CrownStoreController.IsOpen(): boolean
	return isOpen
end

-------------------------------------------------------------------------------------------------
-- Building
-------------------------------------------------------------------------------------------------

local function buildCard(parent: Instance, pack: { Crowns: number, ProductId: number }, order: number): PackCard
	local frame: Frame = Ui.new("Frame", {
		Name = `Pack{pack.Crowns}`,
		Size = UDim2.fromOffset(CARD_SIZE.X, CARD_SIZE.Y),
		BackgroundColor3 = Theme.Colors.PanelTint,
		BorderSizePixel = 0,
		LayoutOrder = order,
		ZIndex = 3,
		Parent = parent,
	})
	Ui.corner(frame, UDim.new(0, 18))
	local stroke = Ui.stroke(frame, Color3.fromRGB(255, 205, 64), 3)
	-- Bigger packs get a bigger pile of Crowns.
	local pile = math.clamp(order, 1, 4)
	for index = 1, pile do
		local offset = (index - (pile + 1) / 2) * 16
		local icon = WalletHud.CrownIcon(
			frame,
			34 + order * 3,
			UDim2.new(0.5, offset, 0, 30 + math.abs(offset) * 0.4),
			Vector2.new(0.5, 0)
		)
		icon.ZIndex = 4 + math.floor(pile - math.abs(index - (pile + 1) / 2))
	end
	local amount = Ui.label(
		frame,
		tostring(pack.Crowns),
		Theme.Fonts.Display,
		Theme.Colors.Ink,
		UDim2.new(1, -16, 0, 40),
		UDim2.new(0.5, 0, 0, 92),
		Vector2.new(0.5, 0)
	)
	amount.ZIndex = 4
	local caption = Ui.label(
		frame,
		if pack.Crowns == 1 then "CROWN" else "CROWNS",
		Theme.Fonts.Display,
		Theme.Colors.InkSoft,
		UDim2.new(1, -16, 0, 20),
		UDim2.new(0.5, 0, 0, 132),
		Vector2.new(0.5, 0)
	)
	caption.ZIndex = 4
	local ribbon = RIBBONS[pack.Crowns]
	if ribbon then
		local tag = Ui.label(
			frame,
			ribbon,
			Theme.Fonts.Display,
			WHITE,
			UDim2.new(1, -20, 0, 22),
			UDim2.new(0.5, 0, 0, -10),
			Vector2.new(0.5, 0)
		)
		tag.BackgroundTransparency = 0
		tag.BackgroundColor3 = Theme.Colors.Pink
		tag.ZIndex = 6
		Ui.corner(tag, UDim.new(0.5, 0))
		Ui.new("UIPadding", { PaddingTop = UDim.new(0, 3), PaddingBottom = UDim.new(0, 3), Parent = tag })
	end
	local button: TextButton = Ui.new("TextButton", {
		Name = "Buy",
		Text = "",
		AutoButtonColor = false,
		Size = UDim2.new(1, -20, 0, 44),
		Position = UDim2.new(0.5, 0, 1, -12),
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
		UDim2.new(1, -18, 1, -16),
		UDim2.fromScale(0.5, 0.5),
		Vector2.new(0.5, 0.5)
	)
	label.ZIndex = 5
	local card: PackCard = {
		ProductId = pack.ProductId,
		Crowns = pack.Crowns,
		Frame = frame,
		Stroke = stroke,
		Buy = button,
		BuyLabel = label,
	}
	button.Activated:Connect(function()
		focusIndex = order
		refresh()
		buy(card)
	end)
	return card
end

local function build()
	gui = Ui.new("ScreenGui", {
		Name = "CrownStore",
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
		"GET CROWNS",
		Theme.Fonts.Display,
		Theme.Colors.Purple,
		UDim2.fromOffset(400, 40),
		UDim2.fromOffset(24, 16)
	)
	title.TextXAlignment = Enum.TextXAlignment.Left
	local subtitle = Ui.label(
		body,
		"Crowns buy items in CUSTOMISE and the ITEM SHOP.",
		Theme.Fonts.Body,
		Theme.Colors.InkSoft,
		UDim2.fromOffset(500, 20),
		UDim2.fromOffset(24, 56)
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

	local row: Frame = Ui.new("Frame", {
		Name = "Packs",
		Size = UDim2.new(1, -40, 0, CARD_SIZE.Y),
		Position = UDim2.new(0.5, 0, 0, 100),
		AnchorPoint = Vector2.new(0.5, 0),
		BackgroundTransparency = 1,
		Parent = body,
	}, {
		Ui.new("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, CARD_GAP),
		}),
	})
	for order, pack in Config.CrownPacks do
		table.insert(cards, buildCard(row, pack, order))
	end
	local note = Ui.label(
		body,
		"Purchases go through Roblox. In Studio they're test purchases and cost nothing.",
		Theme.Fonts.Body,
		Theme.Colors.InkSoft,
		UDim2.new(1, -48, 0, 18),
		UDim2.new(0.5, 0, 1, -18),
		Vector2.new(0.5, 1)
	)
	note.ZIndex = 3
end

function CrownStoreController.Init()
	build()
	WalletHud.GetCrownsRequested:Connect(function()
		setOpen(true)
	end)
	Input.SchemeChanged:Connect(function()
		if isOpen then
			refresh()
		end
	end)
	Remotes.Event("CrownsPurchased").OnClientEvent:Connect(function(crowns: unknown)
		if typeof(crowns) ~= "number" then
			return
		end
		RoundHud.Toast(`+{crowns} CROWNS! THANK YOU!`, Color3.fromRGB(255, 205, 64))
		Sfx.Play("Crown")
	end)
end

return CrownStoreController
