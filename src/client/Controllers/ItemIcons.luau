--!strict
-- Pictures of the items (Shared/Items), drawn with frames: a coloured disc with a white picture
-- on it. Used by the ITEMS window and the round picker.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Items = require(Shared.Items)
local Theme = require(Shared.Theme)
local Ui = require(Shared.Ui)

local ItemIcons = {}

local WHITE = Theme.Colors.White

local function bar(parent: Instance, size: UDim2, position: UDim2, rotation: number, color: Color3?): Frame
	local frame: Frame = Ui.new("Frame", {
		Size = size,
		Position = position,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Rotation = rotation,
		BackgroundColor3 = color or WHITE,
		BorderSizePixel = 0,
		ZIndex = 6,
		Parent = parent,
	})
	Ui.corner(frame, UDim.new(0.5, 0))
	return frame
end

local function glyph(parent: Instance, text: string)
	local label = Ui.label(
		parent,
		text,
		Theme.Fonts.Display,
		WHITE,
		UDim2.fromScale(0.72, 0.5),
		UDim2.fromScale(0.5, 0.5),
		Vector2.new(0.5, 0.5)
	)
	label.ZIndex = 6
	Ui.textOutline(label, Theme.Colors.Ink, 1.5)
end

-- A coloured disc (60 x 60) with a white picture of the item on it.
function ItemIcons.Draw(parent: Instance, def: Items.Def, position: UDim2, anchorPoint: Vector2): Frame
	local disc: Frame = Ui.new("Frame", {
		Name = "Icon",
		Size = UDim2.fromOffset(60, 60),
		Position = position,
		AnchorPoint = anchorPoint,
		BackgroundColor3 = def.Color,
		BorderSizePixel = 0,
		ZIndex = 5,
		Parent = parent,
	})
	Ui.corner(disc, UDim.new(0.5, 0))
	Ui.stroke(disc, WHITE, 3)
	local id = def.Id
	if id == "Slap" then
		-- An open hand: palm, four fingers and a thumb.
		local palm = bar(disc, UDim2.fromOffset(22, 20), UDim2.fromOffset(31, 36), -12)
		Ui.corner(palm, UDim.new(0, 6))
		for index = 0, 3 do
			bar(disc, UDim2.fromOffset(6, 16), UDim2.fromOffset(21 + index * 6, 22 - (index % 3 == 0 and 0 or 2)), -12)
		end
		bar(disc, UDim2.fromOffset(6, 13), UDim2.fromOffset(43, 34), 40)
	elseif id == "Respawn" then
		glyph(disc, "1UP")
	elseif id == "Speed" then
		-- A ball racing along with speed lines behind it.
		local ball = bar(disc, UDim2.fromOffset(18, 18), UDim2.fromOffset(38, 30), 0)
		ball.ZIndex = 7
		for index = -1, 1 do
			bar(disc, UDim2.fromOffset(18 - math.abs(index) * 5, 4), UDim2.fromOffset(19, 30 + index * 7), 0)
		end
	elseif id == "Jump" then
		-- An arrow pointing up.
		bar(disc, UDim2.fromOffset(6, 26), UDim2.fromOffset(30, 34), 0)
		bar(disc, UDim2.fromOffset(6, 18), UDim2.fromOffset(25, 22), -45)
		bar(disc, UDim2.fromOffset(6, 18), UDim2.fromOffset(35, 22), 45)
	elseif id == "DoubleJump" then
		-- Two arrowheads, one above the other.
		for _, y in { 22, 38 } do
			bar(disc, UDim2.fromOffset(6, 18), UDim2.fromOffset(25, y), -45)
			bar(disc, UDim2.fromOffset(6, 18), UDim2.fromOffset(35, y), 45)
		end
	elseif id == "Slide" then
		-- A Bloblet on its belly, sliding.
		bar(disc, UDim2.fromOffset(28, 13), UDim2.fromOffset(36, 34), -6)
		bar(disc, UDim2.fromOffset(12, 4), UDim2.fromOffset(15, 30), 0)
		bar(disc, UDim2.fromOffset(9, 4), UDim2.fromOffset(17, 38), 0)
	elseif id == "Shield" then
		local bubble = bar(disc, UDim2.fromOffset(36, 36), UDim2.fromScale(0.5, 0.5), 0)
		bubble.BackgroundTransparency = 0.6
		Ui.stroke(bubble, WHITE, 3)
		bar(disc, UDim2.fromOffset(8, 8), UDim2.fromOffset(22, 22), 0).ZIndex = 7
	else
		glyph(disc, "2X")
	end
	return disc
end

return ItemIcons
