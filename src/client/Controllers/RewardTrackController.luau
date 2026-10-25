--!strict
-- The reward track screen. On the left, your Bloblet on a turning pedestal; on the right, a strip
-- of cards for every level from 2 to 30, each showing what reaching it gives you (Gumdrops,
-- Crowns or an exclusive item you can't buy, with its rarity), which you've unlocked, and your
-- progress towards the next. Picking a card tries its item on your Bloblet (emotes play on a
-- loop), so you can see what you're working towards. Rewards are handed out by the server the
-- moment you level up (see ProgressService); this screen only shows them.
--
-- Open it with the REWARDS button by your level, or D-pad down on a controller. Your Bloblet's
-- controls pause while it's open. Click a card to pick it; the arrow buttons and the mouse wheel
-- pick the next or previous one, and you can drag or swipe the strip along. Controller: left /
-- right (or the left stick) picks along the track, LB / RB jump five levels, the right stick
-- spins your Bloblet, B closes.
--
-- The strip places its cards itself rather than using a ScrollingFrame, so every card always
-- moves together, gliding along to the picked one.

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage.Shared
local Cosmetics = require(Shared.Cosmetics)
local Progression = require(Shared.Progression)
local Theme = require(Shared.Theme)
local Ui = require(Shared.Ui)

local Input = require(script.Parent.InputController)
local PreviewStage = require(script.Parent.PreviewStage)
local ProfileClient = require(script.Parent.ProfileClient)
local ResponsiveScale = require(script.Parent.ResponsiveScale)
local Sfx = require(script.Parent.Sfx)
local WalletHud = require(script.Parent.WalletHud)

local RewardTrackController = {}

type Card = {
	Level: number,
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
local SWALLOW_ACTION = "WobbleTrackSwallow"
local GAMEPAD_ACTIONS = { CLOSE_ACTION, NAVIGATE_ACTION, SPIN_ACTION, SWALLOW_ACTION }
local SWALLOWED_KEYS = {
	Enum.KeyCode.ButtonA,
	Enum.KeyCode.ButtonX,
	Enum.KeyCode.ButtonY,
	Enum.KeyCode.ButtonL2,
	Enum.KeyCode.ButtonR2,
	Enum.KeyCode.ButtonL3,
	Enum.KeyCode.ButtonR3,
	Enum.KeyCode.ButtonSelect,
	Enum.KeyCode.DPadUp,
	Enum.KeyCode.DPadDown,
}

local WINDOW_SIZE = Vector2.new(900, 520)
local PREVIEW_WIDTH = 330
local RIGHT_X = PREVIEW_WIDTH + 40 -- where the right-hand side starts
local RIGHT_WIDTH = WINDOW_SIZE.X - RIGHT_X - 20
local STRIP_Y = 94
local STRIP_HEIGHT = 250
local CARD_SIZE = Vector2.new(116, 236)
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

local localPlayer = Players.LocalPlayer
local gui: ScreenGui
local windowPanel: Frame
local subtitle: TextLabel
local strip: Frame
local detailLabel: TextLabel
local rewardLabel: TextLabel
local preview: PreviewStage.Stage
local cards: { Card } = {}
local isOpen = false
local selected = FIRST_LEVEL
local offset = 0 -- how far along the strip is scrolled, in the window's own units
local targetOffset = 0 -- where it's gliding to
local lastStickMove = 0
local swipeInput: InputObject? = nil
local swipeStartX = 0
local swipeStartOffset = 0
local swiping = false
local ignoreTapsUntil = 0

local function lastLevel(): number
	return FIRST_LEVEL + #cards - 1
end

local function maxOffset(): number
	return math.max(EDGE * 2 + #cards * STEP - CARD_GAP - RIGHT_WIDTH, 0)
end

-- The scroll that puts a level's card in the middle of the strip (as far as the ends allow).
local function offsetFor(level: number): number
	local centre = EDGE + (level - FIRST_LEVEL) * STEP + CARD_SIZE.X / 2
	return math.clamp(centre - RIGHT_WIDTH / 2, 0, maxOffset())
end

local function placeCards()
	for index, card in cards do
		card.Button.Position = UDim2.fromOffset(EDGE + (index - 1) * STEP - offset, (STRIP_HEIGHT - CARD_SIZE.Y) / 2)
	end
end

local function itemAt(level: number): Cosmetics.Item?
	local reward = Progression.RewardFor(level)
	return if reward and reward.ItemId then Cosmetics.Get(reward.ItemId) else nil
end

-- The preview wears what you're wearing, with the picked level's item tried on.
local function refreshPreview()
	local equipped = table.clone(ProfileClient.GetEquipped())
	local entry = itemAt(selected)
	if entry and entry.Slot ~= "Emote" then
		Cosmetics.SetSlot(equipped, entry.Slot, entry.Id)
	end
	preview.SetAppearance(PreviewStage.AppearanceFor(equipped))
	preview.SetEmote(if entry and entry.Slot == "Emote" then entry.Id else nil)
end

local function refresh()
	local level, into, needed = ProfileClient.GetLevel()
	subtitle.Text = if needed > 0
		then `LEVEL {level}  ·  {into} / {needed} XP TO LEVEL {level + 1}`
		else `LEVEL {level}  ·  TOP LEVEL!`
	for _, card in cards do
		local unlocked = card.Level <= level
		local isNext = card.Level == level + 1
		card.Button.BackgroundColor3 = if unlocked or isNext then WHITE else LOCKED_COLOR
		card.Status.Text = if unlocked then "UNLOCKED" elseif isNext then "NEXT" else "LOCKED"
		card.Status.TextColor3 = if unlocked
			then DONE_COLOR
			elseif isNext then Theme.Colors.Pink
			else Theme.Colors.InkSoft
		card.Track.Visible = isNext
		if isNext and needed > 0 then
			card.Fill.Size = UDim2.fromScale(math.clamp(into / needed, 0, 1), 1)
		end
		local picked = card.Level == selected
		card.Stroke.Color = if picked then Theme.Colors.Pink else card.BaseStroke
		card.Stroke.Thickness = if picked then 6 else 3
	end

	-- What the picked level gives (under the preview) and how far off it is (under the strip).
	local reward = Progression.RewardFor(selected)
	local entry = itemAt(selected)
	rewardLabel.Text = if reward then `LV {selected}: {Progression.Describe(reward)}` else ""
	rewardLabel.TextColor3 = if entry and entry.Rarity then Cosmetics.RarityColors[entry.Rarity] else Theme.Colors.Ink
	if selected <= level then
		detailLabel.Text = if entry then "UNLOCKED! WEAR IT FROM CUSTOMISE" else "UNLOCKED!"
		detailLabel.TextColor3 = DONE_COLOR
	else
		local away = math.max(Progression.TotalXPFor(selected) - ProfileClient.GetXP(), 0)
		detailLabel.Text = `{away} XP TO GO`
		detailLabel.TextColor3 = Theme.Colors.InkSoft
	end
	refreshPreview()
end

local function pick(level: number)
	local clamped = math.clamp(level, FIRST_LEVEL, lastLevel())
	targetOffset = offsetFor(clamped)
	if clamped == selected then
		return
	end
	selected = clamped
	preview.FaceFront()
	Sfx.Play("UiClick")
	refresh()
end

local setOpen: (open: boolean) -> ()

local function onNavigate(_name: string, state: Enum.UserInputState, input: InputObject): Enum.ContextActionResult
	local key = input.KeyCode
	if key == Enum.KeyCode.Thumbstick1 then
		local now = os.clock()
		if math.abs(input.Position.X) >= STICK_THRESHOLD and now - lastStickMove >= STICK_REPEAT then
			lastStickMove = now
			pick(selected + (if input.Position.X > 0 then 1 else -1))
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
		Enum.KeyCode.Thumbstick1
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
		selected = math.clamp(ProfileClient.GetLevel() + 1, FIRST_LEVEL, lastLevel())
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
			Size = UDim2.fromOffset(62, 62),
			Position = UDim2.new(0.5, 0, 0, 44),
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
			UDim2.new(1, -10, 0, 34),
			UDim2.new(0.5, 0, 0, 114),
			Vector2.new(0.5, 0)
		)
		name.TextWrapped = true
		name.ZIndex = 4
		Ui.new("UITextSizeConstraint", { MaxTextSize = 17, Parent = name })
		local rarity = Ui.label(
			card,
			if entry and entry.Rarity then string.upper(entry.Rarity) else "",
			Theme.Fonts.Display,
			rarityColor,
			UDim2.new(1, -10, 0, 16),
			UDim2.new(0.5, 0, 0, 150),
			Vector2.new(0.5, 0)
		)
		rarity.ZIndex = 4
		return rarityColor
	end
	local icon: (Instance, number, UDim2, Vector2) -> Frame = if reward.Kind == "Crowns"
		then WalletHud.CrownIcon
		else WalletHud.GumdropIcon
	icon(card, 50, UDim2.new(0.5, 0, 0, 50), Vector2.new(0.5, 0))
	local amount = Ui.label(
		card,
		`+{reward.Amount}`,
		Theme.Fonts.Display,
		Theme.Colors.Ink,
		UDim2.new(1, -10, 0, 30),
		UDim2.new(0.5, 0, 0, 112),
		Vector2.new(0.5, 0)
	)
	amount.ZIndex = 4
	local caption = Ui.label(
		card,
		if reward.Kind == "Crowns" then (if reward.Amount == 1 then "CROWN" else "CROWNS") else "GUMDROPS",
		Theme.Fonts.Display,
		Theme.Colors.InkSoft,
		UDim2.new(1, -10, 0, 16),
		UDim2.new(0.5, 0, 0, 148),
		Vector2.new(0.5, 0)
	)
	caption.ZIndex = 4
	return CURRENCY_STROKE
end

local function buildCard(level: number): Card
	local button: TextButton = Ui.new("TextButton", {
		Name = `Level{level}`,
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
		Theme.Colors.Purple,
		UDim2.new(1, -16, 0, 28),
		UDim2.new(0.5, 0, 0, 8),
		Vector2.new(0.5, 0)
	)
	header.ZIndex = 4
	local reward = Progression.RewardFor(level)
	local baseStroke = if reward then buildReward(button, reward) else Theme.Colors.Purple
	local stroke = Ui.stroke(button, baseStroke, 3)
	local status = Ui.label(
		button,
		"",
		Theme.Fonts.Display,
		Theme.Colors.InkSoft,
		UDim2.new(1, -16, 0, 20),
		UDim2.new(0.5, 0, 1, -14),
		Vector2.new(0.5, 1)
	)
	status.ZIndex = 4
	local track: Frame = Ui.new("Frame", {
		Size = UDim2.new(1, -20, 0, 10),
		Position = UDim2.new(0.5, 0, 1, -40),
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
			pick(level)
		end
	end)
	return {
		Level = level,
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

-- How you earn XP, in a box under the strip.
local function buildLegend(body: Frame)
	local box: Frame = Ui.new("Frame", {
		Name = "EarnXP",
		Size = UDim2.fromOffset(RIGHT_WIDTH, 110),
		Position = UDim2.fromOffset(RIGHT_X, 390),
		BackgroundColor3 = Theme.Colors.PanelTint,
		BorderSizePixel = 0,
		ZIndex = 2,
		Parent = body,
	})
	Ui.corner(box, UDim.new(0, 16))
	local xp = Progression.XP
	local lines: { { Text: string, Font: Font, Color: Color3, Y: number, Height: number } } = {
		{ Text = "EARN XP BY PLAYING", Font = Theme.Fonts.Display, Color = Theme.Colors.Purple, Y = 10, Height = 22 },
		{
			Text = `PLAY A ROUND +{xp.RoundPlayed}  ·  GET THROUGH +{xp.RoundQualified}  ·  REACH THE FINAL +{xp.FinalReached}`,
			Font = Theme.Fonts.Display,
			Color = Theme.Colors.Ink,
			Y = 38,
			Height = 18,
		},
		{
			Text = `WIN A MATCH +{xp.MatchWon}  ·  DAILY CHALLENGE +{xp.ChallengeDone}`,
			Font = Theme.Fonts.Display,
			Color = Theme.Colors.Ink,
			Y = 60,
			Height = 18,
		},
		{
			Text = `After level {Progression.TrackLength}: +150 Gumdrops every level`,
			Font = Theme.Fonts.Body,
			Color = Theme.Colors.InkSoft,
			Y = 84,
			Height = 16,
		},
	}
	for _, line in lines do
		Ui.label(box, line.Text, line.Font, line.Color, UDim2.new(1, -24, 0, line.Height), UDim2.fromOffset(12, line.Y))
	end
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
	for level = FIRST_LEVEL, Progression.TrackLength do
		table.insert(cards, buildCard(level))
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
		UDim2.fromOffset(RIGHT_WIDTH, 24),
		UDim2.fromOffset(RIGHT_X, STRIP_Y + STRIP_HEIGHT + 10)
	)
	buildLegend(body)
end

function RewardTrackController.Init()
	build()
	ProfileClient.Changed:Connect(function()
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
