--!strict
-- Spectate mode for eliminated players. The server picks who you watch and loads their part of the
-- world for you (SpectatingUserId attribute); this module points the camera at them and shows the
-- bar to switch players or go back to the lobby.
--
--   Keyboard: Q / E to switch      Gamepad: LB / RB to switch, B to return to the lobby

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local Config = require(Shared.Config)
local Match = require(Shared.Match)
local Remotes = require(Shared.Remotes)
local Theme = require(Shared.Theme)
local Ui = require(Shared.Ui)

local Input = require(script.Parent.InputController)
local MatchClient = require(script.Parent.MatchClient)
local ResponsiveScale = require(script.Parent.ResponsiveScale)
local TransitionController = require(script.Parent.TransitionController)

local SpectateController = {}

local ACTION_PREVIOUS = "WobbleSpectatePrevious"
local ACTION_NEXT = "WobbleSpectateNext"
local ACTION_LOBBY = "WobbleSpectateLobby"
local CAMERA_CHECK_INTERVAL = 0.2
local SWITCH_COOLDOWN = 0.25
-- The server moves you back to the lobby EliminatedRespawnDelay seconds after you're knocked out;
-- cover the screen just before that.
local COVER_BEFORE_RESPAWN = 0.45

type Widgets = {
	Holder: Frame,
	Name: TextLabel,
	Hint: TextLabel,
}

local localPlayer = Players.LocalPlayer
local widgets: Widgets? = nil
local active = false
local activeToken = 0
local lastSwitch = 0

local function humanoidOf(player: Player?): Humanoid?
	local character = if player then player.Character else nil
	return if character then character:FindFirstChildOfClass("Humanoid") else nil
end

local function watchedPlayer(): Player?
	local userId = MatchClient.GetSpectatingUserId()
	return if userId ~= 0 then Players:GetPlayerByUserId(userId) else nil
end

-- Points the camera at whoever we're watching (or at ourselves while nobody is available).
local function updateCamera()
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end
	local target = watchedPlayer()
	local humanoid = humanoidOf(target) or humanoidOf(localPlayer)
	if humanoid and camera.CameraSubject ~= humanoid then
		camera.CameraSubject = humanoid
	end
	local ui = widgets
	if ui then
		ui.Name.Text = if target then target.DisplayName else "Waiting for the next round..."
	end
end

local function step(direction: number)
	local now = os.clock()
	if now - lastSwitch < SWITCH_COOLDOWN then
		return
	end
	lastSwitch = now
	Remotes.Event("RequestSpectate"):FireServer(direction)
end

local function returnToLobby()
	Remotes.Event("RequestReturnToLobby"):FireServer()
end

local function bindActions()
	local function handler(callback: () -> ())
		return function(_: string, state: Enum.UserInputState): Enum.ContextActionResult
			if state == Enum.UserInputState.Begin then
				callback()
			end
			return Enum.ContextActionResult.Sink
		end
	end
	ContextActionService:BindAction(
		ACTION_PREVIOUS,
		handler(function()
			step(-1)
		end),
		false,
		Enum.KeyCode.Q,
		Enum.KeyCode.ButtonL1
	)
	ContextActionService:BindAction(
		ACTION_NEXT,
		handler(function()
			step(1)
		end),
		false,
		Enum.KeyCode.E,
		Enum.KeyCode.ButtonR1
	)
	ContextActionService:BindAction(ACTION_LOBBY, handler(returnToLobby), false, Enum.KeyCode.ButtonB)
end

local function unbindActions()
	ContextActionService:UnbindAction(ACTION_PREVIOUS)
	ContextActionService:UnbindAction(ACTION_NEXT)
	ContextActionService:UnbindAction(ACTION_LOBBY)
end

local function shouldBeActive(): boolean
	return MatchClient.GetStatus() == "Eliminated" and MatchClient.GetPhase() ~= "Winner"
end

local function activate()
	active = true
	activeToken += 1
	local token = activeToken
	Input.SetEnabled(false)
	bindActions()
	local ui = widgets
	if ui then
		ui.Holder.Visible = true
		ui.Hint.Text = if Input.GetScheme() == "Gamepad" then "LB / RB to switch · B for lobby" else "Q / E to switch"
		Ui.popIn(ui.Holder, 0.3)
	end

	-- Hide the jump from the arena back to the lobby, then cut to the player we're watching.
	task.spawn(function()
		task.wait(math.max(0, Config.Match.EliminatedRespawnDelay - COVER_BEFORE_RESPAWN))
		if activeToken ~= token then
			return
		end
		TransitionController.Cover()
		local deadline = os.clock() + 1.5
		while activeToken == token and MatchClient.GetSpectatingUserId() == 0 and os.clock() < deadline do
			task.wait(0.05)
		end
		task.wait(0.3)
		updateCamera()
		TransitionController.Uncover()

		while activeToken == token do
			updateCamera()
			task.wait(CAMERA_CHECK_INTERVAL)
		end
	end)
end

