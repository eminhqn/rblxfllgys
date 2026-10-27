--!strict
-- The shared interface every mini-game implements. See MiniGames/_Template.luau for a fully
-- commented example you can copy.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Match = require(ReplicatedStorage.Shared.Match)

export type RoundType = Match.RoundType

export type MiniGameInfo = {
	Id: string, -- unique, matches the module name
	DisplayName: string, -- shown on the round card, e.g. "Rising Tide"
	Type: RoundType,
	Rules: string, -- one short sentence for the round card
	Duration: number, -- time limit in seconds
	MinPlayers: number?, -- won't be picked with fewer players (default 1)
	TeamCount: number?, -- Team rounds only (default 2)
	-- Survival rounds: only players who reach a goal (context.Qualify) go through, everyone else
	-- is out when the round ends, and the round never ends just because few players are left.
	QualifyByGoalOnly: boolean?,
}

-- What a mini-game gets from the round manager. Functions are called with a dot: ctx.Qualify(p).
export type RoundContext = {
	Info: MiniGameInfo,
	Players: { Player }, -- everyone who started this round
	QualifyTarget: number, -- how many players should go through (Final: 1)
	Arena: Model, -- build the map inside this; it is destroyed after the round
	Origin: CFrame, -- centre of the arena in the world
	Teams: { [string]: { Player } }?, -- Team rounds: members per team id (see Shared/Teams)
	Random: Random,

	-- Player state
	IsAlive: (player: Player) -> boolean, -- in this round, not eliminated, still connected
	IsQualified: (player: Player) -> boolean,
	GetAlive: () -> { Player },
	GetRoot: (player: Player) -> BasePart?,
	GetServerTime: () -> number, -- same clock clients animate hazards with
	GetStartTime: () -> number, -- server time when the round went live (0 before Start)

	-- Actions
	Qualify: (player: Player) -> (), -- e.g. crossed the finish line
	Eliminate: (player: Player) -> (), -- e.g. fell in the water
	-- Eliminates every alive player whose Bloblet dipped below a world height. In a Final, if
	-- everyone left would go at once, the highest one is kept as the winner.
	EliminateBelow: (height: number) -> (),
	-- Places a player standing at a ground-level CFrame, facing its LookVector (also used to
	-- respawn mid-round; their momentum is cleared). Before Start they stay frozen.
	SpawnAt: (player: Player, groundCFrame: CFrame) -> (),
	-- Spreads all round players over the given ground-level spots.
	SpawnAll: (spots: { CFrame }) -> (),
	-- Replaces the live counter under the round name (nil = the default for the round type).
	SetCounterText: (text: string?) -> (),
	-- Team rounds: shows each team's score (by team id) in the team score bar. `total` is the most
	-- there is to win (e.g. the number of tiles), so the bar can show what's still up for grabs.
	SetTeamScores: (scores: { [string]: number }, total: number?) -> (),
	-- A pop-up message for everyone in the match (e.g. "CORAL SCORES!"), in a team's colour if
	-- `teamId` is given.
	Announce: (text: string, teamId: string?) -> (),
	-- Called when a competing player presses reset (Roblox menu / Esc > Reset). By default reset
	-- does nothing during a round; races use it to go back to the last checkpoint.
	OnResetRequested: (handler: (player: Player) -> ()) -> (),
	-- Who qualifies by default: Race = everyone who called Qualify; Survival = whoever is still
	-- alive (or only the early qualifiers, once they fill every spot, or always with
	-- Info.QualifyByGoalOnly); Final = the last one standing. Team rounds must decide themselves.
	DefaultQualified: () -> { Player },
}

-- What a bot (Server/Bots) should do right now, from a round's BotGoal. BotBrain works out how:
-- walking, jumping walls and gaps, diving across wide ones, dodging hazards. Everything is optional.
export type BotGoal = {
	MoveTo: Vector3?, -- head for this point (on the ground, or the floor it's on)
	Then: Vector3?, -- the point after MoveTo: once there it carries straight on (no stopping)
	Within: number?, -- close enough to MoveTo (studs, default 2)
	Wander: number?, -- no exact spot: drift about within this many studs of MoveTo
	Stop: boolean?, -- stand still (e.g. holding a rope)
	Jump: boolean?, -- jump now
	Dive: boolean?, -- dive towards MoveTo now
	Grab: boolean?, -- hold GRAB while this is true (eggs, ropes, people)
	Careful: boolean?, -- don't walk off an edge to get there
	Calm: boolean?, -- leave the others alone (no kicking or grabbing)
	Note: string?, -- what it's up to, for Config.Studio.ShowBotThoughts
}

-- One round of a mini-game. The round manager calls these in order:
--   Setup  -> build the map and place players (screens are covered, players frozen)
--   Start  -> GO! players can move
--   Update -> called UpdateRate times a second; return true to end the round early
--   End    -> stop hazards / disconnect events (the arena is destroyed for you afterwards)
--   GetQualified -> the players who go through
export type MiniGame = {
	Setup: () -> (),
	Start: () -> (),
	Update: (dt: number) -> boolean?,
	End: () -> (),
	GetQualified: () -> { Player },
	-- Optional: what a bot should do now (called a few times a second for each bot still in).
	-- Without it bots wander about the middle of the arena (races: RaceKit gives one).
	BotGoal: ((bot: Player) -> BotGoal?)?,
}

export type MiniGameModule = {
	Info: MiniGameInfo,
	new: (context: RoundContext) -> MiniGame,
}

return {}
