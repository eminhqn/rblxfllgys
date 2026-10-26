--!strict
-- ITEM SHOP and GET CROWNS on the right side of the screen, in the lobby, on computers and
-- controllers: Select (View) opens the item shop and LT gets Crowns, with the controller's button
-- pictures on them. ITEM SHOP has a NEW! tag until you've looked at today's shop.
--
-- On phones and tablets the bottom right is the jump buttons, so there ITEM SHOP sits with your
-- Crowns and Gumdrops in the top right instead, and GET CROWNS is the "+" on your Crowns.

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Theme = require(Shared.Theme)
local Ui = require(Shared.Ui)

local CrownStoreController = require(script.Parent.CrownStoreController)
local CustomiseController = require(script.Parent.CustomiseController)
local Input = require(script.Parent.InputController)
local KeyIcon = require(script.Parent.KeyIcon)
local MatchClient = require(script.Parent.MatchClient)
local ProfileClient = require(script.Parent.ProfileClient)
local ResponsiveScale = require(script.Parent.ResponsiveScale)
local WalletHud = require(script.Parent.WalletHud)

local ShopButtons = {}

type Button = {
	Button: TextButton,
	Label: TextLabel,
	Hint: ImageLabel,
}

local SHOP_ACTION = "WobbleOpenItemShop"
local CROWNS_ACTION = "WobbleOpenCrownStore"
local BUTTON_SIZE = Vector2.new(196, 56)
local BADGE_CHECK = 2 -- seconds between checks for a new daily shop
local WHITE = Theme.Colors.White

local localPlayer = Players.LocalPlayer
local holder: Frame
local shopButton: Button
local crownsButton: Button
local newBadge: TextLabel
local bound = false

local function setBindings(on: boolean)
	if on == bound then
		return
	end
	bound = on
	if on then
		ContextActionService:BindAction(
			SHOP_ACTION,
			function(_name: string, state: Enum.UserInputState): Enum.ContextActionResult
				if state == Enum.UserInputState.Begin then
					CustomiseController.OpenShop()
				end
				return Enum.ContextActionResult.Sink
			end,
			false,
			Enum.KeyCode.ButtonSelect
		)
		ContextActionService:BindAction(
			CROWNS_ACTION,
			function(_name: string, state: Enum.UserInputState): Enum.ContextActionResult
				if state == Enum.UserInputState.Begin then
					CrownStoreController.Open()
				end
				return Enum.ContextActionResult.Sink
			end,
			false,
			Enum.KeyCode.ButtonL2
		)
	else
		ContextActionService:UnbindAction(SHOP_ACTION)
		ContextActionService:UnbindAction(CROWNS_ACTION)
	end
end

local function refresh()
	local inLobby = ProfileClient.IsReady() and CustomiseController.CanOpen()
	local scheme = Input.GetScheme()
	holder.Visible = inLobby and scheme ~= "Touch"
	-- The controller buttons work in the lobby whatever's on screen.
	setBindings(inLobby)
	local gamepad = scheme == "Gamepad"
	for _, entry in { shopButton, crownsButton } do
		local showHint = gamepad and entry.Hint.Image ~= ""
		entry.Hint.Visible = showHint
		entry.Label.Size = if showHint then UDim2.new(1, -62, 1, -18) else UDim2.new(1, -60, 1, -18)
	end
	newBadge.Visible = CustomiseController.IsShopNew()
end

local function buildButton(
	text: string,
	color: Color3,
	keyCode: Enum.KeyCode,
	order: number,
	icon: ((Instance, number, UDim2, Vector2) -> Frame)?
): Button
	local button: TextButton = Ui.new("TextButton", {
		Name = text,
		Text = "",
		AutoButtonColor = false,
		Size = UDim2.fromOffset(BUTTON_SIZE.X, BUTTON_SIZE.Y),
		BackgroundColor3 = color,
		BorderSizePixel = 0,
		LayoutOrder = order,
		Parent = holder,
	})
	Ui.corner(button, UDim.new(0.5, 0))
	Ui.stroke(button, WHITE, 3)
	if icon then
		icon(button, 32, UDim2.new(0, 12, 0.5, 0), Vector2.new(0, 0.5))
	end
	local label = Ui.label(
		button,
		text,
		Theme.Fonts.Display,
		WHITE,
		UDim2.new(1, -60, 1, -18),
		UDim2.new(0, 50, 0.5, 0),
		Vector2.new(0, 0.5)
	)
	label.TextXAlignment = Enum.TextXAlignment.Left
	Ui.textOutline(label, Theme.Colors.Ink, 2)
	local hint = KeyIcon.new(keyCode, {
		Name = "GamepadHint",
		Size = UDim2.fromOffset(32, 32),
		Position = UDim2.new(1, -10, 0.5, 0),
		AnchorPoint = Vector2.new(1, 0.5),
		Visible = false,
		ZIndex = 4,
		Parent = button,
	})
	return { Button = button, Label = label, Hint = hint }
