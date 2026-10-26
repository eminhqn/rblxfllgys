--!strict
-- The customise screen (lobby only): try on and buy colours, patterns, eyes, hats, outfits and
-- emotes with Crowns, next to a preview of your Bloblet turning on a pedestal (drag it to spin it
-- yourself). Crowns come from winning matches, from trading Gumdrops (earned by playing) with
-- the TRADE button, or for Robux with the "+" on your Crowns (GET CROWNS).
--
-- The first tab is the ITEM SHOP (the ITEM SHOP buttons in the lobby open straight onto it: see
-- ShopButtons, and the one beside CUSTOMISE on phones and tablets): the
-- daily shop's items and the weekly shop's, each with a countdown to the next shop (see
-- Shared/ItemShop). Shop items can only be bought while they're there; ones you own show up in the
-- other tabs to wear.
--
-- Picking a card tries the item on in the preview and turns the Bloblet back to face you; emote
-- cards make it dance (on a loop) while you point at or pick them. The button underneath buys
-- the item (the server checks the price and your Crowns) or wears it (the server checks you own
-- it). Nothing here changes your profile directly; it only asks the server (ShopService).
--
-- Controller: D-pad right opens it in the lobby (Select opens the item shop). Inside, the D-pad or left stick
-- moves between cards (trying each on), A buys or wears, X trades Gumdrops, Y opens GET CROWNS,
-- LB / RB switch tabs, the right stick spins the preview and B closes. Button hints show under the
-- window while you're using a controller.

local ContextActionService = game:GetService("ContextActionService")
local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local BlobletRig = require(Shared.BlobletRig)
local Config = require(Shared.Config)
local Cosmetics = require(Shared.Cosmetics)
local ItemShop = require(Shared.ItemShop)
local Remotes = require(Shared.Remotes)
local Theme = require(Shared.Theme)
local Ui = require(Shared.Ui)

local CrownStoreController = require(script.Parent.CrownStoreController)
local Input = require(script.Parent.InputController)
local KeyIcon = require(script.Parent.KeyIcon)
local MatchClient = require(script.Parent.MatchClient)
local PreviewStage = require(script.Parent.PreviewStage)
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
local GUMDROPS_PER_CROWN = Config.Economy.GumdropsPerCrown
local GRID_HEIGHT = 270
local GRID_PADDING = 4
local CARD_GAP = 10
local NAV_REPEAT_DELAY = 0.35 -- hold a direction this long before it repeats...
local NAV_REPEAT_RATE = 0.12 -- ...then move this often
local STICK_THRESHOLD = 0.55

local CLOSE_ACTION = "WobbleCloseCustomise"
local OPEN_ACTION = "WobbleOpenCustomise"
local NAVIGATE_ACTION = "WobbleCustomiseNavigate"
local CONFIRM_ACTION = "WobbleCustomiseConfirm"
local TRADE_ACTION = "WobbleCustomiseTrade"
local TAB_ACTION = "WobbleCustomiseTab"
local SPIN_ACTION = "WobbleCustomiseSpin"
local CROWNS_ACTION = "WobbleCustomiseCrowns"
local GAMEPAD_ACTIONS =
	{ CLOSE_ACTION, NAVIGATE_ACTION, CONFIRM_ACTION, TRADE_ACTION, TAB_ACTION, SPIN_ACTION, CROWNS_ACTION }

-- The tabs: the item shop, then one per slot.
local SHOP_TAB = "Shop"
local TABS: { string } = { SHOP_TAB }
for _, slot in Cosmetics.AllSlots() do
	table.insert(TABS, slot)
end
local SHOP_HEIGHT = 296
local SHOP_TIMER_INTERVAL = 0.5

local DPAD_DIRECTIONS: { [Enum.KeyCode]: Vector2 } = {
	[Enum.KeyCode.DPadLeft] = Vector2.new(-1, 0),
	[Enum.KeyCode.DPadRight] = Vector2.new(1, 0),
	[Enum.KeyCode.DPadUp] = Vector2.new(0, -1),
	[Enum.KeyCode.DPadDown] = Vector2.new(0, 1),
}

local WHITE = Color3.fromRGB(255, 255, 255)
local GREY = Color3.fromRGB(190, 184, 210)
local ERROR_COLOR = Color3.fromRGB(230, 60, 90)

local localPlayer = Players.LocalPlayer

local gui: ScreenGui
local openButton: TextButton
local shopButton: TextButton -- ITEM SHOP, in the lobby
local shopBadge: TextLabel -- NEW! on it when the daily shop has changed
local titleLabel: TextLabel
local shopView: Frame
local dailyRow: Frame
local weeklyRow: Frame
local dailyTimer: TextLabel
local weeklyTimer: TextLabel
local windowPanel: Frame -- pops in when the screen opens
local grid: ScrollingFrame
local gridLayout: UIGridLayout
local gamepadHints: Frame
local openHint: ImageLabel -- D-pad right picture on the CUSTOMISE button
local openLabel: TextLabel
local tabButtons: { [string]: TextButton } = {}
local preview: PreviewStage.Stage
local itemName: TextLabel
local actionButton: TextButton
local actionLabel: TextLabel
local actionCrown: Frame -- crown icon shown next to a price
local messageLabel: TextLabel
local crownsLabel: TextLabel
local gumdropsLabel: TextLabel
local tradeButton: TextButton
local tradeLabel: TextLabel
local actionBadge: Frame -- the controller's A button on the BUY / WEAR button
local tradeBadge: Frame -- ...and X on the trade button
local statsLabel: TextLabel
local savingNote: TextLabel

