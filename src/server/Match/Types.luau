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
	-- Places a player standing at a ground-level CFrame. Before Start they stay frozen.
	SpawnAt: (player: Player, groundCFrame: CFrame) -> (),
	-- Spreads all round players over the given ground-level spots.
	SpawnAll: (spots: { CFrame }) -> (),
	-- Who qualifies by default: Race = everyone who called Qualify, Survival = whoever is still
	-- alive, Final = the last one standing. Team rounds must decide themselves.
	DefaultQualified: () -> { Player },
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
}

export type MiniGameModule = {
	Info: MiniGameInfo,
	new: (context: RoundContext) -> MiniGame,
}

return {}
