--!strict
-- World-wide visual settings that can't be expressed in default.project.json
-- (lighting, atmosphere and post effects live there).

local Workspace = game:GetService("Workspace")

local EnvironmentService = {}

function EnvironmentService.Init()
	local terrain = Workspace.Terrain
	local clouds = terrain:FindFirstChildOfClass("Clouds") or Instance.new("Clouds")
	clouds.Cover = 0.58
	clouds.Density = 0.72
	clouds.Color = Color3.fromRGB(255, 255, 255)
	clouds.Parent = terrain
end

return EnvironmentService
