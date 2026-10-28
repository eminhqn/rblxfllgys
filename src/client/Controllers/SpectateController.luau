--!strict
-- Spectate mode. The server picks who you watch and loads their part of the world for you
-- (SpectatingUserId attribute); this module points the camera at them and shows the bar to switch
-- players. You spectate:
--   * knocked out of a match: with BACK TO LOBBY (you can come back to watch from the lobby
--     menu) and, side by side with it, REVIVE (ReviveClient) while you can still come back for
--     the next round
--   * qualified mid-round, or revived: watching the others while you wait for the next round
--
--   Keyboard: Q / E to switch, R to revive
--   Gamepad: LB / RB to switch, B to return to the lobby, A to revive (shown on the buttons)

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local Competitors = require(Shared.Competitors)
local Config = require(Shared.Config)
local Match = require(Shared.Match)
local Remotes = require(Shared.Remotes)
local Theme = require(Shared.Theme)
local Ui = require(Shared.Ui)

local Input = require(script.Parent.InputController)
local KeyIcon = require(script.Parent.KeyIcon)
local MatchClient = require(script.Parent.MatchClient)
local ResponsiveScale = require(script.Parent.ResponsiveScale)
local ReviveClient = require(script.Parent.ReviveClient)
local TransitionController = require(script.Parent.TransitionController)

local SpectateController = {}

local ACTION_PREVIOUS = "WobbleSpectatePrevious"
local ACTION_NEXT = "WobbleSpectateNext"
local ACTION_LOBBY = "WobbleSpectateLobby"
local ACTION_REVIVE = "WobbleSpectateRevive"
local CAMERA_CHECK_INTERVAL = 0.2
local SWITCH_COOLDOWN = 0.25
-- The server moves you back to the lobby EliminatedRespawnDelay seconds after you're knocked out;
-- cover the screen just before that.
local COVER_BEFORE_RESPAWN = 0.45
local CUT_TIME = 0.35 -- straight to watching (from the lobby, or after qualifying): a quick cover
local BUTTON_HEIGHT = 44
local BUTTON_WIDTH = 190 -- each of the two side by side
local BUTTON_GAP = 10
local LOBBY_KEY = Enum.KeyCode.ButtonB
local REVIVE_KEY = Enum.KeyCode.ButtonA

type Widgets = {
	Holder: Frame,
	Name: TextLabel,
	Hint: TextLabel,
	Lobby: TextButton,
	LobbyLabel: TextLabel,
	LobbyKey: ImageLabel,
	Revive: TextButton,
	ReviveLabel: TextLabel,
	ReviveKey: ImageLabel,
	Waiting: TextLabel,
}

local localPlayer = Players.LocalPlayer
local widgets: Widgets? = nil
local active = false
local activeToken = 0
local lastSwitch = 0

local function humanoidIn(character: Model?): Humanoid?
	return if character then character:FindFirstChildOfClass("Humanoid") else nil
end

local function humanoidOf(player: Player?): Humanoid?
	return humanoidIn(if player then player.Character else nil)
end

-- Who we're watching: a player or a bot (Shared/Competitors), by user id.
local function watchedId(): number
	return MatchClient.GetSpectatingUserId()
end

-- Points the camera at whoever we're watching (or at ourselves while nobody is available).
local function updateCamera()
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end
	local targetId = watchedId()
	local target = if targetId ~= 0 then Competitors.CharacterOf(targetId) else nil
	local humanoid = humanoidIn(target) or humanoidOf(localPlayer)
	if humanoid and camera.CameraSubject ~= humanoid then
		camera.CameraSubject = humanoid
	end
	local ui = widgets
	if ui then
		local name = if targetId ~= 0 then Competitors.NameOf(targetId) else nil
		ui.Name.Text = if target and name then name else "Waiting for the next round..."
	end
end

-- Knocked out (rather than qualified or revived): you can go to the lobby and revive.
local function knockedOut(): boolean
	return MatchClient.GetStatus() == "Eliminated"
end

