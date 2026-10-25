--!strict
-- Knows which players in this server are Roblox friends with each other.
--
-- When someone joins, they're checked against everyone already here (one web call per pair, in
-- the background, retried once). Each player's FriendsHere attribute says how many of their
-- friends are in the server, for the lobby's friend bonus badge. ProgressService uses
-- BonusFor to give extra Gumdrops for playing a match with friends (Config.Social).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage.Shared
local Config = require(Shared.Config)
local Match = require(Shared.Match)

local FriendService = {}

local RETRY_DELAY = 5

local friendsOf: { [Player]: { [Player]: boolean } } = {}

local function everyoneIsFriends(): boolean
	return RunService:IsStudio() and Config.Studio.EveryoneIsFriends
end

local function publish(player: Player)
	if player.Parent ~= Players then
		return
	end
	local count = 0
	local friends = friendsOf[player]
	if friends then
		for other in friends do
			if other.Parent == Players then
				count += 1
			end
		end
	end
	player:SetAttribute(Match.PlayerAttr.FriendsHere, count)
end

local function link(a: Player, b: Player)
	local aFriends, bFriends = friendsOf[a], friendsOf[b]
	if not aFriends or not bFriends then
		return -- one of them left while we were asking
	end
	aFriends[b] = true
	bFriends[a] = true
	publish(a)
	publish(b)
end

local function check(newcomer: Player, other: Player)
	if everyoneIsFriends() then
		link(newcomer, other)
		return
	end
	for attempt = 1, 2 do
		local ok, result = pcall(function(): boolean
			return newcomer:IsFriendsWithAsync(other.UserId)
		end)
		if ok then
			if result then
				link(newcomer, other)
			end
			return
		end
		if attempt == 1 then
			task.wait(RETRY_DELAY)
		end
		if newcomer.Parent ~= Players or other.Parent ~= Players then
			return
		end
	end
end

local function onPlayerAdded(player: Player)
	friendsOf[player] = {}
	player:SetAttribute(Match.PlayerAttr.FriendsHere, 0)
	for _, other in Players:GetPlayers() do
		if other ~= player and friendsOf[other] then
			task.spawn(check, player, other)
		end
	end
end

local function onPlayerRemoving(player: Player)
	local friends = friendsOf[player]
	friendsOf[player] = nil
	if not friends then
		return
	end
	for other in friends do
		local theirs = friendsOf[other]
		if theirs then
			theirs[player] = nil
			publish(other)
		end
	end
end

function FriendService.AreFriends(a: Player, b: Player): boolean
	local friends = friendsOf[a]
	return friends ~= nil and friends[b] == true
end

-- How many of `player`'s friends are in `list`.
function FriendService.CountAmong(player: Player, list: { Player }): number
	local count = 0
	for _, other in list do
		if other ~= player and FriendService.AreFriends(player, other) then
			count += 1
		end
	end
	return count
end

-- The extra share of Gumdrops for playing with this many friends (0, 0.15 or 0.25).
function FriendService.BonusFor(friendCount: number): number
	if friendCount >= 2 then
		return Config.Social.FriendBonusMore
	elseif friendCount == 1 then
		return Config.Social.FriendBonusOne
	end
	return 0
end

function FriendService.Init()
	Players.PlayerAdded:Connect(onPlayerAdded)
	for _, player in Players:GetPlayers() do
		if not friendsOf[player] then
			onPlayerAdded(player)
		end
	end
	Players.PlayerRemoving:Connect(onPlayerRemoving)
end

return FriendService
