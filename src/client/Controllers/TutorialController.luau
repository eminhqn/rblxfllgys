--!strict
-- The tutorial on screen (the server's TutorialService runs it; Shared/Tutorial lists the steps).
--
--   * New players are offered it once, a few seconds after they first join: PLAY TUTORIAL or NO
--     THANKS (A / B on a controller). It's in the lobby MENU too, to play it again any time.
--   * While you're in it, a panel at the top says which step you're on, what to do and which
--     button does it (for keyboard, controller or touch), with a LEAVE button (Back / View on a
--     controller).
--   * When you finish: TUTORIAL DONE! and the Gumdrops (the first time), then back to the lobby.

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Config = require(Shared.Config)
local Match = require(Shared.Match)
local Remotes = require(Shared.Remotes)
local Theme = require(Shared.Theme)
local Tutorial = require(Shared.Tutorial)
local Ui = require(Shared.Ui)

local Input = require(script.Parent.InputController)
local MatchClient = require(script.Parent.MatchClient)
local ProfileClient = require(script.Parent.ProfileClient)
local ResponsiveScale = require(script.Parent.ResponsiveScale)
local RoundHud = require(script.Parent.RoundHud)
local Sfx = require(script.Parent.Sfx)

local TutorialController = {}

local OFFER_ACTION = "WobbleTutorialOffer"
local LEAVE_ACTION = "WobbleTutorialLeave"
local WHITE = Theme.Colors.White
local GREY = Color3.fromRGB(200, 194, 214)

-- What to press for each step, on each kind of controls.
local KEYS: { [string]: { KeyboardMouse: string, Gamepad: string, Touch: string } } = {
	Move = { KeyboardMouse = "W A S D", Gamepad = "LEFT STICK", Touch = "THE STICK" },
	Jump = { KeyboardMouse = "SPACE", Gamepad = "A", Touch = "JUMP" },
	Dive = { KeyboardMouse = "SPACE, THEN CTRL", Gamepad = "A, THEN X", Touch = "JUMP, THEN DIVE" },
	Grab = { KeyboardMouse = "HOLD SHIFT", Gamepad = "HOLD RB", Touch = "HOLD GRAB" },
	Kick = { KeyboardMouse = "F", Gamepad = "B", Touch = "KICK" },
	Bounce = { KeyboardMouse = "STEER WITH W A S D", Gamepad = "STEER WITH THE STICK", Touch = "STEER WITH THE STICK" },
}

local localPlayer = Players.LocalPlayer
local offerGui: ScreenGui
local offerPanel: Frame
local stepGui: ScreenGui
local stepPanel: Frame
local stepTitle: TextLabel
local stepText: TextLabel
local stepKeys: TextLabel
local leaveButton: TextButton
local offerOpen = false
local offeredThisSession = false

local function request(action: string)
	Remotes.Event("RequestTutorial"):FireServer(action)
end

local function currentStep(): number
	local step = localPlayer:GetAttribute(Match.PlayerAttr.TutorialStep)
	return if typeof(step) == "number" then step else 0
end

-------------------------------------------------------------------------------------------------
-- The offer
-------------------------------------------------------------------------------------------------

local function setOfferOpen(open: boolean)
	if open == offerOpen then
		return
	end
	offerOpen = open
	offerGui.Enabled = open
	Input.SetBlocked("TutorialOffer", open)
	if open then
		Ui.popIn(offerPanel)
		ContextActionService:BindActionAtPriority(
			OFFER_ACTION,
			function(_name: string, state: Enum.UserInputState, input: InputObject): Enum.ContextActionResult
				if state == Enum.UserInputState.Begin then
					if input.KeyCode == Enum.KeyCode.ButtonA then
						setOfferOpen(false)
						request("Start")
					elseif input.KeyCode == Enum.KeyCode.ButtonB then
						setOfferOpen(false)
						request("Decline")
					end
				end
				return Enum.ContextActionResult.Sink
			end,
			false,
			Enum.ContextActionPriority.High.Value + 20,
			Enum.KeyCode.ButtonA,
			Enum.KeyCode.ButtonB
		)
	else
		ContextActionService:UnbindAction(OFFER_ACTION)
	end
end

-- New players, once: a few seconds after their data arrives, while they're in the lobby.
local function maybeOffer()
	if offeredThisSession or not ProfileClient.IsReady() then
		return
	end
	if localPlayer:GetAttribute(Match.PlayerAttr.TutorialOffered) ~= false then
		return
	end
	offeredThisSession = true
	task.delay(Config.Tutorial.OfferDelay, function()
		if not MatchClient.IsInMatchFlow() and currentStep() == 0 then
			setOfferOpen(true)
		end
	end)
end

local function bigButton(parent: Instance, text: string, color: Color3, position: UDim2): TextButton
	local button: TextButton = Ui.new("TextButton", {
		Text = "",
		AutoButtonColor = false,
		Size = UDim2.fromOffset(200, 48),
		Position = position,
		AnchorPoint = Vector2.new(0.5, 0),
		BackgroundColor3 = color,
		BorderSizePixel = 0,
		ZIndex = 5,
		Parent = parent,
	})
	Ui.corner(button, UDim.new(0.5, 0))
	Ui.stroke(button, WHITE, 3)
	local label = Ui.label(
		button,
		text,
		Theme.Fonts.Display,
		WHITE,
		UDim2.new(1, -16, 1, -12),
		UDim2.fromScale(0.5, 0.5),
		Vector2.new(0.5, 0.5)
	)
	label.ZIndex = 6
	Ui.textOutline(label, Theme.Colors.Ink, 1.5)
	return button
end

local function buildOffer()
	offerGui = Ui.new("ScreenGui", {
		Name = "TutorialOffer",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		DisplayOrder = 40,
		Enabled = false,
		Parent = localPlayer:WaitForChild("PlayerGui"),
	})
	Ui.new("Frame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Theme.Colors.Shadow,
		BackgroundTransparency = 0.55,
		BorderSizePixel = 0,
		Parent = offerGui,
	})
	local window: Frame = Ui.new("Frame", {
		Size = UDim2.fromOffset(520, 270),
		Position = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundTransparency = 1,
		Parent = offerGui,
	})
	ResponsiveScale.Attach(window, "Hud")
	local panel = Ui.panel(window, UDim2.fromScale(1, 1), UDim2.new(), Vector2.zero)
	offerPanel = panel.Root
	local title = Ui.label(
		panel.Body,
		"NEW TO WOBBLE RUSH?",
		Theme.Fonts.Display,
		Theme.Colors.Purple,
		UDim2.new(1, -40, 0, 40),
		UDim2.new(0.5, 0, 0, 20),
		Vector2.new(0.5, 0)
	)
	title.ZIndex = 4
	local text = Ui.label(
		panel.Body,
		`Take the quick tutorial (about a minute): learn to move, jump, dive, grab and kick. Finish it for {Config.Tutorial.Reward} Gumdrops!`,
		Theme.Fonts.Body,
		Theme.Colors.Ink,
		UDim2.new(1, -60, 0, 80),
		UDim2.new(0.5, 0, 0, 70),
		Vector2.new(0.5, 0)
	)
	text.TextWrapped = true
	text.ZIndex = 4
	Ui.new("UITextSizeConstraint", { MaxTextSize = 22, Parent = text })
	local play = bigButton(panel.Body, "PLAY TUTORIAL (A)", Theme.Colors.Lime, UDim2.new(0.5, -110, 0, 176))
	local skip = bigButton(panel.Body, "NO THANKS (B)", GREY, UDim2.new(0.5, 110, 0, 176))
	play.Activated:Connect(function()
		setOfferOpen(false)
		request("Start")
	end)
	skip.Activated:Connect(function()
		setOfferOpen(false)
		request("Decline")
	end)
