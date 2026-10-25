--!strict
-- On-screen controls for phones and tablets: a floating thumbstick on the left half of the screen
-- and big round Jump / Dive / Grab / Kick buttons on the right, plus a small Emote button. Shown
-- only while the player is using touch.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage.Shared
local Signal = require(Shared.Signal)
local Theme = require(Shared.Theme)
local Ui = require(Shared.Ui)

local ClientEvents = require(script.Parent.ClientEvents)
local Input = require(script.Parent.InputController)
local ResponsiveScale = require(script.Parent.ResponsiveScale)

local TouchControls = {}

local STICK_RADIUS = 60

local gui: ScreenGui? = nil
local stickBase: Frame? = nil
local stickKnob: Frame? = nil
local stickScale: UIScale? = nil
local activeStickInput: InputObject? = nil
local stickOrigin = Vector2.zero
local releaseCallbacks: { [InputObject]: () -> () } = {}

local function resetStick()
	activeStickInput = nil
	Input.SetTouchMove(Vector2.zero)
	if stickBase then
		stickBase.Visible = false
	end
	if stickKnob then
		stickKnob.Position = UDim2.fromScale(0.5, 0.5)
	end
end

local function releaseAll()
	for input, release in releaseCallbacks do
		releaseCallbacks[input] = nil
		release()
	end
	resetStick()
end

local function circle(parent: Instance, name: string, size: number, color: Color3, transparency: number): Frame
	local frame: Frame = Ui.new("Frame", {
		Name = name,
		Size = UDim2.fromOffset(size, size),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		BackgroundColor3 = color,
		BackgroundTransparency = transparency,
		BorderSizePixel = 0,
		Parent = parent,
	})
	Ui.corner(frame, UDim.new(0.5, 0))
	return frame
end

local function makeButton(
	parent: Instance,
	name: string,
	text: string,
	color: Color3,
	size: number,
	position: UDim2
): (Frame, TextButton)
	local holder: Frame = Ui.new("Frame", {
		Name = name,
		Size = UDim2.fromOffset(size, size),
		Position = position,
		AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundTransparency = 1,
		Parent = parent,
	})
	local shadow = circle(holder, "Shadow", size, Theme.Colors.Shadow, Theme.ShadowTransparency)
	shadow.Position = UDim2.new(0.5, 0, 0.5, Theme.ShadowOffset)
	local face: TextButton = Ui.new("TextButton", {
		Name = "Face",
		Text = "",
		AutoButtonColor = false,
		Size = UDim2.fromScale(1, 1),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		BackgroundColor3 = color,
		BorderSizePixel = 0,
		ZIndex = 2,
		Parent = holder,
	})
	Ui.corner(face, UDim.new(0.5, 0))
	Ui.stroke(face, Theme.Colors.White, 3)
	Ui.label(
		face,
		text,
		Theme.Fonts.Display,
		Theme.Colors.White,
		UDim2.fromScale(0.7, 0.34),
		UDim2.fromScale(0.5, 0.5),
		Vector2.new(0.5, 0.5)
	)
	return holder, face
end

-- A dark disc that shrinks away while a move is cooling down.
local function addCooldownDisc(face: GuiButton, started: Signal.Signal<number>)
	local cooldown: Frame = Ui.new("Frame", {
		Name = "Cooldown",
		Size = UDim2.fromScale(1, 1),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		BackgroundColor3 = Theme.Colors.Ink,
		BackgroundTransparency = 0.45,
		BorderSizePixel = 0,
		Visible = false,
		ZIndex = 4,
		Parent = face,
	})
	Ui.corner(cooldown, UDim.new(0.5, 0))
	started:Connect(function(duration: number)
		cooldown.Size = UDim2.fromScale(1, 1)
		cooldown.Visible = true
		local tween = TweenService:Create(
			cooldown,
			TweenInfo.new(duration, Enum.EasingStyle.Linear),
			{ Size = UDim2.fromScale(0, 0) }
		)
		tween.Completed:Once(function(state: Enum.PlaybackState)
			if state == Enum.PlaybackState.Completed then
				cooldown.Visible = false
			end
		end)
		tween:Play()
	end)
end

local function bindPress(face: GuiButton, onPress: () -> (), onRelease: (() -> ())?)
	face.InputBegan:Connect(function(input: InputObject)
		local inputType = input.UserInputType
		if inputType ~= Enum.UserInputType.Touch and inputType ~= Enum.UserInputType.MouseButton1 then
			return
		end
		if input.UserInputState ~= Enum.UserInputState.Begin then
			return
		end
		Ui.pressBounce(face)
		onPress()
		if onRelease then
			releaseCallbacks[input] = onRelease
		end
	end)
end

