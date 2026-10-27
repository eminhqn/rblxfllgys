--!strict
-- Random teams for team rounds only. In the lobby and in solo rounds nobody has a team:
-- no Team objects exist, so there's no outline, no team chip and no team headers in the player
-- list. When a team round starts, the round manager calls AssignRandomTeams with the players
-- still in the match, and ClearTeams once the round is over. Teams are always as even as they can
-- be. Players in a party (PartyService) go on the same team unless that would make the teams
-- uneven; then the party is split up for that round, and the round manager tells them why.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TeamsService = game:GetService("Teams")

local Teams = require(ReplicatedStorage.Shared.Teams)

local Bots = require(script.Parent.Parent.Bots.Bots)

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

-- Shuffles `players` into `teamCount` teams (2 to #Teams.List) chosen at random, at most one
-- player apart in size. `groupOf` gives the party a player is in (or nil): a party goes on one
-- team whenever it fits. Returns the members of each team by team id, and the players whose party
-- had to be split up to keep the teams even.
function TeamService.AssignRandomTeams(
	players: { Player },
	teamCount: number,
	groupOf: ((player: Player) -> string?)?
): ({ [string]: { Player } }, { Player })
	TeamService.ClearTeams()
	local count = math.clamp(math.floor(teamCount), 2, #Teams.List)

	-- Parties stay together where they can; everyone else is a group of one. Biggest groups are
	-- placed first, each on whichever team has the most room left.
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

	-- How many each team gets: as even as possible (the first few take one extra).
	local room: { number } = {}
	for index = 1, count do
		room[index] = #players // count + (if index <= #players % count then 1 else 0)
	end
	local function roomiest(): number
		local best = 1
		for index = 2, count do
			if room[index] > room[best] then
				best = index
			end
		end
		return best
	end
	local function place(player: Player, index: number)
		player.Neutral = false
		player.Team = chosen[index]
		if Bots.Is(player) then
			-- Clients can't see a bot's Team: its Bloblet says which team it's on.
			local character = player.Character
			if character then
				character:SetAttribute("TeamId", chosenIds[index])
			end
		end
		table.insert(members[chosenIds[index]], player)
		room[index] -= 1
	end

	local split: { Player } = {}
	for _, group in groups do
		local best = roomiest()
		if #group <= room[best] then
			for _, player in group do
				place(player, best)
			end
		else
			-- Too big for any team: as many as fit stay together, the rest go to the next roomiest.
			local nextIndex = 1
			while nextIndex <= #group do
				local target = roomiest()
				local take = math.max(1, room[target])
				for _ = 1, take do
					local player = group[nextIndex]
					if not player then
						break
					end
					place(player, target)
					nextIndex += 1
				end
			end
			for _, player in group do
				table.insert(split, player)
			end
		end
	end
	return members, split
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
	for _, bot in Bots.All() do
		bot.Team = nil :: any
		bot.Neutral = true
		local character = bot.Character
		if character then
			character:SetAttribute("TeamId", nil)
		end
	end
end

function TeamService.GetTeamId(player: Player): string?
	local def = Teams.FromPlayer(player)
	return if def then def.Id else nil
end

return TeamService
