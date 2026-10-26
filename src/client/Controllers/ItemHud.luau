--!strict
-- Items in a match (Shared/Items), on this client:
--   * a row in the top stack while you're competing: the items you picked that are working this
--     round (SPEED, JUMP, SLIDE, SHIELD, 2X) and, holding a slapper, how many SLAPS you have, with
--     the slap button (left click / RT; on touch screens a SLAP button next to the others,
--     TouchControls)
--   * the respawn offer when you're knocked out with a RESPAWN: RESPAWN (R / Y / tap) or
--     NO THANKS (B / tap), with a bar running down. Your Bloblet stays put meanwhile.
--   * SHIELD bubbles round every shielded Bloblet, cracking more with each hit they take, and the
--     slap, shield crack / break and respawn effects
--   * "+10 SLAPS!" when an item pack you bought arrives

local CollectionService = game:GetService("CollectionService")
local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TextService = game:GetService("TextService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local Config = require(Shared.Config)
local Items = require(Shared.Items)
local Match = require(Shared.Match)
local Remotes = require(Shared.Remotes)
local Tags = require(Shared.Tags)
local Theme = require(Shared.Theme)
local Ui = require(Shared.Ui)

local ClientEvents = require(script.Parent.ClientEvents)
local Effects = require(script.Parent.Effects)
local Hud = require(script.Parent.Hud)
local Input = require(script.Parent.InputController)
local KeyIcon = require(script.Parent.KeyIcon)
local MatchClient = require(script.Parent.MatchClient)
local ProfileClient = require(script.Parent.ProfileClient)
local ResponsiveScale = require(script.Parent.ResponsiveScale)
local RoundHud = require(script.Parent.RoundHud)
local Sfx = require(script.Parent.Sfx)
local TouchControls = require(script.Parent.TouchControls)

local ItemHud = {}

local OFFER_USE_ACTION = "WobbleRespawnUse"
local OFFER_SKIP_ACTION = "WobbleRespawnSkip"
local SHIELD_ATTRIBUTE = "Shield" -- set on Bloblets by the server's ItemService
local CHIP_HEIGHT = 28
local CHIP_TEXT = 16
local ROW_PADDING = 8
local ROW_GAP = 6
local BUBBLE_SIZE = 6.4
local BUBBLE_LIFT = 0.4 -- above the root, round the body
local CRACKS_PER_HIT = 4
local CRACK_SPOTS = 12 -- places a crack can start from
local CRACKED_COLOR = Color3.fromRGB(255, 80, 110) -- a nearly broken bubble turns this colour
local WHITE = Theme.Colors.White
local SLAP_DEF = Items.Get("Slap") :: Items.Def
local RESPAWN_DEF = Items.Get("Respawn") :: Items.Def
local SHIELD_DEF = Items.Get("Shield") :: Items.Def

type OfferWidgets = {
	Gui: ScreenGui,
	Panel: Frame,
	Count: TextLabel,
	Bar: Frame,
	UseHint: ImageLabel,
	UseKey: TextLabel,
	SkipHint: ImageLabel,
}

local localPlayer = Players.LocalPlayer
local rowPanel: Ui.Panel
local rowBody: Frame
local rowShown = false
local rowKey = "" -- what the row was last built for
local offer: OfferWidgets
local offerOpen = false
type Bubble = {
	Hits: number,
	Parts: { BasePart }, -- the bubble, then its cracks
	Offsets: { CFrame }, -- where each part sits, from the bubble's centre
}

local bubbles: { [Model]: Bubble } = {}
local bubbleFolder: Folder? = nil
local hadBoosts = false

local function textWidth(text: string): number
	local size = TextService:GetTextSize(text, CHIP_TEXT, Enum.Font.FredokaOne, Vector2.new(1000, 100))
	return math.ceil(size.X)
end

-- Hits your shield has left (0 = none, or broken).
local function myShieldHits(): number
	local character = localPlayer.Character
	local value = if character then character:GetAttribute(SHIELD_ATTRIBUTE) else nil
	return if typeof(value) == "number" then value else 0
end

-------------------------------------------------------------------------------------------------
-- The row in the top stack
-------------------------------------------------------------------------------------------------

local function chip(text: string, color: Color3, order: number, dim: boolean): number
	local width = textWidth(text) + 20
	local frame: Frame = Ui.new("Frame", {
		Name = text,
		Size = UDim2.fromOffset(width, CHIP_HEIGHT),
		BackgroundColor3 = color,
		BackgroundTransparency = if dim then 0.65 else 0,
		BorderSizePixel = 0,
		LayoutOrder = order,
		ZIndex = 3,
		Parent = rowBody,
	})
	frame:SetAttribute("TouchTransparency", if dim then 0.75 else 0.1)
	Ui.corner(frame, UDim.new(0.5, 0))
	local label: TextLabel = Ui.new("TextLabel", {
		Text = text,
		FontFace = Theme.Fonts.Display,
		TextSize = CHIP_TEXT,
		TextColor3 = WHITE,
		TextTransparency = if dim then 0.35 else 0,
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 4,
		Parent = frame,
	})
	Ui.textOutline(label, Theme.Colors.Ink, 1.5)
	return width
end

-- Rebuilds the row when what it shows changes.
local function refreshRow()
	local competing = MatchClient.IsCompeting()
	-- Slaps only count while you're holding the slapper (you picked SLAPS this round).
	local slaps = if ProfileClient.IsItemActive("Slap") then ProfileClient.GetItemCount("Slap") else 0
	local boosts: { Items.Def } = {}
	for _, def in Items.List do
		if def.Kind == "Round" and ProfileClient.IsItemActive(def.Id) then
			table.insert(boosts, def)
		end
	end
	local scheme = Input.GetScheme()
	local showSlaps = competing and slaps > 0
	TouchControls.SetSlap(if showSlaps and MatchClient.GetPhase() ~= "Winner" then slaps else nil)
	local visible = competing and (#boosts > 0 or slaps > 0)

	-- A round just started with items you picked: a little fanfare.
	local hasBoosts = competing and (#boosts > 0 or slaps > 0)
	if hasBoosts and not hadBoosts then
		Sfx.Play("Boost")
	end
	hadBoosts = hasBoosts

	-- The shield shows its hits left; once broken it stays on the row, faded.
	local shieldHits = myShieldHits()
	local shieldDim = shieldHits <= 0 and MatchClient.GetPhase() == "Playing"
	local key = `{visible}|{slaps}|{scheme}|{shieldHits}|{shieldDim}`
	for _, def in boosts do
		key ..= `|{def.Id}`
	end
	if key == rowKey then
		return
	end
	rowKey = key
	for _, child in rowBody:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
	rowPanel.Root.Visible = visible
	if not visible then
		rowShown = false
		return
	end

	local width = ROW_PADDING * 2
	local count = 0
	for index, def in boosts do
		local text = if def.Id == "Shield" and shieldHits > 0 then `{def.Short} {shieldHits}` else def.Short
		width += chip(text, def.Color, index, def.Id == "Shield" and shieldDim)
		count += 1
	end
	if slaps > 0 then
		width += chip(`{SLAP_DEF.Short} x{slaps}`, SLAP_DEF.Color, 100, false)
		count += 1
		-- Which button slaps (touch screens have the SLAP button instead).
		if scheme == "Gamepad" then
			KeyIcon.new(Enum.KeyCode.ButtonR2, {
				Size = UDim2.fromOffset(CHIP_HEIGHT, CHIP_HEIGHT),
				LayoutOrder = 101,
				ZIndex = 4,
				Parent = rowBody,
			})
			width += CHIP_HEIGHT
			count += 1
		elseif scheme == "KeyboardMouse" then
			width += chip("CLICK", Theme.Colors.Purple, 101, false)
			count += 1
		end
	end
	width += math.max(0, count - 1) * ROW_GAP
	rowPanel.Root.Size = UDim2.fromOffset(width, CHIP_HEIGHT + ROW_PADDING * 2)
	if not rowShown then
		rowShown = true
		Ui.popIn(rowPanel.Root)
	end
end

local function buildRow()
	rowPanel = Ui.panel(Hud.GetTopStack(), UDim2.fromOffset(200, 44), UDim2.new(), Vector2.zero)
	rowPanel.Root.Name = "MatchItems"
	rowPanel.Root.LayoutOrder = Hud.TopOrder.MatchItems
	rowPanel.Root.Visible = false
	rowBody = rowPanel.Body
	Ui.padding(rowBody, ROW_PADDING)
	Ui.new("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		SortOrder = Enum.SortOrder.LayoutOrder,
		Padding = UDim.new(0, ROW_GAP),
		Parent = rowBody,
	})
end

-------------------------------------------------------------------------------------------------
-- The respawn offer
-------------------------------------------------------------------------------------------------

local function offerEndsAt(): number
	local value = localPlayer:GetAttribute(Match.PlayerAttr.RespawnOfferUntil)
	return if typeof(value) == "number" then value else 0
end

local function answer(use: boolean)
	if not offerOpen then
		return
	end
	Remotes.Event("RequestRespawnChoice"):FireServer(use)
	Sfx.Play("UiClick")
	-- Close straight away; the server clears the offer (or brings us back) a moment later.
	offer.Gui.Enabled = false
end

local function bindOffer(bound: boolean)
	if not bound then
		ContextActionService:UnbindAction(OFFER_USE_ACTION)
		ContextActionService:UnbindAction(OFFER_SKIP_ACTION)
		return
	end
	local high = Enum.ContextActionPriority.High.Value + 10
	ContextActionService:BindActionAtPriority(
		OFFER_USE_ACTION,
		function(_name: string, state: Enum.UserInputState): Enum.ContextActionResult
			if state == Enum.UserInputState.Begin then
				answer(true)
			end
			return Enum.ContextActionResult.Sink
		end,
		false,
		high,
		Enum.KeyCode.ButtonY,
		Enum.KeyCode.R
	)
	ContextActionService:BindActionAtPriority(
		OFFER_SKIP_ACTION,
		function(_name: string, state: Enum.UserInputState): Enum.ContextActionResult
			if state == Enum.UserInputState.Begin then
				answer(false)
			end
			return Enum.ContextActionResult.Sink
		end,
		false,
		high,
		Enum.KeyCode.ButtonB
	)
end

local function refreshOfferHints()
	local gamepad = Input.GetScheme() == "Gamepad"
	offer.UseHint.Visible = gamepad and offer.UseHint.Image ~= ""
	offer.SkipHint.Visible = gamepad and offer.SkipHint.Image ~= ""
	offer.UseKey.Visible = Input.GetScheme() == "KeyboardMouse"
end

local function refreshOffer()
	local open = offerEndsAt() > MatchClient.ServerTime() and MatchClient.GetStatus() == "Eliminated"
	if open == offerOpen then
		return
	end
	offerOpen = open
	offer.Gui.Enabled = open
	Input.SetBlocked("RespawnOffer", open)
	bindOffer(open)
	if open then
		local left = ProfileClient.GetItemCount("Respawn")
		offer.Count.Text = if left == 1 then "You have 1 respawn" else `You have {left} respawns`
		refreshOfferHints()
		Ui.popIn(offer.Panel)
		Sfx.Play("Announce")
	end
end

local function buildOfferButton(
	parent: Instance,
	text: string,
	color: Color3,
	position: UDim2,
	keyCode: Enum.KeyCode,
	onClick: () -> ()
): (TextButton, ImageLabel)
	local button: TextButton = Ui.new("TextButton", {
		Text = "",
		AutoButtonColor = false,
		Size = UDim2.fromOffset(176, 48),
		Position = position,
		AnchorPoint = Vector2.new(0.5, 1),
		BackgroundColor3 = color,
		BorderSizePixel = 0,
		ZIndex = 4,
		Parent = parent,
	})
	Ui.corner(button, UDim.new(0.5, 0))
	Ui.stroke(button, WHITE, 3)
	local label = Ui.label(
		button,
		text,
		Theme.Fonts.Display,
		WHITE,
		UDim2.new(1, -60, 1, -18),
		UDim2.new(0.5, 10, 0.5, 0),
		Vector2.new(0.5, 0.5)
	)
	label.ZIndex = 5
	Ui.textOutline(label, Theme.Colors.Ink, 1.5)
	local hint = KeyIcon.new(keyCode, {
		Size = UDim2.fromOffset(30, 30),
		Position = UDim2.new(0, 10, 0.5, 0),
		AnchorPoint = Vector2.new(0, 0.5),
		ZIndex = 5,
		Visible = false,
		Parent = button,
	})
	button.Activated:Connect(function()
		Ui.pressBounce(button)
		onClick()
	end)
	return button, hint
end

local function buildOffer()
	local gui: ScreenGui = Ui.new("ScreenGui", {
		Name = "RespawnOffer",
		ResetOnSpawn = false,
		IgnoreGuiInset = false,
		DisplayOrder = 14,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		Enabled = false,
		Parent = localPlayer:WaitForChild("PlayerGui"),
	})
	local holder: Frame = Ui.new("Frame", {
		Size = UDim2.fromOffset(420, 196),
		Position = UDim2.fromScale(0.5, 0.66),
		AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundTransparency = 1,
		Parent = gui,
	})
	ResponsiveScale.Attach(holder, "Hud")
	local panel = Ui.panel(holder, UDim2.fromScale(1, 1), UDim2.new(), Vector2.zero)
	local body = panel.Body
	Ui.stroke(body, RESPAWN_DEF.Color, 4)

	local title = Ui.label(
		body,
		"RESPAWN?",
		Theme.Fonts.Display,
		RESPAWN_DEF.Color,
		UDim2.fromOffset(300, 40),
		UDim2.new(0.5, 0, 0, 12),
		Vector2.new(0.5, 0)
	)
	Ui.textOutline(title, Theme.Colors.Ink, 2)
	local count = Ui.label(
		body,
		"",
		Theme.Fonts.Body,
		Theme.Colors.InkSoft,
		UDim2.fromOffset(360, 20),
		UDim2.new(0.5, 0, 0, 56),
		Vector2.new(0.5, 0)
	)
	-- Time left to choose.
	local track: Frame = Ui.new("Frame", {
		Size = UDim2.new(1, -48, 0, 10),
		Position = UDim2.new(0.5, 0, 0, 86),
		AnchorPoint = Vector2.new(0.5, 0),
		BackgroundColor3 = Theme.Colors.PanelTint,
		BorderSizePixel = 0,
		ZIndex = 3,
		Parent = body,
	})
	Ui.corner(track, UDim.new(0.5, 0))
	local bar: Frame = Ui.new("Frame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = RESPAWN_DEF.Color,
		BorderSizePixel = 0,
		ZIndex = 4,
		Parent = track,
	})
	Ui.corner(bar, UDim.new(0.5, 0))

	local useButton, useHint = buildOfferButton(
		body,
		"RESPAWN",
		RESPAWN_DEF.Color,
		UDim2.new(0.5, -96, 1, -18),
		Enum.KeyCode.ButtonY,
		function()
			answer(true)
		end
	)
	local _, skipHint = buildOfferButton(
		body,
		"NO THANKS",
		Theme.Colors.Pink,
		UDim2.new(0.5, 96, 1, -18),
		Enum.KeyCode.ButtonB,
		function()
			answer(false)
		end
	)
	-- The keyboard key for RESPAWN, on the button.
	local useKey = Ui.label(
		useButton,
		"R",
		Theme.Fonts.Display,
		Theme.Colors.Ink,
		UDim2.fromOffset(26, 26),
		UDim2.new(0, 12, 0.5, 0),
		Vector2.new(0, 0.5)
	)
	useKey.BackgroundTransparency = 0
	useKey.BackgroundColor3 = WHITE
	useKey.ZIndex = 5
	useKey.Visible = false
	Ui.corner(useKey, UDim.new(0, 6))

	offer = {
		Gui = gui,
		Panel = panel.Root,
		Count = count,
		Bar = bar,
		UseHint = useHint,
		UseKey = useKey,
		SkipHint = skipHint,
	}
end

-------------------------------------------------------------------------------------------------
-- Shield bubbles and item effects
-------------------------------------------------------------------------------------------------

local function getBubbleFolder(): Folder
	local existing = bubbleFolder
	if existing and existing.Parent then
		return existing
	end
	local created = Instance.new("Folder")
	created.Name = "WobbleShields"
	created.Parent = Workspace
	bubbleFolder = created
	return created
end

-- A crack: a short zigzag of thin glowing lines on the bubble's surface, starting at one of a
-- fixed set of points (so a bubble cracks the same way every time).
local function addCrack(bubble: Bubble, index: number)
	-- Points spread over the sphere with the golden angle.
	local y = 1 - (index - 0.5) / CRACK_SPOTS * 2
	local ring = math.sqrt(math.max(0, 1 - y * y))
	local angle = index * 2.39996
	local start = Vector3.new(math.cos(angle) * ring, y, math.sin(angle) * ring)
	local across = start:Cross(Vector3.yAxis)
	across = if across.Magnitude > 0.1 then across.Unit else start:Cross(Vector3.xAxis).Unit
	local side = start:Cross(across).Unit
	local points = { start }
	for step, wiggle in { 0.1, -0.14, 0.12 } do
		table.insert(points, (points[step] + across * 0.28 + side * wiggle).Unit)
	end
	local radius = BUBBLE_SIZE / 2 + 0.03
	for step = 1, #points - 1 do
		local from, to = points[step] * radius, points[step + 1] * radius
		local line = Instance.new("Part")
		line.Name = "Crack"
		line.Size = Vector3.new(0.09, 0.09, (to - from).Magnitude + 0.06)
		line.Material = Enum.Material.Neon
		line.Color = WHITE
		line.Anchored = true
		line.CanCollide = false
		line.CanQuery = false
		line.CanTouch = false
		line.CastShadow = false
		line.Parent = getBubbleFolder()
		table.insert(bubble.Parts, line)
		table.insert(bubble.Offsets, CFrame.lookAt((from + to) / 2, to))
	end
end

local function removeBubble(model: Model)
	local bubble = bubbles[model]
	if bubble then
		for _, part in bubble.Parts do
			part:Destroy()
		end
		bubbles[model] = nil
	end
end

-- Shows a bubble with `hits` hits left round a Bloblet (nil = none). Fewer hits left = more cracks
-- and a redder bubble.
local function setBubble(model: Model, hits: number?)
	local existing = bubbles[model]
	if existing and existing.Hits == hits then
		return
	end
	removeBubble(model)
	if not hits or hits <= 0 then
		return
	end
	local full = math.max(Config.Items.ShieldHits, 1)
	local taken = math.clamp(full - hits, 0, full)
	local damage = if full > 1 then taken / (full - 1) else 1
	local ball = Instance.new("Part")
	ball.Name = "ShieldBubble"
	ball.Shape = Enum.PartType.Ball
	ball.Size = Vector3.one * BUBBLE_SIZE
	ball.Material = Enum.Material.ForceField
	ball.Color = SHIELD_DEF.Color:Lerp(CRACKED_COLOR, damage * 0.85)
	ball.Anchored = true
	ball.CanCollide = false
	ball.CanQuery = false
	ball.CanTouch = false
	ball.CastShadow = false
	ball.Parent = getBubbleFolder()
	local bubble: Bubble = { Hits = hits, Parts = { ball }, Offsets = { CFrame.identity } }
	for index = 1, taken * CRACKS_PER_HIT + taken // 2 do
		addCrack(bubble, index)
	end
	bubbles[model] = bubble
end

local function shieldHitsOf(model: Model): number?
	local value = model:GetAttribute(SHIELD_ATTRIBUTE)
	return if typeof(value) == "number" and value > 0 then value else nil
end

local function watchBloblet(instance: Instance)
	if not instance:IsA("Model") then
		return
	end
	local model = instance
	local function update()
		setBubble(model, if model.Parent then shieldHitsOf(model) else nil)
		if model == localPlayer.Character then
			refreshRow()
		end
	end
	model:GetAttributeChangedSignal(SHIELD_ATTRIBUTE):Connect(update)
	update()
end

-- Every bubble (and its cracks) follows its Bloblet, all moved in one go.
local function followBubbles()
	local parts: { BasePart } = {}
	local cframes: { CFrame } = {}
	for model, bubble in bubbles do
		local root = model.PrimaryPart
		if not model.Parent or not root then
			removeBubble(model)
			continue
		end
		local centre = CFrame.new(root.Position + Vector3.new(0, BUBBLE_LIFT, 0))
		for index, part in bubble.Parts do
			table.insert(parts, part)
			table.insert(cframes, centre * bubble.Offsets[index])
		end
	end
	if #parts > 0 then
		Workspace:BulkMoveTo(parts, cframes, Enum.BulkMoveMode.FireCFrameChanged)
	end
end

local function onItemEffect(kind: unknown, position: unknown)
	if typeof(position) ~= "Vector3" then
		return
	end
	if kind == "Slap" then
		Effects.Burst(position + Vector3.new(0, 1, 0), {
			Count = 14,
			Colors = { Theme.Colors.Yellow, WHITE, SLAP_DEF.Color },
			Size = Vector3.new(0.5, 0.5, 0.5),
			Speed = 28,
			Up = 10,
			Life = 0.5,
		})
		Sfx.PlayAt("Slap", position)
	elseif kind == "ShieldCrack" then
		Effects.Burst(position + Vector3.new(0, BUBBLE_LIFT, 0), {
			Count = 8,
			Colors = { SHIELD_DEF.Color, WHITE },
			Size = Vector3.new(0.3, 0.3, 0.06),
			Speed = 16,
			Life = 0.45,
			Material = Enum.Material.Neon,
		})
		Sfx.PlayAt("ShieldCrack", position)
	elseif kind == "ShieldPop" then
		Effects.Burst(position + Vector3.new(0, BUBBLE_LIFT, 0), {
			Count = 18,
			Colors = { SHIELD_DEF.Color, WHITE },
			Size = Vector3.new(0.4, 0.4, 0.4),
			Speed = 22,
			Life = 0.6,
			Shape = Enum.PartType.Ball,
			Material = Enum.Material.Neon,
		})
		Sfx.PlayAt("ShieldPop", position)
	elseif kind == "Revive" then
		Effects.Burst(position, {
			Count = 22,
			Colors = { RESPAWN_DEF.Color, WHITE, Theme.Colors.Yellow },
			Size = Vector3.new(0.5, 0.5, 0.5),
			Speed = 18,
			Up = 24,
			Life = 0.8,
		})
		Sfx.PlayAt("Revive", position)
	end
end

-------------------------------------------------------------------------------------------------

function ItemHud.Init()
	buildRow()
	buildOffer()

	local lastStatus = MatchClient.GetStatus()
	MatchClient.LocalChanged:Connect(function(name: string)
		if name == Match.PlayerAttr.Status then
			local status = MatchClient.GetStatus()
			if lastStatus == "Eliminated" and status == "Playing" then
				RoundHud.Toast("BACK IN THE ROUND!", RESPAWN_DEF.Color)
			end
			lastStatus = status
		end
		refreshRow()
		refreshOffer()
	end)
	MatchClient.Changed:Connect(function(name: string)
		if name == Match.Attr.Phase then
			refreshRow()
		end
	end)
	ProfileClient.Changed:Connect(refreshRow)
	Input.SchemeChanged:Connect(function()
		refreshRow()
		if offerOpen then
			refreshOfferHints()
		end
	end)

	Remotes.Event("ItemsPurchased").OnClientEvent:Connect(function(itemId: unknown, amount: unknown)
		local def = if typeof(itemId) == "string" then Items.Get(itemId) else nil
		if not def or typeof(amount) ~= "number" then
			return
		end
		RoundHud.Toast(`+{amount} {def.Name}! THANK YOU!`, def.Color)
		Sfx.Play("Unlock")
	end)
	Remotes.Event("ItemEffect").OnClientEvent:Connect(onItemEffect)
	-- A puff of air under your feet when you DOUBLE JUMP.
	ClientEvents.DoubleJumped:Connect(function()
		local character = localPlayer.Character
		local root = if character then character.PrimaryPart else nil
		if root then
			Effects.Burst(root.Position - Vector3.new(0, 1.8, 0), {
				Count = 10,
				Colors = { WHITE, (Items.Get("DoubleJump") :: Items.Def).Color },
				Size = Vector3.new(0.5, 0.5, 0.5),
				Speed = 14,
				Gravity = 20,
				Drag = 3,
				Life = 0.5,
				Shape = Enum.PartType.Ball,
			})
		end
	end)

	CollectionService:GetInstanceAddedSignal(Tags.Bloblet):Connect(watchBloblet)
	CollectionService:GetInstanceRemovedSignal(Tags.Bloblet):Connect(function(instance: Instance)
		if instance:IsA("Model") then
			removeBubble(instance)
		end
	end)
	for _, instance in CollectionService:GetTagged(Tags.Bloblet) do
		watchBloblet(instance)
	end

	RunService.RenderStepped:Connect(function()
		followBubbles()
		if offerOpen then
			local left = offerEndsAt() - MatchClient.ServerTime()
			if left <= 0 then
				refreshOffer()
			else
				local total = math.max(1, Config.Items.RespawnOfferTime)
				offer.Bar.Size = UDim2.fromScale(math.clamp(left / total, 0, 1), 1)
			end
		end
	end)
	refreshRow()
	refreshOffer()
end

return ItemHud
