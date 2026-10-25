--!strict
-- The "updating" screen. It's shown in the temporary holding server while an update rolls out
-- (see the server's SoftShutdown), and on the way out whenever this game teleports you between
-- servers (TeleportService:SetTeleportGui), so moving to the new version looks like part of the
-- game rather than a disconnect.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TeleportService = game:GetService("TeleportService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage.Shared
local Theme = require(Shared.Theme)
local Ui = require(Shared.Ui)

local UpdatingScreen = {}

local function build(): ScreenGui
	local gui: ScreenGui = Ui.new("ScreenGui", {
		Name = "Updating",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		DisplayOrder = 100,
	})
	local background: Frame = Ui.new("Frame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Theme.Colors.White,
		BorderSizePixel = 0,
		Parent = gui,
	})
	Ui.new("UIGradient", {
		Color = ColorSequence.new(Theme.Colors.Pink, Theme.Colors.Purple),
		Rotation = 90,
		Parent = background,
	})
	local title = Ui.label(
		background,
		"WOBBLE RUSH",
		Theme.Fonts.Display,
		Theme.Colors.White,
		UDim2.fromScale(0.6, 0.12),
		UDim2.fromScale(0.5, 0.38),
		Vector2.new(0.5, 0.5)
	)
	Ui.stroke(title, Theme.Colors.Ink, 4, 0.3)
	local message = Ui.label(
		background,
		"Updating to the newest version. You'll be back in a moment!",
		Theme.Fonts.Body,
		Theme.Colors.White,
		UDim2.fromScale(0.7, 0.05),
		UDim2.fromScale(0.5, 0.5),
		Vector2.new(0.5, 0.5)
	)
	Ui.stroke(message, Theme.Colors.Ink, 2, 0.4)
	-- Three bouncing candy dots.
	local colors = { Theme.Colors.Yellow, Theme.Colors.Aqua, Theme.Colors.Lime }
	for index, color in colors do
		local x = 0.5 + (index - 2) * 0.04
		local dot: Frame = Ui.new("Frame", {
			Size = UDim2.fromOffset(26, 26),
			Position = UDim2.fromScale(x, 0.62),
			AnchorPoint = Vector2.new(0.5, 0.5),
			BackgroundColor3 = color,
			BorderSizePixel = 0,
			Parent = background,
		})
		Ui.corner(dot, UDim.new(0.5, 0))
		Ui.stroke(dot, Theme.Colors.White, 3)
		local bounce = TweenService:Create(
			dot,
			TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, -1, true, (index - 1) * 0.15),
			{ Position = UDim2.fromScale(x, 0.59) }
		)
		bounce:Play()
	end
	return gui
end

-- In the holding server: put the screen up until the teleport onwards takes us away.
function UpdatingScreen.ShowHolding()
	build().Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
end

-- Shown while being teleported out of this game (only an update does that).
function UpdatingScreen.UseForTeleports()
	pcall(function()
		TeleportService:SetTeleportGui(build())
	end)
end

return UpdatingScreen
