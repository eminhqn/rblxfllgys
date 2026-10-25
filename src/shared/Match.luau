--!strict
-- Names shared by the server's MatchService and the client UI.
--
-- Match state is published as attributes on ReplicatedStorage.MatchState (plus a few attributes on
-- each Player). Attributes replicate automatically, so a player who joins or streams in mid-match
-- always sees the current state, and the UI just reacts to attribute changes.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

export type Phase =
	"Idle" -- nothing happening, waiting for enough players to press PLAY
	| "Queue" -- enough players queued, counting down to the match
	| "Loading" -- screens cover while the next arena is built and players are moved
	| "Intro" -- round card and 3-2-1 countdown, players frozen
	| "Playing"
	| "RoundOver"
	| "Winner"

export type Status = "None" | "Playing" | "Qualified" | "Eliminated" | "Winner"

export type RoundType = "Race" | "Survival" | "Team" | "Final"

local Match = {}

Match.FolderName = "MatchState"

-- Set (true) on ReplicatedStorage in the temporary holding server used during an update (the
-- server's SoftShutdown); clients there only show the updating screen.
Match.HoldingServerAttribute = "WobbleHoldingServer"

-- Attributes on the ReplicatedStorage.MatchState folder.
Match.Attr = table.freeze({
	Phase = "Phase",
	PhaseEndsAt = "PhaseEndsAt", -- workspace:GetServerTimeNow() when the phase ends, 0 = no timer
	QueueCount = "QueueCount",
	QueueMin = "QueueMin",
	QueueMax = "QueueMax",
	RoundNumber = "RoundNumber",
	RoundName = "RoundName",
	RoundType = "RoundType",
	RoundRules = "RoundRules",
	CounterText = "CounterText", -- e.g. "QUALIFIED 3 / 7"
	-- Team rounds: JSON {"Total": n?, "Scores": [{"Id": "Coral", "Score": 12}, ...]}, "" = none
	TeamScores = "TeamScores",
	-- A pop-up for everyone in the match, e.g. "CORAL SCORES!": JSON {"Text", "Team"?, "At"}, "" = none
	Announcement = "Announcement",
	PlayersInMatch = "PlayersInMatch",
	WinnerName = "WinnerName",
	WinnerUserId = "WinnerUserId",
	WinnerSpot = "WinnerSpot", -- CFrame: the top of the lobby podium, facing the crowd
	-- The current round's arena (its bounding box), for the clients' intro camera. Unset between rounds.
	ArenaCenter = "ArenaCenter", -- Vector3
	ArenaSize = "ArenaSize", -- Vector3
	ParkourCheckpoints = "ParkourCheckpoints", -- how many checkpoints the lobby parkour has
})

-- Attributes on each Player.
Match.PlayerAttr = table.freeze({
	Status = "MatchStatus", -- Status
	InMatch = "InMatch", -- still competing (not eliminated)
	Queued = "Queued",
	Spectating = "SpectatingUserId", -- who you are watching, 0 = nobody
	Checkpoint = "RaceCheckpoint", -- race rounds: the furthest checkpoint reached (0 = start)
	-- Saved profile (DataService), for this player's own UI:
	Crowns = "Crowns", -- spent on items
	Gumdrops = "Gumdrops", -- earned by playing, traded for Crowns
	Owned = "OwnedItems", -- JSON array of bought item ids
	Equipped = "EquippedItems", -- JSON object: slot -> item id
	-- JSON object: Matches, Wins, RoundsPlayed, RoundsQualified, GumdropsEarned, TimeSurvived
	Stats = "Stats",
	Settings = "Settings", -- JSON object: Shared/PlayerSettings
	XP = "XP", -- total XP earned (the level comes from it: Shared/Progression)
	Daily = "DailyChallenges", -- JSON: {"Day", "NextReset", "Challenges": [{"Id", "Progress", "Done"}]}
	DataReady = "DataReady", -- the profile has loaded
	DataSaving = "DataSaving", -- false if progress can't be saved this session
	ParkourDone = "ParkourDone", -- has finished the lobby parkour at least once
	ParkourBest = "ParkourBest", -- best parkour time in seconds, 0 = never finished
	-- Your best parkour time on day ParkourDay (see Shared/Leaderboards' ParkourToday board).
	ParkourDay = "ParkourDay",
	ParkourDayBest = "ParkourDayBest", -- seconds, 0 = none
	-- The parkour run in progress (ParkourService): -1 = not on the course, 0 = on the start pad
	-- or past it, then the checkpoint reached.
	ParkourStage = "ParkourStage",
	ParkourStartedAt = "ParkourStartedAt", -- server time the run's clock started, 0 = not running
	-- Social (FriendService, PartyService):
	FriendsHere = "FriendsHere", -- how many of your Roblox friends are in this server
	Party = "PartyId", -- the party you're in, "" = none
	-- This team round your party is on different teams, so the teams are even (unset otherwise).
	PartySplit = "PartySplit",
})

Match.TypeLabels = table.freeze({
	Race = "RACE",
	Survival = "SURVIVAL",
	Team = "TEAM",
	Final = "FINAL",
})

local folder: Folder? = nil

-- The MatchState folder (created by the server, waited for on clients).
function Match.GetFolder(): Folder
	local cached = folder
	if cached then
		return cached
	end
	local resolved: Folder
	if RunService:IsServer() then
		local existing = ReplicatedStorage:FindFirstChild(Match.FolderName)
		if existing and existing:IsA("Folder") then
			resolved = existing
		else
			resolved = Instance.new("Folder")
			resolved.Name = Match.FolderName
			resolved.Parent = ReplicatedStorage
		end
	else
		resolved = ReplicatedStorage:WaitForChild(Match.FolderName) :: Folder
	end
	folder = resolved
	return resolved
end

function Match.IsRoundType(value: unknown): boolean
	return value == "Race" or value == "Survival" or value == "Team" or value == "Final"
end

return table.freeze(Match)