end

-------------------------------------------------------------------------------------------------
-- The step panel
-------------------------------------------------------------------------------------------------

local function refreshStep()
	local step = currentStep()
	local count = #Tutorial.Steps
	local inTutorial = step > 0
	stepGui.Enabled = inTutorial
	if inTutorial then
		ContextActionService:BindActionAtPriority(
			LEAVE_ACTION,
			function(_name: string, state: Enum.UserInputState): Enum.ContextActionResult
				if state == Enum.UserInputState.Begin then
					request("Leave")
				end
				return Enum.ContextActionResult.Sink
			end,
			false,
			Enum.ContextActionPriority.High.Value,
			Enum.KeyCode.ButtonSelect
		)
	else
		ContextActionService:UnbindAction(LEAVE_ACTION)
		return
	end
	if step > count then
		stepTitle.Text = "TUTORIAL DONE!"
		stepText.Text = "You're ready! Press PLAY in the lobby to join a match."
		stepKeys.Text = "BACK TO THE LOBBY..."
		leaveButton.Visible = false
		return
	end
	local def = Tutorial.Steps[step]
	stepTitle.Text = `TUTORIAL  ·  STEP {step} OF {count}`
	stepText.Text = def.Text
	local keys = KEYS[def.Action]
	local scheme = Input.GetScheme()
	stepKeys.Text = if scheme == "Gamepad"
		then keys.Gamepad
		elseif scheme == "Touch" then keys.Touch
		else keys.KeyboardMouse
	leaveButton.Visible = true
