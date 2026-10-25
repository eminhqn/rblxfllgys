--!strict
-- Pictures of controller buttons (UserInputService:GetImageForKeyCode) with a black outline round
-- them. Roblox's button pictures are mostly white, which disappears against light panels, so every
-- button hint in the game is drawn with this.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Ui = require(ReplicatedStorage.Shared.Ui)

local KeyIcon = {}

local OUTLINE_COLOR = Color3.fromRGB(0, 0, 0)
local OUTLINE_WIDTH = 2 -- pixels
local DIRECTIONS = {
	Vector2.new(-1, 0),
	Vector2.new(1, 0),
	Vector2.new(0, -1),
	Vector2.new(0, 1),
	Vector2.new(-0.7, -0.7),
	Vector2.new(0.7, -0.7),
	Vector2.new(-0.7, 0.7),
	Vector2.new(0.7, 0.7),
}

-- Makes the picture for `keyCode` from `props` (Size, Position, Parent, Visible, ZIndex and so
-- on). Use the returned ImageLabel like any other: its own copy of the picture is hidden and the
-- outline and picture sit inside it. Its Image is "" when the platform has no picture for that
-- button, so callers can fall back to text.
function KeyIcon.new(keyCode: Enum.KeyCode, props: { [string]: any }): ImageLabel
	local image = UserInputService:GetImageForKeyCode(keyCode)
	local holder: ImageLabel = Ui.new("ImageLabel", props)
	holder.Name = props.Name or "KeyIcon"
	holder.Image = image
	holder.ImageTransparency = 1
	holder.BackgroundTransparency = 1
	if image == "" then
		return holder
	end
	-- Black copies nudged out in every direction make the outline; the real picture goes on top.
	for _, direction in DIRECTIONS do
		Ui.new("ImageLabel", {
			Name = "Outline",
			Image = image,
			ImageColor3 = OUTLINE_COLOR,
			Size = UDim2.fromScale(1, 1),
			Position = UDim2.fromOffset(direction.X * OUTLINE_WIDTH, direction.Y * OUTLINE_WIDTH),
			BackgroundTransparency = 1,
			ZIndex = holder.ZIndex,
			Parent = holder,
		})
	end
	Ui.new("ImageLabel", {
		Name = "Picture",
		Image = image,
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		ZIndex = holder.ZIndex + 1,
		Parent = holder,
	})
	return holder
end

return KeyIcon
