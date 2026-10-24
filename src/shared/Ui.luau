--!strict
-- Tiny helpers for building rounded, shadowed, tweened UI in code. Used for ScreenGuis on the
-- client and SurfaceGuis (signs, the lobby screen) on the server.

local TweenService = game:GetService("TweenService")

local Theme = require(script.Parent.Theme)

local Ui = {}

-- Creates an instance, assigns properties (Parent last) and parents any children to it.
function Ui.new(className: string, props: { [string]: any }?, children: { Instance }?): any
	local instance: any = Instance.new(className)
	local parent: Instance? = nil
	if props then
		for key, value in props do
			if key == "Parent" then
				parent = value
			else
				instance[key] = value
			end
		end
	end
	if children then
		for _, child in children do
			child.Parent = instance
		end
	end
	if parent then
		instance.Parent = parent
	end
	return instance
end

function Ui.corner(parent: Instance, radius: UDim?): UICorner
	local corner = Instance.new("UICorner")
	corner.CornerRadius = radius or Theme.CornerRadius
	corner.Parent = parent
	return corner
end

function Ui.stroke(parent: Instance, color: Color3, thickness: number, transparency: number?): UIStroke
	local stroke = Instance.new("UIStroke")
	stroke.Color = color
	stroke.Thickness = thickness
	stroke.Transparency = transparency or 0
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = parent
	return stroke
end

function Ui.padding(parent: Instance, pixels: number): UIPadding
	local padding = Instance.new("UIPadding")
	local offset = UDim.new(0, pixels)
	padding.PaddingTop = offset
	padding.PaddingBottom = offset
	padding.PaddingLeft = offset
	padding.PaddingRight = offset
	padding.Parent = parent
	return padding
end

export type Panel = {
	Root: Frame, -- position/size this
	Shadow: Frame,
	Body: Frame, -- put content in this
}

-- A rounded panel with a soft drop shadow underneath.
function Ui.panel(parent: Instance, size: UDim2, position: UDim2, anchorPoint: Vector2, color: Color3?): Panel
	local root: Frame = Ui.new("Frame", {
		Name = "Panel",
		Size = size,
		Position = position,
		AnchorPoint = anchorPoint,
		BackgroundTransparency = 1,
		Parent = parent,
	})
	local shadow: Frame = Ui.new("Frame", {
		Name = "Shadow",
		Size = UDim2.fromScale(1, 1),
		Position = UDim2.fromOffset(0, Theme.ShadowOffset),
		BackgroundColor3 = Theme.Colors.Shadow,
		BackgroundTransparency = Theme.ShadowTransparency,
		BorderSizePixel = 0,
		ZIndex = 1,
		Parent = root,
	})
	Ui.corner(shadow)
	local body: Frame = Ui.new("Frame", {
		Name = "Body",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = color or Theme.Colors.Panel,
		BorderSizePixel = 0,
		ZIndex = 2,
		Parent = root,
	})
	Ui.corner(body)
	return { Root = root, Shadow = shadow, Body = body }
end

function Ui.label(
	parent: Instance,
	text: string,
	font: Font,
	color: Color3,
	size: UDim2,
	position: UDim2?,
	anchorPoint: Vector2?
): TextLabel
	return Ui.new("TextLabel", {
		Name = "Label",
		Text = text,
		FontFace = font,
		TextColor3 = color,
		TextScaled = true,
		BackgroundTransparency = 1,
		Size = size,
		Position = position or UDim2.new(),
		AnchorPoint = anchorPoint or Vector2.zero,
		ZIndex = 3,
		Parent = parent,
	})
end

function Ui.tween(instance: Instance, info: TweenInfo, goals: { [string]: any }): Tween
	local tween = TweenService:Create(instance, info, goals)
	tween:Play()
	return tween
end

-- Returns (creating if needed) a UIScale child, used for pop/press animations.
function Ui.scaleOf(guiObject: GuiObject): UIScale
	local existing = guiObject:FindFirstChildOfClass("UIScale")
	if existing then
		return existing
	end
	local scale = Instance.new("UIScale")
	scale.Parent = guiObject
	return scale
end

-- Springs a GUI object in from nothing.
function Ui.popIn(guiObject: GuiObject, delaySeconds: number?)
	local scale = Ui.scaleOf(guiObject)
	scale.Scale = 0
	task.delay(delaySeconds or 0, function()
		Ui.tween(scale, Theme.Tweens.Pop, { Scale = 1 })
	end)
end

-- Quick squash used when a button is pressed.
function Ui.pressBounce(guiObject: GuiObject)
	local scale = Ui.scaleOf(guiObject)
	scale.Scale = 0.88
	Ui.tween(scale, Theme.Tweens.Pop, { Scale = 1 })
end

return Ui