-- The buttons along the bottom and the controls line, for what you can do now.
local function layoutBar()
	local ui = widgets
	if not ui then
		return
	end
	local out = knockedOut()
	local canRevive, reviveText = ReviveClient.Available()
	canRevive = canRevive and out
	ui.Lobby.Visible = out
	ui.Revive.Visible = canRevive
	ui.ReviveLabel.Text = reviveText
	ui.Waiting.Visible = not out
	-- Side by side: BACK TO LOBBY on the left, REVIVE on the right.
	local offset = (BUTTON_WIDTH + BUTTON_GAP) / 2
	ui.Lobby.Size = UDim2.fromOffset(if canRevive then BUTTON_WIDTH else 250, BUTTON_HEIGHT)
	ui.Lobby.Position = UDim2.new(0.5, if canRevive then -offset else 0, 1, -14)
	ui.Revive.Position = UDim2.new(0.5, offset, 1, -14)
	-- A controller's B and A on the buttons themselves.
	local gamepad = Input.GetScheme() == "Gamepad"
	local lobbyKey = gamepad and ui.LobbyKey.Image ~= ""
	local reviveKey = gamepad and ui.ReviveKey.Image ~= ""
	ui.LobbyKey.Visible = lobbyKey
	ui.ReviveKey.Visible = reviveKey
	ui.LobbyLabel.Size = UDim2.new(1, if lobbyKey then -56 else -24, 1, -14)
	ui.LobbyLabel.Position = UDim2.new(0.5, if lobbyKey then 14 else 0, 0.5, 0)
	ui.ReviveLabel.Size = UDim2.new(1, if reviveKey then -56 else -24, 1, -14)
	ui.ReviveLabel.Position = UDim2.new(0.5, if reviveKey then 14 else 0, 0.5, 0)
	local parts = { if gamepad then "LB / RB to switch" else "Q / E to switch" }
	if canRevive and not gamepad then
		table.insert(parts, "R to revive")
	end
	ui.Hint.Text = table.concat(parts, " · ")
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
	if knockedOut() then
		Remotes.Event("RequestReturnToLobby"):FireServer()
	end
end

local function revive()
	if knockedOut() then
		ReviveClient.Revive()
	end
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
	ContextActionService:BindAction(ACTION_LOBBY, handler(returnToLobby), false, LOBBY_KEY)
	ContextActionService:BindAction(ACTION_REVIVE, handler(revive), false, Enum.KeyCode.R, REVIVE_KEY)
end

local function unbindActions()
	ContextActionService:UnbindAction(ACTION_PREVIOUS)
	ContextActionService:UnbindAction(ACTION_NEXT)
	ContextActionService:UnbindAction(ACTION_LOBBY)
	ContextActionService:UnbindAction(ACTION_REVIVE)
end

-- While a respawn offer is open (ItemHud) you're still deciding, so spectating waits; the server
-- only moves you to the lobby once the offer is over.
local function respawnOfferOpen(): boolean
	local untilTime = localPlayer:GetAttribute(Match.PlayerAttr.RespawnOfferUntil)
	return typeof(untilTime) == "number" and untilTime > MatchClient.ServerTime()
end

local function shouldBeActive(): boolean
	if MatchClient.GetPhase() == "Winner" then
		return false
	end
	local status = MatchClient.GetStatus()
	if status == "Eliminated" then
		return not respawnOfferOpen()
	end
	-- Qualified (or revived), once the server has given you someone to watch.
	return status == "Qualified" and watchedId() ~= 0
end

