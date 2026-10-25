--!strict
-- Client entry point.

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")
local UserInputService = game:GetService("UserInputService")

if not game:IsLoaded() then
	game.Loaded:Wait()
end

local Remotes = require(ReplicatedStorage.Shared.Remotes)

local Controllers = script.Parent.Controllers
local BlobletAnimator = require(Controllers.BlobletAnimator)
local CameraDirector = require(Controllers.CameraDirector)
local CameraFX = require(Controllers.CameraFX)
local Celebration = require(Controllers.Celebration)
local CustomiseController = require(Controllers.CustomiseController)
local Effects = require(Controllers.Effects)
local EmoteController = require(Controllers.EmoteController)
local HazardController = require(Controllers.HazardController)
local Hud = require(Controllers.Hud)
local InputController = require(Controllers.InputController)
local MatchClient = require(Controllers.MatchClient)
local MenuController = require(Controllers.MenuController)
local MovementController = require(Controllers.MovementController)
local ProfileClient = require(Controllers.ProfileClient)
local ResponsiveScale = require(Controllers.ResponsiveScale)
local RoundHud = require(Controllers.RoundHud)
local Sfx = require(Controllers.Sfx)
local SpectateController = require(Controllers.SpectateController)
local TeamOutlines = require(Controllers.TeamOutlines)
local TouchControls = require(Controllers.TouchControls)
local TransitionController = require(Controllers.TransitionController)
local WalletHud = require(Controllers.WalletHud)

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
-- The default controls re-enable themselves when the input device changes (keyboard -> gamepad).
UserInputService.LastInputTypeChanged:Connect(function()
	task.defer(disableDefaultControls)
end)

pcall(function()
	StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, false)
	StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Health, false)
end)

ResponsiveScale.Init()
InputController.Init()
ProfileClient.Init()
MovementController.Init()
EmoteController.Init()
BlobletAnimator.Init()
Effects.Init()
HazardController.Init()
TeamOutlines.Init()
CameraFX.Init()
Sfx.Init()
TouchControls.Init()
MatchClient.Init()
TransitionController.Init()
CameraDirector.Init()
Celebration.Init()
Hud.Init()
MenuController.Init()
RoundHud.Init()
WalletHud.Init()
CustomiseController.Init()
SpectateController.Init()

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
