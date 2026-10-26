--!strict
-- Everything players earn from playing, in one place:
--   * Gumdrops for every round (plus a bonus for playing with friends: Config.Social) and Crowns
--     for winning a match (Config.Economy), and the stats behind them, time survived included
--   * DOUBLE REWARDS (an item, ItemService): a round's Gumdrops and XP are doubled
--   * XP and levels (Shared/Progression): each new level pays out its reward track reward
--   * daily challenges (Shared/Challenges): progress, and their Gumdrops when one is done
--   * badges (Config.Badges), once you've created them and pasted in their ids
--   * the summary each player sees on the results screen when a match ends
-- MatchService tells it what happened. Nothing here listens to clients.

local BadgeService = game:GetService("BadgeService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage.Shared
local Challenges = require(Shared.Challenges)
local Config = require(Shared.Config)
local Progression = require(Shared.Progression)
local Remotes = require(Shared.Remotes)

local DataService = require(script.Parent.DataService)
local FriendService = require(script.Parent.FriendService)
local ItemService = require(script.Parent.ItemService)

local ProgressService = {}

type BadgeName = "FirstQualify" | "ReachFinal" | "FirstWin" | "TenWins"

-- What a player got out of the current match (sent to them as the results screen).
type Summary = {
	Won: boolean,
	ReachedFinal: boolean,
	OutInRound: number, -- the round they were knocked out in, 0 = never
	RoundsPlayed: number,
	RoundsQualified: number,
	Gumdrops: number, -- for playing rounds
	Crowns: number,
	ChallengeGumdrops: number,
	Challenges: { string }, -- challenges finished during the match
	XP: number,
	LevelBefore: number,
	FriendBonus: number, -- extra share of round Gumdrops for the friends in this match
	FriendGumdrops: number, -- how many Gumdrops that bonus added
	Survived: number, -- seconds spent still in survival rounds and finals
	DoubledRounds: number, -- rounds whose Gumdrops and XP DOUBLE REWARDS doubled
}

local DAILY_CHECK_INTERVAL = 30 -- seconds; swaps in new challenges soon after midnight UTC
local WINS_FOR_BADGE = 10

local summaries: { [Player]: Summary } = {}
local badgesChecked: { [Player]: { [string]: boolean } } = {}

local XP = Progression.XP

local function newSummary(): Summary
	return {
		Won = false,
		ReachedFinal = false,
		OutInRound = 0,
		RoundsPlayed = 0,
		RoundsQualified = 0,
		Gumdrops = 0,
		Crowns = 0,
		ChallengeGumdrops = 0,
		Challenges = {},
		XP = 0,
		LevelBefore = 1,
		FriendBonus = 0,
		FriendGumdrops = 0,
		Survived = 0,
		DoubledRounds = 0,
	}
end

local function levelOf(player: Player): number
	local profile = DataService.Get(player)
	return if profile then (Progression.LevelFor(profile.XP)) else 1
end

-- Gives XP. Every level it reaches that hasn't paid out yet pays its reward track reward, and the
-- player gets a LEVEL UP pop-up listing them.
local function addXP(player: Player, amount: number)
	if RunService:IsStudio() then
		amount *= Config.Studio.XPMultiplier
	end
	if amount <= 0 then
		return
	end
	local before, after = 1, 1
	local rewards: { { [string]: any } } = {}
	local updated = DataService.Update(player, function(profile: DataService.Profile)
		before = Progression.LevelFor(profile.XP)
		profile.XP = math.min(profile.XP + amount, Config.Economy.MaxCurrency)
		after = Progression.LevelFor(profile.XP)
		local cap = Config.Economy.MaxCurrency
		for level = profile.TrackClaimed + 1, after do
			local reward = Progression.RewardFor(level)
			if not reward then
				continue
			end
			if reward.Kind == "Gumdrops" then
				DataService.GiveGumdrops(profile, reward.Amount)
			elseif reward.Kind == "Crowns" then
				profile.Crowns = math.min(profile.Crowns + reward.Amount, cap)
			elseif reward.ItemId then
				profile.Owned[reward.ItemId] = true
			end
			table.insert(rewards, { Level = level, Kind = reward.Kind, Amount = reward.Amount, ItemId = reward.ItemId })
		end
		profile.TrackClaimed = math.max(profile.TrackClaimed, after)
	end)
	if not updated then
		return
	end
	local summary = summaries[player]
	if summary then
		summary.XP += amount
	end
	if after > before then
		Remotes.Event("LevelUp"):FireClient(player, after, rewards)
	end
end

-- Awards a badge if it's set up and the player doesn't have it yet. Never blocks the caller.
local function award(player: Player, name: BadgeName)
	local badgeId = Config.Badges[name]
	if not badgeId or badgeId == 0 then
		return
	end
	local checked = badgesChecked[player]
	if not checked then
		checked = {}
		badgesChecked[player] = checked
	end
	if checked[name] then
		return
	end
	checked[name] = true
	task.spawn(function()
		local ok, err = pcall(function()
			if not BadgeService:UserHasBadgeAsync(player.UserId, badgeId) then
				BadgeService:AwardBadge(player.UserId, badgeId)
			end
		end)
		if not ok then
			warn(`[ProgressService] Couldn't award badge {name} to {player.Name}: {err}`)
			checked[name] = nil -- try again next time
		end
	end)
end

-- Adds to a daily challenge counter. Finished challenges pay their Gumdrops straight away.
local function record(player: Player, counter: Challenges.Counter, amount: number)
	DataService.RefreshDaily(player)
	local finished: { Challenges.Def } = {}
	DataService.Update(player, function(profile: DataService.Profile)
		for _, entry in profile.Daily.Challenges do
			local def = Challenges.Get(entry.Id)
			if def and def.Counter == counter and not entry.Done then
				entry.Progress = math.min(def.Goal, entry.Progress + amount)
				if entry.Progress >= def.Goal then
					entry.Done = true
					DataService.GiveGumdrops(profile, def.Reward)
					table.insert(finished, def)
				end
			end
		end
	end)
	local summary = summaries[player]
	for _, def in finished do
		if summary then
			summary.ChallengeGumdrops += def.Reward
			table.insert(summary.Challenges, def.Text)
		end
		Remotes.Event("ChallengeCompleted"):FireClient(player, def.Id)
		addXP(player, XP.ChallengeDone)
	end
end

-- A match is starting with these players.
function ProgressService.MatchStarted(players: { Player })
	table.clear(summaries)
	for _, player in players do
		local summary = newSummary()
		summary.LevelBefore = levelOf(player)
		summary.FriendBonus = FriendService.BonusFor(FriendService.CountAmong(player, players))
		summaries[player] = summary
		DataService.AddStat(player, "Matches", 1)
	end
end

-- A round is about to be played by these players.
function ProgressService.RoundStarted(players: { Player }, roundType: string)
	if roundType ~= "Final" then
		return
	end
	for _, player in players do
		local summary = summaries[player]
		if summary then
			summary.ReachedFinal = true
		end
		record(player, "FinalsReached", 1)
		award(player, "ReachFinal")
		addXP(player, XP.FinalReached)
	end
end

-- A round is over for a player who took part: Gumdrops, stats and challenges. `survived` is how
-- many seconds they were still in it once it got going.
function ProgressService.RoundEnded(
	player: Player,
	roundType: string,
	qualified: boolean,
	roundNumber: number,
	survived: number
)
	local economy = Config.Economy
	local summary = summaries[player]
	local gumdrops = economy.RoundPlayed + (if qualified then economy.RoundQualified else 0)
	local bonus = if summary then math.floor(gumdrops * summary.FriendBonus + 0.5) else 0
	local doubled = ItemService.IsActive(player, "DoubleRewards")
	local multiplier = if doubled then Config.Items.DoubleRewardsMultiplier else 1
	-- DOUBLE REWARDS doubles the lot, friend bonus included.
	local total = (gumdrops + bonus) * multiplier
	DataService.AddGumdrops(player, total)
	DataService.AddStat(player, "RoundsPlayed", 1)
	-- Time survived counts in rounds where staying in is the point.
	local seconds = if roundType == "Survival" or roundType == "Final" then math.floor(survived + 0.5) else 0
	if seconds > 0 then
		DataService.AddStat(player, "TimeSurvived", seconds)
	end
	if summary then
		summary.RoundsPlayed += 1
		summary.Gumdrops += total
		summary.FriendGumdrops += bonus * multiplier
		if doubled then
			summary.DoubledRounds += 1
		end
		summary.Survived += seconds
	end
	record(player, "RoundsPlayed", 1)
	addXP(player, (XP.RoundPlayed + (if qualified then XP.RoundQualified else 0)) * multiplier)
	if not qualified then
		if summary and summary.OutInRound == 0 then
			summary.OutInRound = roundNumber
		end
		return
	end
	DataService.AddStat(player, "RoundsQualified", 1)
	if summary then
		summary.RoundsQualified += 1
	end
	record(player, "RoundsQualified", 1)
	if roundType == "Race" then
		record(player, "RacesFinished", 1)
	elseif roundType == "Survival" then
		record(player, "SurvivalsSurvived", 1)
	elseif roundType == "Team" then
		record(player, "TeamWins", 1)
	end
	award(player, "FirstQualify")
end

-- The match is over: the winner's Crowns, then everyone's results screen.
function ProgressService.MatchEnded(winner: Player?, rounds: number)
	if winner and winner.Parent == Players then
		local crowns = Config.Economy.MatchWinCrowns
		DataService.AddCrowns(winner, crowns)
		DataService.AddStat(winner, "Wins", 1)
		local summary = summaries[winner]
		if summary then
			summary.Won = true
			summary.Crowns += crowns
		end
		record(winner, "MatchesWon", 1)
		award(winner, "FirstWin")
		addXP(winner, XP.MatchWon)
		local profile = DataService.Get(winner)
		if profile and profile.Stats.Wins >= WINS_FOR_BADGE then
			award(winner, "TenWins")
		end
	end

	for player, summary in summaries do
		if player.Parent ~= Players then
			continue
		end
		record(player, "MatchesPlayed", 1)
		local profile = DataService.Get(player)
		local level, levelXP, levelNeeded = Progression.LevelFor(if profile then profile.XP else 0)
		Remotes.Event("MatchResults"):FireClient(player, {
			Won = summary.Won,
			ReachedFinal = summary.ReachedFinal,
			OutInRound = summary.OutInRound,
			Rounds = rounds,
			RoundsPlayed = summary.RoundsPlayed,
			RoundsQualified = summary.RoundsQualified,
			Gumdrops = summary.Gumdrops,
			Crowns = summary.Crowns,
			ChallengeGumdrops = summary.ChallengeGumdrops,
			Challenges = summary.Challenges,
			TotalWins = if profile then profile.Stats.Wins else 0,
			TotalMatches = if profile then profile.Stats.Matches else 0,
			XP = summary.XP,
			LevelBefore = summary.LevelBefore,
			Level = level,
			LevelXP = levelXP,
			LevelNeeded = levelNeeded,
			FriendBonus = math.floor(summary.FriendBonus * 100 + 0.5), -- percent
			FriendGumdrops = summary.FriendGumdrops,
			Survived = summary.Survived,
			DoubleRewards = summary.DoubledRounds > 0,
		})
	end
	table.clear(summaries)
end

function ProgressService.Init()
	Players.PlayerRemoving:Connect(function(player: Player)
		summaries[player] = nil
		badgesChecked[player] = nil
	end)
	-- New challenges show up soon after midnight UTC without anyone having to rejoin.
	task.spawn(function()
		while true do
			task.wait(DAILY_CHECK_INTERVAL)
			for _, player in Players:GetPlayers() do
				DataService.RefreshDaily(player)
			end
		end
	end)
end

return ProgressService
