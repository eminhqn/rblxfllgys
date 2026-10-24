--!strict
-- Camera shake for big hits and hard landings.
--
-- The default Roblox camera reads the current camera orientation each frame, so a shake offset
-- added after it would build up over time. We remove last frame's offset just before the camera
-- updates and apply a fresh one just after.

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local ClientEvents = require(script.Parent.ClientEvents)

local CameraFX = {}

local HARD_LANDING_SPEED = 75
local TRAUMA_DECAY = 1.6 -- per second
local MAX_OFFSET = 0.9 -- studs
local MAX_ANGLE = 0.06 -- radians

local trauma = 0
local appliedOffset: CFrame? = nil

-- Adds shake. `amount` is 0-1; it stacks up to 1 and fades out on its own.
function CameraFX.Shake(amount: number)
	trauma = math.clamp(trauma + amount, 0, 1)
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
