--!strict
-- This client's view of its own saved profile: Crowns, Gumdrops, unlocked items, what it's
-- wearing, stats, settings and daily challenges. The server publishes them as player attributes (see DataService); this module decodes
-- them and says when they change. Nothing here can change the profile: the customise screen asks
-- the server through ShopService's remotes.

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Challenges = require(Shared.Challenges)
local Cosmetics = require(Shared.Cosmetics)
local Match = require(Shared.Match)
local PlayerSettings = require(Shared.PlayerSettings)
local Progression = require(Shared.Progression)
local Signal = require(Shared.Signal)

-- Today's daily challenges as the server last sent them.
export type Daily = {
	NextReset: number, -- unix time they're replaced
	Challenges: { Challenges.Progress },
}

local ProfileClient = {}

ProfileClient.Changed = Signal.new() :: Signal.Signal<()>

local PlayerAttr = Match.PlayerAttr
local localPlayer = Players.LocalPlayer

local owned: { [string]: boolean } = {}
local equipped: Cosmetics.Equipped = table.clone(Cosmetics.Defaults)
local stats: { [string]: number } = {}
local settings: PlayerSettings.Settings = table.clone(PlayerSettings.Defaults)
local daily: Daily = { NextReset = 0, Challenges = {} }

local function decode(name: string): any
	local raw = localPlayer:GetAttribute(name)
	if typeof(raw) ~= "string" or raw == "" then
		return nil
	end
	local ok, value = pcall(function(): any
		return HttpService:JSONDecode(raw)
	end)
	return if ok then value else nil
end

local function refresh()
	table.clear(owned)
	local ownedList = decode(PlayerAttr.Owned)
	if typeof(ownedList) == "table" then
		for _, id in ownedList do
			if typeof(id) == "string" then
				owned[id] = true
			end
		end
	end
	local equippedData = decode(PlayerAttr.Equipped)
	local fresh = table.clone(Cosmetics.Defaults)
	if typeof(equippedData) == "table" then
		for _, slot in Cosmetics.AllSlots() do
			local id = equippedData[slot]
			if typeof(id) == "string" and Cosmetics.Get(id) then
				Cosmetics.SetSlot(fresh, slot, id)
			end
		end
	end
	equipped = fresh
	table.clear(stats)
	local statsData = decode(PlayerAttr.Stats)
	if typeof(statsData) == "table" then
		for name, value in statsData do
			if typeof(name) == "string" and typeof(value) == "number" then
				stats[name] = value
			end
		end
	end
	settings = PlayerSettings.Sanitize(decode(PlayerAttr.Settings))
	local dailyData = decode(PlayerAttr.Daily)
	local freshDaily: Daily = { NextReset = 0, Challenges = {} }
	if typeof(dailyData) == "table" then
		if typeof(dailyData.NextReset) == "number" then
			freshDaily.NextReset = dailyData.NextReset
		end
		if typeof(dailyData.Challenges) == "table" then
			for _, entry in dailyData.Challenges do
				if
					typeof(entry) == "table"
					and typeof(entry.Id) == "string"
					and Challenges.Get(entry.Id)
					and typeof(entry.Progress) == "number"
				then
					table.insert(freshDaily.Challenges, {
						Id = entry.Id,
						Progress = entry.Progress,
						Done = entry.Done == true,
					})
				end
			end
		end
	end
	daily = freshDaily
	ProfileClient.Changed:Fire()
end

function ProfileClient.IsReady(): boolean
	return localPlayer:GetAttribute(PlayerAttr.DataReady) == true
end

-- False when the server couldn't load the profile and won't save this session.
function ProfileClient.IsSaving(): boolean
	return localPlayer:GetAttribute(PlayerAttr.DataSaving) ~= false
end

-- Crowns: what items cost.
function ProfileClient.GetCrowns(): number
	local value = localPlayer:GetAttribute(PlayerAttr.Crowns)
	return if typeof(value) == "number" then value else 0
end

-- Gumdrops: earned by playing, traded for Crowns.
function ProfileClient.GetGumdrops(): number
	local value = localPlayer:GetAttribute(PlayerAttr.Gumdrops)
	return if typeof(value) == "number" then value else 0
end

function ProfileClient.Owns(itemId: string): boolean
	local entry = Cosmetics.Get(itemId)
	return entry ~= nil and (Cosmetics.IsFree(entry) or owned[itemId] == true)
end

function ProfileClient.GetEquipped(): Cosmetics.Equipped
	return equipped
end

function ProfileClient.GetStat(name: string): number
	return stats[name] or 0
end

function ProfileClient.GetXP(): number
	local value = localPlayer:GetAttribute(PlayerAttr.XP)
	return if typeof(value) == "number" then value else 0
end

-- Your level, how much XP you have into it, and how much it needs.
function ProfileClient.GetLevel(): (number, number, number)
	return Progression.LevelFor(ProfileClient.GetXP())
end

-- The settings saved with the profile (ClientSettings has the ones in use right now).
function ProfileClient.GetSettings(): PlayerSettings.Settings
	return settings
end

function ProfileClient.GetDaily(): Daily
	return daily
end

function ProfileClient.Init()
	local watched = {
		[PlayerAttr.Crowns] = true,
		[PlayerAttr.Gumdrops] = true,
		[PlayerAttr.Owned] = true,
		[PlayerAttr.Equipped] = true,
		[PlayerAttr.Stats] = true,
		[PlayerAttr.Settings] = true,
		[PlayerAttr.XP] = true,
		[PlayerAttr.Daily] = true,
		[PlayerAttr.DataReady] = true,
		[PlayerAttr.DataSaving] = true,
	}
	localPlayer.AttributeChanged:Connect(function(name: string)
		if watched[name] then
			refresh()
		end
	end)
	refresh()
end

return ProfileClient
