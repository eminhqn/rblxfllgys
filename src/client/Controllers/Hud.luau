--!strict
-- The HUD frame: a "top stack" of panels down the top-left of the screen (the Wobble Rush badge
-- and PLAY menu in the lobby; the round bar, team scores and team chip in a round), out of the way
-- of the action in the middle, and a controls card that matches whatever device you're using
-- (touch players get on-screen buttons instead; anyone can hide it in the settings). On phones and tablets the panels in the stack
-- turn see-through so more of the game shows behind them; their text stays solid.
-- Other modules parent their panels to Hud.GetTopStack().
--
-- On phones and tablets the thumbstick takes the lower left of the screen, so the lobby panels
-- that would reach down into it (wallet and CUSTOMISE, level and REWARDS, daily challenges) move
-- to a second stack in the top right instead (Hud.MoveRightOnTouch).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage.Shared
local Match = require(Shared.Match)
local Teams = require(Shared.Teams)
local Theme = require(Shared.Theme)
local Ui = require(Shared.Ui)

local ClientSettings = require(script.Parent.ClientSettings)
local Input = require(script.Parent.InputController)
local KeyIcon = require(script.Parent.KeyIcon)
local MatchClient = require(script.Parent.MatchClient)
local ResponsiveScale = require(script.Parent.ResponsiveScale)

local Hud = {}

-- Order of panels in the top stack.
Hud.TopOrder = table.freeze({
	Title = 1,
	RoundBar = 2,
	TeamScores = 3,
	TeamChip = 4,
	PartySplit = 5, -- "your party is split up this round" under the team chip
	MatchItems = 6, -- your items in a match: boosts working, slaps left (ItemHud)
	Menu = 7,
	Wallet = 8, -- Crowns, Gumdrops, the MENU (touch) and settings buttons
	Level = 9, -- level and XP bar (lobby)
	Challenges = 10, -- daily challenges (lobby)
})

local topStack: Frame? = nil
local sideStack: Frame? = nil -- top right, for touch screens

-- Pieces that move to the side stack on touch screens, and what to tell them when they move.
type SideItem = {
	Object: GuiObject,
	OnMoved: ((onRight: boolean) -> ())?,
}
local sideItems: { SideItem } = {}

-- Background transparency of top stack pieces on touch screens. A GuiObject in the stack can set
-- its own with a "TouchTransparency" attribute (e.g. coloured chips stay more solid).
local PANEL_TOUCH_TRANSPARENCY = 0.4
local SHADOW_TOUCH_TRANSPARENCY = 0.94

local HINT_VISIBLE_SECONDS = 25
-- Slapping needs SLAP picked in the round picker (ItemPicker), which puts the slapper in your hand.
local SLAP_ACTION = "Slap (pick SLAP)"

type HintRow = {
	Key: string,
	KeyCode: Enum.KeyCode?, -- gamepad buttons show the platform's button image when available
	Action: string,
}

local localPlayer = Players.LocalPlayer

local function keyName(keyCode: Enum.KeyCode, fallback: string): string
	-- Respects the player's keyboard layout (e.g. AZERTY shows Z instead of W).
	local ok, result = pcall(function()
		return UserInputService:GetStringForKeyCode(keyCode)
	end)
	if ok and typeof(result) == "string" and result ~= "" then
		return string.upper(result)
	end
	return fallback
end

local function rowsFor(scheme: Input.Scheme): { HintRow }
	if scheme == "Gamepad" then
		return {
			{ Key = "L", KeyCode = Enum.KeyCode.Thumbstick1, Action = "Move" },
			{ Key = "A", KeyCode = Enum.KeyCode.ButtonA, Action = "Jump" },
			{ Key = "X", KeyCode = Enum.KeyCode.ButtonX, Action = "Dive" },
			{ Key = "R2", KeyCode = Enum.KeyCode.ButtonR2, Action = "Grab (hold)" },
			{ Key = "B", KeyCode = Enum.KeyCode.ButtonB, Action = "Kick" },
			{ Key = "UP", KeyCode = Enum.KeyCode.DPadUp, Action = "Emote" },
			{ Key = "Y", KeyCode = Enum.KeyCode.ButtonY, Action = SLAP_ACTION },
		}
	end
	local wasd = keyName(Enum.KeyCode.W, "W")
		.. keyName(Enum.KeyCode.A, "A")
		.. keyName(Enum.KeyCode.S, "S")
		.. keyName(Enum.KeyCode.D, "D")
	return {
		{ Key = wasd, Action = "Move" },
		{ Key = "SPACE", Action = "Jump" },
		{ Key = "CTRL", Action = "Dive" },
		{ Key = "SHIFT", Action = "Grab (hold)" },
		{ Key = keyName(Enum.KeyCode.F, "F") .. " / CLICK", Action = "Kick" },
		{ Key = keyName(Enum.KeyCode.G, "G"), Action = "Emote" },
		{ Key = keyName(Enum.KeyCode.R, "R"), Action = SLAP_ACTION },
	}