end

local function build()
	local gui: ScreenGui = Ui.new("ScreenGui", {
		Name = "ShopButtons",
		ResetOnSpawn = false,
		IgnoreGuiInset = false,
		DisplayOrder = 2,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		Parent = localPlayer:WaitForChild("PlayerGui"),
	})
	-- Halfway down the right edge: clear of Roblox's player list in the top right and the controls
	-- card in the bottom right.
	holder = Ui.new("Frame", {
		Name = "Shop",
		Size = UDim2.fromOffset(BUTTON_SIZE.X, BUTTON_SIZE.Y * 2 + 12),
		Position = UDim2.new(1, -16, 0.5, 0),
		AnchorPoint = Vector2.new(1, 0.5),
		BackgroundTransparency = 1,
		Visible = false,
		Parent = gui,
	}, {
		Ui.new("UIListLayout", {
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, 12),
		}),
	})
	ResponsiveScale.Attach(holder, "Hud")
	shopButton = buildButton("ITEM SHOP", Theme.Colors.Pink, Enum.KeyCode.ButtonSelect, 1, nil)
	crownsButton = buildButton("GET CROWNS", Theme.Colors.Lime, Enum.KeyCode.ButtonL2, 2, WalletHud.CrownIcon)
	-- The item shop's icon: a little shopping bag with a handle.
	local handle: Frame = Ui.new("Frame", {
		Size = UDim2.fromOffset(16, 16),
		Position = UDim2.new(0, 28, 0.5, -8),
		AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundTransparency = 1,
		Parent = shopButton.Button,
	})
	Ui.corner(handle, UDim.new(0.5, 0))
	Ui.stroke(handle, WHITE, 3)
	local bag: Frame = Ui.new("Frame", {
		Size = UDim2.fromOffset(30, 24),
		Position = UDim2.new(0, 28, 0.5, 5),
		AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundColor3 = Theme.Colors.Yellow,
		BorderSizePixel = 0,
		ZIndex = 2,
		Parent = shopButton.Button,
	})
	Ui.corner(bag, UDim.new(0, 6))
	Ui.stroke(bag, WHITE, 2)
	newBadge = Ui.label(
		shopButton.Button,
		"NEW!",
		Theme.Fonts.Display,
		Theme.Colors.Ink,
		UDim2.fromOffset(52, 22),
		UDim2.fromOffset(-8, -8),
		Vector2.zero
	)
	newBadge.BackgroundTransparency = 0
	newBadge.BackgroundColor3 = Theme.Colors.Yellow
	newBadge.Rotation = -8
	newBadge.ZIndex = 5
	Ui.corner(newBadge, UDim.new(0.5, 0))
	Ui.new("UIPadding", { PaddingTop = UDim.new(0, 3), PaddingBottom = UDim.new(0, 3), Parent = newBadge })

	shopButton.Button.Activated:Connect(function()
		Ui.pressBounce(shopButton.Button)
		CustomiseController.OpenShop()
	end)
	crownsButton.Button.Activated:Connect(function()
		Ui.pressBounce(crownsButton.Button)
		CrownStoreController.Open()
	end)
end

function ShopButtons.Init()
	build()
	ProfileClient.Changed:Connect(refresh)
	MatchClient.LocalChanged:Connect(refresh)
	Input.SchemeChanged:Connect(refresh)
	refresh()
	task.spawn(function()
		while true do
			task.wait(BADGE_CHECK)
			refresh()
		end
	end)
end

return ShopButtons
