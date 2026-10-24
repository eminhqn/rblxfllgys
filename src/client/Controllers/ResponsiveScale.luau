--!strict
-- Scales UI containers with the screen so the same layout works on phones, tablets, PCs and TVs.
-- Each container gets a UIScale that is updated whenever the viewport changes size.

local GuiService = game:GetService("GuiService")
local Workspace = game:GetService("Workspace")

export type Profile = "Hud" | "Touch"

type ProfileDef = {
	BaseWidth: number,
	BaseHeight: number,
	Min: number,
	Max: number,
}

local PROFILES: { [Profile]: ProfileDef } = {
	Hud = { BaseWidth = 1280, BaseHeight = 720, Min = 0.6, Max = 1.4 },
	Touch = { BaseWidth = 1000, BaseHeight = 500, Min = 0.75, Max = 1.3 },
}

local TEN_FOOT_BOOST = 1.2 -- TVs are viewed from the couch

local ResponsiveScale = {}

local tracked: { [UIScale]: Profile } = {}
local viewportConnection: RBXScriptConnection? = nil

local function compute(profile: Profile): number
	local def = PROFILES[profile]
	local camera = Workspace.CurrentCamera
	local viewport = if camera then camera.ViewportSize else Vector2.new(def.BaseWidth, def.BaseHeight)
	local value = math.min(viewport.X / def.BaseWidth, viewport.Y / def.BaseHeight)
	if GuiService:IsTenFootInterface() then
		value *= TEN_FOOT_BOOST
	end
	return math.clamp(value, def.Min, def.Max)
end

local function updateAll()
	for scale, profile in tracked do
		if scale.Parent then
			scale.Scale = compute(profile :: Profile)
		else
			tracked[scale] = nil
		end
	end
end

local function watchCamera()
	if viewportConnection then
		viewportConnection:Disconnect()
		viewportConnection = nil
	end
	local camera = Workspace.CurrentCamera
	if camera then
		viewportConnection = camera:GetPropertyChangedSignal("ViewportSize"):Connect(updateAll)
	end
	updateAll()
end

-- Adds a responsive UIScale to `target`. Don't also use Ui.popIn on the same object.
function ResponsiveScale.Attach(target: GuiObject, profile: Profile): UIScale
	local scale = Instance.new("UIScale")
	scale.Name = "ResponsiveScale"
	scale.Scale = compute(profile)
	scale.Parent = target
	tracked[scale] = profile
	return scale
end

function ResponsiveScale.Init()
	Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(watchCamera)
	watchCamera()
end

return ResponsiveScale
