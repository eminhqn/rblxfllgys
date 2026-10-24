--!strict
-- Random teams for team rounds only. In the lobby and in solo rounds nobody has a team:
-- no Team objects exist, so there's no outline, no team chip and no team headers in the player
-- list. When a team round starts, the round manager calls AssignRandomTeams with the players
-- still in the match, and ClearTeams once the round is over.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TeamsService = game:GetService("Teams")

local Teams = require(ReplicatedStorage.Shared.Teams)

local TeamService = {}

local teamInstances: { [string]: Team } = {}

function TeamService.Init()
	TeamService.ClearTeams()
end

-- Shuffles `players` into `teamCount` balanced teams (2 to #Teams.List) chosen at random.
-- Returns the members of each team by team id.
function TeamService.AssignRandomTeams(players: { Player }, teamCount: number): { [string]: { Player } }
	TeamService.ClearTeams()
	local count = math.clamp(math.floor(teamCount), 2, #Teams.List)

	local shuffled = table.clone(players)
	for index = #shuffled, 2, -1 do
		local swap = math.random(index)
		shuffled[index], shuffled[swap] = shuffled[swap], shuffled[index]
	end

	-- Which colours get used is random too. (Teams.List is frozen, so copy it before shuffling.)
	local defs: { Teams.TeamDef } = {}
	for _, def in Teams.List do
		table.insert(defs, def)
	end
	for index = #defs, 2, -1 do
		local swap = math.random(index)
		defs[index], defs[swap] = defs[swap], defs[index]
	end

	local members: { [string]: { Player } } = {}
	local chosen: { Team } = {}
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
	end

	for index, player in shuffled do
		local slot = (index - 1) % count + 1
		local team = chosen[slot]
		player.Neutral = false
		player.Team = team
		table.insert(members[team:GetAttribute("TeamId") :: string], player)
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