local function deactivate()
	active = false
	activeToken += 1
	unbindActions()
	Input.SetEnabled(true)
	local ui = widgets
	if ui then
		ui.Holder.Visible = false
	end
	local camera = Workspace.CurrentCamera
	local humanoid = humanoidOf(localPlayer)
	if camera and humanoid then
		camera.CameraSubject = humanoid
	end
end

local function refresh()
	local wanted = shouldBeActive()
	if wanted and not active then
		activate()
	elseif not wanted and active then
		local backToLobby = MatchClient.GetStatus() == "None"
		deactivate()
		if backToLobby then
			TransitionController.Flash(0.4)
		end
	end
end

local function build()
	local playerGui = localPlayer:WaitForChild("PlayerGui")
	local gui: ScreenGui = Ui.new("ScreenGui", {
		Name = "Spectate",
		ResetOnSpawn = false,
		IgnoreGuiInset = false,
		DisplayOrder = 8,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		Parent = playerGui,
	})
	local holder: Frame = Ui.new("Frame", {
		Name = "Bar",
		Size = UDim2.fromOffset(440, 168),
		Position = UDim2.new(0.5, 0, 1, -20),
		AnchorPoint = Vector2.new(0.5, 1),
		BackgroundTransparency = 1,
		Visible = false,
		Parent = gui,
	})
	ResponsiveScale.Attach(holder, "Hud")
	local inner: Frame = Ui.new("Frame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Parent = holder,
	})
	local panel = Ui.panel(inner, UDim2.new(1, 0, 1, -Theme.ShadowOffset), UDim2.new(), Vector2.zero)

	Ui.label(
		panel.Body,
		"SPECTATING",
		Theme.Fonts.Body,
		Theme.Colors.InkSoft,
		UDim2.fromOffset(200, 20),
		UDim2.new(0.5, 0, 0, 12),
		Vector2.new(0.5, 0)
	)
	local name = Ui.label(
		panel.Body,
		"",
		Theme.Fonts.Display,
		Theme.Colors.Ink,
		UDim2.new(1, -150, 0, 36),
		UDim2.new(0.5, 0, 0, 34),
		Vector2.new(0.5, 0)
	)
	local hint = Ui.label(
		panel.Body,
		"",
		Theme.Fonts.Body,
		Theme.Colors.InkSoft,
		UDim2.new(1, -40, 0, 18),
		UDim2.new(0.5, 0, 0, 74),
		Vector2.new(0.5, 0)
	)

	local function roundButton(text: string, position: UDim2, onClick: () -> ())
		local button: TextButton = Ui.new("TextButton", {
			Text = "",
			AutoButtonColor = false,
			Size = UDim2.fromOffset(52, 52),
			Position = position,
			AnchorPoint = Vector2.new(0.5, 0),
			BackgroundColor3 = Theme.Colors.Purple,
			BorderSizePixel = 0,
			ZIndex = 3,
			Parent = panel.Body,
		})
		Ui.corner(button, UDim.new(0.5, 0))
		local label = Ui.label(
			button,
			text,
			Theme.Fonts.Display,
			Theme.Colors.White,
			UDim2.fromScale(0.6, 0.6),
			UDim2.fromScale(0.5, 0.5),
			Vector2.new(0.5, 0.5)
		)
		label.ZIndex = 4
		button.Activated:Connect(function()
			Ui.pressBounce(button)
			onClick()
		end)
	end
	roundButton("<", UDim2.fromOffset(46, 22), function()
		step(-1)
	end)
	roundButton(">", UDim2.new(1, -46, 0, 22), function()
		step(1)
	end)

	local lobbyButton: TextButton = Ui.new("TextButton", {
		Text = "",
		AutoButtonColor = false,
		Size = UDim2.fromOffset(250, 44),
		Position = UDim2.new(0.5, 0, 1, -14),
		AnchorPoint = Vector2.new(0.5, 1),
		BackgroundColor3 = Theme.Colors.Yellow,
		BorderSizePixel = 0,
		ZIndex = 3,
		Parent = panel.Body,
	})
	Ui.corner(lobbyButton, UDim.new(0, 16))
	local lobbyLabel = Ui.label(
		lobbyButton,
		"BACK TO LOBBY",
		Theme.Fonts.Display,
		Theme.Colors.Ink,
		UDim2.new(1, -30, 1, -14),
		UDim2.fromScale(0.5, 0.5),
		Vector2.new(0.5, 0.5)
	)
	lobbyLabel.ZIndex = 4
	lobbyButton.Activated:Connect(function()
		Ui.pressBounce(lobbyButton)
		returnToLobby()
	end)

	widgets = { Holder = inner, Name = name, Hint = hint }
	-- The outer holder carries the responsive scale; `inner` is what pops in and hides.
	holder.Visible = true
	inner.Visible = false
end

function SpectateController.Init()
	build()
	MatchClient.LocalChanged:Connect(function(attribute: string)
		if attribute == Match.PlayerAttr.Status then
			refresh()
		elseif attribute == Match.PlayerAttr.Spectating and active then
			updateCamera()
		end
	end)
	MatchClient.Changed:Connect(function(attribute: string)
		if attribute == Match.Attr.Phase then
			refresh()
		end
	end)
	refresh()
end

return SpectateController