local function activate()
	active = true
	activeToken += 1
	local token = activeToken
	Input.SetBlocked("Spectate", true)
	bindActions()
	local ui = widgets
	if ui then
		ui.Holder.Visible = true
		layoutBar()
		Ui.popIn(ui.Holder, 0.3)
	end
	-- Just knocked out (nobody to watch yet): the server is about to move you to the lobby.
	local fromArena = knockedOut() and watchedId() == 0

	task.spawn(function()
		if fromArena then
			-- Hide the jump from the arena back to the lobby, then cut to the player we're watching.
			task.wait(math.max(0, Config.Match.EliminatedRespawnDelay - COVER_BEFORE_RESPAWN))
			if activeToken ~= token then
				return
			end
			TransitionController.Cover()
			local deadline = os.clock() + 1.5
			while activeToken == token and watchedId() == 0 and os.clock() < deadline do
				task.wait(0.05)
			end
			task.wait(0.3)
			updateCamera()
			TransitionController.Uncover()
		else
			TransitionController.Flash(CUT_TIME)
			task.wait(CUT_TIME * 0.6)
			if activeToken ~= token then
				return
			end
			updateCamera()
		end

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
	Input.SetBlocked("Spectate", false)
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
	elseif active then
		layoutBar() -- (knocked out -> revived: the buttons change)
	end
end

-- A wide rounded button along the bottom of the bar, with its controller button on the left.
local function bottomButton(
	parent: Instance,
	text: string,
	color: Color3,
	textColor: Color3,
	keyCode: Enum.KeyCode
): (TextButton, TextLabel, ImageLabel)
	local button: TextButton = Ui.new("TextButton", {
		Text = "",
		AutoButtonColor = false,
		Size = UDim2.fromOffset(250, BUTTON_HEIGHT),
		Position = UDim2.new(0.5, 0, 1, -14),
		AnchorPoint = Vector2.new(0.5, 1),
		BackgroundColor3 = color,
		BorderSizePixel = 0,
		ZIndex = 3,
		Parent = parent,
	})
	Ui.corner(button, UDim.new(0, 16))
	local label = Ui.label(
		button,
		text,
		Theme.Fonts.Display,
		textColor,
		UDim2.new(1, -24, 1, -14),
		UDim2.fromScale(0.5, 0.5),
		Vector2.new(0.5, 0.5)
	)
	label.ZIndex = 4
	local key = KeyIcon.new(keyCode, {
		Size = UDim2.fromOffset(30, 30),
		Position = UDim2.new(0, 10, 0.5, 0),
		AnchorPoint = Vector2.new(0, 0.5),
		Visible = false,
		ZIndex = 5,
		Parent = button,
	})
	return button, label, key
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

	local lobbyButton, lobbyLabel, lobbyKey =
		bottomButton(panel.Body, "BACK TO LOBBY", Theme.Colors.Yellow, Theme.Colors.Ink, LOBBY_KEY)
	lobbyButton.Activated:Connect(function()
		Ui.pressBounce(lobbyButton)
		returnToLobby()
	end)
	local reviveButton, reviveLabel, reviveKey =
		bottomButton(panel.Body, "REVIVE", ReviveClient.Color, Theme.Colors.White, REVIVE_KEY)
	reviveButton.Size = UDim2.fromOffset(BUTTON_WIDTH, BUTTON_HEIGHT)
	reviveButton.Visible = false
	Ui.textOutline(reviveLabel, Theme.Colors.Ink, 1.5)
	reviveButton.Activated:Connect(function()
		Ui.pressBounce(reviveButton)
		revive()
	end)
	-- Qualified or revived: no buttons, just where you stand.
	local waiting = Ui.label(
		panel.Body,
		"YOU'RE IN THE NEXT ROUND!",
		Theme.Fonts.Display,
		Theme.Colors.Lime,
		UDim2.new(1, -40, 0, 30),
		UDim2.new(0.5, 0, 1, -20),
		Vector2.new(0.5, 1)
	)
	Ui.textOutline(waiting, Theme.Colors.Ink, 1.5)
	waiting.Visible = false

	widgets = {
		Holder = inner,
		Name = name,
		Hint = hint,
		Lobby = lobbyButton,
		LobbyLabel = lobbyLabel,
		LobbyKey = lobbyKey,
		Revive = reviveButton,
		ReviveLabel = reviveLabel,
		ReviveKey = reviveKey,
		Waiting = waiting,
	}
	-- The outer holder carries the responsive scale; `inner` is what pops in and hides.
	holder.Visible = true
	inner.Visible = false
end

function SpectateController.Init()
	build()
	MatchClient.LocalChanged:Connect(function(attribute: string)
		if attribute == Match.PlayerAttr.Status or attribute == Match.PlayerAttr.RespawnOfferUntil then
			refresh()
		elseif attribute == Match.PlayerAttr.Spectating then
			if active then
				updateCamera()
			end
			refresh() -- (qualified: watching starts once there's someone to watch)
		end
	end)
	MatchClient.Changed:Connect(function(attribute: string)
		if attribute == Match.Attr.Phase then
			refresh()
		end
	end)
	ReviveClient.Changed:Connect(function()
		if active then
			layoutBar()
		end
	end)
	Input.SchemeChanged:Connect(function()
		if active then
			layoutBar()
		end
	end)
	refresh()
end

return SpectateController
