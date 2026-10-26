--!strict
-- The round picker: while each round loads and during its round card, the items you have show
-- along the bottom of the screen and you pick the ones you want for that round (Shared/Items).
-- At GO the server (ItemService) uses them: a boost, shield or double rewards is used up and works
-- for the round; SLAPS puts your slapper in your hand (each hit uses one). Respawns aren't picked:
-- you're offered one if you're knocked out (ItemHud).
--
--   Controller: the left stick or D-pad left / right moves along the cards, A picks or unpicks.
--   Mouse and touch: click or tap a card.
-- Your Bloblet is frozen until GO anyway, so while the picker is up the controls only work it.

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage.Shared
local Config = require(Shared.Config)
local Items = require(Shared.Items)
local Match = require(Shared.Match)
local Remotes = require(Shared.Remotes)
local Theme = require(Shared.Theme)
local Ui = require(Shared.Ui)

local Input = require(script.Parent.InputController)
local ItemIcons = require(script.Parent.ItemIcons)
local KeyIcon = require(script.Parent.KeyIcon)
local MatchClient = require(script.Parent.MatchClient)
local ProfileClient = require(script.Parent.ProfileClient)
local ResponsiveScale = require(script.Parent.ResponsiveScale)
local Sfx = require(script.Parent.Sfx)

local ItemPicker = {}

type Card = {
	Def: Items.Def,
	Button: TextButton,
	Stroke: UIStroke,
	Count: TextLabel,
	State: TextLabel,
	StateChip: Frame,
}

local NAVIGATE_ACTION = "WobblePickerNavigate"
local PICK_ACTION = "WobblePickerPick"
local CARD_SIZE = Vector2.new(100, 122)
local CARD_GAP = 10
local PADDING = 14
local HEADER = 52
local FOOTER = 22
local STICK_THRESHOLD = 0.6
local STICK_REPEAT = 0.22
local WHITE = Theme.Colors.White
local PICKED_COLOR = Theme.Colors.Lime

local localPlayer = Players.LocalPlayer
local gui: ScreenGui
local holder: Frame
local panel: Ui.Panel
local row: Frame
local hintLabel: TextLabel
local hintIcon: ImageLabel
local respawnNote: TextLabel
local bar: Frame
local cards: { Card } = {}
local shownKey = "" -- which items the cards were built for
local isOpen = false
local focusIndex = 1
local lastStickMove = 0

