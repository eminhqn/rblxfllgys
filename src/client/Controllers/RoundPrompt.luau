--!strict
-- A button prompt low in the middle of the screen, for things a round wants you to press. The
-- server sets your RoundPrompt attribute (Shared/Match) and this shows what it means, with the
-- button for your controls (keyboard, controller or touch):
--   * Tug of Wobble: GRAB THE ROPE next to it, then MASH JUMP to pull (it bounces with each tug)
--   * Egg Scramble: carrying an egg, take it up to your nest (or DIVE to throw it)

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Match = require(Shared.Match)
local Theme = require(Shared.Theme)
local Ui = require(Shared.Ui)

local ClientEvents = require(script.Parent.ClientEvents)
local Input = require(script.Parent.InputController)
local ResponsiveScale = require(script.Parent.ResponsiveScale)

local RoundPrompt = {}

type Keys = { KeyboardMouse: string, Gamepad: string, Touch: string }
type Prompt = { Text: string, Keys: Keys, Color: Color3 }

local PROMPTS: { [string]: Prompt } = {
	GrabRope = {
		Text = "GRAB THE ROPE!",
		Keys = { KeyboardMouse = "HOLD SHIFT", Gamepad = "HOLD LT", Touch = "HOLD GRAB" },
		Color = Theme.Colors.Aqua,
	},
	Pull = {
		Text = "PULL! (GRAB AGAIN TO LET GO)",
		Keys = { KeyboardMouse = "MASH SPACE", Gamepad = "MASH A", Touch = "MASH JUMP" },
		Color = Theme.Colors.Pink,
	},
	CarryEgg = {
		Text = "TAKE IT UP TO YOUR NEST!",
		Keys = { KeyboardMouse = "CTRL TO THROW", Gamepad = "X TO THROW", Touch = "DIVE TO THROW" },
		Color = Theme.Colors.Orange,
	},
}

local localPlayer = Players.LocalPlayer

local gui: ScreenGui
local card: Frame
local keyPill: Frame
local keyLabel: TextLabel
local textLabel: TextLabel
local shownId: string? = nil

local function refresh()
	local value = localPlayer:GetAttribute(Match.PlayerAttr.RoundPrompt)
	local id = if typeof(value) == "string" then value else nil
	local prompt = if id then PROMPTS[id] else nil
	gui.Enabled = prompt ~= nil
	if not prompt then
		shownId = nil
		return
	end
	local scheme = Input.GetScheme()
	keyLabel.Text = if scheme == "Gamepad"
		then prompt.Keys.Gamepad
		elseif scheme == "Touch" then prompt.Keys.Touch
		else prompt.Keys.KeyboardMouse
	keyPill.BackgroundColor3 = prompt.Color
	textLabel.Text = prompt.Text
	if id ~= shownId then
		shownId = id
		Ui.popIn(card)
	end
end

local function build()
	gui = Ui.new("ScreenGui", {
		Name = "RoundPrompt",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		DisplayOrder = 6,
		Enabled = false,
		Parent = localPlayer:WaitForChild("PlayerGui"),
	})
	local holder: Frame = Ui.new("Frame", {
		Size = UDim2.fromOffset(420, 92),
		Position = UDim2.fromScale(0.5, 0.72),
		AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundTransparency = 1,
		Parent = gui,
	})
	ResponsiveScale.Attach(holder, "Hud")
	card = Ui.new("Frame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Parent = holder,
	})
	keyPill = Ui.new("Frame", {
		Size = UDim2.fromOffset(230, 46),
		Position = UDim2.fromScale(0.5, 0),
		AnchorPoint = Vector2.new(0.5, 0),
		BackgroundColor3 = Theme.Colors.Pink,
		BorderSizePixel = 0,
		Parent = card,
	})
	Ui.corner(keyPill, UDim.new(0.5, 0))
	Ui.stroke(keyPill, Theme.Colors.White, 3)
	keyLabel = Ui.label(
		keyPill,
		"",
		Theme.Fonts.Display,
		Theme.Colors.White,
		UDim2.new(1, -24, 1, -12),
		UDim2.fromScale(0.5, 0.5),
		Vector2.new(0.5, 0.5)
	)
	Ui.textOutline(keyLabel, Theme.Colors.Ink, 1.5)
	textLabel = Ui.label(
		card,
		"",
		Theme.Fonts.Display,
		Theme.Colors.White,
		UDim2.new(1, 0, 0, 34),
		UDim2.new(0.5, 0, 0, 54),
		Vector2.new(0.5, 0)
	)
	Ui.stroke(textLabel, Theme.Colors.Ink, 3)
end

function RoundPrompt.Init()
	build()
	localPlayer:GetAttributeChangedSignal(Match.PlayerAttr.RoundPrompt):Connect(refresh)
	Input.SchemeChanged:Connect(refresh)
	ClientEvents.Pulled:Connect(function()
		if gui.Enabled then
			Ui.pressBounce(keyPill)
		end
	end)
	refresh()
end

return RoundPrompt
