--!strict
-- A row in the top stack with your Crowns (what items cost; won by winning matches) and your
-- Gumdrops (earned by playing; trade 500 for a Crown in the customise screen). When either goes
-- up, its chip bounces and a "+N" floats up beside it. If the server couldn't load your saved
-- data, a small NOT SAVING pill says so. On phones and tablets the lobby's MENU button (LobbyMenu)
-- and the settings gear sit in this row too.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage.Shared
local Theme = require(Shared.Theme)
local Ui = require(Shared.Ui)

local Hud = require(script.Parent.Hud)
local ProfileClient = require(script.Parent.ProfileClient)
local Sfx = require(script.Parent.Sfx)

local WalletHud = {}

type Chip = {
	Panel: Ui.Panel,
	Amount: TextLabel,
	Gain: TextLabel,
	Shown: number?,
}

local GUMDROP_COLOR = Color3.fromRGB(255, 92, 168)
local GOLD = Color3.fromRGB(255, 205, 64)
local GOLD_DARK = Color3.fromRGB(226, 160, 30)

local row: Frame
local crownChip: Chip
local gumdropChip: Chip
local notSaving: Frame

-- The row other lobby buttons go in (after WalletHud.Init). LayoutOrder 3+ goes after the chips.
function WalletHud.GetRow(): Frame
	return row
end

-- A little round gumdrop with a shine, drawn with frames.
function WalletHud.GumdropIcon(parent: Instance, size: number, position: UDim2, anchor: Vector2): Frame
	local icon: Frame = Ui.new("Frame", {
		Name = "Gumdrop",
		Size = UDim2.fromOffset(size, size),
		Position = position,
		AnchorPoint = anchor,
		BackgroundColor3 = GUMDROP_COLOR,
		BorderSizePixel = 0,
		ZIndex = 3,
		Parent = parent,
	})
	Ui.corner(icon, UDim.new(0.5, 0))
	Ui.stroke(icon, Theme.Colors.White, 2)
	Ui.new("UIGradient", {
		Color = ColorSequence.new(Theme.Colors.White, GUMDROP_COLOR),
		Rotation = 60,
		Offset = Vector2.new(-0.35, 0),
		Parent = icon,
	})
	local shine: Frame = Ui.new("Frame", {
		Size = UDim2.fromScale(0.28, 0.28),
		Position = UDim2.fromScale(0.3, 0.28),
		AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundColor3 = Theme.Colors.White,
		BorderSizePixel = 0,
		ZIndex = 4,
		Parent = icon,
	})
	Ui.corner(shine, UDim.new(0.5, 0))
	return icon
end

-- A little gold crown (a band with three round points and a gem), drawn with frames.
function WalletHud.CrownIcon(parent: Instance, size: number, position: UDim2, anchor: Vector2): Frame
	local icon: Frame = Ui.new("Frame", {
		Name = "Crown",
		Size = UDim2.fromOffset(size, size),
		Position = position,
		AnchorPoint = anchor,
		BackgroundTransparency = 1,
		ZIndex = 3,
		Parent = parent,
	})
	for _, x in { 0.14, 0.5, 0.86 } do
		local point: Frame = Ui.new("Frame", {
			Size = UDim2.fromScale(0.32, 0.32),
			Position = UDim2.fromScale(x, 0.3),
			AnchorPoint = Vector2.new(0.5, 0.5),
			BackgroundColor3 = GOLD,
			BorderSizePixel = 0,
			ZIndex = 3,
			Parent = icon,
		})
		Ui.corner(point, UDim.new(0.5, 0))
	end
	local band: Frame = Ui.new("Frame", {
		Size = UDim2.fromScale(1, 0.55),
		Position = UDim2.fromScale(0.5, 1),
		AnchorPoint = Vector2.new(0.5, 1),
		BackgroundColor3 = GOLD,
		BorderSizePixel = 0,
		ZIndex = 4,
		Parent = icon,
	})
	Ui.corner(band, UDim.new(0.25, 0))
	Ui.stroke(band, GOLD_DARK, 1.5)
	local gem: Frame = Ui.new("Frame", {
		Size = UDim2.fromScale(0.26, 0.26),
		Position = UDim2.fromScale(0.5, 0.72),
		AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundColor3 = Theme.Colors.Pink,
		BorderSizePixel = 0,
		ZIndex = 5,
		Parent = icon,
	})
	Ui.corner(gem, UDim.new(0.5, 0))
	return icon
