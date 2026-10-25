--!strict
-- The lobby's three leaderboards: most wins, most Gumdrops collected (all time, not what you have
-- now) and most time survived (every second you've stayed in survival rounds and finals).
--
-- The server (LeaderboardService) keeps each board's top players as a JSON attribute on the
-- ReplicatedStorage.Leaderboards folder:
--   {"Saved": true, "Entries": [{"U": userId, "N": "display name", "V": value}, ...]}
-- best first. "Saved" is false when the saved boards can't be read (e.g. Studio without API
-- access): the board then shows the players in this server. Clients draw the boards
-- (LeaderboardController).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

export type BoardId = "Wins" | "Gumdrops" | "Survived"

export type Board = {
	Id: BoardId,
	Title: string,
	Stat: string, -- the profile stat it ranks (DataService Stats)
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

function Leaderboards.Get(id: string): Board?
	for _, board in Leaderboards.List do
		if board.Id == id then
			return board
		end
	end
	return nil
end

-- 1234567 -> "1,234,567"
local function withCommas(value: number): string
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
	if id == "Survived" then
		local seconds = math.max(0, math.floor(value))
		local hours = seconds // 3600
		local minutes = (seconds % 3600) // 60
		if hours > 0 then
			return `{withCommas(hours)}h {string.format("%02d", minutes)}m`
		end
		return `{minutes}m {string.format("%02d", seconds % 60)}s`
	end
	return withCommas(value)
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
