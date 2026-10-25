--!strict
-- A full-screen candy wipe that hides the moment the camera jumps somewhere new: entering a round,
-- switching to spectating, or coming back to the lobby.
--
-- It covers automatically for players taking part in a match while the server is loading the
-- next arena or crowning the winner. Other modules can call Cover / Uncover too.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Match = require(Shared.Match)
local Theme = require(Shared.Theme)
local Ui = require(Shared.Ui)

local MatchClient = require(script.Parent.MatchClient)
local Sfx = require(script.Parent.Sfx)

local TransitionController = {}

local COVER_TIME = 0.35
local UNCOVER_TIME = 0.45
local WINNER_UNCOVER_DELAY = 0.9 -- the server moves everyone home 0.45 s into the Winner phase

local wipe: Frame? = nil
local covered = false
local coverToken = 0

local HIDDEN_BELOW = UDim2.fromScale(0.5, 1.75)
local SHOWN = UDim2.fromScale(0.5, 0.5)
local HIDDEN_ABOVE = UDim2.fromScale(0.5, -0.75)

function TransitionController.IsCovered(): boolean
	return covered
end

function TransitionController.Cover()
	local frame = wipe
	if not frame or covered then
		return
	end
	covered = true
	coverToken += 1
	Sfx.Play("Whoosh")
	frame.Position = HIDDEN_BELOW
	frame.Visible = true
	Ui.tween(frame, TweenInfo.new(COVER_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Position = SHOWN })
end

function TransitionController.Uncover()
	local frame = wipe
	if not frame or not covered then
		return
	end
	covered = false
	coverToken += 1
	Sfx.Play("Whoosh")
	local token = coverToken
	local tween = Ui.tween(
		frame,
		TweenInfo.new(UNCOVER_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
		{ Position = HIDDEN_ABOVE }
	)
	tween.Completed:Once(function()
		if coverToken == token then
			frame.Visible = false
		end
	end)
end

-- Covers, waits `seconds`, then uncovers (unless something else re-covered meanwhile).
function TransitionController.Flash(seconds: number)
	TransitionController.Cover()
	local token = coverToken
	task.delay(seconds, function()
		if coverToken == token then
			TransitionController.Uncover()
		end
	end)
end

local function onPhaseChanged()
	local phase = MatchClient.GetPhase()
	local involved = MatchClient.IsInMatchFlow()
	if phase == "Loading" and involved then
		TransitionController.Cover()
	elseif phase == "Intro" then
		TransitionController.Uncover()
	elseif phase == "Winner" and involved then
		TransitionController.Flash(WINNER_UNCOVER_DELAY)
	end
end

function TransitionController.Init()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	local gui: ScreenGui = Ui.new("ScreenGui", {
		Name = "Transition",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		DisplayOrder = 50,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		Parent = playerGui,
	})
	-- Oversized and tilted so the edges never show while it slides.
	local frame: Frame = Ui.new("Frame", {
		Name = "Wipe",
		Size = UDim2.fromScale(1.6, 1.6),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = HIDDEN_BELOW,
		Rotation = -6,
		BackgroundColor3 = Theme.Colors.White,
		BorderSizePixel = 0,
		Visible = false,
		Parent = gui,
	})
	Ui.new("UIGradient", {
		Color = ColorSequence.new(Theme.Colors.Pink, Theme.Colors.Purple),
		Rotation = 90,
		Parent = frame,
	})
	local logo = Ui.label(
		frame,
		"WOBBLE RUSH",
		Theme.Fonts.Display,
		Theme.Colors.White,
		UDim2.fromScale(0.4, 0.08),
		UDim2.fromScale(0.5, 0.5),
		Vector2.new(0.5, 0.5)
	)
	logo.Rotation = 6
	Ui.new("UIStroke", {
		Color = Theme.Colors.Ink,
		Thickness = 4,
		Transparency = 0.4,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual,
		Parent = logo,
	})
	wipe = frame

	MatchClient.Changed:Connect(function(name: string)
		if name == Match.Attr.Phase then
			onPhaseChanged()
		end
	end)
	-- In case our status arrives just after the Loading phase did.
	MatchClient.LocalChanged:Connect(function(name: string)
		if name == Match.PlayerAttr.Status and MatchClient.GetPhase() == "Loading" and MatchClient.IsInMatchFlow() then
			TransitionController.Cover()
		end
	end)
end

return TransitionController