local isOpen = false
local currentSlot = "Color"
local selectedId: string? = nil
local cards: { Card } = {}
local purchasing = false
local trading = false
local hoveredEmote: string? = nil -- emote card under the mouse
local heldDpad: Vector2? = nil
local heldStick: Vector2? = nil
local repeatAt = 0
local shownShop = "" -- which day's and week's shop the ITEM SHOP tab is showing
local seenShopDay = -1 -- the daily shop you've looked at this session (for the NEW! badge)
local lastTimerUpdate = 0

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
	return PreviewStage.AppearanceFor(equipped)
end

local function refreshPreview()
	preview.SetAppearance(previewAppearance())
end

-- The preview dances the emote card you're pointing at, or the one you've picked, on a loop.
local function updatePreviewEmote()
	local wanted = hoveredEmote
	if not wanted and currentSlot == "Emote" then
		wanted = selectedId
	end
	preview.SetEmote(wanted)
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
			card.Status.Text = if Cosmetics.IsFree(entry) then "FREE" else "OWNED"
			card.Status.TextColor3 = Theme.Colors.InkSoft
		elseif entry.Level then
			-- A reward track exclusive: unlocked by reaching its level, never sold.
			card.Status.Text = `LV {entry.Level}`
			card.Status.TextColor3 = if entry.Rarity then Cosmetics.RarityColors[entry.Rarity] else Theme.Colors.Purple
		else
			card.Status.Text = tostring(entry.Price)
			card.Status.TextColor3 = Theme.Colors.Pink
			card.PriceIcon.Visible = true
		end
		local selected = entry.Id == selectedId
		card.Stroke.Thickness = if selected then 4 else 2
		card.Stroke.Color = if selected
			then Theme.Colors.Purple
			elseif entry.Rarity then Cosmetics.RarityColors[entry.Rarity]
			else GREY
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
	actionCrown.Visible = false
	local crowns = ProfileClient.GetCrowns()
	if purchasing then
		actionLabel.Text = "..."
		actionButton.BackgroundColor3 = GREY
	elseif isEquipped(entry) then
		actionLabel.Text = if entry.Slot == "Emote" then "EQUIPPED" else "WEARING"
		actionButton.BackgroundColor3 = GREY
	elseif ProfileClient.Owns(entry.Id) then
		actionLabel.Text = if entry.Slot == "Emote" then "EQUIP" else "WEAR"
		actionButton.BackgroundColor3 = Theme.Colors.Lime
	elseif entry.Level then
		actionLabel.Text = `LEVEL {entry.Level} REWARD`
		actionButton.BackgroundColor3 = GREY
	elseif crowns >= entry.Price then
		actionLabel.Text = `BUY  {entry.Price}`
		actionButton.BackgroundColor3 = Theme.Colors.Yellow
		actionCrown.Visible = true
	else
		actionLabel.Text = `NEED {entry.Price}`
		actionButton.BackgroundColor3 = GREY
		actionCrown.Visible = true
	end
end

local function refreshHeader()
	crownsLabel.Text = tostring(ProfileClient.GetCrowns())
	local gumdrops = ProfileClient.GetGumdrops()
	gumdropsLabel.Text = tostring(gumdrops)
	if trading then
		tradeLabel.Text = "..."
		tradeButton.BackgroundColor3 = GREY
	elseif gumdrops >= GUMDROPS_PER_CROWN then
		tradeLabel.Text = `TRADE {GUMDROPS_PER_CROWN} FOR 1 CROWN`
		tradeButton.BackgroundColor3 = Theme.Colors.Yellow
	else
		tradeLabel.Text = `{gumdrops} / {GUMDROPS_PER_CROWN} FOR A CROWN`
		tradeButton.BackgroundColor3 = Theme.Colors.PanelTint
	end
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
	if itemId ~= selectedId then
		preview.FaceFront() -- turn round to show it off
	end
	selectedId = itemId
	messageLabel.Text = ""
	Sfx.Play("UiClick")
	refreshAll()
end

