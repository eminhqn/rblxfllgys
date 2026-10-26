--!strict
-- The reward track screen. On the left, your Bloblet on a turning pedestal; on the right, a strip
-- with two rows of cards for every level from 2 to 30: the FREE track on top and the PREMIUM track
-- (a Game Pass, Config.Premium) under it. Each card shows what reaching that level gives you
-- (Gumdrops, Crowns, a pack of items or an exclusive item you can't buy, with its rarity), which
-- you've unlocked, and your progress towards the next. Picking a card tries its item on your
-- Bloblet (emotes play on a loop), so you can see what you're working towards. Under the strip,
-- without the premium track, an UNLOCK button buys it: every premium reward for the levels you've
-- already reached is paid the moment you do. Rewards are handed out by the server (ProgressService,
-- PremiumService); this screen only shows them.
--
-- Open it from the lobby MENU (LT on a controller), or D-pad down on a controller. Your Bloblet's
-- controls pause while it's open. Click a card to pick it; the arrow buttons and the mouse wheel
-- pick the next or previous one, and you can drag or swipe the strip along. Controller: left /
-- right (or the left stick) picks along the track, up / down switches between the free and premium
-- rows, LB / RB jump five levels, Y unlocks the premium track, the right stick spins your Bloblet,
-- B closes.
--
-- The strip places its cards itself rather than using a ScrollingFrame, so every card always
-- moves together, gliding along to the picked one.

local ContextActionService = game:GetService("ContextActionService")
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage.Shared
local Config = require(Shared.Config)
local Cosmetics = require(Shared.Cosmetics)
local Items = require(Shared.Items)
local Progression = require(Shared.Progression)
local Theme = require(Shared.Theme)
local Ui = require(Shared.Ui)

local Input = require(script.Parent.InputController)
local ItemIcons = require(script.Parent.ItemIcons)
local KeyIcon = require(script.Parent.KeyIcon)
local PreviewStage = require(script.Parent.PreviewStage)
local ProfileClient = require(script.Parent.ProfileClient)
local ResponsiveScale = require(script.Parent.ResponsiveScale)
local Sfx = require(script.Parent.Sfx)
local WalletHud = require(script.Parent.WalletHud)

local RewardTrackController = {}

type Card = {
	Level: number,
	Premium: boolean, -- on the premium row
	Button: TextButton,
	Stroke: UIStroke,
	Status: TextLabel,
	Track: Frame, -- the progress bar shown on the next level's card
	Fill: Frame,
	BaseStroke: Color3,
}

local CLOSE_ACTION = "WobbleTrackClose"
local NAVIGATE_ACTION = "WobbleTrackNavigate"
local SPIN_ACTION = "WobbleTrackSpin"
local BUY_ACTION = "WobbleTrackBuy"
local SWALLOW_ACTION = "WobbleTrackSwallow"
local GAMEPAD_ACTIONS = { CLOSE_ACTION, NAVIGATE_ACTION, SPIN_ACTION, BUY_ACTION, SWALLOW_ACTION }
local SWALLOWED_KEYS = {
	Enum.KeyCode.ButtonA,
	Enum.KeyCode.ButtonX,
	Enum.KeyCode.ButtonL2,
	Enum.KeyCode.ButtonR2,
	Enum.KeyCode.ButtonL3,
	Enum.KeyCode.ButtonR3,
	Enum.KeyCode.ButtonSelect,
}

local WINDOW_SIZE = Vector2.new(900, 664)
local PREVIEW_WIDTH = 330
local RIGHT_X = PREVIEW_WIDTH + 40 -- where the right-hand side starts
local RIGHT_WIDTH = WINDOW_SIZE.X - RIGHT_X - 20
local STRIP_Y = 94
local STRIP_HEIGHT = 404
local ROW_LABEL_Y = { 6, 206 } -- free row, premium row
local ROW_CARD_Y = { 30, 230 }
local CARD_SIZE = Vector2.new(116, 168)
local CARD_GAP = 12
local STEP = CARD_SIZE.X + CARD_GAP
local EDGE = 12 -- space before the first card and after the last
local GLIDE_RATE = 14 -- how quickly the strip glides along
local FIRST_LEVEL = 2
local STICK_THRESHOLD = 0.6
local STICK_REPEAT = 0.2
local SWIPE_THRESHOLD = 8 -- how far a press on the strip moves before it's a swipe rather than a tap
local TAP_AFTER_SWIPE = 0.15 -- seconds after a swipe that a card ignores being "clicked"

local WHITE = Theme.Colors.White
local LOCKED_COLOR = Color3.fromRGB(226, 220, 238)
local DONE_COLOR = Theme.Colors.Lime
local CURRENCY_STROKE = Color3.fromRGB(206, 198, 226)
local GOLD = Color3.fromRGB(255, 190, 40)
local PREMIUM_CARD = Color3.fromRGB(255, 247, 222)
local PREMIUM_LOCKED = Color3.fromRGB(236, 226, 200)
local PREMIUM_PANEL = Color3.fromRGB(255, 240, 200)

local localPlayer = Players.LocalPlayer
local gui: ScreenGui
local windowPanel: Frame
local subtitle: TextLabel
local strip: Frame
local detailLabel: TextLabel
local rewardLabel: TextLabel
local premiumText: TextLabel
local buyButton: TextButton
local buyLabel: TextLabel
local buyBadge: ImageLabel
local preview: PreviewStage.Stage
local cards: { Card } = {}
local isOpen = false
local selected = FIRST_LEVEL
local selectedPremium = false -- which row the picked card is on
local passPrice: number? = nil -- Robux, once Roblox has told us
local offset = 0 -- how far along the strip is scrolled, in the window's own units
local targetOffset = 0 -- where it's gliding to
local lastStickMove = 0
local swipeInput: InputObject? = nil
local swipeStartX = 0
local swipeStartOffset = 0
local swiping = false
local ignoreTapsUntil = 0

local COLUMNS = Progression.TrackLength - FIRST_LEVEL + 1

local function lastLevel(): number
	return Progression.TrackLength
end

local function maxOffset(): number
	return math.max(EDGE * 2 + COLUMNS * STEP - CARD_GAP - RIGHT_WIDTH, 0)
end

-- The scroll that puts a level's card in the middle of the strip (as far as the ends allow).
local function offsetFor(level: number): number
	local centre = EDGE + (level - FIRST_LEVEL) * STEP + CARD_SIZE.X / 2
	return math.clamp(centre - RIGHT_WIDTH / 2, 0, maxOffset())
end

local function placeCards()
	for _, card in cards do
		card.Button.Position = UDim2.fromOffset(
			EDGE + (card.Level - FIRST_LEVEL) * STEP - offset,
			ROW_CARD_Y[if card.Premium then 2 else 1]
		)
	end
end

local function rewardAt(level: number, premium: boolean): Progression.Reward?
	return if premium then Progression.PremiumRewardFor(level) else Progression.RewardFor(level)
end

local function itemAt(level: number, premium: boolean): Cosmetics.Item?
	local reward = rewardAt(level, premium)
	return if reward and reward.ItemId then Cosmetics.Get(reward.ItemId) else nil
end

-- How many premium rewards are waiting for you to unlock (the levels you've already reached).
local function premiumWaiting(level: number): number
	return math.max(math.min(level, Progression.TrackLength) - 1, 0)
end

-- The preview wears what you're wearing, with the picked card's item tried on.
local function refreshPreview()
	local equipped = table.clone(ProfileClient.GetEquipped())
	local entry = itemAt(selected, selectedPremium)
	if entry and entry.Slot ~= "Emote" then
		Cosmetics.SetSlot(equipped, entry.Slot, entry.Id)
	end
	preview.SetAppearance(PreviewStage.AppearanceFor(equipped))
	preview.SetEmote(if entry and entry.Slot == "Emote" then entry.Id else nil)
	preview.SetSlapper(if entry and entry.Slot == "Slapper" then entry.Id else nil)
end

local function refreshPremiumBar(level: number)
	local owned = ProfileClient.HasPremium()
	buyButton.Visible = not owned
	if owned then
		premiumText.Text = "PREMIUM TRACK: YOURS! Every level pays both rewards."
		return
	end
	local waiting = premiumWaiting(level)
	premiumText.Text = if waiting > 0
		then `PREMIUM TRACK: a bigger reward every level and its own exclusive items. Unlock it now and your {waiting} {if waiting
				== 1
			then "reward"
			else "rewards"} so far are yours straight away.`
		else "PREMIUM TRACK: a bigger reward every level and its own exclusive items. Everything you reach is yours."
	local ready = Config.Premium.GamePassId ~= 0
	buyButton.BackgroundColor3 = if ready then GOLD else LOCKED_COLOR
	buyLabel.Text = if not ready then "NOT SET UP YET" elseif passPrice then `UNLOCK  R$ {passPrice}` else "UNLOCK"
	buyBadge.Visible = ready and Input.GetScheme() == "Gamepad"
end

local function refresh()
	local level, into, needed = ProfileClient.GetLevel()
	local owned = ProfileClient.HasPremium()
	subtitle.Text = if needed > 0
		then `LEVEL {level}  ·  {into} / {needed} XP TO LEVEL {level + 1}`
		else `LEVEL {level}  ·  TOP LEVEL!`
	for _, card in cards do
		local reached = card.Level <= level
		local isNext = card.Level == level + 1
		local unlocked = reached and (owned or not card.Premium)
		if card.Premium then
			card.Button.BackgroundColor3 = if unlocked or isNext then PREMIUM_CARD else PREMIUM_LOCKED
		else
			card.Button.BackgroundColor3 = if unlocked or isNext then WHITE else LOCKED_COLOR
		end
		if unlocked then
			card.Status.Text = "UNLOCKED"
			card.Status.TextColor3 = DONE_COLOR
		elseif reached then
			card.Status.Text = "UNLOCK IT" -- premium, reached, not bought yet
			card.Status.TextColor3 = GOLD
		elseif isNext then
			card.Status.Text = "NEXT"
			card.Status.TextColor3 = Theme.Colors.Pink
		else
			card.Status.Text = "LOCKED"
			card.Status.TextColor3 = Theme.Colors.InkSoft
		end
		card.Track.Visible = isNext
		if isNext and needed > 0 then
			card.Fill.Size = UDim2.fromScale(math.clamp(into / needed, 0, 1), 1)
		end
		local picked = card.Level == selected and card.Premium == selectedPremium
		card.Stroke.Color = if picked then Theme.Colors.Pink else card.BaseStroke
		card.Stroke.Thickness = if picked then 6 else 3
	end

	-- What the picked card gives (under the preview) and how far off it is (under the strip).
	local reward = rewardAt(selected, selectedPremium)
	local entry = itemAt(selected, selectedPremium)
	rewardLabel.Text = if reward
		then `{if selectedPremium then "PREMIUM " else ""}LV {selected}: {Progression.Describe(reward)}`
		else ""
	rewardLabel.TextColor3 = if entry and entry.Rarity
		then Cosmetics.RarityColors[entry.Rarity]
		elseif selectedPremium then GOLD
		else Theme.Colors.Ink
	if selected <= level and (owned or not selectedPremium) then
		detailLabel.Text = if entry then "UNLOCKED! WEAR IT FROM CUSTOMISE" else "UNLOCKED!"
		detailLabel.TextColor3 = DONE_COLOR
	elseif selected <= level then
		detailLabel.Text = "YOU'VE REACHED THIS ONE: UNLOCK THE PREMIUM TRACK TO GET IT NOW"
		detailLabel.TextColor3 = GOLD
	else
		local away = math.max(Progression.TotalXPFor(selected) - ProfileClient.GetXP(), 0)
		detailLabel.Text = if selectedPremium and not owned
			then `{away} XP TO GO  ·  NEEDS THE PREMIUM TRACK`
			else `{away} XP TO GO`
		detailLabel.TextColor3 = Theme.Colors.InkSoft
	end
	refreshPremiumBar(level)
	refreshPreview()
end

-- Asks Roblox to show the premium pass purchase (PremiumService grants it when Roblox says it's
-- bought).
local function buyPremium()
	local passId = Config.Premium.GamePassId
	if passId == 0 or ProfileClient.HasPremium() then
		return
	end
	Sfx.Play("UiClick")
	MarketplaceService:PromptGamePassPurchase(localPlayer, passId)
end

-- The pass's price, once (shown on the UNLOCK button).
local function fetchPrice()
	local passId = Config.Premium.GamePassId
	if passId == 0 or passPrice then
		return
	end
	task.spawn(function()
		local ok, info = pcall(function(): any
			return MarketplaceService:GetProductInfo(passId, Enum.InfoType.GamePass)
		end)
		if ok and typeof(info) == "table" and typeof(info.PriceInRobux) == "number" then
			passPrice = info.PriceInRobux
			if isOpen then
				refresh()
			end
		end
	end)
end

local function pick(level: number, premium: boolean?)
	local clamped = math.clamp(level, FIRST_LEVEL, lastLevel())
	local row = if premium == nil then selectedPremium else premium
	targetOffset = offsetFor(clamped)
	if clamped == selected and row == selectedPremium then
		return
	end
	selected = clamped
	selectedPremium = row
	preview.FaceFront()
	Sfx.Play("UiClick")
	refresh()
end

local setOpen: (open: boolean) -> ()

local function onNavigate(_name: string, state: Enum.UserInputState, input: InputObject): Enum.ContextActionResult
	local key = input.KeyCode
	if key == Enum.KeyCode.Thumbstick1 then
		local now = os.clock()
		local stick = input.Position
		if now - lastStickMove >= STICK_REPEAT then
			if math.abs(stick.X) >= STICK_THRESHOLD and math.abs(stick.X) >= math.abs(stick.Y) then
				lastStickMove = now
				pick(selected + (if stick.X > 0 then 1 else -1))
			elseif math.abs(stick.Y) >= STICK_THRESHOLD then
				lastStickMove = now
				pick(selected, stick.Y < 0) -- down is the premium row
			end
		end
		return Enum.ContextActionResult.Sink
	end
	if state ~= Enum.UserInputState.Begin then
		return Enum.ContextActionResult.Sink
	end
	if key == Enum.KeyCode.DPadLeft then
		pick(selected - 1)
	elseif key == Enum.KeyCode.DPadRight then
		pick(selected + 1)
	elseif key == Enum.KeyCode.ButtonL1 then
		pick(selected - 5)
	elseif key == Enum.KeyCode.ButtonR1 then
		pick(selected + 5)
	elseif key == Enum.KeyCode.DPadUp then
		pick(selected, false)
	elseif key == Enum.KeyCode.DPadDown then
		pick(selected, true)
	end
	return Enum.ContextActionResult.Sink
end

-- While the screen is open these sit above everything else, so the pad only works the screen.
local function bindGamepad()
	local high = Enum.ContextActionPriority.High.Value + 10
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
		onNavigate,
		false,
		high,
		Enum.KeyCode.DPadLeft,
		Enum.KeyCode.DPadRight,
		Enum.KeyCode.ButtonL1,
		Enum.KeyCode.ButtonR1,
		Enum.KeyCode.DPadUp,
		Enum.KeyCode.DPadDown,
		Enum.KeyCode.Thumbstick1
	)
	ContextActionService:BindActionAtPriority(
		BUY_ACTION,
		function(_name: string, state: Enum.UserInputState): Enum.ContextActionResult
			if state == Enum.UserInputState.Begin then
				buyPremium()
			end
			return Enum.ContextActionResult.Sink
		end,
		false,
		high,
		Enum.KeyCode.ButtonY
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
	Input.SetBlocked("RewardTrack", open)
	preview.SetActive(open)
	if open then
		fetchPrice()
		selected = math.clamp(ProfileClient.GetLevel() + 1, FIRST_LEVEL, lastLevel())
		selectedPremium = false
		targetOffset = offsetFor(selected)
		offset = targetOffset -- straight there when opening; after that it glides
		placeCards()
		bindGamepad()
		preview.FaceFront()
		Ui.popIn(windowPanel)
		refresh()
	else
		for _, action in GAMEPAD_ACTIONS do
			ContextActionService:UnbindAction(action)
		end
		preview.SetStickSpin(0)
		swipeInput = nil
		swiping = false
	end
end

function RewardTrackController.Open()
	setOpen(true)
end

function RewardTrackController.IsOpen(): boolean
	return isOpen
end

-------------------------------------------------------------------------------------------------
-- Swiping and the mouse wheel
-------------------------------------------------------------------------------------------------

local function beginSwipe(input: InputObject)
	local inputType = input.UserInputType
	if inputType ~= Enum.UserInputType.MouseButton1 and inputType ~= Enum.UserInputType.Touch then
		return
	end
	if swipeInput == input then
		return -- the card and the strip under it both saw this press
	end
	swipeInput = input
	swipeStartX = input.Position.X
	swipeStartOffset = offset
	swiping = false
end

local function hookStripInput()
	strip.InputBegan:Connect(beginSwipe)
	for _, card in cards do
		card.Button.InputBegan:Connect(beginSwipe)
	end

	UserInputService.InputChanged:Connect(function(input: InputObject)
		if not isOpen then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseWheel then
			-- Only while the mouse is over the strip (the screen ignores the top bar, like this).
			local mouse = UserInputService:GetMouseLocation()
			local corner, size = strip.AbsolutePosition, strip.AbsoluteSize
			if
				mouse.X >= corner.X
				and mouse.X <= corner.X + size.X
				and mouse.Y >= corner.Y
				and mouse.Y <= corner.Y + size.Y
			then
				pick(selected + (if input.Position.Z < 0 then 1 else -1))
			end
			return
		end
		local swipe = swipeInput
		if not swipe then
			return
		end
		local moved = input == swipe
			or (
				swipe.UserInputType == Enum.UserInputType.MouseButton1
				and input.UserInputType == Enum.UserInputType.MouseMovement
			)
		if not moved then
			return
		end
		-- Screen pixels to the window's own units (the window is scaled to fit the screen).
		local scale = math.max(strip.AbsoluteSize.X / RIGHT_WIDTH, 1e-3)
		local dragged = (input.Position.X - swipeStartX) / scale
		if not swiping and math.abs(dragged) > SWIPE_THRESHOLD then
			swiping = true
		end
		if swiping then
			offset = math.clamp(swipeStartOffset - dragged, 0, maxOffset())
			targetOffset = offset
			placeCards()
		end
	end)

	UserInputService.InputEnded:Connect(function(input: InputObject)
		local swipe = swipeInput
		if not swipe then
			return
		end
		local mouseUp = swipe.UserInputType == Enum.UserInputType.MouseButton1
			and input.UserInputType == Enum.UserInputType.MouseButton1
		if input ~= swipe and not mouseUp then
			return
		end
		swipeInput = nil
		if swiping then
			swiping = false
			ignoreTapsUntil = os.clock() + TAP_AFTER_SWIPE -- letting go over a card isn't picking it
		end
	end)
end

-------------------------------------------------------------------------------------------------
-- Building
-------------------------------------------------------------------------------------------------

-- The circle and caption showing a level's reward. Returns the card's border colour.
local function buildReward(card: Instance, reward: Progression.Reward): Color3
	if reward.Kind == "Item" then
		local entry = if reward.ItemId then Cosmetics.Get(reward.ItemId) else nil
		local rarityColor = if entry and entry.Rarity then Cosmetics.RarityColors[entry.Rarity] else Theme.Colors.Purple
		local swatch: Frame = Ui.new("Frame", {
			Size = UDim2.fromOffset(48, 48),
			Position = UDim2.new(0.5, 0, 0, 30),
			AnchorPoint = Vector2.new(0.5, 0),
			BackgroundColor3 = if entry then entry.Swatch else WHITE,
			BorderSizePixel = 0,
			ZIndex = 4,
			Parent = card,
		})
		Ui.corner(swatch, UDim.new(0.5, 0))
		Ui.stroke(swatch, rarityColor, 4)
		local name = Ui.label(
			card,
			if entry then entry.Name else "",
			Theme.Fonts.Body,
			Theme.Colors.Ink,
			UDim2.new(1, -10, 0, 28),
			UDim2.new(0.5, 0, 0, 80),
			Vector2.new(0.5, 0)
		)
		name.TextWrapped = true
		name.ZIndex = 4
		Ui.new("UITextSizeConstraint", { MaxTextSize = 15, Parent = name })
		local rarity = Ui.label(
			card,
			if entry and entry.Rarity then string.upper(entry.Rarity) else "",
			Theme.Fonts.Display,
			rarityColor,
			UDim2.new(1, -10, 0, 14),
			UDim2.new(0.5, 0, 0, 108),
			Vector2.new(0.5, 0)
		)
		rarity.ZIndex = 4
		return rarityColor
	end
	local amountText = `+{reward.Amount}`
	local captionText = "GUMDROPS"
	local def = if reward.Kind == "PowerUp" and reward.PowerUp then Items.Get(reward.PowerUp) else nil
	if def then
		-- A pack of items: its picture, how many, and what.
		local icon = ItemIcons.Draw(card, def, UDim2.new(0.5, 0, 0, 30), Vector2.new(0.5, 0))
		icon.Size = UDim2.fromOffset(46, 46)
		icon.ZIndex = 4
		local rounds = def.Unit == "ROUND"
		amountText = if rounds then `x{reward.Amount}` else `+{reward.Amount}`
		captionText = if rounds then def.Name else def.Units
	else
		local icon: (Instance, number, UDim2, Vector2) -> Frame = if reward.Kind == "Crowns"
			then WalletHud.CrownIcon
			else WalletHud.GumdropIcon
		icon(card, 42, UDim2.new(0.5, 0, 0, 34), Vector2.new(0.5, 0))
		if reward.Kind == "Crowns" then
			captionText = if reward.Amount == 1 then "CROWN" else "CROWNS"
		end
	end
	local amount = Ui.label(
		card,
		amountText,
		Theme.Fonts.Display,
		Theme.Colors.Ink,
		UDim2.new(1, -10, 0, 24),
		UDim2.new(0.5, 0, 0, 80),
		Vector2.new(0.5, 0)
	)
	amount.ZIndex = 4
	local caption = Ui.label(
		card,
		captionText,
		Theme.Fonts.Display,
		Theme.Colors.InkSoft,
		UDim2.new(1, -10, 0, 14),
		UDim2.new(0.5, 0, 0, 106),
		Vector2.new(0.5, 0)
	)
	caption.ZIndex = 4
	return if def then def.Color else CURRENCY_STROKE
end

local function buildCard(level: number, premium: boolean): Card
	local button: TextButton = Ui.new("TextButton", {
		Name = if premium then `Premium{level}` else `Level{level}`,
		Text = "",
		AutoButtonColor = false,
		Size = UDim2.fromOffset(CARD_SIZE.X, CARD_SIZE.Y),
		BackgroundColor3 = WHITE,
		BorderSizePixel = 0,
		ZIndex = 3,
		Parent = strip,
	})
	Ui.corner(button, UDim.new(0, 16))
	local header = Ui.label(
		button,
		`LV {level}`,
		Theme.Fonts.Display,
		if premium then GOLD else Theme.Colors.Purple,
		UDim2.new(1, -16, 0, 22),
		UDim2.new(0.5, 0, 0, 5),
		Vector2.new(0.5, 0)
	)
	header.ZIndex = 4
	local reward = rewardAt(level, premium)
	local baseStroke = if reward then buildReward(button, reward) else Theme.Colors.Purple
	if premium and not (reward and reward.Kind == "Item") then
		baseStroke = GOLD
	end
	local stroke = Ui.stroke(button, baseStroke, 3)
	local status = Ui.label(
		button,
		"",
		Theme.Fonts.Display,
		Theme.Colors.InkSoft,
		UDim2.new(1, -16, 0, 18),
		UDim2.new(0.5, 0, 1, -8),
		Vector2.new(0.5, 1)
	)
	status.ZIndex = 4
	local track: Frame = Ui.new("Frame", {
		Size = UDim2.new(1, -20, 0, 8),
		Position = UDim2.new(0.5, 0, 1, -30),
		AnchorPoint = Vector2.new(0.5, 1),
		BackgroundColor3 = LOCKED_COLOR,
		BorderSizePixel = 0,
		Visible = false,
		ZIndex = 4,
		Parent = button,
	})
	Ui.corner(track, UDim.new(0.5, 0))
	local fill: Frame = Ui.new("Frame", {
		Size = UDim2.fromScale(0, 1),
		BackgroundColor3 = Theme.Colors.Pink,
		BorderSizePixel = 0,
		ZIndex = 5,
		Parent = track,
	})
	Ui.corner(fill, UDim.new(0.5, 0))
	button.Activated:Connect(function()
		if not swiping and os.clock() >= ignoreTapsUntil then
			pick(level, premium)
		end
	end)
	return {
		Level = level,
		Premium = premium,
		Button = button,
		Stroke = stroke,
		Status = status,
		Track = track,
		Fill = fill,
		BaseStroke = baseStroke,
	}
end

-- A round button with a white rim (the close button and the arrows either side of the strip).
local function roundButton(parent: Instance, text: string, position: UDim2, color: Color3): TextButton
	local button: TextButton = Ui.new("TextButton", {
		Text = "",
		AutoButtonColor = false,
		Size = UDim2.fromOffset(42, 42),
		Position = position,
		AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundColor3 = color,
		BorderSizePixel = 0,
		ZIndex = 6,
		Parent = parent,
	})
	Ui.corner(button, UDim.new(0.5, 0))
	Ui.stroke(button, WHITE, 3)
	local label = Ui.label(
		button,
		text,
		Theme.Fonts.Display,
		WHITE,
		UDim2.new(1, -16, 1, -16),
		UDim2.fromScale(0.5, 0.5),
		Vector2.new(0.5, 0.5)
	)
	label.ZIndex = 7
	return button
end

-- How you earn XP, in a box at the bottom.
local function buildLegend(body: Frame)
	local box: Frame = Ui.new("Frame", {
		Name = "EarnXP",
		Size = UDim2.fromOffset(RIGHT_WIDTH, 60),
		Position = UDim2.fromOffset(RIGHT_X, 590),
		BackgroundColor3 = Theme.Colors.PanelTint,
		BorderSizePixel = 0,
		ZIndex = 2,
		Parent = body,
	})
	Ui.corner(box, UDim.new(0, 16))
	local xp = Progression.XP
	local lines: { { Text: string, Font: Font, Color: Color3, Y: number, Height: number } } = {
		{
			Text = `EARN XP: ROUND +{xp.RoundPlayed}  ·  GET THROUGH +{xp.RoundQualified}  ·  FINAL +{xp.FinalReached}  ·  WIN +{xp.MatchWon}  ·  CHALLENGE +{xp.ChallengeDone}`,
			Font = Theme.Fonts.Display,
			Color = Theme.Colors.Ink,
			Y = 10,
			Height = 18,
		},
		{
			Text = `After level {Progression.TrackLength}: +150 Gumdrops every level (+{Config.Premium.PastTrackGumdrops} more with PREMIUM)`,
			Font = Theme.Fonts.Body,
			Color = Theme.Colors.InkSoft,
			Y = 34,
			Height = 16,
		},
	}
	for _, line in lines do
		Ui.label(box, line.Text, line.Font, line.Color, UDim2.new(1, -24, 0, line.Height), UDim2.fromOffset(12, line.Y))
	end
end

-- Under the strip: what the premium track is, and (without it) the UNLOCK button.
local function buildPremiumBar(body: Frame)
	local bar: Frame = Ui.new("Frame", {
		Name = "Premium",
		Size = UDim2.fromOffset(RIGHT_WIDTH, 52),
		Position = UDim2.fromOffset(RIGHT_X, STRIP_Y + STRIP_HEIGHT + 34),
		BackgroundColor3 = PREMIUM_PANEL,
		BorderSizePixel = 0,
		ZIndex = 2,
		Parent = body,
	})
	Ui.corner(bar, UDim.new(0, 16))
	Ui.stroke(bar, GOLD, 3)
	premiumText = Ui.label(
		bar,
		"",
		Theme.Fonts.Body,
		Theme.Colors.Ink,
		UDim2.new(1, -210, 1, -10),
		UDim2.new(0, 14, 0.5, 0),
		Vector2.new(0, 0.5)
	)
	premiumText.TextWrapped = true
	premiumText.TextXAlignment = Enum.TextXAlignment.Left
	premiumText.ZIndex = 3
	Ui.new("UITextSizeConstraint", { MaxTextSize = 16, Parent = premiumText })
	buyButton = Ui.new("TextButton", {
		Name = "Unlock",
		Text = "",
		AutoButtonColor = false,
		Size = UDim2.fromOffset(180, 38),
		Position = UDim2.new(1, -10, 0.5, 0),
		AnchorPoint = Vector2.new(1, 0.5),
		BackgroundColor3 = GOLD,
		BorderSizePixel = 0,
		ZIndex = 3,
		Parent = bar,
	})
	Ui.corner(buyButton, UDim.new(0.5, 0))
	Ui.stroke(buyButton, WHITE, 3)
	buyLabel = Ui.label(
		buyButton,
		"UNLOCK",
		Theme.Fonts.Display,
		WHITE,
		UDim2.new(1, -44, 1, -10),
		UDim2.new(0.5, 12, 0.5, 0),
		Vector2.new(0.5, 0.5)
	)
	buyLabel.ZIndex = 4
	Ui.textOutline(buyLabel, Theme.Colors.Ink, 1.5)
	buyBadge = KeyIcon.new(Enum.KeyCode.ButtonY, {
		Size = UDim2.fromOffset(28, 28),
		Position = UDim2.new(0, 6, 0.5, 0),
		AnchorPoint = Vector2.new(0, 0.5),
		ZIndex = 4,
		Visible = false,
		Parent = buyButton,
	})
	buyButton.Activated:Connect(buyPremium)
end

local function build()
	gui = Ui.new("ScreenGui", {
		Name = "RewardTrack",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		DisplayOrder = 31,
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

	-- Left: your Bloblet, trying on the picked level's item.
	preview = PreviewStage.new(body, UDim2.new(0, PREVIEW_WIDTH, 1, -70), UDim2.fromOffset(20, 20))
	rewardLabel = Ui.label(
		body,
		"",
		Theme.Fonts.Display,
		Theme.Colors.Ink,
		UDim2.fromOffset(PREVIEW_WIDTH, 30),
		UDim2.new(0, 20, 1, -42)
	)

	-- Right: title, the strip of cards, and how to earn XP.
	local title = Ui.label(
		body,
		"REWARD TRACK",
		Theme.Fonts.Display,
		Theme.Colors.Purple,
		UDim2.fromOffset(RIGHT_WIDTH - 60, 38),
		UDim2.fromOffset(RIGHT_X, 20)
	)
	title.TextXAlignment = Enum.TextXAlignment.Left
	subtitle = Ui.label(
		body,
		"",
		Theme.Fonts.Display,
		Theme.Colors.InkSoft,
		UDim2.fromOffset(RIGHT_WIDTH - 60, 20),
		UDim2.fromOffset(RIGHT_X, 62)
	)
	subtitle.TextXAlignment = Enum.TextXAlignment.Left
	local close = roundButton(body, "X", UDim2.new(1, -41, 0, 41), Theme.Colors.Pink)
	close.Activated:Connect(function()
		setOpen(false)
	end)

	strip = Ui.new("Frame", {
		Name = "Strip",
		Size = UDim2.fromOffset(RIGHT_WIDTH, STRIP_HEIGHT),
		Position = UDim2.fromOffset(RIGHT_X, STRIP_Y),
		BackgroundColor3 = Theme.Colors.PanelTint,
		BorderSizePixel = 0,
		ClipsDescendants = true,
		ZIndex = 2,
		Parent = body,
	})
	Ui.corner(strip, UDim.new(0, 16))
	for row, name in { "FREE TRACK", "PREMIUM TRACK" } do
		local label = Ui.label(
			strip,
			name,
			Theme.Fonts.Display,
			if row == 2 then GOLD else Theme.Colors.Purple,
			UDim2.fromOffset(RIGHT_WIDTH - 24, 20),
			UDim2.fromOffset(14, ROW_LABEL_Y[row])
		)
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.ZIndex = 3
		if row == 2 then
			Ui.textOutline(label, Theme.Colors.Ink, 1)
		end
	end
	for level = FIRST_LEVEL, Progression.TrackLength do
		table.insert(cards, buildCard(level, false))
		table.insert(cards, buildCard(level, true))
	end
	placeCards()
	hookStripInput()

	local stripMiddle = STRIP_Y + STRIP_HEIGHT / 2
	local back = roundButton(body, "<", UDim2.fromOffset(RIGHT_X, stripMiddle), Theme.Colors.Purple)
	back.Activated:Connect(function()
		pick(selected - 1)
	end)
	local forward = roundButton(body, ">", UDim2.fromOffset(RIGHT_X + RIGHT_WIDTH, stripMiddle), Theme.Colors.Purple)
	forward.Activated:Connect(function()
		pick(selected + 1)
	end)

	detailLabel = Ui.label(
		body,
		"",
		Theme.Fonts.Display,
		Theme.Colors.InkSoft,
		UDim2.fromOffset(RIGHT_WIDTH, 22),
		UDim2.fromOffset(RIGHT_X, STRIP_Y + STRIP_HEIGHT + 8)
	)
	buildPremiumBar(body)
	buildLegend(body)
end

function RewardTrackController.Init()
	build()
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
	-- The strip glides along to where it's heading (it follows your finger while you swipe).
	RunService.RenderStepped:Connect(function(dt: number)
		if not isOpen or swiping or offset == targetOffset then
			return
		end
		if math.abs(targetOffset - offset) < 0.5 then
			offset = targetOffset
		else
			offset += (targetOffset - offset) * (1 - math.exp(-GLIDE_RATE * dt))
		end
		placeCards()
	end)
	-- D-pad down opens it.
	ContextActionService:BindAction(
		"WobbleTrackOpen",
		function(_name: string, state: Enum.UserInputState): Enum.ContextActionResult
			if state == Enum.UserInputState.Begin and ProfileClient.IsReady() then
				setOpen(true)
				return Enum.ContextActionResult.Sink
			end
			return Enum.ContextActionResult.Pass
		end,
		false,
		Enum.KeyCode.DPadDown
	)
end

return RewardTrackController
