--!strict
-- Plays your equipped emote (G, D-pad up, or the EMOTE button). It starts on your screen straight
-- away and the server tells everyone else (Emote / EmoteAt attributes on your Bloblet). Emotes only
-- start while you're standing on something and fade out if you run off.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Cosmetics = require(Shared.Cosmetics)
local Remotes = require(Shared.Remotes)

local Input = require(script.Parent.InputController)
local MovementController = require(script.Parent.MovementController)
local ProfileClient = require(script.Parent.ProfileClient)

local EmoteController = {}

local localEmote: string? = nil
local localStart = -math.huge

-- The emote this client started for its own Bloblet and how long ago (seconds).
function EmoteController.GetLocal(): (string?, number)
	return localEmote, os.clock() - localStart
end

local function play()
	local pose = MovementController.GetPose()
	if not MovementController.GetRoot() or not pose.Grounded or pose.Diving or pose.Ragdolled then
		return
	end
	local emoteId = ProfileClient.GetEquipped().Emote
	local entry = Cosmetics.Get(emoteId)
	local duration = if entry and entry.Duration then entry.Duration else 1.5
	local now = os.clock()
	if now - localStart < duration then
		return -- let the current one finish
	end
	localEmote = emoteId
	localStart = now
	Remotes.Event("RequestEmote"):FireServer()
end

function EmoteController.Init()
	Input.EmotePressed:Connect(play)
end

return EmoteController