end

local function buildStepPanel()
	stepGui = Ui.new("ScreenGui", {
		Name = "Tutorial",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		DisplayOrder = 12,
		Enabled = false,
		Parent = localPlayer:WaitForChild("PlayerGui"),
	})
	local holder: Frame = Ui.new("Frame", {
		Size = UDim2.fromOffset(560, 132),
		Position = UDim2.new(0.5, 0, 0, 70),
		AnchorPoint = Vector2.new(0.5, 0),
		BackgroundTransparency = 1,
		Parent = stepGui,
	})
	ResponsiveScale.Attach(holder, "Hud")
	local panel = Ui.panel(holder, UDim2.fromScale(1, 1), UDim2.new(), Vector2.zero)
	stepPanel = panel.Root
	stepTitle = Ui.label(
		panel.Body,
		"",
		Theme.Fonts.Display,
		Theme.Colors.Purple,
		UDim2.new(1, -150, 0, 26),
		UDim2.fromOffset(18, 10)
	)
	stepTitle.TextXAlignment = Enum.TextXAlignment.Left
	stepTitle.ZIndex = 4
	stepText = Ui.label(
		panel.Body,
		"",
		Theme.Fonts.Display,
		Theme.Colors.Ink,
		UDim2.new(1, -36, 0, 44),
		UDim2.fromOffset(18, 40)
	)
	stepText.TextWrapped = true
	stepText.TextXAlignment = Enum.TextXAlignment.Left
	stepText.ZIndex = 4
	Ui.new("UITextSizeConstraint", { MaxTextSize = 22, Parent = stepText })
	stepKeys = Ui.label(
		panel.Body,
		"",
		Theme.Fonts.Display,
		Theme.Colors.Pink,
		UDim2.new(1, -36, 0, 24),
		UDim2.fromOffset(18, 90)
	)
	stepKeys.TextXAlignment = Enum.TextXAlignment.Left
	stepKeys.ZIndex = 4
	leaveButton = Ui.new("TextButton", {
		Text = "",
		AutoButtonColor = false,
		Size = UDim2.fromOffset(120, 34),
		Position = UDim2.new(1, -12, 0, 10),
		AnchorPoint = Vector2.new(1, 0),
		BackgroundColor3 = Theme.Colors.Pink,
		BorderSizePixel = 0,
		ZIndex = 5,
		Parent = panel.Body,
	})
	Ui.corner(leaveButton, UDim.new(0.5, 0))
	local leaveLabel = Ui.label(
		leaveButton,
		"LEAVE",
		Theme.Fonts.Display,
		WHITE,
		UDim2.new(1, -12, 1, -10),
		UDim2.fromScale(0.5, 0.5),
		Vector2.new(0.5, 0.5)
	)
	leaveLabel.ZIndex = 6
	leaveButton.Activated:Connect(function()
		request("Leave")
	end)
end

local function onEvent(kind: unknown, _step: unknown, reward: unknown)
	if kind == "Started" then
		Sfx.Play("Go")
	elseif kind == "Step" then
		Sfx.Play("Checkpoint")
		Ui.popIn(stepPanel)
	elseif kind == "Finished" then
		Sfx.Play("Qualify")
		if typeof(reward) == "number" and reward > 0 then
			RoundHud.Toast(`TUTORIAL DONE! +{reward} GUMDROPS`, Theme.Colors.Lime)
		else
			RoundHud.Toast("TUTORIAL DONE!", Theme.Colors.Lime)
		end
	end
end

-- Starts the tutorial (the lobby MENU's TUTORIAL entry).
function TutorialController.Open()
	if currentStep() == 0 and not MatchClient.IsInMatchFlow() then
		request("Start")
	end
end

function TutorialController.Init()
	buildOffer()
	buildStepPanel()
	localPlayer.AttributeChanged:Connect(function(name: string)
		if name == Match.PlayerAttr.TutorialStep then
			refreshStep()
		end
	end)
	Input.SchemeChanged:Connect(refreshStep)
	ProfileClient.Changed:Connect(maybeOffer)
	Remotes.Event("TutorialEvent").OnClientEvent:Connect(onEvent)
	refreshStep()
	maybeOffer()
end

return TutorialController
