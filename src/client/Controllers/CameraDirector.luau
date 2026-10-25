--!strict
-- Two short camera moments, after which the normal camera carries on:
--   * Round intro: while the round card and the 3-2-1 show, the camera starts high over the far
--     end of the arena and glides back across it, settling behind your Bloblet just before GO!
--   * Winner: after the match, the camera swings round the lobby podium to show off the winner
--     while the fireworks go off.
-- Pressing jump skips either one. Only players taking part get them: people waiting in the lobby
-- keep their camera, and spectators keep watching whoever they're watching until the match ends.
-- Players can turn both off in the settings, and Config.Cinematics switches each one off for
-- everyone.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local BlobletRig = require(Shared.BlobletRig)
local Config = require(Shared.Config)
local Match = require(Shared.Match)
local MathUtil = require(Shared.MathUtil)
local Theme = require(Shared.Theme)
local Ui = require(Shared.Ui)

local CameraFX = require(script.Parent.CameraFX)
local ClientSettings = require(script.Parent.ClientSettings)
local Input = require(script.Parent.InputController)
local MatchClient = require(script.Parent.MatchClient)
local ResponsiveScale = require(script.Parent.ResponsiveScale)

local CameraDirector = {}

type Shot = {
	StartsAt: number, -- server time
	EndsAt: number, -- server time
	Pose: (alpha: number, dt: number) -> CFrame, -- alpha goes 0 -> 1 over the shot
}

local Attr = Match.Attr
local CINEMATICS = Config.Cinematics

local MIN_SHOT_TIME = 1.5 -- don't bother with a shot shorter than this (e.g. joining late)

-- Intro glide.
local REACH_MIN, REACH_MAX = 40, 420 -- how far ahead of you the glide starts
local START_BACK = 36 -- the camera starts this far behind the point it looks at...
local START_HEIGHT_MIN, START_HEIGHT_MAX = 34, 80 -- ...and this high above it
local SWAY_MAX = 16 -- sideways drift in the middle of the glide

-- Winner orbit.
local WINNER_START_DELAY = 0.4 -- the transition wipe has covered the screen by then
local WINNER_END_EARLY = 0.5
local WINNER_SWING = math.rad(65) -- swings from one side of the winner to the other
local WINNER_RADIUS_START, WINNER_RADIUS_END = 30, 13
local WINNER_HEIGHT_START, WINNER_HEIGHT_END = 12, 4
local WINNER_FOLLOW_RANGE = 25 -- follow the winner while they're this close to the podium

local localPlayer = Players.LocalPlayer
local shot: Shot? = nil
local ownsCamera = false
local skipHint: TextLabel

local function serverNow(): number
	return Workspace:GetServerTimeNow()
end

local function smoothstep(t: number): number
	return t * t * (3 - 2 * t)
end

local function easeInOutSine(t: number): number
	return (1 - math.cos(t * math.pi)) / 2
end

local function easeOutCubic(t: number): number
	return 1 - (1 - t) ^ 3
end

local function localRoot(): BasePart?
	local character = localPlayer.Character
	return if character then character.PrimaryPart else nil
end

-- From high over the far end of the arena, back across it to just behind our Bloblet.
local function introShot(): Shot?
	local root = localRoot()
	local center = MatchClient.Get(Attr.ArenaCenter)
	local size = MatchClient.Get(Attr.ArenaSize)
	if not root or typeof(center) ~= "Vector3" or typeof(size) ~= "Vector3" then
		return nil
	end
	local now = serverNow()
	local endsAt = MatchClient.GetNumber(Attr.PhaseEndsAt) - CINEMATICS.SettleBeforeGo
	if endsAt - now < MIN_SHOT_TIME then
		return nil
	end
	local zoom = CameraFX.GetZoom()
	local final = CameraFX.BehindPose(root.CFrame, zoom)
	local flatLook = MathUtil.flat(root.CFrame.LookVector)
	if not final or flatLook.Magnitude < 1e-3 then
		return nil
	end
	local forward = flatLook.Unit
	local right = forward:Cross(Vector3.yAxis)
	local position = root.Position

	-- How far the arena reaches ahead of us (spawns face along a course, or into the middle).
	local reach = (center - position):Dot(forward) + math.abs(forward.X) * size.X / 2 + math.abs(forward.Z) * size.Z / 2
	reach = math.clamp(reach, REACH_MIN, REACH_MAX)
	-- Level with us, or with the middle of the arena if that's higher (a race that climbs).
	local far = Vector3.new(position.X, math.max(position.Y, center.Y), position.Z) + forward * reach
	local finalFocus = final.Position + final.LookVector * zoom
	local finalBack = final.Position - finalFocus
	local startBack = -forward * START_BACK
		+ Vector3.yAxis * math.clamp(size.Y * 0.25 + START_HEIGHT_MIN, START_HEIGHT_MIN, START_HEIGHT_MAX)
	local sway = math.min(reach * 0.12, SWAY_MAX) * (if math.random() < 0.5 then -1 else 1)

	return {
		StartsAt = now,
		EndsAt = endsAt,
		Pose = function(alpha: number): CFrame
			local target = far:Lerp(finalFocus, easeInOutSine(alpha))
			local offset = startBack:Lerp(finalBack, smoothstep(alpha))
			local drift = right * math.sin(alpha * math.pi) * sway
			return CFrame.lookAt(target + offset + drift, target)
		end,
	}
end

-- Where to point the winner orbit: the winner if they're on the podium, else the podium itself.
local function winnerFocus(spot: CFrame, winnerId: number): Vector3
	local winner = Players:GetPlayerByUserId(winnerId)
	local character = if winner then winner.Character else nil
	local root = if character then character.PrimaryPart else nil
	if root and (root.Position - spot.Position).Magnitude < WINNER_FOLLOW_RANGE then
		return root.Position + Vector3.new(0, 1, 0)
	end
	return spot.Position + Vector3.new(0, BlobletRig.Dimensions.RootHeight + 1, 0)
