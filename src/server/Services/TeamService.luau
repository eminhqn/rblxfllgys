--!strict
-- Random teams for team rounds only. In the lobby and in solo rounds nobody has a team:
-- no Team objects exist, so there's no outline, no team chip and no team headers in the player
-- list. When a team round starts, the round manager calls AssignRandomTeams with the players
-- still in the match, and ClearTeams once the round is over. Players in a party (PartyService)
-- always end up on the same team.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TeamsService = game:GetService("Teams")

local Teams = require(ReplicatedStorage.Shared.Teams)

local TeamService = {}

local teamInstances: { [string]: Team } = {}

function TeamService.Init()
	TeamService.ClearTeams()
end

local function shuffle<T>(list: { T })
	for index = #list, 2, -1 do
		local swap = math.random(index)
		list[index], list[swap] = list[swap], list[index]
	end
end

-- Shuffles `players` into `teamCount` teams (2 to #Teams.List) chosen at random, as even as they
-- can be. `groupOf` gives the party a player is in (or nil): everyone in one party goes on the
-- same team, so with parties the teams can end up a player or two apart. Returns the members of
-- each team by team id.
function TeamService.AssignRandomTeams(
	players: { Player },
	teamCount: number,
	groupOf: ((player: Player) -> string?)?
): { [string]: { Player } }
	TeamService.ClearTeams()
	local count = math.clamp(math.floor(teamCount), 2, #Teams.List)

	-- Parties stay together; everyone else is a group of one. Biggest groups are placed first, each
	-- on whichever team is smallest at the time.
	local groups: { { Player } } = {}
	local byParty: { [string]: { Player } } = {}
	for _, player in players do
		local partyId = if groupOf then groupOf(player) else nil
		if partyId then
			local existing = byParty[partyId]
			if existing then
				table.insert(existing, player)
			else
				local group = { player }
				byParty[partyId] = group
				table.insert(groups, group)
			end
		else
			table.insert(groups, { player })
		end
	end
	shuffle(groups)
	table.sort(groups, function(a: { Player }, b: { Player }): boolean
		return #a > #b
	end)

	-- Which colours get used is random too. (Teams.List is frozen, so copy it before shuffling.)
	local defs: { Teams.TeamDef } = {}
	for _, def in Teams.List do
		table.insert(defs, def)
	end
	shuffle(defs)

	local members: { [string]: { Player } } = {}
	local chosen: { Team } = {}
	local chosenIds: { string } = {}
	for index = 1, count do
		local def = defs[index]
		local team = Instance.new("Team")
		team.Name = def.DisplayName
		team.TeamColor = def.BrickColor
		team.AutoAssignable = false
		team:SetAttribute("TeamId", def.Id)
		team.Parent = TeamsService
		teamInstances[def.Id] = team
		members[def.Id] = {}
		chosen[index] = team
		chosenIds[index] = def.Id
	end

	for _, group in groups do
		local smallest = 1
		for index = 2, count do
			if #members[chosenIds[index]] < #members[chosenIds[smallest]] then
				smallest = index
			end
		end
		for _, player in group do
			player.Neutral = false
			player.Team = chosen[smallest]
			table.insert(members[chosenIds[smallest]], player)
		end
	end
	return members
end

-- Everyone goes back to having no team (lobby, solo rounds, end of a team round).
function TeamService.ClearTeams()
	for _, team in teamInstances do
		for _, player in team:GetPlayers() do
			-- Roblox accepts nil here (no team) even though the type says Team.
			player.Team = nil :: any
			player.Neutral = true
		end
		team:Destroy()
	end
	table.clear(teamInstances)
end

function TeamService.GetTeamId(player: Player): string?
	local def = Teams.FromPlayer(player)
	return if def then def.Id else nil
end

return TeamService
