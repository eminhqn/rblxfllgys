--!strict
-- The reward track screen: every level from 2 to 30 in a row of cards, each showing what reaching
-- it gives you (Gumdrops, Crowns or an exclusive item you can't buy, with its rarity), which ones
-- you've already unlocked, and your progress towards the next. Rewards are handed out by the
-- server the moment you level up (see ProgressService); this screen only shows them.
--
-- Open it with the REWARDS button by your level, or D-pad down on a controller. Your Bloblet's
-- controls pause while it's open. Controller: left / right (or the left stick) moves along the
-- track, LB / RB jump five levels, B closes.

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Cosmetics = require(Shared.Cosmetics)
local Progression = require(Shared.Progression)
local Theme = require(Shared.Theme)
local Ui = require(Shared.Ui)

local Input = require(script.Parent.InputController)
local ProfileClient = require(script.Parent.ProfileClient)
local ResponsiveScale = require(script.Parent.ResponsiveScale)
local Sfx = require(script.Parent.Sfx)
local WalletHud = require(script.Parent.WalletHud)

local RewardTrackController = {}

type Card = {
	Level: number,
	Frame: Frame,
	Stroke: UIStroke,
	Status: TextLabel,
	Track: Frame, -- the progress bar shown on the next level's card
	Fill: Frame,
	BaseStroke: Color3,
}

local CLOSE_ACTION = "WobbleTrackClose"
local NAVIGATE_ACTION = "WobbleTrackNavigate"
local SWALLOW_ACTION = "WobbleTrackSwallow"
local GAMEPAD_ACTIONS = { CLOSE_ACTION, NAVIGATE_ACTION, SWALLOW_ACTION }
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
	Enum.KeyCode.Thumbstick2,
}

local WINDOW_SIZE = Vector2.new(780, 430)
local CARD_SIZE = Vector2.new(116, 236)
local CARD_GAP = 12
local FIRST_LEVEL = 2
local STICK_THRESHOLD = 0.6
local STICK_REPEAT = 0.2

local WHITE = Theme.Colors.White
local LOCKED_COLOR = Color3.fromRGB(226, 220, 238)
local DONE_COLOR = Theme.Colors.Lime

local localPlayer = Players.LocalPlayer
local gui: ScreenGui
local windowPanel: Frame
local subtitle: TextLabel
local scroller: ScrollingFrame
local cards: { Card } = {}
local isOpen = false
local focused = FIRST_LEVEL
local lastStickMove = 0

-- The circle and caption showing a level's reward.
local function buildReward(card: Frame, reward: Progression.Reward): Color3
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
	return Color3.fromRGB(206, 198, 226)
end

