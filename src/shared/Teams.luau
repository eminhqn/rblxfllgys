--!strict
-- Team definitions. Nobody has a team in the lobby or in solo rounds. When a team round starts the
-- server splits the remaining players into random, balanced teams, and every Bloblet then gets a
-- thin outline in its team colour. The lobby decks reuse these colours as decoration.

export type TeamDef = {
	Id: string,
	DisplayName: string,
	Color: Color3, -- the colour we actually draw with
	BrickColor: BrickColor, -- required by Roblox's Team instance (must be unique per team)
}

local Teams = {}

Teams.List = table.freeze({
	table.freeze({
		Id = "Coral",
		DisplayName = "Team Coral",
		Color = Color3.fromRGB(255, 84, 160),
		BrickColor = BrickColor.new("Hot pink"),
	}),
	table.freeze({
		Id = "Aqua",
		DisplayName = "Team Aqua",
		Color = Color3.fromRGB(38, 206, 232),
		BrickColor = BrickColor.new("Toothpaste"),
	}),
	table.freeze({
		Id = "Lime",
		DisplayName = "Team Lime",
		Color = Color3.fromRGB(118, 218, 72),
		BrickColor = BrickColor.new("Lime green"),
	}),
	table.freeze({
		Id = "Sunny",
		DisplayName = "Team Sunny",
		Color = Color3.fromRGB(255, 196, 36),
		BrickColor = BrickColor.new("New Yeller"),
	}),
} :: { TeamDef })

local byId: { [string]: TeamDef } = {}
for _, team in Teams.List do
	byId[team.Id] = team
end

function Teams.Get(id: string): TeamDef?
	return byId[id]
end

-- Reads the TeamId attribute the server puts on Roblox Team instances.
function Teams.FromPlayer(player: Player): TeamDef?
	local team = player.Team
	if not team then
		return nil
	end
	local id = team:GetAttribute("TeamId")
	if typeof(id) ~= "string" then
		return nil
	end
	return byId[id]
end

return table.freeze(Teams)
