--!strict
-- One input layer for keyboard, gamepad and touch. The rest of the client asks for a
-- camera-relative move vector and listens for jump/dive/grab without caring about the device.
--
--   Keyboard: WASD move, Space jump, Left Ctrl or C dive, Left Shift or E grab (hold),
--             F or left click kick, G emote, R slap (with SLAPS, in a round)
--   Gamepad:  left stick move, A jump, X dive, R2/RB grab (hold), B kick, D-pad up emote, Y slap
--   Touch:    on-screen stick and buttons (TouchControls)

local GuiService = game:GetService("GuiService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local MathUtil = require(Shared.MathUtil)
local Signal = require(Shared.Signal)

export type Scheme = "KeyboardMouse" | "Gamepad" | "Touch"

local InputController = {}

InputController.JumpPressed = Signal.new() :: Signal.Signal<()>
InputController.DivePressed = Signal.new() :: Signal.Signal<()>
InputController.GrabChanged = Signal.new() :: Signal.Signal<boolean>
InputController.KickPressed = Signal.new() :: Signal.Signal<()>
InputController.EmotePressed = Signal.new() :: Signal.Signal<()>
InputController.SlapPressed = Signal.new() :: Signal.Signal<()>
InputController.SchemeChanged = Signal.new() :: Signal.Signal<Scheme>
InputController.EnabledChanged = Signal.new() :: Signal.Signal<boolean>

local STICK_DEADZONE = 0.15

local MOVE_KEYS: { [Enum.KeyCode]: Vector2 } = {
	[Enum.KeyCode.W] = Vector2.new(0, 1),
	[Enum.KeyCode.S] = Vector2.new(0, -1),
	[Enum.KeyCode.A] = Vector2.new(-1, 0),
	[Enum.KeyCode.D] = Vector2.new(1, 0),
}
local JUMP_KEYS: { [Enum.KeyCode]: boolean } = {
	[Enum.KeyCode.Space] = true,
	[Enum.KeyCode.ButtonA] = true,
}
local DIVE_KEYS: { [Enum.KeyCode]: boolean } = {
	[Enum.KeyCode.LeftControl] = true,
	[Enum.KeyCode.C] = true,
	[Enum.KeyCode.ButtonX] = true,
}
local KICK_KEYS: { [Enum.KeyCode]: boolean } = {
	[Enum.KeyCode.F] = true,
	[Enum.KeyCode.ButtonB] = true,
}
local EMOTE_KEYS: { [Enum.KeyCode]: boolean } = {
	[Enum.KeyCode.G] = true,
	[Enum.KeyCode.DPadUp] = true,
}
local SLAP_KEYS: { [Enum.KeyCode]: boolean } = {
	[Enum.KeyCode.R] = true,
	[Enum.KeyCode.ButtonY] = true, -- PLAY in the lobby, where there's no slapping
}
local GRAB_KEYS: { [Enum.KeyCode]: boolean } = {
	[Enum.KeyCode.LeftShift] = true,
	[Enum.KeyCode.E] = true,
	[Enum.KeyCode.ButtonR2] = true,
	[Enum.KeyCode.ButtonR1] = true,
}

local heldMoveKeys: { [Enum.KeyCode]: boolean } = {}
local gamepadStick = Vector2.zero
local touchStick = Vector2.zero
local jumpSources: { [string]: boolean } = {}
local grabSources: { [string]: boolean } = {}
local grabHeld = false
local enabled = true
local blockers: { [string]: boolean } = {} -- reasons gameplay input is paused (SetBlocked)
local scheme: Scheme = "KeyboardMouse"

local function applyDeadzone(stick: Vector2): Vector2
	local magnitude = stick.Magnitude
	if magnitude < STICK_DEADZONE then
		return Vector2.zero
	end
	return stick.Unit * math.min(1, (magnitude - STICK_DEADZONE) / (1 - STICK_DEADZONE))
end

local function keyboardVector(): Vector2
	local sum = Vector2.zero
	for key in heldMoveKeys do
		sum += MOVE_KEYS[key]
	end
	return if sum.Magnitude > 0 then sum.Unit else Vector2.zero
end

local function updateGrab()
	local held = if enabled then next(grabSources) ~= nil else false
	if held ~= grabHeld then
		grabHeld = held
		InputController.GrabChanged:Fire(held)
	end
end

local function schemeFor(inputType: Enum.UserInputType): Scheme?
	if inputType == Enum.UserInputType.Touch then
		return "Touch" :: Scheme
	elseif string.find(inputType.Name, "^Gamepad") then
		return "Gamepad" :: Scheme
	elseif
		inputType == Enum.UserInputType.Keyboard
		or inputType == Enum.UserInputType.MouseButton1
		or inputType == Enum.UserInputType.MouseButton2
		or inputType == Enum.UserInputType.MouseMovement
		or inputType == Enum.UserInputType.MouseWheel
	then
		return "KeyboardMouse" :: Scheme
	end
	return nil
end

local function setScheme(newScheme: Scheme)
	if newScheme ~= scheme then
		scheme = newScheme
		InputController.SchemeChanged:Fire(newScheme)
	end
end

local function clearAll()
	table.clear(heldMoveKeys)
	table.clear(jumpSources)
	table.clear(grabSources)
	gamepadStick = Vector2.zero
	touchStick = Vector2.zero
	updateGrab()
end

-- Source-based press/release so keyboard, gamepad and touch can overlap safely.
function InputController.PressJump(source: string)
	if not enabled then
		return
	end
	jumpSources[source] = true
	InputController.JumpPressed:Fire()
end

function InputController.ReleaseJump(source: string)
	jumpSources[source] = nil
end

function InputController.PressDive()
	if enabled then
		InputController.DivePressed:Fire()
	end
end

function InputController.PressKick()
	if enabled then
		InputController.KickPressed:Fire()
	end
end

function InputController.PressEmote()
	if enabled then
		InputController.EmotePressed:Fire()
	end
end

function InputController.PressSlap()
	if enabled then
		InputController.SlapPressed:Fire()
	end
end

function InputController.SetGrab(source: string, held: boolean)
	if held then
		grabSources[source] = true
	else
		grabSources[source] = nil
	end
	updateGrab()
end

function InputController.SetTouchMove(stick: Vector2)
	touchStick = if stick.Magnitude > 1 then stick.Unit else stick
end

function InputController.IsJumpHeld(): boolean
	return next(jumpSources) ~= nil
end

function InputController.GetScheme(): Scheme
	return scheme
end

-- Pauses gameplay input for as long as `reason` (e.g. "Customise", "Settings", "Spectate") needs
-- it paused. Input comes back once no reason is left, so two menus can't switch it back on for
-- each other. Pausing clears anything held.
function InputController.SetBlocked(reason: string, blocked: boolean)
	if blocked then
		blockers[reason] = true
	else
		blockers[reason] = nil
	end
	local isEnabled = next(blockers) == nil
	if enabled == isEnabled then
		return
	end
	enabled = isEnabled
	if not isEnabled then
		clearAll()
	end
	InputController.EnabledChanged:Fire(isEnabled)
end

function InputController.IsEnabled(): boolean
	return enabled
end

-- World-space horizontal direction, relative to the camera, magnitude 0..1.
function InputController.GetMoveVector(): Vector3
	if not enabled then
		return Vector3.zero
	end
	local raw = if gamepadStick.Magnitude > 0
		then gamepadStick
		elseif touchStick.Magnitude > 0 then touchStick
		else keyboardVector()
	if raw.Magnitude < 1e-3 then
		return Vector3.zero
	end

	local camera = Workspace.CurrentCamera
	if not camera then
		return Vector3.new(raw.X, 0, -raw.Y)
	end
	local cameraCFrame = camera.CFrame
	local forward = MathUtil.flat(cameraCFrame.LookVector)
	if forward.Magnitude < 1e-3 then
		-- Looking straight down: the camera's up vector points "forward".
		forward = MathUtil.flat(cameraCFrame.UpVector)
	end
	forward = forward.Unit
	local right = forward:Cross(Vector3.yAxis)
	return MathUtil.clampMagnitude(forward * raw.Y + right * raw.X, 1)
end

function InputController.Init()
	if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
		scheme = "Touch" :: Scheme
	elseif UserInputService.GamepadEnabled and GuiService:IsTenFootInterface() then
		scheme = "Gamepad" :: Scheme
	end
	local lastScheme = schemeFor(UserInputService:GetLastInputType())
	if lastScheme then
		scheme = lastScheme :: Scheme
	end

	UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
		local newScheme = schemeFor(input.UserInputType)
		if newScheme then
			setScheme(newScheme :: Scheme)
		end
		if gameProcessed then
			return -- typing in chat, clicking UI, etc.
		end
		local key = input.KeyCode
		if MOVE_KEYS[key] then
			heldMoveKeys[key] = true
		elseif JUMP_KEYS[key] then
			InputController.PressJump(key.Name)
		elseif DIVE_KEYS[key] then
			InputController.PressDive()
		elseif KICK_KEYS[key] or input.UserInputType == Enum.UserInputType.MouseButton1 then
			InputController.PressKick()
		elseif GRAB_KEYS[key] then
			InputController.SetGrab(key.Name, true)
		elseif EMOTE_KEYS[key] then
			InputController.PressEmote()
		elseif SLAP_KEYS[key] then
			InputController.PressSlap()
		end
	end)

	UserInputService.InputEnded:Connect(function(input: InputObject)
		local key = input.KeyCode
		if MOVE_KEYS[key] then
			heldMoveKeys[key] = nil
		elseif JUMP_KEYS[key] then
			InputController.ReleaseJump(key.Name)
		elseif GRAB_KEYS[key] then
			InputController.SetGrab(key.Name, false)
		end
	end)

	UserInputService.InputChanged:Connect(function(input: InputObject)
		if input.KeyCode == Enum.KeyCode.Thumbstick1 then
			local position = input.Position
			gamepadStick = applyDeadzone(Vector2.new(position.X, position.Y))
			if gamepadStick.Magnitude > 0 then
				setScheme("Gamepad")
			end
		end
	end)

	UserInputService.GamepadDisconnected:Connect(function()
		gamepadStick = Vector2.zero
	end)
	UserInputService.WindowFocusReleased:Connect(clearAll)
end

return InputController