local function buildCard(entry: Cosmetics.Item, order: number, parent: Instance): Card
	local button: TextButton = Ui.new("TextButton", {
		Name = entry.Id,
		Text = "",
		AutoButtonColor = false,
		Size = UDim2.fromOffset(CARD_SIZE.X, CARD_SIZE.Y), -- the grid sets this itself
		BackgroundColor3 = Theme.Colors.PanelTint,
		BorderSizePixel = 0,
		LayoutOrder = order,
		Parent = parent,
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
	local priceIcon = WalletHud.CrownIcon(button, 16, UDim2.fromOffset(18, 88), Vector2.zero)
	if entry.Rarity then
		-- Reward track exclusives say how rare they are, in the corner.
		local rarity = Ui.label(
			button,
			string.upper(entry.Rarity),
			Theme.Fonts.Display,
			Cosmetics.RarityColors[entry.Rarity],
			UDim2.fromOffset(70, 14),
			UDim2.fromOffset(6, 5)
		)
		rarity.TextXAlignment = Enum.TextXAlignment.Left
		rarity.ZIndex = 4
	end
	button.Activated:Connect(function()
		selectItem(entry.Id)
	end)
	if entry.Slot == "Emote" then
		-- Pointing at an emote card shows the dance.
		button.MouseEnter:Connect(function()
			hoveredEmote = entry.Id
		end)
		button.MouseLeave:Connect(function()
			if hoveredEmote == entry.Id then
				hoveredEmote = nil
			end
		end)
	end
	return { Item = entry, Button = button, Status = status, PriceIcon = priceIcon, Stroke = stroke }
end

-- The time the item shop goes by (Shared/ItemShop).
local function serverNow(): number
	return ItemShop.Time(Workspace:GetServerTimeNow())
end

-- Which day's and week's shop it is (changes when either shop does).
local function shopKey(now: number): string
	return `{ItemShop.Day(now)}/{ItemShop.Week(now)}`
end

-- 5h 12m, or 3d 4h for the weekly shop.
local function timeLeft(seconds: number): string
	local whole = math.max(0, math.floor(seconds))
	if whole >= 86400 then
		return `{whole // 86400}d {(whole % 86400) // 3600}h`
	elseif whole >= 3600 then
		return `{whole // 3600}h {string.format("%02d", (whole % 3600) // 60)}m`
	end
	return `{whole // 60}m {string.format("%02d", whole % 60)}s`
end

local function updateShopTimers()
	local now = serverNow()
	dailyTimer.Text = `NEW ITEMS IN {timeLeft(ItemShop.NextDaily(now) - now)}`
	weeklyTimer.Text = `NEW ITEMS IN {timeLeft(ItemShop.NextWeekly(now) - now)}`
end

local function switchTab(slot: string)
	currentSlot = slot
	local inShop = slot == SHOP_TAB
	for tabSlot, tab in tabButtons do
		tab.BackgroundColor3 = if tabSlot == slot then Theme.Colors.Purple else Theme.Colors.PanelTint
		local label = tab:FindFirstChildOfClass("TextLabel")
		if label then
			label.TextColor3 = if tabSlot == slot
				then WHITE
				elseif tabSlot == SHOP_TAB then Theme.Colors.Pink
				else Theme.Colors.Purple
		end
	end
	for _, card in cards do
		card.Button:Destroy()
	end
	table.clear(cards)
	hoveredEmote = nil
	titleLabel.Text = if inShop then "ITEM SHOP" else "CUSTOMISE"
	grid.Visible = not inShop
	shopView.Visible = inShop
	if inShop then
		-- Today's daily items, then this week's.
		local now = serverNow()
		shownShop = shopKey(now)
		seenShopDay = ItemShop.Day(now)
		shopBadge.Visible = false
		for order, entry in ItemShop.Daily(now) do
			table.insert(cards, buildCard(entry, order, dailyRow))
		end
		for order, entry in ItemShop.Weekly(now) do
			table.insert(cards, buildCard(entry, order, weeklyRow))
		end
		updateShopTimers()
		selectedId = if cards[1] then cards[1].Item.Id else nil
	else
		local order = 0
		for _, entry in Cosmetics.ForSlot(slot) do
			if entry.Shop and not ProfileClient.Owns(entry.Id) then
				continue -- shop items you don't own are only in the ITEM SHOP
			end
			order += 1
			table.insert(cards, buildCard(entry, order, grid))
		end
		grid.CanvasPosition = Vector2.zero
		selectedId = Cosmetics.InSlot(ProfileClient.GetEquipped(), slot)
	end
	messageLabel.Text = ""
	refreshAll()
end

-------------------------------------------------------------------------------------------------
-- Controller navigation
-------------------------------------------------------------------------------------------------

local function selectedIndex(): number?
	for index, card in cards do
		if card.Item.Id == selectedId then
			return index
		end
	end
	return nil
end

local function gridColumns(): number
	if currentSlot == SHOP_TAB then
		return ItemShop.DailyCount -- the daily row on top, the weekly row under it
	end
	local counted = gridLayout.AbsoluteCellCount.X
	if counted >= 1 then
		return counted
	end
	local usable = grid.Size.X.Offset - GRID_PADDING - 10 + CARD_GAP
	return math.max(1, math.floor(usable / (CARD_SIZE.X + CARD_GAP)))
end

-- Scrolls the grid so the card is fully in view (the grid's own units, unaffected by UI scale).
local function scrollIntoView(index: number)
	if currentSlot == SHOP_TAB then
		return -- the shop doesn't scroll
	end
	local row = (index - 1) // gridColumns()
	local top = GRID_PADDING + row * (CARD_SIZE.Y + CARD_GAP)
	local bottom = top + CARD_SIZE.Y
	local view = grid.CanvasPosition.Y
	if top < view then
		grid.CanvasPosition = Vector2.new(0, math.max(0, top - GRID_PADDING))
	elseif bottom > view + GRID_HEIGHT then
		grid.CanvasPosition = Vector2.new(0, bottom - GRID_HEIGHT + GRID_PADDING)
	end
end

-- Moves the selection one card left/right or one row up/down, trying the new card on.
local function moveSelection(direction: Vector2)
	if #cards == 0 then
		return
	end
	local index = selectedIndex() or 1
	local columns = gridColumns()
	local target = index + direction.X + direction.Y * columns
	if target > #cards and direction.Y > 0 and (index - 1) // columns < (#cards - 1) // columns then
		target = #cards -- down into a part-filled last row
	end
	if target < 1 or target > #cards then
		return
	end
	selectItem(cards[target].Item.Id)
	scrollIntoView(target)
end

local function stepTab(step: number)
	local current = table.find(TABS, currentSlot) or 1
	local nextIndex = (current - 1 + step) % #TABS + 1
	Sfx.Play("UiClick")
	switchTab(TABS[nextIndex])
end

local function stickDirection(position: Vector3): Vector2?
	if Vector2.new(position.X, position.Y).Magnitude < STICK_THRESHOLD then
		return nil
	end
	if math.abs(position.X) > math.abs(position.Y) then
		return Vector2.new(math.sign(position.X), 0)
	end
	return Vector2.new(0, -math.sign(position.Y)) -- stick up = previous row
end

local function onNavigate(_name: string, state: Enum.UserInputState, input: InputObject): Enum.ContextActionResult
	local now = os.clock()
	if input.KeyCode == Enum.KeyCode.Thumbstick1 then
		local direction = stickDirection(input.Position)
		if direction ~= heldStick then
			heldStick = direction
			if direction then
				moveSelection(direction)
				repeatAt = now + NAV_REPEAT_DELAY
			end
		end
		return Enum.ContextActionResult.Sink
	end
	local direction = DPAD_DIRECTIONS[input.KeyCode]
	if not direction then
		return Enum.ContextActionResult.Pass
	end
	if state == Enum.UserInputState.Begin then
		heldDpad = direction
		repeatAt = now + NAV_REPEAT_DELAY
		moveSelection(direction)
	elseif state == Enum.UserInputState.End or state == Enum.UserInputState.Cancel then
		if heldDpad == direction then
			heldDpad = nil
		end
	end
	return Enum.ContextActionResult.Sink
end

-- Holding a direction keeps moving.
local function repeatNavigation()
	local held = heldDpad or heldStick
	local now = os.clock()
	if held and now >= repeatAt then
		repeatAt = now + NAV_REPEAT_RATE
		moveSelection(held)
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
	if entry.Level then
		showMessage(
			`The {entry.Name} is the level {entry.Level} reward: play to level up! (See REWARDS in the lobby.)`,
			ERROR_COLOR
		)
		return
	end
	if ProfileClient.GetCrowns() < entry.Price then
		showMessage(
			`Not enough Crowns yet. Win a match, trade {GUMDROPS_PER_CROWN} Gumdrops for one, or get more with +.`,
			ERROR_COLOR
		)
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

-- Swaps Gumdrops for a Crown (the server checks you have enough).
local function onTrade()
	if trading then
		return
	end
	if ProfileClient.GetGumdrops() < GUMDROPS_PER_CROWN then
		showMessage(`Earn {GUMDROPS_PER_CROWN} Gumdrops by playing rounds, then trade them here.`, ERROR_COLOR)
		return
	end
	trading = true
	refreshHeader()
	task.spawn(function()
		local ok, success, message = pcall(function(): (any, any)
			return Remotes.Function("RequestTrade"):InvokeServer()
		end)
		trading = false
		if ok and success == true then
			showMessage(if typeof(message) == "string" then message else "+1 Crown!", Theme.Colors.Lime)
		else
			showMessage(
				if ok and typeof(message) == "string" then message else "Couldn't trade. Try again!",
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

-- A controller binding that runs `callback` when the button goes down (and swallows the input).
local function onPress(callback: (input: InputObject) -> ())
	return function(_name: string, state: Enum.UserInputState, input: InputObject): Enum.ContextActionResult
		if state == Enum.UserInputState.Begin then
			callback(input)
		end
		return Enum.ContextActionResult.Sink
	end
end

-- While the screen is open these sit above everything else, so B doesn't kick, A doesn't jump...
local function bindGamepad()
	local high = Enum.ContextActionPriority.High.Value
	ContextActionService:BindActionAtPriority(
		CLOSE_ACTION,
		onPress(function()
			setOpen(false)
		end),
		false,
		high,
		Enum.KeyCode.ButtonB
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
			Ui.pressBounce(actionButton)
			onAction()
		end),
		false,
		high,
		Enum.KeyCode.ButtonA
	)
	ContextActionService:BindActionAtPriority(
		TRADE_ACTION,
		onPress(function()
			Ui.pressBounce(tradeButton)
			onTrade()
		end),
		false,
		high,
		Enum.KeyCode.ButtonX
	)
	ContextActionService:BindActionAtPriority(
		TAB_ACTION,
		onPress(function(input: InputObject)
			stepTab(if input.KeyCode == Enum.KeyCode.ButtonL1 then -1 else 1)
		end),
		false,
		high,
		Enum.KeyCode.ButtonL1,
		Enum.KeyCode.ButtonR1
	)
	ContextActionService:BindActionAtPriority(
		SPIN_ACTION,
		function(_name: string, _state: Enum.UserInputState, input: InputObject): Enum.ContextActionResult
			preview.SetStickSpin(input.Position.X)
			return Enum.ContextActionResult.Sink
		end,
		false,
		high,
		Enum.KeyCode.Thumbstick2
	)
	ContextActionService:BindActionAtPriority(
		CROWNS_ACTION,
		onPress(function()
			CrownStoreController.Open()
		end),
		false,
		high,
		Enum.KeyCode.ButtonY
	)
end

local function unbindGamepad()
	for _, action in GAMEPAD_ACTIONS do
		ContextActionService:UnbindAction(action)
	end
	heldDpad = nil
	heldStick = nil
	preview.SetStickSpin(0)
end

-- Button hints under the window, on the BUY / WEAR and trade buttons, and on the CUSTOMISE
-- button, only while using a controller.
local function refreshGamepadLook()
	local gamepad = Input.GetScheme() == "Gamepad"
	gamepadHints.Visible = gamepad
	actionBadge.Visible = gamepad
	tradeBadge.Visible = gamepad
	tradeLabel.Size = if gamepad then UDim2.new(1, -46, 1, -8) else UDim2.new(1, -20, 1, -8)
	tradeLabel.Position = if gamepad then UDim2.new(0.5, 12, 0.5, 0) else UDim2.fromScale(0.5, 0.5)
	openHint.Visible = gamepad and openHint.Image ~= ""
	openLabel.Size = if openHint.Visible then UDim2.new(1, -52, 1, -12) else UDim2.new(1, -20, 1, -12)
	openLabel.Position = if openHint.Visible then UDim2.new(0.5, -14, 0.5, 0) else UDim2.fromScale(0.5, 0.5)
end

function setOpen(open: boolean)
	if open == isOpen or (open and not canOpen()) then
		return
	end
	isOpen = open
	gui.Enabled = open
	Input.SetBlocked("Customise", open)
	preview.SetActive(open)
	if open then
		bindGamepad()
		refreshGamepadLook()
		Ui.popIn(windowPanel)
		switchTab(currentSlot)
	else
		unbindGamepad()
		if GuiService.SelectedObject and GuiService.SelectedObject:IsDescendantOf(gui) then
			GuiService.SelectedObject = nil
		end
	end
end

function CustomiseController.IsOpen(): boolean
	return isOpen
end

-- Whether the screen can be opened now (in the lobby, with your profile loaded).
function CustomiseController.CanOpen(): boolean
	return canOpen()
end

-- True until you've looked at today's item shop (for NEW! tags).
function CustomiseController.IsShopNew(): boolean
	return ItemShop.Day(serverNow()) ~= seenShopDay
end

-- Opens the screen on the ITEM SHOP tab.
function CustomiseController.OpenShop()
	if isOpen then
		switchTab(SHOP_TAB)
	elseif canOpen() then
		currentSlot = SHOP_TAB
		setOpen(true)
	end
end

local function refreshOpenButton()
	local available = canOpen()
	openButton.Visible = available
	-- On phones and tablets ITEM SHOP sits here in the top right; elsewhere it's on the right
	-- side of the screen (ShopButtons).
	shopButton.Visible = available and Input.GetScheme() == "Touch"
	if isOpen and not available then
		setOpen(false)
	end
	if available then
		-- D-pad right opens it. (While it's open the D-pad moves between cards instead: those
		-- bindings sit above this one.)
		ContextActionService:BindAction(
			OPEN_ACTION,
			function(_name: string, state: Enum.UserInputState): Enum.ContextActionResult
				if state == Enum.UserInputState.Begin then
					setOpen(true)
				end
				return Enum.ContextActionResult.Sink
			end,
			false,
			Enum.KeyCode.DPadRight
		)
	else
		ContextActionService:UnbindAction(OPEN_ACTION)
	end
end

-------------------------------------------------------------------------------------------------
-- Building
-------------------------------------------------------------------------------------------------

-- A controller button's picture at the left end of a button (a lettered circle if the platform
-- has no picture for it). Shown only while using a controller (refreshGamepadLook).
local BADGE_COLORS: { [Enum.KeyCode]: Color3 } = {
	[Enum.KeyCode.ButtonA] = Color3.fromRGB(96, 186, 70),
	[Enum.KeyCode.ButtonX] = Color3.fromRGB(64, 128, 230),
}

local function buttonBadge(button: GuiObject, keyCode: Enum.KeyCode, letter: string, size: number): Frame
	local badge: Frame = Ui.new("Frame", {
		Name = "GamepadBadge",
		Size = UDim2.fromOffset(size, size),
		Position = UDim2.new(0, 6, 0.5, 0),
		AnchorPoint = Vector2.new(0, 0.5),
		BackgroundTransparency = 1,
		Visible = false,
		ZIndex = 5,
		Parent = button,
	})
	if UserInputService:GetImageForKeyCode(keyCode) ~= "" then
		KeyIcon.new(keyCode, {
			Size = UDim2.fromScale(1, 1),
			ZIndex = 5,
			Parent = badge,
		})
	else
		badge.BackgroundTransparency = 0
		badge.BackgroundColor3 = BADGE_COLORS[keyCode] or Theme.Colors.Ink
		Ui.corner(badge, UDim.new(0.5, 0))
		Ui.stroke(badge, WHITE, 2)
		local label = Ui.label(
			badge,
			letter,
			Theme.Fonts.Display,
			WHITE,
			UDim2.fromScale(0.7, 0.7),
			UDim2.fromScale(0.5, 0.5),
			Vector2.new(0.5, 0.5)
		)
		label.ZIndex = 6
	end
	return badge
end

local function buildShopButton()
	shopButton = Ui.new("TextButton", {
		Name = "ItemShopButton",
		Text = "",
		AutoButtonColor = false,
		Size = UDim2.fromOffset(128, 40),
		BackgroundColor3 = Theme.Colors.Pink,
		BorderSizePixel = 0,
		LayoutOrder = 3, -- after the Crowns and Gumdrops chips
		Visible = false,
		Parent = WalletHud.GetRow(),
	})
	Ui.corner(shopButton, UDim.new(0.5, 0))
	Ui.stroke(shopButton, WHITE, 3)
	Ui.label(
		shopButton,
		"ITEM SHOP",
		Theme.Fonts.Display,
		WHITE,
		UDim2.new(1, -20, 1, -12),
		UDim2.fromScale(0.5, 0.5),
		Vector2.new(0.5, 0.5)
	)
	-- NEW! until you've looked at today's shop.
	shopBadge = Ui.label(
		shopButton,
		"NEW!",
		Theme.Fonts.Display,
		Theme.Colors.Ink,
		UDim2.fromOffset(46, 20),
		UDim2.new(1, 6, 0, -6),
		Vector2.new(1, 0)
	)
	shopBadge.BackgroundTransparency = 0
	shopBadge.BackgroundColor3 = Theme.Colors.Yellow
	shopBadge.Rotation = 8
	shopBadge.ZIndex = 5
	Ui.corner(shopBadge, UDim.new(0.5, 0))
	Ui.new("UIPadding", { PaddingTop = UDim.new(0, 3), PaddingBottom = UDim.new(0, 3), Parent = shopBadge })
	shopButton.Activated:Connect(function()
		Ui.pressBounce(shopButton)
		CustomiseController.OpenShop()
	end)
end

local function buildOpenButton()
	openButton = Ui.new("TextButton", {
		Name = "CustomiseButton",
		Text = "",
		AutoButtonColor = false,
		Size = UDim2.fromOffset(140, 40),
		BackgroundColor3 = Theme.Colors.Purple,
		BorderSizePixel = 0,
		LayoutOrder = 4, -- after ITEM SHOP
		Visible = false,
		Parent = WalletHud.GetRow(),
	})
	Ui.corner(openButton, UDim.new(0.5, 0))
	Ui.stroke(openButton, WHITE, 3)
	openLabel = Ui.label(
		openButton,
		"CUSTOMISE",
		Theme.Fonts.Display,
		WHITE,
		UDim2.new(1, -20, 1, -12),
		UDim2.fromScale(0.5, 0.5),
		Vector2.new(0.5, 0.5)
	)
	openHint = KeyIcon.new(Enum.KeyCode.DPadRight, {
		Name = "GamepadHint",
		Size = UDim2.fromOffset(28, 28),
		Position = UDim2.new(1, -8, 0.5, 0),
		AnchorPoint = Vector2.new(1, 0.5),
		Visible = false,
		ZIndex = 4,
		Parent = openButton,
	})
	openButton.Activated:Connect(function()
		Ui.pressBounce(openButton)
		if currentSlot == SHOP_TAB then
			currentSlot = "Color" -- CUSTOMISE opens on your things; ITEM SHOP opens the shop
		end
		setOpen(true)
	end)
	buildShopButton()
end

local function buildPreview(body: Frame)
	preview = PreviewStage.new(body, UDim2.new(0, PREVIEW_WIDTH, 1, -70), UDim2.fromOffset(20, 20))
	itemName = Ui.label(
		body,
		"",
		Theme.Fonts.Display,
		Theme.Colors.Ink,
		UDim2.fromOffset(PREVIEW_WIDTH, 34),
		UDim2.new(0, 20, 1, -44),
		Vector2.zero
	)
end

local function buildShop(body: Frame)
	local left = PREVIEW_WIDTH + 40
	local width = WINDOW_SIZE.X - left - 20

	titleLabel = Ui.label(
		body,
		"CUSTOMISE",
		Theme.Fonts.Display,
		Theme.Colors.Purple,
		UDim2.fromOffset(210, 40),
		UDim2.fromOffset(left, 16),
		Vector2.zero
	)
	titleLabel.TextXAlignment = Enum.TextXAlignment.Left
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

	-- Crowns and Gumdrops, then the close button, in the top right.
	local function balance(
		pillWidth: number,
		rightInset: number,
		icon: (Instance, number, UDim2, Vector2) -> Frame
	): (TextLabel, Frame)
		local holder: Frame = Ui.new("Frame", {
			Size = UDim2.fromOffset(pillWidth, 38),
			Position = UDim2.new(1, -rightInset, 0, 18),
			AnchorPoint = Vector2.new(1, 0),
			BackgroundColor3 = Theme.Colors.PanelTint,
			BorderSizePixel = 0,
			Parent = body,
		})
		Ui.corner(holder, UDim.new(0.5, 0))
		icon(holder, 24, UDim2.new(0, 8, 0.5, 0), Vector2.new(0, 0.5))
		local label = Ui.label(
			holder,
			"0",
			Theme.Fonts.Display,
			Theme.Colors.Ink,
			UDim2.new(1, -46, 1, -10),
			UDim2.new(0, 40, 0.5, 0),
			Vector2.new(0, 0.5)
		)
		label.TextXAlignment = Enum.TextXAlignment.Left
		return label, holder
	end
	local crownsPill
	crownsLabel, crownsPill = balance(116, 68, WalletHud.CrownIcon)
	gumdropsLabel = balance(118, 192, WalletHud.GumdropIcon)
	-- "+" on the Crowns: GET CROWNS (for Robux).
	crownsLabel.Size = UDim2.new(1, -76, 1, -10)
	local plus: TextButton = Ui.new("TextButton", {
		Name = "GetCrowns",
		Text = "",
		AutoButtonColor = false,
		Size = UDim2.fromOffset(28, 28),
		Position = UDim2.new(1, -5, 0.5, 0),
		AnchorPoint = Vector2.new(1, 0.5),
		BackgroundColor3 = Theme.Colors.Lime,
		BorderSizePixel = 0,
		Parent = crownsPill,
	})
	Ui.corner(plus, UDim.new(0.5, 0))
	Ui.stroke(plus, WHITE, 2)
	local plusLabel = Ui.label(
		plus,
		"+",
		Theme.Fonts.Display,
		WHITE,
		UDim2.new(1, -6, 1, -6),
		UDim2.fromScale(0.5, 0.5),
		Vector2.new(0.5, 0.5)
	)
	Ui.textOutline(plusLabel, Theme.Colors.Ink, 1.5)
	plus.Activated:Connect(function()
		Ui.pressBounce(plus)
		CrownStoreController.Open()
	end)

	-- Gumdrops -> Crown trade, under the balances.
	tradeButton = Ui.new("TextButton", {
		Name = "Trade",
		Text = "",
		AutoButtonColor = false,
		Size = UDim2.fromOffset(250, 26),
		Position = UDim2.new(1, -18, 0, 60),
		AnchorPoint = Vector2.new(1, 0),
		BackgroundColor3 = Theme.Colors.PanelTint,
		BorderSizePixel = 0,
		Parent = body,
	})
	Ui.corner(tradeButton, UDim.new(0.5, 0))
	Ui.stroke(tradeButton, Theme.Colors.Yellow, 2)
	tradeLabel = Ui.label(
		tradeButton,
		"",
		Theme.Fonts.Display,
		Theme.Colors.Ink,
		UDim2.new(1, -20, 1, -8),
		UDim2.fromScale(0.5, 0.5),
		Vector2.new(0.5, 0.5)
	)
	tradeBadge = buttonBadge(tradeButton, Enum.KeyCode.ButtonX, "X", 22)
	tradeButton.Activated:Connect(function()
		Ui.pressBounce(tradeButton)
		onTrade()
	end)

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
		UDim2.fromOffset(250, 12),
		UDim2.fromOffset(left, 75),
		Vector2.zero
	)
	savingNote.TextXAlignment = Enum.TextXAlignment.Left

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
	local tabWidth = (width - 6 * (#TABS - 1)) / #TABS
	for order, slot in TABS do
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
			if slot == SHOP_TAB then "SHOP" else Cosmetics.SlotLabels[slot],
			Theme.Fonts.Display,
			if slot == SHOP_TAB then Theme.Colors.Pink else Theme.Colors.Purple,
			UDim2.new(1, -8, 1, -12),
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
		Size = UDim2.fromOffset(width, GRID_HEIGHT),
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
		Ui.new("UIPadding", {
			PaddingTop = UDim.new(0, GRID_PADDING),
			PaddingLeft = UDim.new(0, GRID_PADDING),
			PaddingRight = UDim.new(0, 10),
			PaddingBottom = UDim.new(0, GRID_PADDING),
		}),
	})
	gridLayout = Ui.new("UIGridLayout", {
		CellSize = UDim2.fromOffset(CARD_SIZE.X, CARD_SIZE.Y),
		CellPadding = UDim2.fromOffset(CARD_GAP, CARD_GAP),
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = grid,
	})

	-- The ITEM SHOP tab: the daily shop's row, then the weekly shop's.
	shopView = Ui.new("Frame", {
		Name = "ItemShop",
		Size = UDim2.fromOffset(width, SHOP_HEIGHT),
		Position = UDim2.fromOffset(left, 132),
		BackgroundTransparency = 1,
		Visible = false,
		Parent = body,
	})
	local function section(y: number, title: string, color: Color3): (Frame, TextLabel)
		local heading = Ui.label(
			shopView,
			title,
			Theme.Fonts.Display,
			color,
			UDim2.fromOffset(200, 22),
			UDim2.fromOffset(GRID_PADDING, y)
		)
		heading.TextXAlignment = Enum.TextXAlignment.Left
		local timer = Ui.label(
			shopView,
			"",
			Theme.Fonts.Display,
			Theme.Colors.InkSoft,
			UDim2.fromOffset(240, 18),
			UDim2.new(1, -GRID_PADDING, 0, y + 2),
			Vector2.new(1, 0)
		)
		timer.TextXAlignment = Enum.TextXAlignment.Right
		local row: Frame = Ui.new("Frame", {
			Size = UDim2.new(1, 0, 0, CARD_SIZE.Y),
			Position = UDim2.fromOffset(GRID_PADDING, y + 26),
			BackgroundTransparency = 1,
			Parent = shopView,
		}, {
			Ui.new("UIListLayout", {
				FillDirection = Enum.FillDirection.Horizontal,
				SortOrder = Enum.SortOrder.LayoutOrder,
				Padding = UDim.new(0, CARD_GAP),
			}),
		})
		return row, timer
	end
	dailyRow, dailyTimer = section(0, "DAILY SHOP", Theme.Colors.Pink)
	weeklyRow, weeklyTimer = section(CARD_SIZE.Y + 36, "WEEKLY SHOP", Theme.Colors.Purple)

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
		UDim2.new(1, -70, 1, -16),
		UDim2.fromScale(0.5, 0.5),
		Vector2.new(0.5, 0.5)
	)
	actionCrown = WalletHud.CrownIcon(actionButton, 26, UDim2.new(1, -16, 0.5, 0), Vector2.new(1, 0.5))
	actionBadge = buttonBadge(actionButton, Enum.KeyCode.ButtonA, "A", 32)
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

local buildGamepadHints: (window: Frame) -> ()

-- One "button picture + what it does" pair for the hint bar.
local function hint(parent: Instance, keyCodes: { Enum.KeyCode }, fallback: string, action: string, order: number)
	local item: Frame = Ui.new("Frame", {
		Size = UDim2.fromOffset(0, 30),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundTransparency = 1,
		LayoutOrder = order,
		Parent = parent,
	}, {
		Ui.new("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, 4),
		}),
	})
	local hasImages = true
	for _, keyCode in keyCodes do
		if UserInputService:GetImageForKeyCode(keyCode) == "" then
			hasImages = false
		end
	end
	if hasImages then
		for index, keyCode in keyCodes do
			KeyIcon.new(keyCode, {
				Size = UDim2.fromOffset(28, 28),
				LayoutOrder = index,
				Parent = item,
			})
		end
	else
		local chip: TextLabel = Ui.label(item, fallback, Theme.Fonts.Display, WHITE, UDim2.fromOffset(0, 26))
		chip.AutomaticSize = Enum.AutomaticSize.X
		chip.TextScaled = false
		chip.TextSize = 18
		chip.BackgroundTransparency = 0
		chip.BackgroundColor3 = Theme.Colors.Purple
		chip.LayoutOrder = 1
		Ui.textOutline(chip, Theme.Colors.Ink, 2)
		Ui.corner(chip, UDim.new(0, 8))
		Ui.new("UIPadding", { PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8), Parent = chip })
	end
	local label = Ui.label(item, action, Theme.Fonts.Display, WHITE, UDim2.fromOffset(0, 24))
	label.AutomaticSize = Enum.AutomaticSize.X
	label.TextScaled = false
	label.TextSize = 20
	label.LayoutOrder = 10
	Ui.textOutline(label, Color3.fromRGB(0, 0, 0), 2)
