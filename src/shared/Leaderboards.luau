--!strict
-- The lobby's three leaderboards: most wins, most Gumdrops collected (all time, not what you have
-- now) and most time survived (every second you've stayed in survival rounds and finals). Plus
-- the parkour tower's FASTEST TODAY board (ParkourToday): today's quickest finishes, fastest
-- first, starting again every day; its JSON also has "Day" (the day number), "NextReset" (server
-- time it starts again) and "Prize" (Gumdrops for the day's fastest).
--
-- The server (LeaderboardService) keeps each board's top players as a JSON attribute on the
-- ReplicatedStorage.Leaderboards folder:
--   {"Saved": true, "Entries": [{"U": userId, "N": "display name", "V": value}, ...]}
-- best first. "Saved" is false when the saved boards can't be read (e.g. Studio without API
-- access): the board then shows the players in this server. Clients draw the boards
-- (LeaderboardController).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

export type BoardId = "Wins" | "Gumdrops" | "Survived" | "ParkourToday"

export type Board = {
	Id: BoardId,
	Title: string,
	Stat: string, -- the profile stat it ranks (DataService Stats); "" for the parkour board
	Color: Color3,
}

export type Entry = {
	UserId: number,
	Name: string,
	Value: number,
}

local Leaderboards = {}

Leaderboards.FolderName = "Leaderboards"

local BOARDS: { Board } = {
	{ Id = "Wins", Title = "MOST WINS", Stat = "Wins", Color = Color3.fromRGB(255, 190, 40) },
	{ Id = "Gumdrops", Title = "GUMDROPS COLLECTED", Stat = "GumdropsEarned", Color = Color3.fromRGB(255, 92, 168) },
	{ Id = "Survived", Title = "TIME SURVIVED", Stat = "TimeSurvived", Color = Color3.fromRGB(40, 196, 210) },
}
for _, board in BOARDS do
	table.freeze(board)
end

Leaderboards.List = table.freeze(BOARDS)

-- Today's fastest parkour finishes (values in hundredths of a second, smallest first).
Leaderboards.ParkourToday = table.freeze({
	Id = "ParkourToday",
	Title = "FASTEST TODAY",
	Stat = "",
	Color = Color3.fromRGB(255, 140, 66),
} :: Board)

function Leaderboards.Get(id: string): Board?
	for _, board in Leaderboards.List do
		if board.Id == id then
			return board
		end
	end
	return if id == "ParkourToday" then Leaderboards.ParkourToday else nil
end

-- 83.4 seconds -> "1:23.40"
function Leaderboards.FormatTime(seconds: number): string
	local hundredths = math.max(0, math.floor(seconds * 100 + 0.5))
	return string.format("%d:%05.2f", hundredths // 6000, (hundredths % 6000) / 100)
end

-- 1234567 -> "1,234,567"
function Leaderboards.WithCommas(value: number): string
	local text = tostring(math.floor(value))
	local formatted = text
	while true do
		local replaced, count = string.gsub(formatted, "^(-?%d+)(%d%d%d)", "%1,%2")
		formatted = replaced
		if count == 0 then
			break
		end
	end
	return formatted
end

-- How a board shows a score: "1,234" or, for time survived, "3h 12m" / "4m 05s".
function Leaderboards.Format(id: BoardId, value: number): string
	if id == "ParkourToday" then
		return Leaderboards.FormatTime(value / 100)
	elseif id == "Survived" then
		local seconds = math.max(0, math.floor(value))
		local hours = seconds // 3600
		local minutes = (seconds % 3600) // 60
		if hours > 0 then
			return `{Leaderboards.WithCommas(hours)}h {string.format("%02d", minutes)}m`
		end
		return `{minutes}m {string.format("%02d", seconds % 60)}s`
	end
	return Leaderboards.WithCommas(value)
end

local folder: Folder? = nil

-- The folder holding the boards (created by the server, waited for on clients).
function Leaderboards.GetFolder(): Folder
	local cached = folder
	if cached then
		return cached
	end
	local resolved: Folder
	if RunService:IsServer() then
		local existing = ReplicatedStorage:FindFirstChild(Leaderboards.FolderName)
		if existing and existing:IsA("Folder") then
			resolved = existing
		else
			resolved = Instance.new("Folder")
			resolved.Name = Leaderboards.FolderName
			resolved.Parent = ReplicatedStorage
		end
	else
		resolved = ReplicatedStorage:WaitForChild(Leaderboards.FolderName) :: Folder
	end
	folder = resolved
	return resolved
end

return table.freeze(Leaderboards)
