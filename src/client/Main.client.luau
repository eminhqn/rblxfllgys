--!strict
-- Client entry point.

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")

if not game:IsLoaded() then
	game.Loaded:Wait()
end

local Remotes = require(ReplicatedStorage.Shared.Remotes)

local Controllers = script.Parent.Controllers
local BlobletAnimator = require(Controllers.BlobletAnimator)
local CameraFX = require(Controllers.CameraFX)
local HazardController = require(Controllers.HazardController)
local Hud = require(Controllers.Hud)
local InputController = require(Controllers.InputController)
local MovementController = require(Controllers.MovementController)
local ResponsiveScale = require(Controllers.ResponsiveScale)
local Sfx = require(Controllers.Sfx)
local TeamOutlines = require(Controllers.TeamOutlines)
local TouchControls = require(Controllers.TouchControls)

local localPlayer = Players.LocalPlayer

-- We read input ourselves (InputController), so switch off Roblox's default movement controls
-- and their on-screen thumbstick/jump button. The default camera stays.
local function disableDefaultControls()
	local playerScripts = localPlayer:WaitForChild("PlayerScripts")
	local playerModule = playerScripts:WaitForChild("PlayerModule", 10)
	if playerModule and playerModule:IsA("ModuleScript") then
		local ok, err = pcall(function()
			local module: any = (require :: any)(playerModule)
			module:GetControls():Disable()
		end)
		if not ok then
			warn(`[Client] Could not disable default controls: {err}`)
		end
	end
end

GuiService.TouchControlsEnabled = false
disableDefaultControls()
localPlayer.CharacterAdded:Connect(function()
	task.defer(disableDefaultControls)
end)

pcall(function()
	StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, false)
	StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Health, false)
end)

ResponsiveScale.Init()
InputController.Init()
MovementController.Init()
BlobletAnimator.Init()
HazardController.Init()
TeamOutlines.Init()
CameraFX.Init()
Sfx.Init()
TouchControls.Init()
Hud.Init()

-- "Reset Character" in the Roblox menu asks the server for a fresh Bloblet instead of killing it.
local resetRequested = Instance.new("BindableEvent")
resetRequested.Event:Connect(function()
	Remotes.Event("RequestRespawn"):FireServer()
end)
task.spawn(function()
	for _ = 1, 20 do
		local ok = pcall(function()
			StarterGui:SetCore("ResetButtonCallback", resetRequested)
		end)
		if ok then
			return
		end
		task.wait(0.5)
	end
end)
