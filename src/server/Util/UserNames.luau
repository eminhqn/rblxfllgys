--!strict
-- Display names for user ids (for leaderboards), asked for in one go and remembered.

local Players = game:GetService("Players")
local UserService = game:GetService("UserService")

local UserNames = {}

local FALLBACK = "Wobbler"

local names: { [number]: string } = {}

-- Looks up any of these ids it doesn't know yet (one web call). Yields.
function UserNames.Fetch(userIds: { number })
	local missing: { number } = {}
	for _, userId in userIds do
		if not names[userId] then
			local player = Players:GetPlayerByUserId(userId)
			if player then
				names[userId] = player.DisplayName
			else
				table.insert(missing, userId)
			end
		end
	end
	if #missing == 0 then
		return
	end
	local ok, infos = pcall(function(): { any }
		return UserService:GetUserInfosByUserIdsAsync(missing)
	end)
	if ok then
		for _, info in infos do
			if typeof(info.Id) == "number" and typeof(info.DisplayName) == "string" then
				names[info.Id] = info.DisplayName
			end
		end
	end
end

-- The name for a user id (after Fetch), or a stand-in.
function UserNames.Get(userId: number): string
	return names[userId] or FALLBACK
end

return UserNames