end

local function buildTopStack(gui: ScreenGui)
	local top: Frame = Ui.new("Frame", {
		Name = "TopStack",
		Size = UDim2.fromOffset(470, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Position = UDim2.fromOffset(12, 8),
		AnchorPoint = Vector2.zero,
		BackgroundTransparency = 1,
		Parent = gui,
	})
	ResponsiveScale.Attach(top, "Hud")
	Ui.new("UIListLayout", {
		FillDirection = Enum.FillDirection.Vertical,
		HorizontalAlignment = Enum.HorizontalAlignment.Left,
		SortOrder = Enum.SortOrder.LayoutOrder,
		Padding = UDim.new(0, 10),
		Parent = top,
	})
	topStack = top

	local side: Frame = Ui.new("Frame", {
		Name = "SideStack",
		Size = UDim2.fromOffset(470, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Position = UDim2.new(1, -12, 0, 8),
		AnchorPoint = Vector2.new(1, 0),
		BackgroundTransparency = 1,
		Parent = gui,
	})
	ResponsiveScale.Attach(side, "Hud")
	Ui.new("UIListLayout", {
		FillDirection = Enum.FillDirection.Vertical,
		HorizontalAlignment = Enum.HorizontalAlignment.Right,
		SortOrder = Enum.SortOrder.LayoutOrder,
		Padding = UDim.new(0, 10),
		Parent = side,
	})
	sideStack = side

	local title = Ui.panel(top, UDim2.fromOffset(300, 58), UDim2.new(), Vector2.zero)
	title.Root.LayoutOrder = Hud.TopOrder.Title
	local titleLabel = Ui.label(
		title.Body,
		"WOBBLE RUSH",
		Theme.Fonts.Display,
		Theme.Colors.White,
		UDim2.new(1, -28, 1, -16),
		UDim2.fromScale(0.5, 0.5),
		Vector2.new(0.5, 0.5)
	)
	Ui.new("UIGradient", {
		Color = ColorSequence.new(Theme.Colors.Pink, Theme.Colors.Purple),
		Parent = titleLabel,
	})
	Ui.popIn(title.Root, 0.1)
	-- The badge belongs to the lobby; during a match the round bar takes its place.
	local function updateTitle()
		title.Root.Visible = not MatchClient.IsInMatchFlow()
	end
	MatchClient.LocalChanged:Connect(function(name: string)
		if name == Match.PlayerAttr.Status then
			updateTitle()
		end
	end)
	updateTitle()

	local chip = Ui.panel(top, UDim2.fromOffset(190, 38), UDim2.new(), Vector2.zero)
	chip.Root.LayoutOrder = Hud.TopOrder.TeamChip
	chip.Body:SetAttribute("TouchTransparency", 0.15)
	Ui.corner(chip.Body, UDim.new(0.5, 0))
	Ui.corner(chip.Shadow, UDim.new(0.5, 0))
	local chipLabel = Ui.label(
		chip.Body,
		"",
		Theme.Fonts.Display,
		Theme.Colors.White,
		UDim2.new(1, -24, 1, -12),
		UDim2.fromScale(0.5, 0.5),
		Vector2.new(0.5, 0.5)
	)
	chip.Root.Visible = false

	local function updateTeam()
		local team = Teams.FromPlayer(localPlayer)
		chip.Root.Visible = team ~= nil
		if team then
			chip.Body.BackgroundColor3 = team.Color
			chipLabel.Text = string.upper(team.DisplayName)
			Ui.popIn(chip.Root)
		end
	end
	localPlayer:GetPropertyChangedSignal("Team"):Connect(updateTeam)
	updateTeam()

	-- When the teams couldn't stay even with your party together, this says why you're apart.
	local note = Ui.panel(top, UDim2.fromOffset(330, 50), UDim2.new(), Vector2.zero)
	note.Root.LayoutOrder = Hud.TopOrder.PartySplit
	note.Root.Visible = false
	local noteLabel = Ui.label(
		note.Body,
		"Your party is on different teams this round, so the teams are even.",
		Theme.Fonts.Body,
		Theme.Colors.Ink,
		UDim2.new(1, -24, 1, -12),
		UDim2.fromScale(0.5, 0.5),
		Vector2.new(0.5, 0.5)
	)
	noteLabel.TextWrapped = true
	local function updateNote()
		local split = localPlayer:GetAttribute(Match.PlayerAttr.PartySplit) == true
		if split and not note.Root.Visible then
			Ui.popIn(note.Root)
		end
		note.Root.Visible = split
	end
	localPlayer:GetAttributeChangedSignal(Match.PlayerAttr.PartySplit):Connect(updateNote)
	updateNote()
end

local function buildControlsHint(gui: ScreenGui)
	local holder: Frame = Ui.new("Frame", {
		Name = "ControlsHint",
		Size = UDim2.fromOffset(270, 316),
		-- Bottom right: the top stack runs a long way down the left in the lobby.
		Position = UDim2.new(1, -16, 1, -16),
		AnchorPoint = Vector2.new(1, 1),
		BackgroundTransparency = 1,
		Parent = gui,
	})
	ResponsiveScale.Attach(holder, "Hud")
	local group: CanvasGroup = Ui.new("CanvasGroup", {
		Name = "Fade",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Parent = holder,
	})
	local panel = Ui.panel(group, UDim2.new(1, 0, 1, -Theme.ShadowOffset), UDim2.new(), Vector2.zero)
	Ui.padding(panel.Body, 14)
	local list: Frame = Ui.new("Frame", {
		Name = "Rows",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		ZIndex = 3,
		Parent = panel.Body,
	})
	Ui.new("UIListLayout", {
		Padding = UDim.new(0, 8),
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = list,
	})

	local function wanted(scheme: Input.Scheme): boolean
		return scheme ~= "Touch" and Input.IsEnabled() and ClientSettings.Get().ControlsHint
	end

	local fadeToken = 0
	local function show(scheme: Input.Scheme)
		fadeToken += 1
		local token = fadeToken
		holder.Visible = wanted(scheme)
		for _, child in list:GetChildren() do
			if child:IsA("GuiObject") then
				child:Destroy()
			end
		end
		for index, row in rowsFor(scheme) do
			local rowFrame: Frame = Ui.new("Frame", {
				Name = row.Action,
				Size = UDim2.new(1, 0, 0, 32),
				BackgroundTransparency = 1,
				LayoutOrder = index,
				ZIndex = 3,
				Parent = list,
			})
			local chip: Frame = Ui.new("Frame", {
				Name = "Key",
				Size = UDim2.fromOffset(104, 32),
				BackgroundColor3 = Theme.Colors.PanelTint,
				BorderSizePixel = 0,
				ZIndex = 3,
				Parent = rowFrame,
			})
			Ui.corner(chip, UDim.new(0, 10))
			Ui.stroke(chip, Theme.Colors.Purple, 2, 0.4)
			local image = if row.KeyCode then UserInputService:GetImageForKeyCode(row.KeyCode) else ""
			if row.KeyCode and image ~= "" then
				KeyIcon.new(row.KeyCode, {
					Size = UDim2.fromOffset(26, 26),
					Position = UDim2.fromScale(0.5, 0.5),
					AnchorPoint = Vector2.new(0.5, 0.5),
					ZIndex = 4,
					Parent = chip,
				})
			else
				local keyLabel = Ui.label(
					chip,
					row.Key,
					Theme.Fonts.Display,
					Theme.Colors.Purple,
					UDim2.new(1, -10, 1, -10),
					UDim2.fromScale(0.5, 0.5),
					Vector2.new(0.5, 0.5)
				)
				keyLabel.ZIndex = 4
			end
			local actionLabel = Ui.label(
				rowFrame,
				row.Action,
				Theme.Fonts.Body,
				Theme.Colors.Ink,
				UDim2.new(1, -116, 0, 22),
				UDim2.new(0, 116, 0.5, 0),
				Vector2.new(0, 0.5)
			)
			actionLabel.TextXAlignment = Enum.TextXAlignment.Left
		end

		group.GroupTransparency = 1
		TweenService:Create(group, Theme.Tweens.Smooth, { GroupTransparency = 0 }):Play()
		task.delay(HINT_VISIBLE_SECONDS, function()
			if fadeToken == token then
				TweenService:Create(group, TweenInfo.new(1.2), { GroupTransparency = 1 }):Play()
			end
		end)
	end

	Input.SchemeChanged:Connect(show)
	Input.EnabledChanged:Connect(function()
		holder.Visible = wanted(Input.GetScheme())
	end)
	-- Turning the hint on in the settings shows it again (then it fades as usual).
	local hintOn = ClientSettings.Get().ControlsHint
	ClientSettings.Changed:Connect(function(settings)
		if settings.ControlsHint ~= hintOn then
			hintOn = settings.ControlsHint
			show(Input.GetScheme())
		end
	end)
	show(Input.GetScheme())
end

-- How see-through a top stack piece should be on a touch screen, or nil if it stays as built.
local function touchTransparencyOf(object: GuiObject): number?
	local custom = object:GetAttribute("TouchTransparency")
	if typeof(custom) == "number" then
		return custom
	end
	local parent = object.Parent
	local stack = if parent then parent.Parent else nil
	if parent and parent.Name == "Panel" and stack and (stack == topStack or stack == sideStack) then
		if object.Name == "Body" then
			return PANEL_TOUCH_TRANSPARENCY
		elseif object.Name == "Shadow" then
			return SHADOW_TOUCH_TRANSPARENCY
		end
	end
	return nil
end

local function applyTouchLook(object: Instance)
	if not object:IsA("GuiObject") then
		return
	end
	local touchValue = touchTransparencyOf(object)
	if not touchValue then
		return
	end
	-- Remember how it was built so it can go back when the device changes.
	local stored = object:GetAttribute("OpaqueTransparency")
	local opaque: number
	if typeof(stored) == "number" then
		opaque = stored
	else
		opaque = object.BackgroundTransparency
		object:SetAttribute("OpaqueTransparency", opaque)
	end
	object.BackgroundTransparency = if Input.GetScheme() == "Touch" then touchValue else opaque
end

local function watchTouchLook(stacks: { Frame })
	local function applyAll()
		for _, stack in stacks do
			for _, descendant in stack:GetDescendants() do
				applyTouchLook(descendant)
			end
		end
	end
	-- Deferred so a new piece's attributes are set before we look at it.
	for _, stack in stacks do
		stack.DescendantAdded:Connect(function(descendant: Instance)
			task.defer(applyTouchLook, descendant)
		end)
	end
	Input.SchemeChanged:Connect(applyAll)
	applyAll()
end

-- Puts a side item in the top-right stack on touch screens, otherwise back in the top stack.
local function placeSideItem(item: SideItem)
	local onRight = Input.GetScheme() == "Touch"
	local parent = if onRight then sideStack else topStack
	if item.Object.Parent ~= parent then
		item.Object.Parent = parent
	end
	local onMoved = item.OnMoved
	if onMoved then
		onMoved(onRight)
	end
end

function Hud.Init()
	local playerGui = localPlayer:WaitForChild("PlayerGui")
	local gui: ScreenGui = Ui.new("ScreenGui", {
		Name = "Hud",
		ResetOnSpawn = false,
		IgnoreGuiInset = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		Parent = playerGui,
	})
	buildTopStack(gui)
	buildControlsHint(gui)
	local side = sideStack
	assert(side, "the side stack is built with the top stack")
	watchTouchLook({ Hud.GetTopStack(), side })
	Input.SchemeChanged:Connect(function()
		for _, item in sideItems do
			placeSideItem(item)
		end
	end)
end

-- The frame panels are stacked in; set each panel's LayoutOrder from Hud.TopOrder.
function Hud.GetTopStack(): Frame
	local top = topStack
	assert(top, "Hud.Init must run before Hud.GetTopStack")
	return top
end

-- Moves a piece of the top stack to the top right of the screen while the player is using touch
-- (and back when they aren't), keeping its LayoutOrder. onMoved hears which side it's on, e.g. to
-- line a row up against the right edge.
function Hud.MoveRightOnTouch(object: GuiObject, onMoved: ((onRight: boolean) -> ())?)
	local item: SideItem = { Object = object, OnMoved = onMoved }
	table.insert(sideItems, item)
	placeSideItem(item)
end

return Hud
