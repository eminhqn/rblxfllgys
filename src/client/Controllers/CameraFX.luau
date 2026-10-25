--!strict
-- Camera shake for big hits and hard landings, and turning the camera to look along the course
-- whenever the server places us somewhere new (round start, race respawn).
--
-- The default Roblox camera reads the current camera orientation each frame, so a shake offset
-- added after it would build up over time. We remove last frame's offset just before the camera
-- updates and apply a fresh one just after.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local MathUtil = require(ReplicatedStorage.Shared.MathUtil)

local ClientEvents = require(script.Parent.ClientEvents)

local CameraFX = {}

local HARD_LANDING_SPEED = 75
local TRAUMA_DECAY = 1.6 -- per second
local MAX_OFFSET = 0.9 -- studs
local MAX_ANGLE = 0.06 -- radians

local SNAP_PITCH = math.rad(16) -- looking slightly down at your Bloblet
local SNAP_MIN_DISTANCE = 14
local FOCUS_HEIGHT = 1.5 -- above the root

local trauma = 0
local appliedOffset: CFrame? = nil
local snapPending = false

-- Adds shake. `amount` is 0-1; it stacks up to 1 and fades out on its own.
function CameraFX.Shake(amount: number)
	trauma = math.clamp(trauma + amount, 0, 1)
end

-- Turns the camera to look over the Bloblet's shoulder on the next frame (keeping the zoom).
function CameraFX.SnapBehind()
	snapPending = true
end

-- Where the camera sits behind a Bloblet whose root is at `root`, `distance` studs away: the same
-- angle SnapBehind uses.
function CameraFX.BehindPose(root: CFrame, distance: number): CFrame?
	local look = MathUtil.flat(root.LookVector)
	if look.Magnitude < 1e-3 then
		return nil
	end
	local focus = root.Position + Vector3.new(0, FOCUS_HEIGHT, 0)
	local direction = look.Unit * math.cos(SNAP_PITCH) - Vector3.yAxis * math.sin(SNAP_PITCH)
	return CFrame.lookAt(focus - direction * math.max(distance, SNAP_MIN_DISTANCE), focus)
end

-- How far the camera is from what it's looking at (the player's zoom), at least SNAP_MIN_DISTANCE.
function CameraFX.GetZoom(): number
	local camera = Workspace.CurrentCamera
	if not camera then
		return SNAP_MIN_DISTANCE
	end
	return math.max((camera.CFrame.Position - camera.Focus.Position).Magnitude, SNAP_MIN_DISTANCE)
end

function CameraFX.Init()
	RunService:BindToRenderStep("WobbleShakeUndo", Enum.RenderPriority.Camera.Value - 1, function()
		local camera = Workspace.CurrentCamera
		local offset = appliedOffset
		if camera and offset then
			camera.CFrame *= offset:Inverse()
		end
		appliedOffset = nil
	end)

	RunService:BindToRenderStep("WobbleShakeApply", Enum.RenderPriority.Camera.Value + 1, function(dt: number)
		local camera = Workspace.CurrentCamera
		if trauma <= 0 or not camera then
			return
		end
		trauma = math.max(0, trauma - dt * TRAUMA_DECAY)
		local intensity = trauma * trauma
		local t = os.clock() * 18
		local offset = CFrame.new(
			math.noise(t, 0, 1) * intensity * MAX_OFFSET,
			math.noise(t, 0, 2) * intensity * MAX_OFFSET,
			0
		) * CFrame.Angles(
			math.noise(t, 0, 3) * intensity * MAX_ANGLE,
			math.noise(t, 0, 4) * intensity * MAX_ANGLE,
			math.noise(t, 0, 5) * intensity * MAX_ANGLE
		)
		camera.CFrame *= offset
		appliedOffset = offset
	end)

	-- After the default camera has updated: put the camera behind the Bloblet, keeping the zoom.
	-- The default camera carries on from whatever angle we leave it at.
	RunService:BindToRenderStep("WobbleCameraSnap", Enum.RenderPriority.Camera.Value + 2, function()
		if not snapPending then
			return
		end
		snapPending = false
		local camera = Workspace.CurrentCamera
		local character = Players.LocalPlayer.Character
		local root = if character then character.PrimaryPart else nil
		if not camera or not root or camera.CameraType ~= Enum.CameraType.Custom then
			return
		end
		local pose = CameraFX.BehindPose(root.CFrame, CameraFX.GetZoom())
		if not pose then
			return
		end
		camera.CFrame = pose
		appliedOffset = nil -- replaced, so there's no shake to undo next frame
	end)

	ClientEvents.Teleported:Connect(function()
		snapPending = true
	end)

	ClientEvents.KnockedDown:Connect(function(strength: number)
		CameraFX.Shake(0.35 + strength * 0.45)
	end)
	ClientEvents.Landed:Connect(function(impactSpeed: number)
		if impactSpeed > HARD_LANDING_SPEED then
			CameraFX.Shake(math.clamp((impactSpeed - HARD_LANDING_SPEED) / 80, 0.1, 0.35))
		end
	end)
end

return CameraFX
