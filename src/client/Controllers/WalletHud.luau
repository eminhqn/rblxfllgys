--!strict
-- A row in the top stack with your Gumdrops (the soft currency). When you earn some, the chip
-- bounces and a "+15" floats up beside it. If the server couldn't load your saved data, a small
-- NOT SAVING pill says so. The customise screen adds its button to this row.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage.Shared
local Theme = require(Shared.Theme)
local Ui = require(Shared.Ui)

local Hud = require(script.Parent.Hud)
local ProfileClient = require(script.Parent.ProfileClient)
local Sfx = require(script.Parent.Sfx)

local WalletHud = {}

local GUMDROP_COLOR = Color3.fromRGB(255, 92, 168)

local row: Frame
local chip: Ui.Panel
local amountLabel: TextLabel
local gainLabel: TextLabel
local notSaving: Frame
local shownCoins: number? = nil

-- The row other lobby buttons go in (after WalletHud.Init).
function WalletHud.GetRow(): Frame
	return row
end

-- A little round gumdrop with a shine, drawn with frames.
local function gumdropIcon(parent: Instance, size: number, position: UDim2, anchor: Vector2): Frame
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

WalletHud.GumdropIcon = gumdropIcon

local function showGain(amount: number)
	gainLabel.Text = `+{amount}`
	gainLabel.Position = UDim2.new(1, 8, 0.5, 0)
	gainLabel.TextTransparency = 0
	gainLabel.Visible = true
	local rise = TweenService:Create(
		gainLabel,
		TweenInfo.new(1.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Position = UDim2.new(1, 8, 0.5, -34), TextTransparency = 1 }
	)
	rise:Play()
	Ui.pressBounce(chip.Root)
	Sfx.Play("Coins")
end

local function refresh()
	local ready = ProfileClient.IsReady()
	row.Visible = ready
	notSaving.Visible = ready and not ProfileClient.IsSaving()
	if not ready then
		return
	end
	local coins = ProfileClient.GetCoins()
	local previous = shownCoins
	if previous and coins > previous then
		showGain(coins - previous)
	end
	shownCoins = coins
	amountLabel.Text = tostring(coins)
end

function WalletHud.Init()
	row = Ui.new("Frame", {
		Name = "WalletRow",
		Size = UDim2.fromOffset(460, 42),
		BackgroundTransparency = 1,
		LayoutOrder = Hud.TopOrder.Wallet,
		Visible = false,
		Parent = Hud.GetTopStack(),
	}, {
		Ui.new("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, 10),
		}),
	})

	chip = Ui.panel(row, UDim2.fromOffset(150, 40), UDim2.new(), Vector2.zero)
	chip.Root.LayoutOrder = 1
	Ui.corner(chip.Body, UDim.new(0.5, 0))
	Ui.corner(chip.Shadow, UDim.new(0.5, 0))
	chip.Body:SetAttribute("TouchTransparency", 0.35)
	gumdropIcon(chip.Body, 26, UDim2.new(0, 10, 0.5, 0), Vector2.new(0, 0.5))
	amountLabel = Ui.label(
		chip.Body,
		"0",
		Theme.Fonts.Display,
		Theme.Colors.Ink,
		UDim2.new(1, -52, 1, -12),
		UDim2.new(0, 44, 0.5, 0),
		Vector2.new(0, 0.5)
	)
	amountLabel.TextXAlignment = Enum.TextXAlignment.Left
	gainLabel = Ui.label(
		chip.Root,
		"",
		Theme.Fonts.Display,
		Theme.Colors.Lime,
		UDim2.fromOffset(80, 30),
		UDim2.new(1, 8, 0.5, 0),
		Vector2.new(0, 0.5)
	)
	gainLabel.TextXAlignment = Enum.TextXAlignment.Left
	gainLabel.Visible = false
	gainLabel.ZIndex = 6
	Ui.stroke(gainLabel, Theme.Colors.Ink, 2)

	notSaving = Ui.new("Frame", {
		Name = "NotSaving",
		Size = UDim2.fromOffset(120, 26),
		BackgroundColor3 = Theme.Colors.Orange,
		BorderSizePixel = 0,
		LayoutOrder = 3,
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
