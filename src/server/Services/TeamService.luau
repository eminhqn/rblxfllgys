--!strict
-- Creates the Roblox Team objects and assigns players randomly while keeping teams balanced.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TeamsService = game:GetService("Teams")

local Teams = require(ReplicatedStorage.Shared.Teams)

local TeamService = {}

local teamInstances: { [string]: Team } = {}

function TeamService.Init()
	for _, def in Teams.List do
		local team = Instance.new("Team")
		team.Name = def.DisplayName
		team.TeamColor = def.BrickColor
		team.AutoAssignable = false
		team:SetAttribute("TeamId", def.Id)
		team.Parent = TeamsService
		teamInstances[def.Id] = team
	end
end

-- Puts the player on one of the smallest teams, chosen at random.
function TeamService.Assign(player: Player): string
	local smallest = math.huge
	local candidates: { string } = {}
	for _, def in Teams.List do
		local count = 0
		for _, member in teamInstances[def.Id]:GetPlayers() do
			if member ~= player then
				count += 1
			end
		end
		if count < smallest then
			smallest = count
			candidates = { def.Id }
		elseif count == smallest then
			table.insert(candidates, def.Id)
		end
	end
	local chosen = candidates[math.random(#candidates)]
	player.Neutral = false
	player.Team = teamInstances[chosen]
	return chosen
end

function TeamService.GetTeamId(player: Player): string?
	local def = Teams.FromPlayer(player)
	return if def then def.Id else nil
end

function TeamService.CountMembers(teamId: string): number
	local team = teamInstances[teamId]
	return if team then #team:GetPlayers() else 0
end

return TeamService
