--!strict
-- Daily challenges. Every player gets three a day, picked from the list below (a different mix
-- for each player), each paying Gumdrops when done. They reset at midnight UTC. The server counts
-- progress (ProgressService) and saves it with the profile; the lobby shows it (ChallengesHud).

export type Counter =
	"RoundsPlayed"
	| "RoundsQualified"
	| "RacesFinished"
	| "SurvivalsSurvived"
	| "TeamWins"
	| "FinalsReached"
	| "MatchesPlayed"
	| "MatchesWon"

export type Def = {
	Id: string,
	Text: string,
	Counter: Counter,
	Goal: number,
	Reward: number, -- Gumdrops
}

-- One of a player's challenges for the day, as saved.
export type Progress = {
	Id: string,
	Progress: number,
	Done: boolean,
}

local Challenges = {}

Challenges.PerDay = 3
Challenges.DayLength = 24 * 60 * 60

local list: { Def } = {
	{ Id = "Play5", Text = "Play 5 rounds", Counter = "RoundsPlayed", Goal = 5, Reward = 60 },
	{ Id = "Play10", Text = "Play 10 rounds", Counter = "RoundsPlayed", Goal = 10, Reward = 120 },
	{ Id = "Qualify3", Text = "Get through 3 rounds", Counter = "RoundsQualified", Goal = 3, Reward = 80 },
	{ Id = "Qualify8", Text = "Get through 8 rounds", Counter = "RoundsQualified", Goal = 8, Reward = 160 },
	{ Id = "Race2", Text = "Finish 2 races", Counter = "RacesFinished", Goal = 2, Reward = 80 },
	{ Id = "Survive2", Text = "Survive 2 survival rounds", Counter = "SurvivalsSurvived", Goal = 2, Reward = 80 },
	{ Id = "Team1", Text = "Win a team round", Counter = "TeamWins", Goal = 1, Reward = 80 },
	{ Id = "Final1", Text = "Reach a final", Counter = "FinalsReached", Goal = 1, Reward = 120 },
	{ Id = "Matches3", Text = "Play 3 matches", Counter = "MatchesPlayed", Goal = 3, Reward = 90 },
	{ Id = "Win1", Text = "Win a match", Counter = "MatchesWon", Goal = 1, Reward = 250 },
}

local byId: { [string]: Def } = {}
for _, def in list do
	assert(not byId[def.Id], `duplicate challenge id {def.Id}`)
	byId[def.Id] = table.freeze(def)
end

Challenges.List = table.freeze(list)

function Challenges.Get(id: string): Def?
	return byId[id]
end

-- Which day it is (days since 1970, UTC).
function Challenges.DayNumber(unixTime: number): number
	return unixTime // Challenges.DayLength
end

-- When the day's challenges are replaced (unix time).
function Challenges.NextReset(unixTime: number): number
	return (Challenges.DayNumber(unixTime) + 1) * Challenges.DayLength
end

-- The player's challenges for a day: always the same three for the same player and day, each
-- counting something different.
function Challenges.PickFor(userId: number, day: number): { Def }
	local random = Random.new(math.abs(userId) % 1000003 * 1000 + day % 1000)
	local pool = table.clone(list)
	for index = #pool, 2, -1 do
		local swap = random:NextInteger(1, index)
		pool[index], pool[swap] = pool[swap], pool[index]
	end
	local picked: { Def } = {}
	local counters: { [string]: boolean } = {}
	for _, def in pool do
		if #picked >= Challenges.PerDay then
			break
		end
		if not counters[def.Counter] then
			counters[def.Counter] = true
			table.insert(picked, def)
		end
	end
	return picked
end

return table.freeze(Challenges)