end

-- A slow swing round the podium, moving in close.
local function winnerShot(): Shot?
	local spot = MatchClient.Get(Attr.WinnerSpot)
	local winnerId = MatchClient.GetNumber(Attr.WinnerUserId)
	if typeof(spot) ~= "CFrame" or winnerId == 0 then
		return nil
	end
	local startsAt = serverNow() + WINNER_START_DELAY
	local endsAt = MatchClient.GetNumber(Attr.PhaseEndsAt) - WINNER_END_EARLY
	local flatFacing = MathUtil.flat(spot.LookVector)
	if endsAt - startsAt < MIN_SHOT_TIME or flatFacing.Magnitude < 1e-3 then
		return nil
	end
	local facing = flatFacing.Unit
	local focus: Vector3? = nil

	return {
		StartsAt = startsAt,
		EndsAt = endsAt,
		Pose = function(alpha: number, dt: number): CFrame
			-- Follow the winner smoothly (they hop about while they cheer).
			local target = winnerFocus(spot, winnerId)
			local current = focus
			focus = if current then target + (current - target) * math.exp(-6 * dt) else target
			local center = focus or target
			local approach = easeOutCubic(math.min(alpha * 1.6, 1))
			local radius = WINNER_RADIUS_START + (WINNER_RADIUS_END - WINNER_RADIUS_START) * approach
			local height = WINNER_HEIGHT_START + (WINNER_HEIGHT_END - WINNER_HEIGHT_START) * approach
			local turn = (easeInOutSine(alpha) * 2 - 1) * WINNER_SWING
			local direction = CFrame.Angles(0, turn, 0):VectorToWorldSpace(facing)
			return CFrame.lookAt(center + direction * radius + Vector3.yAxis * height, center)
		end,
	}
end

-- Hands the camera back to the normal follow camera, behind our Bloblet.
local function finish()
	shot = nil
	skipHint.Visible = false
	if ownsCamera then
		ownsCamera = false
		local camera = Workspace.CurrentCamera
		if camera then
			camera.CameraType = Enum.CameraType.Custom
		end
		CameraFX.SnapBehind()
	end
end

local function begin(newShot: Shot?)
	finish()
	shot = newShot
end

local function onRender(dt: number)
	local current = shot
	local camera = Workspace.CurrentCamera
	if not current or not camera then
		return
	end
	local now = serverNow()
	if now < current.StartsAt then
		return
	end
	local alpha = (now - current.StartsAt) / math.max(current.EndsAt - current.StartsAt, 1e-3)
	if alpha >= 1 then
		finish()
		return
	end
	if not ownsCamera then
		ownsCamera = true
		skipHint.Visible = true
		Ui.popIn(skipHint)
	end
	if camera.CameraType ~= Enum.CameraType.Scriptable then
		camera.CameraType = Enum.CameraType.Scriptable -- again if a respawn handed it back to Roblox
	end
	local pose = current.Pose(math.clamp(alpha, 0, 1), dt)
	camera.CFrame = pose
	camera.Focus = CFrame.new(pose.Position + pose.LookVector * 20)
end

local function onPhaseChanged()
	local phase = MatchClient.GetPhase()
	local wanted = ClientSettings.Get().CameraMoments
	if phase == "Intro" then
		local competing = MatchClient.IsCompeting() and MatchClient.GetStatus() == "Playing"
		begin(if CINEMATICS.IntroFlyover and wanted and competing then introShot() else nil)
	elseif phase == "Winner" then
		begin(if CINEMATICS.WinnerOrbit and wanted and MatchClient.IsInMatchFlow() then winnerShot() else nil)
	else
		begin(nil)
	end
end

-- True while a camera moment has the camera (other modules leave it alone meanwhile).
function CameraDirector.IsActive(): boolean
	return ownsCamera
end

function CameraDirector.Init()
	local gui: ScreenGui = Ui.new("ScreenGui", {
		Name = "CameraDirector",
		ResetOnSpawn = false,
		IgnoreGuiInset = false,
		DisplayOrder = 9,
		Parent = localPlayer:WaitForChild("PlayerGui"),
	})
	-- The holder scales with the screen; the label inside pops in.
	local holder: Frame = Ui.new("Frame", {
		Name = "SkipHint",
		Size = UDim2.fromOffset(220, 26),
		Position = UDim2.new(0.5, 0, 1, -18),
		AnchorPoint = Vector2.new(0.5, 1),
		BackgroundTransparency = 1,
		Parent = gui,
	})
	ResponsiveScale.Attach(holder, "Hud")
	skipHint = Ui.label(
		holder,
		"JUMP TO SKIP",
		Theme.Fonts.Display,
		Theme.Colors.White,
		UDim2.fromScale(1, 1),
		UDim2.fromScale(0.5, 0.5),
		Vector2.new(0.5, 0.5)
	)
	skipHint.TextTransparency = 0.15
	skipHint.Visible = false
	Ui.stroke(skipHint, Theme.Colors.Ink, 2, 0.3)

	RunService:BindToRenderStep("WobbleCameraDirector", Enum.RenderPriority.Camera.Value, onRender)
	MatchClient.Changed:Connect(function(name: string)
		if name == Attr.Phase then
			onPhaseChanged()
		end
	end)
	Input.JumpPressed:Connect(function()
		if shot then
			finish()
		end
	end)
	ClientSettings.Changed:Connect(function(settings)
		if not settings.CameraMoments and shot then
			finish()
		end
	end)
	onPhaseChanged()
end

return CameraDirector