local function buildCard(level: number, order: number): Card
	local frame: Frame = Ui.new("Frame", {
		Name = `Level{level}`,
		Size = UDim2.fromOffset(CARD_SIZE.X, CARD_SIZE.Y),
		BackgroundColor3 = WHITE,
		BorderSizePixel = 0,
		LayoutOrder = order,
		ZIndex = 3,
		Parent = scroller,
	})
	Ui.corner(frame, UDim.new(0, 16))
	local header = Ui.label(
		frame,
		`LV {level}`,
		Theme.Fonts.Display,
		Theme.Colors.Purple,
		UDim2.new(1, -16, 0, 28),
		UDim2.new(0.5, 0, 0, 8),
		Vector2.new(0.5, 0)
	)
	header.ZIndex = 4
	local reward = Progression.RewardFor(level)
	local baseStroke = if reward then buildReward(frame, reward) else Theme.Colors.Purple
	local stroke = Ui.stroke(frame, baseStroke, 3)
	local status = Ui.label(
		frame,
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
		Parent = frame,
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
	return {
		Level = level,
		Frame = frame,
		Stroke = stroke,
		Status = status,
		Track = track,
		Fill = fill,
		BaseStroke = baseStroke,
	}
end

local function refresh()
	local level, into, needed = ProfileClient.GetLevel()
	subtitle.Text = if needed > 0
		then `LEVEL {level}  ·  {into} / {needed} XP TO LEVEL {level + 1}`
		else `LEVEL {level}  ·  TOP LEVEL!`
	local gamepad = Input.GetScheme() == "Gamepad"
	for _, card in cards do
		local unlocked = card.Level <= level
		local isNext = card.Level == level + 1
		card.Frame.BackgroundColor3 = if unlocked or isNext then WHITE else LOCKED_COLOR
		card.Status.Text = if unlocked then "UNLOCKED" elseif isNext then "NEXT" else "LOCKED"
		card.Status.TextColor3 = if unlocked
			then DONE_COLOR
			elseif isNext then Theme.Colors.Pink
			else Theme.Colors.InkSoft
		card.Track.Visible = isNext
		if isNext and needed > 0 then
			card.Fill.Size = UDim2.fromScale(math.clamp(into / needed, 0, 1), 1)
		end
		local highlighted = isOpen and gamepad and card.Level == focused
		card.Stroke.Color = if highlighted then Theme.Colors.Pink else card.BaseStroke
		card.Stroke.Thickness = if highlighted or isNext then 5 else 3
	end
end

-- Scrolls so the given level's card is in view (centred where possible). CanvasPosition is in the
-- window's own units, before the screen scaling, so this works from the layout's sizes.
local function scrollTo(level: number)
	local index = math.clamp(level - FIRST_LEVEL, 0, #cards - 1)
	local step = CARD_SIZE.X + CARD_GAP
	local viewWidth = WINDOW_SIZE.X - 36 -- the scroller's width inside the window's padding
	local canvasWidth = 24 + #cards * step - CARD_GAP
	local cardCenter = 12 + index * step + CARD_SIZE.X / 2
	local target = math.clamp(cardCenter - viewWidth / 2, 0, math.max(canvasWidth - viewWidth, 0))
	scroller.CanvasPosition = Vector2.new(target, 0)
end

local function moveFocus(step: number)
	local last = FIRST_LEVEL + #cards - 1
	local nextLevel = math.clamp(focused + step, FIRST_LEVEL, last)
	if nextLevel ~= focused then
		focused = nextLevel
		Sfx.Play("UiClick")
		scrollTo(focused)
		refresh()
	end
end

local setOpen: (open: boolean) -> ()

local function onNavigate(_name: string, state: Enum.UserInputState, input: InputObject): Enum.ContextActionResult
	local key = input.KeyCode
	if key == Enum.KeyCode.Thumbstick1 then
		local now = os.clock()
		if math.abs(input.Position.X) >= STICK_THRESHOLD and now - lastStickMove >= STICK_REPEAT then
			lastStickMove = now
			moveFocus(if input.Position.X > 0 then 1 else -1)
		end
		return Enum.ContextActionResult.Sink
	end
	if state ~= Enum.UserInputState.Begin then
		return Enum.ContextActionResult.Sink
	end
	if key == Enum.KeyCode.DPadLeft then
		moveFocus(-1)
	elseif key == Enum.KeyCode.DPadRight then
		moveFocus(1)
	elseif key == Enum.KeyCode.ButtonL1 then
		moveFocus(-5)
	elseif key == Enum.KeyCode.ButtonR1 then
		moveFocus(5)
	end
	return Enum.ContextActionResult.Sink
end

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
	if open then
		local level = ProfileClient.GetLevel()
		focused = math.clamp(level + 1, FIRST_LEVEL, FIRST_LEVEL + #cards - 1)
		bindGamepad()
		Ui.popIn(windowPanel)
		refresh()
		task.defer(scrollTo, focused) -- once the layout has its size
	else
		for _, action in GAMEPAD_ACTIONS do
			ContextActionService:UnbindAction(action)
		end
	end
end

function RewardTrackController.Open()
	setOpen(true)
end

function RewardTrackController.IsOpen(): boolean
	return isOpen
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
	Ui.padding(body, 18)

	local title =
		Ui.label(body, "REWARD TRACK", Theme.Fonts.Display, Theme.Colors.Purple, UDim2.new(0.6, 0, 0, 36), UDim2.new())
	title.TextXAlignment = Enum.TextXAlignment.Left
	subtitle =
		Ui.label(body, "", Theme.Fonts.Display, Theme.Colors.InkSoft, UDim2.new(0.8, 0, 0, 20), UDim2.fromOffset(0, 38))
	subtitle.TextXAlignment = Enum.TextXAlignment.Left
	local close: TextButton = Ui.new("TextButton", {
		Text = "",
		AutoButtonColor = false,
		Size = UDim2.fromOffset(40, 40),
		Position = UDim2.fromScale(1, 0),
		AnchorPoint = Vector2.new(1, 0),
		BackgroundColor3 = Theme.Colors.Pink,
		BorderSizePixel = 0,
		ZIndex = 4,
		Parent = body,
	})
	Ui.corner(close, UDim.new(0.5, 0))
	local closeLabel = Ui.label(
		close,
		"X",
		Theme.Fonts.Display,
		WHITE,
		UDim2.new(1, -14, 1, -14),
		UDim2.fromScale(0.5, 0.5),
		Vector2.new(0.5, 0.5)
	)
	closeLabel.ZIndex = 5
	close.Activated:Connect(function()
		setOpen(false)
	end)

	scroller = Ui.new("ScrollingFrame", {
		Name = "Track",
		Size = UDim2.new(1, 0, 0, CARD_SIZE.Y + 28),
		Position = UDim2.fromOffset(0, 70),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollingDirection = Enum.ScrollingDirection.X,
		AutomaticCanvasSize = Enum.AutomaticSize.X,
		CanvasSize = UDim2.new(),
		ScrollBarThickness = 8,
		ScrollBarImageColor3 = Theme.Colors.Purple,
		ZIndex = 3,
		Parent = body,
	})
	Ui.new("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		Padding = UDim.new(0, CARD_GAP),
		SortOrder = Enum.SortOrder.LayoutOrder,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		Parent = scroller,
	})
	Ui.new("UIPadding", {
		PaddingLeft = UDim.new(0, 12),
		PaddingRight = UDim.new(0, 12),
		Parent = scroller,
	})
	for level = FIRST_LEVEL, Progression.TrackLength do
		table.insert(cards, buildCard(level, level))
	end

	local xp = Progression.XP
	local legend = Ui.label(
		body,
		`EARN XP:  ROUND +{xp.RoundPlayed}  ·  GET THROUGH +{xp.RoundQualified}  ·  FINAL +{xp.FinalReached}  ·  WIN +{xp.MatchWon}  ·  CHALLENGE +{xp.ChallengeDone}`,
		Theme.Fonts.Display,
		Theme.Colors.Purple,
		UDim2.new(1, 0, 0, 20),
		UDim2.new(0.5, 0, 1, -24),
		Vector2.new(0.5, 1)
	)
	legend.ZIndex = 3
	local after = Ui.label(
		body,
		`After level {Progression.TrackLength}: +150 Gumdrops every level`,
		Theme.Fonts.Body,
		Theme.Colors.InkSoft,
		UDim2.new(1, 0, 0, 18),
		UDim2.fromScale(0.5, 1),
		Vector2.new(0.5, 1)
	)
	after.ZIndex = 3
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
