--!strict
-- Lobby HUD: the Wobble Rush badge, your team chip and a controls card that matches whatever
-- device you're using (keyboard or gamepad; touch players get on-screen buttons instead).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage.Shared
local Teams = require(Shared.Teams)
local Theme = require(Shared.Theme)
local Ui = require(Shared.Ui)

local Input = require(script.Parent.InputController)
local ResponsiveScale = require(script.Parent.ResponsiveScale)

local Hud = {}

local HINT_VISIBLE_SECONDS = 25

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
	}
end

local function buildTopBadge(gui: ScreenGui)
	local top: Frame = Ui.new("Frame", {
		Name = "Top",
		Size = UDim2.fromOffset(320, 110),
		Position = UDim2.new(0.5, 0, 0, 8),
		AnchorPoint = Vector2.new(0.5, 0),
		BackgroundTransparency = 1,
		Parent = gui,
	})
	ResponsiveScale.Attach(top, "Hud")

	local title = Ui.panel(top, UDim2.fromOffset(300, 58), UDim2.fromScale(0.5, 0), Vector2.new(0.5, 0))
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

	local chip = Ui.panel(top, UDim2.fromOffset(190, 38), UDim2.new(0.5, 0, 0, 68), Vector2.new(0.5, 0))
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
end

local function buildControlsHint(gui: ScreenGui)
	local holder: Frame = Ui.new("Frame", {
		Name = "ControlsHint",
		Size = UDim2.fromOffset(250, 196),
		Position = UDim2.new(0, 16, 1, -16),
		AnchorPoint = Vector2.new(0, 1),
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

	local fadeToken = 0
	local function show(scheme: Input.Scheme)
		fadeToken += 1
		local token = fadeToken
		holder.Visible = scheme ~= "Touch"
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
				Size = UDim2.fromOffset(84, 32),
				BackgroundColor3 = Theme.Colors.PanelTint,
				BorderSizePixel = 0,
				ZIndex = 3,
				Parent = rowFrame,
			})
			Ui.corner(chip, UDim.new(0, 10))
			Ui.stroke(chip, Theme.Colors.Purple, 2, 0.4)
			local image = if row.KeyCode then UserInputService:GetImageForKeyCode(row.KeyCode) else ""
			if image ~= "" then
				Ui.new("ImageLabel", {
					Image = image,
					Size = UDim2.fromOffset(26, 26),
					Position = UDim2.fromScale(0.5, 0.5),
					AnchorPoint = Vector2.new(0.5, 0.5),
					BackgroundTransparency = 1,
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
				UDim2.new(1, -96, 0, 22),
				UDim2.new(0, 96, 0.5, 0),
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
	show(Input.GetScheme())
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
	buildTopBadge(gui)
	buildControlsHint(gui)
end

return Hud