local function buildStick(root: ScreenGui)
	local zone: Frame = Ui.new("Frame", {
		Name = "StickZone",
		Size = UDim2.fromScale(0.45, 0.65),
		Position = UDim2.fromScale(0, 1),
		AnchorPoint = Vector2.new(0, 1),
		BackgroundTransparency = 1,
		Active = true, -- swallow the touch so the camera doesn't rotate
		Parent = root,
	})
	local base = circle(root, "StickBase", STICK_RADIUS * 2, Theme.Colors.White, 0.55)
	base.Visible = false
	Ui.stroke(base, Theme.Colors.White, 3, 0.2)
	local knob = circle(base, "Knob", 64, Theme.Colors.White, 0.05)
	Ui.stroke(knob, Theme.Colors.Purple, 3)
	stickBase = base
	stickKnob = knob
	stickScale = ResponsiveScale.Attach(base, "Touch")

	zone.InputBegan:Connect(function(input: InputObject)
		if input.UserInputType ~= Enum.UserInputType.Touch or activeStickInput then
			return
		end
		activeStickInput = input
		stickOrigin = Vector2.new(input.Position.X, input.Position.Y)
		local origin = stickOrigin - root.AbsolutePosition
		base.Position = UDim2.fromOffset(origin.X, origin.Y)
		base.Visible = true
	end)
end

local function updateVisibility()
	local root = gui
	if not root then
		return
	end
	local visible = Input.GetScheme() == "Touch" and Input.IsEnabled()
	if root.Enabled and not visible then
		releaseAll()
	end
	root.Enabled = visible
end

function TouchControls.Init()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	local root: ScreenGui = Ui.new("ScreenGui", {
		Name = "TouchControls",
		ResetOnSpawn = false,
		IgnoreGuiInset = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		DisplayOrder = 5,
		Enabled = false,
		Parent = playerGui,
	})
	gui = root
	buildStick(root)

	local cluster: Frame = Ui.new("Frame", {
		Name = "Buttons",
		Size = UDim2.fromOffset(270, 270),
		Position = UDim2.new(1, -16, 1, -16),
		AnchorPoint = Vector2.new(1, 1),
		BackgroundTransparency = 1,
		Parent = root,
	})
	ResponsiveScale.Attach(cluster, "Touch")

	local _, jumpFace = makeButton(cluster, "Jump", "JUMP", Theme.Colors.Yellow, 112, UDim2.fromScale(0.7, 0.7))
	bindPress(jumpFace, function()
		Input.PressJump("TouchJump")
	end, function()
		Input.ReleaseJump("TouchJump")
	end)

	local _, diveFace = makeButton(cluster, "Dive", "DIVE", Theme.Colors.Pink, 84, UDim2.fromScale(0.2, 0.78))
	bindPress(diveFace, function()
		Input.PressDive()
	end)

	local _, grabFace = makeButton(cluster, "Grab", "GRAB", Theme.Colors.Aqua, 84, UDim2.fromScale(0.72, 0.2))
	bindPress(grabFace, function()
		Input.SetGrab("TouchGrab", true)
	end, function()
		Input.SetGrab("TouchGrab", false)
	end)

	local _, kickFace = makeButton(cluster, "Kick", "KICK", Theme.Colors.Orange, 84, UDim2.fromScale(0.22, 0.3))
	bindPress(kickFace, function()
		Input.PressKick()
	end)

	local _, emoteFace = makeButton(cluster, "Emote", "EMOTE", Theme.Colors.Purple, 60, UDim2.fromScale(0.47, 0.47))
	bindPress(emoteFace, function()
		Input.PressEmote()
	end)

	addCooldownDisc(diveFace, ClientEvents.DiveCooldownStarted)
	addCooldownDisc(kickFace, ClientEvents.KickCooldownStarted)

	UserInputService.InputChanged:Connect(function(input: InputObject)
		if input ~= activeStickInput then
			return
		end
		local scale = if stickScale then stickScale.Scale else 1
		local radius = STICK_RADIUS * scale
		local delta = Vector2.new(input.Position.X, input.Position.Y) - stickOrigin
		if delta.Magnitude > radius then
			delta = delta.Unit * radius
		end
		if stickKnob then
			stickKnob.Position = UDim2.new(0.5, delta.X / scale, 0.5, delta.Y / scale)
		end
		-- Screen Y grows downwards; pushing the stick up means "forward".
		Input.SetTouchMove(Vector2.new(delta.X / radius, -delta.Y / radius))
	end)

	UserInputService.InputEnded:Connect(function(input: InputObject)
		if input == activeStickInput then
			resetStick()
		end
		local release = releaseCallbacks[input]
		if release then
			releaseCallbacks[input] = nil
			release()
		end
	end)

	Input.SchemeChanged:Connect(updateVisibility)
	Input.EnabledChanged:Connect(updateVisibility)
	updateVisibility()
end

return TouchControls