end

-- The controller hint bar under the window.
function buildGamepadHints(window: Frame)
	gamepadHints = Ui.new("Frame", {
		Name = "GamepadHints",
		Size = UDim2.new(1, 0, 0, 40),
		Position = UDim2.new(0.5, 0, 1, 12),
		AnchorPoint = Vector2.new(0.5, 0),
		BackgroundColor3 = Theme.Colors.Shadow,
		BackgroundTransparency = 0.35,
		BorderSizePixel = 0,
		Visible = false,
		Parent = window,
	}, {
		Ui.new("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, 22),
		}),
	})
	Ui.corner(gamepadHints, UDim.new(0.5, 0))
	hint(gamepadHints, { Enum.KeyCode.DPadLeft, Enum.KeyCode.DPadRight }, "D-PAD", "CHOOSE", 1)
	hint(gamepadHints, { Enum.KeyCode.ButtonA }, "A", "BUY / WEAR", 2)
	hint(gamepadHints, { Enum.KeyCode.ButtonX }, "X", "TRADE", 3)
	hint(gamepadHints, { Enum.KeyCode.ButtonY }, "Y", "CROWNS", 4)
	hint(gamepadHints, { Enum.KeyCode.ButtonL1, Enum.KeyCode.ButtonR1 }, "LB RB", "TABS", 5)
	hint(gamepadHints, { Enum.KeyCode.Thumbstick2 }, "R", "SPIN", 6)
	hint(gamepadHints, { Enum.KeyCode.ButtonB }, "B", "CLOSE", 7)
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
	buildGamepadHints(window)
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
	Input.SchemeChanged:Connect(function()
		refreshGamepadLook()
		refreshOpenButton()
	end)
	refreshOpenButton()
	refreshGamepadLook()

	RunService.RenderStepped:Connect(function()
		if not isOpen then
			return
		end
		repeatNavigation()
		updatePreviewEmote()
		-- The shop's countdowns, and new items when a shop changes while you're looking.
		local now = os.clock()
		if currentSlot == SHOP_TAB and now - lastTimerUpdate >= SHOP_TIMER_INTERVAL then
			lastTimerUpdate = now
			if shopKey(serverNow()) ~= shownShop then
				switchTab(SHOP_TAB)
			else
				updateShopTimers()
			end
		end
	end)
	-- NEW! on the ITEM SHOP button once a new daily shop is out.
	task.spawn(function()
		while true do
			shopBadge.Visible = ItemShop.Day(serverNow()) ~= seenShopDay
			task.wait(5)
		end
	end)
end

return CustomiseController