end

local function buildChip(
	width: number,
	order: number,
	icon: (Instance, number, UDim2, Vector2) -> Frame,
	gainColor: Color3
): Chip
	local panel = Ui.panel(row, UDim2.fromOffset(width, 40), UDim2.new(), Vector2.zero)
	panel.Root.LayoutOrder = order
	Ui.corner(panel.Body, UDim.new(0.5, 0))
	Ui.corner(panel.Shadow, UDim.new(0.5, 0))
	panel.Body:SetAttribute("TouchTransparency", 0.35)
	icon(panel.Body, 26, UDim2.new(0, 10, 0.5, 0), Vector2.new(0, 0.5))
	local amount = Ui.label(
		panel.Body,
		"0",
		Theme.Fonts.Display,
		Theme.Colors.Ink,
		UDim2.new(1, -52, 1, -12),
		UDim2.new(0, 44, 0.5, 0),
		Vector2.new(0, 0.5)
	)
	amount.TextXAlignment = Enum.TextXAlignment.Left
	local gain = Ui.label(
		panel.Root,
		"",
		Theme.Fonts.Display,
		gainColor,
		UDim2.fromOffset(70, 28),
		UDim2.new(0.5, 0, 0, -4),
		Vector2.new(0.5, 1)
	)
	gain.Visible = false
	gain.ZIndex = 6
	Ui.stroke(gain, Theme.Colors.Ink, 2)
	return { Panel = panel, Amount = amount, Gain = gain, Shown = nil }
end

local function setChip(chip: Chip, value: number, sound: string)
	local previous = chip.Shown
	if previous and value > previous then
		local gain = chip.Gain
		gain.Text = `+{value - previous}`
		gain.Position = UDim2.new(0.5, 0, 0, -4)
		gain.TextTransparency = 0
		gain.Visible = true
		TweenService:Create(
			gain,
			TweenInfo.new(1.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ Position = UDim2.new(0.5, 0, 0, -34), TextTransparency = 1 }
		):Play()
		Ui.pressBounce(chip.Panel.Root)
		Sfx.Play(sound)
	end
	chip.Shown = value
	chip.Amount.Text = tostring(value)
end

local function refresh()
	local ready = ProfileClient.IsReady()
	row.Visible = ready
	notSaving.Visible = ready and not ProfileClient.IsSaving()
	if ready then
		setChip(crownChip, ProfileClient.GetCrowns(), "Crown")
		setChip(gumdropChip, ProfileClient.GetGumdrops(), "Gumdrops")
	end
end

function WalletHud.Init()
	row = Ui.new("Frame", {
		Name = "WalletRow",
		Size = UDim2.fromOffset(460, 42),
		BackgroundTransparency = 1,
		LayoutOrder = Hud.TopOrder.Wallet,
		Visible = false,
		Parent = Hud.GetTopStack(),
	})
	local layout: UIListLayout = Ui.new("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		SortOrder = Enum.SortOrder.LayoutOrder,
		Padding = UDim.new(0, 10),
		Parent = row,
	})
	-- In the top right on phones and tablets, lined up against the right edge.
	Hud.MoveRightOnTouch(row, function(onRight: boolean)
		layout.HorizontalAlignment = if onRight then Enum.HorizontalAlignment.Right else Enum.HorizontalAlignment.Left
	end)

	crownChip = buildChip(100, 1, WalletHud.CrownIcon, GOLD)
	gumdropChip = buildChip(126, 2, WalletHud.GumdropIcon, Theme.Colors.Lime)
	notSaving = Ui.new("Frame", {
		Name = "NotSaving",
		Size = UDim2.fromOffset(120, 26),
		BackgroundColor3 = Theme.Colors.Orange,
		BorderSizePixel = 0,
		LayoutOrder = 5,
		Visible = false,
		Parent = row,
	})
	Ui.corner(notSaving, UDim.new(0.5, 0))
	Ui.label(
		notSaving,
		"NOT SAVING",
		Theme.Fonts.Display,
		Theme.Colors.White,
		UDim2.new(1, -16, 1, -8),
		UDim2.fromScale(0.5, 0.5),
		Vector2.new(0.5, 0.5)
	)

	ProfileClient.Changed:Connect(refresh)
	refresh()
end

return WalletHud
