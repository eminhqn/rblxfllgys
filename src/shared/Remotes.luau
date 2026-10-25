--!strict
-- Every RemoteEvent and RemoteFunction lives in ReplicatedStorage.Remotes. The server creates
-- them all at startup (before parenting the folder, so clients see the complete set at once);
-- clients wait for them.
--
-- Clients can send anything through a remote, so every OnServerEvent handler must check argument
-- types, reject NaN/inf values, rate-limit, and decide the outcome itself.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

export type EventName =
	"RequestDive" -- client -> server (direction: Vector3)
	| "RequestGrab" -- client -> server ()
	| "RequestRelease" -- client -> server ()
	| "EndDive" -- client -> server (), the local dive/slide finished or was cancelled
	| "RequestKick" -- client -> server ()
	| "ReportKnockdown" -- client -> server (strength: number 0-1), the client was hit by a hazard
	| "RequestRespawn" -- client -> server (), used by the Reset Character menu button
	| "RequestQueue" -- client -> server (wantsToPlay: boolean), the PLAY / CANCEL button
	| "RequestSpectate" -- client -> server (direction: number), -1 previous / 1 next player
	| "RequestReturnToLobby" -- client -> server (), stop spectating
	| "ActionRejected" -- server -> client (action: string)
	| "ApplyRagdoll" -- server -> client (impulse: Vector3, duration: number)
	| "RequestEquip" -- client -> server (slot: string, itemId: string), customise screen
	| "RequestEmote" -- client -> server (), plays the emote the player has equipped

-- client -> server (itemId: string), returns (ok: boolean, message: string)
export type FunctionName = "RequestPurchase"

local EVENT_NAMES: { EventName } = {
	"RequestDive",
	"RequestGrab",
	"RequestRelease",
	"EndDive",
	"RequestKick",
	"ReportKnockdown",
	"RequestRespawn",
	"RequestQueue",
	"RequestSpectate",
	"RequestReturnToLobby",
	"ActionRejected",
	"ApplyRagdoll",
	"RequestEquip",
	"RequestEmote",
}

local FUNCTION_NAMES: { FunctionName } = {
	"RequestPurchase",
}

local FOLDER_NAME = "Remotes"

local Remotes = {}

local folder: Folder? = nil

local function createFolder(): Folder
	local newFolder = Instance.new("Folder")
	newFolder.Name = FOLDER_NAME
	for _, name in EVENT_NAMES do
		local event = Instance.new("RemoteEvent")
		event.Name = name
		event.Parent = newFolder
	end
	for _, name in FUNCTION_NAMES do
		local remote = Instance.new("RemoteFunction")
		remote.Name = name
		remote.Parent = newFolder
	end
	newFolder.Parent = ReplicatedStorage
	return newFolder
end

local function getFolder(): Folder
	local cached = folder
	if cached then
		return cached
	end
	local resolved: Folder
	if RunService:IsServer() then
		local existing = ReplicatedStorage:FindFirstChild(FOLDER_NAME)
		resolved = if existing and existing:IsA("Folder") then existing else createFolder()
	else
		resolved = ReplicatedStorage:WaitForChild(FOLDER_NAME) :: Folder
	end
	folder = resolved
	return resolved
end

function Remotes.Event(name: EventName): RemoteEvent
	local event = getFolder():WaitForChild(name)
	assert(event:IsA("RemoteEvent"), `Remote {name} is not a RemoteEvent`)
	return event
end

function Remotes.Function(name: FunctionName): RemoteFunction
	local remote = getFolder():WaitForChild(name)
	assert(remote:IsA("RemoteFunction"), `Remote {name} is not a RemoteFunction`)
	return remote
end

-- Call once from the server entry point so the folder exists before any player joins.
function Remotes.Setup()
	assert(RunService:IsServer(), "Remotes.Setup must run on the server")
	getFolder()
end

return Remotes
