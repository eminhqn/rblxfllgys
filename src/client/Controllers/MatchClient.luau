--!strict
-- This client's view of the match. Reads the MatchState folder's attributes and the local
-- player's match attributes (both written only by the server) and tells UI modules when they
-- change. See Shared/Match for what each attribute means.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local Match = require(Shared.Match)
local Signal = require(Shared.Signal)

local MatchClient = {}

MatchClient.Changed = Signal.new() :: Signal.Signal<string> -- a MatchState attribute changed
MatchClient.LocalChanged = Signal.new() :: Signal.Signal<string> -- a local player attribute changed

local localPlayer = Players.LocalPlayer
local folder: Folder? = nil

function MatchClient.Get(key: string): any
	local stateFolder = folder
	return if stateFolder then stateFolder:GetAttribute(key) else nil
end

function MatchClient.GetString(key: string): string
	local value = MatchClient.Get(key)
	return if typeof(value) == "string" then value else ""
end

function MatchClient.GetNumber(key: string): number
	local value = MatchClient.Get(key)
	return if typeof(value) == "number" then value else 0
end

function MatchClient.GetPhase(): Match.Phase
	local phase = MatchClient.GetString(Match.Attr.Phase)
	return (if phase == "" then "Idle" else phase) :: Match.Phase
end

function MatchClient.GetStatus(): Match.Status
	local status = localPlayer:GetAttribute(Match.PlayerAttr.Status)
	return (if typeof(status) == "string" then status else "None") :: Match.Status
end

function MatchClient.IsQueued(): boolean
	return localPlayer:GetAttribute(Match.PlayerAttr.Queued) == true
end

-- Still competing in the current match.
function MatchClient.IsCompeting(): boolean
	return localPlayer:GetAttribute(Match.PlayerAttr.InMatch) == true
end

-- Taking part in the current match in any way (competing, spectating after being knocked out,
-- or celebrating the win).
function MatchClient.IsInMatchFlow(): boolean
	return MatchClient.GetStatus() ~= "None"
end

function MatchClient.GetSpectatingUserId(): number
	local value = localPlayer:GetAttribute(Match.PlayerAttr.Spectating)
	return if typeof(value) == "number" then value else 0
end

function MatchClient.ServerTime(): number
	return Workspace:GetServerTimeNow()
end

-- Seconds until the current phase ends (0 when the phase has no timer).
function MatchClient.TimeLeft(): number
	local endsAt = MatchClient.GetNumber(Match.Attr.PhaseEndsAt)
	if endsAt <= 0 then
		return 0
	end
	return math.max(0, endsAt - Workspace:GetServerTimeNow())
end

function MatchClient.Init()
	local stateFolder = Match.GetFolder()
	folder = stateFolder
	stateFolder.AttributeChanged:Connect(function(name: string)
		MatchClient.Changed:Fire(name)
	end)
	localPlayer.AttributeChanged:Connect(function(name: string)
		MatchClient.LocalChanged:Fire(name)
	end)
end

return MatchClient