-- Picks are open for us (the server sets ItemPicks when a round we're in starts loading).
local function picksOpen(): boolean
	return localPlayer:GetAttribute(Match.PlayerAttr.ItemPicks) ~= nil
		and MatchClient.IsCompeting()
		and MatchClient.GetStatus() == "Playing"
end

-- The items you could pick right now.
local function pickable(): { Items.Def }
	local list: { Items.Def } = {}
	for _, def in Items.List do
		if Items.IsPickable(def) and ProfileClient.GetItemCount(def.Id) > 0 then
			table.insert(list, def)
		end
	end
	return list
end

-- Seconds until GO (the rest of loading, then the round card).
local function timeToGo(): number
	local phase = MatchClient.GetPhase()
	local left = MatchClient.TimeLeft()
	return if phase == "Loading" then left + Config.Match.IntroTime else left
end

local function showFocus()
	local gamepad = Input.GetScheme() == "Gamepad"
	for index, card in cards do
		local picked = ProfileClient.IsItemPicked(card.Def.Id)
		local focused = gamepad and index == focusIndex
		card.Button.BackgroundColor3 = if picked then PICKED_COLOR:Lerp(WHITE, 0.55) else Theme.Colors.PanelTint
		card.Stroke.Color = if focused then Theme.Colors.Yellow elseif picked then PICKED_COLOR else card.Def.Color
		card.Stroke.Thickness = if focused then 6 elseif picked then 4 else 2
		card.State.Text = if picked then "PICKED!" else "PICK"
		card.StateChip.BackgroundColor3 = if picked then PICKED_COLOR else card.Def.Color
		card.Count.Text = `x{ProfileClient.GetItemCount(card.Def.Id)}`
	end
	local scheme = Input.GetScheme()
	hintIcon.Visible = gamepad and hintIcon.Image ~= ""
	hintLabel.Text = if gamepad
		then "TO PICK  ·  STICK TO MOVE"
		elseif scheme == "Touch" then "TAP THE ONES YOU WANT"
		else "CLICK THE ONES YOU WANT"
	hintLabel.Position = UDim2.fromOffset(if hintIcon.Visible then 32 else 0, 0)
end

local function toggle(index: number)
	local card = cards[index]
	if not card then
		return
	end
	focusIndex = index
	Ui.pressBounce(card.Button)
	local picked = ProfileClient.IsItemPicked(card.Def.Id)
	Sfx.Play(if picked then "UiClick" else "Unlock")
	Remotes.Event("RequestItemPick"):FireServer(card.Def.Id, not picked)
	showFocus()
end

local function moveFocus(step: number)
	local nextIndex = math.clamp(focusIndex + step, 1, #cards)
	if nextIndex ~= focusIndex then
		focusIndex = nextIndex
		Sfx.Play("UiClick")
		showFocus()
	end
end

local function bind(bound: boolean)
	if not bound then
		ContextActionService:UnbindAction(NAVIGATE_ACTION)
		ContextActionService:UnbindAction(PICK_ACTION)
		return
	end
	local high = Enum.ContextActionPriority.High.Value + 12
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
		PICK_ACTION,
		function(_name: string, state: Enum.UserInputState): Enum.ContextActionResult
			if state == Enum.UserInputState.Begin then
				toggle(focusIndex)
			end
			return Enum.ContextActionResult.Sink
		end,
		false,
		high,
		Enum.KeyCode.ButtonA
	)
end

local function buildCard(def: Items.Def, index: number): Card
	local button: TextButton = Ui.new("TextButton", {
		Name = def.Id,
		Text = "",
		AutoButtonColor = false,
		Size = UDim2.fromOffset(CARD_SIZE.X, CARD_SIZE.Y),
		BackgroundColor3 = Theme.Colors.PanelTint,
		BorderSizePixel = 0,
		LayoutOrder = index,
		ZIndex = 3,
		Parent = row,
	})
	Ui.corner(button, UDim.new(0, 16))
	local stroke = Ui.stroke(button, def.Color, 2)
	ItemIcons.Draw(button, def, UDim2.new(0.5, 0, 0, 5), Vector2.new(0.5, 0))
	local name = Ui.label(
		button,
		def.Short,
		Theme.Fonts.Display,
		def.Color,
		UDim2.new(1, -12, 0, 18),
		UDim2.new(0.5, 0, 0, 67),
		Vector2.new(0.5, 0)
	)
	name.ZIndex = 4
	Ui.textOutline(name, Theme.Colors.Ink, 1)
	local count = Ui.label(
		button,
		"",
		Theme.Fonts.Display,
		Theme.Colors.Ink,
		UDim2.new(1, -12, 0, 13),
		UDim2.new(0.5, 0, 0, 85),
		Vector2.new(0.5, 0)
	)
	count.ZIndex = 4
	local chip: Frame = Ui.new("Frame", {
		Size = UDim2.new(1, -14, 0, 22),
		Position = UDim2.new(0.5, 0, 1, -5),
		AnchorPoint = Vector2.new(0.5, 1),
		BackgroundColor3 = def.Color,
		BorderSizePixel = 0,
		ZIndex = 4,
		Parent = button,
	})
	Ui.corner(chip, UDim.new(0.5, 0))
	local state = Ui.label(
		chip,
		"PICK",
		Theme.Fonts.Display,
		WHITE,
		UDim2.new(1, -12, 1, -8),
		UDim2.fromScale(0.5, 0.5),
		Vector2.new(0.5, 0.5)
	)
	state.ZIndex = 5
	Ui.textOutline(state, Theme.Colors.Ink, 1)
	button.Activated:Connect(function()
		toggle(index)
	end)
	button.MouseEnter:Connect(function()
		if Input.GetScheme() == "Gamepad" then
			focusIndex = index
			showFocus()
		end
	end)
	return { Def = def, Button = button, Stroke = stroke, Count = count, State = state, StateChip = chip }
end

-- Rebuilds the cards for the items you have (and sizes the panel to fit them).
local function rebuild(list: { Items.Def })
	local key = ""
	for _, def in list do
		key ..= def.Id .. "|"
	end
	if key == shownKey then
		return
	end
	shownKey = key
	for _, card in cards do
		card.Button:Destroy()
	end
	table.clear(cards)
	for index, def in list do
		table.insert(cards, buildCard(def, index))
	end
	focusIndex = math.clamp(focusIndex, 1, math.max(#cards, 1))
	local width = math.max(#list * CARD_SIZE.X + (#list - 1) * CARD_GAP + PADDING * 2, 360)
	holder.Size = UDim2.fromOffset(width, HEADER + CARD_SIZE.Y + FOOTER + PADDING)
end

local function refresh()
	local list = pickable()
	local open = picksOpen() and #list > 0
	if open then
		rebuild(list)
		local respawns = ProfileClient.GetItemCount("Respawn")
		respawnNote.Text = if respawns > 0
			then `+ {respawns} {if respawns == 1 then "RESPAWN" else "RESPAWNS"}: OFFERED IF YOU'RE KNOCKED OUT`
			else "PICKED ITEMS START WORKING AT GO"
	end
	if open ~= isOpen then
		isOpen = open
		gui.Enabled = open
		Input.SetBlocked("ItemPicker", open)
		bind(open)
		if open then
			focusIndex = 1
			Ui.popIn(panel.Root)
			Sfx.Play("Whoosh")
		end
	end
	if open then
		showFocus()
	end
end

local function build()
	gui = Ui.new("ScreenGui", {
		Name = "ItemPicker",
		ResetOnSpawn = false,
		IgnoreGuiInset = false,
		DisplayOrder = 55, -- over the screen that covers the loading arena
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		Enabled = false,
		Parent = localPlayer:WaitForChild("PlayerGui"),
	})
	holder = Ui.new("Frame", {
		Name = "Holder",
		Size = UDim2.fromOffset(400, HEADER + CARD_SIZE.Y + FOOTER + PADDING),
		-- Under the round card (which sits in the middle during the countdown).
		Position = UDim2.new(0.5, 0, 1, -12),
		AnchorPoint = Vector2.new(0.5, 1),
		BackgroundTransparency = 1,
		Parent = gui,
	})
	ResponsiveScale.Attach(holder, "Hud")
	panel = Ui.panel(holder, UDim2.fromScale(1, 1), UDim2.new(), Vector2.zero)
	local body = panel.Body
	Ui.stroke(body, Theme.Colors.Purple, 3)

	local title = Ui.label(
		body,
		"PICK YOUR ITEMS FOR THIS ROUND",
		Theme.Fonts.Display,
		Theme.Colors.Purple,
		UDim2.new(1, -28, 0, 24),
		UDim2.fromOffset(PADDING, 6)
	)
	title.TextXAlignment = Enum.TextXAlignment.Left
	local hint: Frame = Ui.new("Frame", {
		Size = UDim2.new(1, -28, 0, 18),
		Position = UDim2.fromOffset(PADDING, 30),
		BackgroundTransparency = 1,
		ZIndex = 3,
		Parent = body,
	})
	hintIcon = KeyIcon.new(Enum.KeyCode.ButtonA, {
		Size = UDim2.fromOffset(24, 24),
		Position = UDim2.fromScale(0, 0.5),
		AnchorPoint = Vector2.new(0, 0.5),
		ZIndex = 4,
		Visible = false,
		Parent = hint,
	})
	hintLabel = Ui.label(hint, "", Theme.Fonts.Body, Theme.Colors.InkSoft, UDim2.new(1, -32, 1, 0))
	hintLabel.TextXAlignment = Enum.TextXAlignment.Left

	-- Time left to pick: runs down to GO.
	local track: Frame = Ui.new("Frame", {
		Size = UDim2.new(1, -32, 0, 6),
		Position = UDim2.new(0.5, 0, 0, HEADER - 2),
		AnchorPoint = Vector2.new(0.5, 1),
		BackgroundColor3 = Theme.Colors.PanelTint,
		BorderSizePixel = 0,
		ZIndex = 3,
		Parent = body,
	})
	Ui.corner(track, UDim.new(0.5, 0))
	bar = Ui.new("Frame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Theme.Colors.Purple,
		BorderSizePixel = 0,
		ZIndex = 4,
		Parent = track,
	})
	Ui.corner(bar, UDim.new(0.5, 0))

	row = Ui.new("Frame", {
		Name = "Cards",
		Size = UDim2.new(1, -PADDING * 2, 0, CARD_SIZE.Y),
		Position = UDim2.new(0.5, 0, 0, HEADER + 4),
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
	respawnNote = Ui.label(
		body,
		"",
		Theme.Fonts.Body,
		Theme.Colors.InkSoft,
		UDim2.new(1, -32, 0, 16),
		UDim2.new(0.5, 0, 1, -8),
		Vector2.new(0.5, 1)
	)
end

function ItemPicker.Init()
	build()
	MatchClient.LocalChanged:Connect(refresh)
	MatchClient.Changed:Connect(function(name: string)
		if name == Match.Attr.Phase then
			refresh()
		end
	end)
	ProfileClient.Changed:Connect(refresh)
	Input.SchemeChanged:Connect(function()
		if isOpen then
			showFocus()
		end
	end)
	RunService.RenderStepped:Connect(function()
		if isOpen then
			local total = Config.Match.LoadingTime + Config.Match.IntroTime
			bar.Size = UDim2.fromScale(math.clamp(timeToGo() / total, 0, 1), 1)
		end
	end)
	refresh()
end

return ItemPicker
