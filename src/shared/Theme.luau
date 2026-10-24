--!strict
-- Visual language for all UI (screen GUIs and in-world signs): bright candy colours,
-- rounded corners, soft shadows and a bold friendly font.

local Theme = {}

Theme.Colors = table.freeze({
	Pink = Color3.fromRGB(255, 77, 166),
	Aqua = Color3.fromRGB(40, 210, 222),
	Purple = Color3.fromRGB(124, 92, 255),
	Yellow = Color3.fromRGB(255, 204, 51),
	Lime = Color3.fromRGB(120, 220, 80),
	Orange = Color3.fromRGB(255, 140, 66),
	Ink = Color3.fromRGB(45, 32, 84), -- main text colour on light panels
	InkSoft = Color3.fromRGB(110, 98, 150),
	White = Color3.fromRGB(255, 255, 255),
	Panel = Color3.fromRGB(255, 255, 255),
	PanelTint = Color3.fromRGB(246, 240, 255),
	Shadow = Color3.fromRGB(40, 16, 80),
})

Theme.Fonts = table.freeze({
	Display = Font.fromEnum(Enum.Font.FredokaOne),
	Body = Font.fromEnum(Enum.Font.BuilderSansBold),
})

Theme.CornerRadius = UDim.new(0, 18)
Theme.ShadowOffset = 6
Theme.ShadowTransparency = 0.78

Theme.Tweens = table.freeze({
	Fast = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
	Smooth = TweenInfo.new(0.35, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
	Pop = TweenInfo.new(0.42, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
	Bounce = TweenInfo.new(0.6, Enum.EasingStyle.Elastic, Enum.EasingDirection.Out),
})

return table.freeze(Theme)
