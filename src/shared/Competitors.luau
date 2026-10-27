--!strict
-- Finding the Bloblets in a match from what the server publishes, for players and bots alike.
--
-- A match can have bots in it (Server/Bots). They aren't Roblox players, so Players can't find
-- them: bots have negative user ids, and their Bloblets carry the attributes UserId, DisplayName,
-- TeamId (in team rounds) and MatchStatus. Anything that looks a competitor up by user id (who
-- you're spectating, the match winner, who's grabbing you) goes through here.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")

local Match = require(script.Parent.Match)
local Tags = require(script.Parent.Tags)
local Teams = require(script.Parent.Teams)

local Competitors = {}

-- Is this Bloblet a bot's?
function Competitors.IsBot(model: Model): boolean
	return model:GetAttribute("Bot") == true
end

-- A player's character, or a bot's Bloblet, by user id.
function Competitors.CharacterOf(userId: number): Model?
	if userId > 0 then
		local player = Players:GetPlayerByUserId(userId)
		return if player then player.Character else nil
	end
	if userId < 0 then
		for _, instance in CollectionService:GetTagged(Tags.Bloblet) do
			if instance:IsA("Model") and instance:GetAttribute("UserId") == userId then
				return instance
			end
		end
	end
	return nil
end

-- The name to show for a player or a bot.
function Competitors.NameOf(userId: number): string?
	if userId > 0 then
		local player = Players:GetPlayerByUserId(userId)
		return if player then player.DisplayName else nil
	end
	local model = Competitors.CharacterOf(userId)
	local name = if model then model:GetAttribute("DisplayName") else nil
	return if typeof(name) == "string" then name else nil
end

-- The team a Bloblet is on (team rounds only), player or bot.
function Competitors.TeamOf(model: Model): Teams.TeamDef?
	local player = Players:GetPlayerFromCharacter(model)
	if player then
		return Teams.FromPlayer(player)
	end
	local id = model:GetAttribute("TeamId")
	return if typeof(id) == "string" then Teams.Get(id) else nil
end

-- Playing, Qualified, Eliminated, Winner or None (Shared/Match), player or bot.
function Competitors.StatusOf(model: Model): string?
	local player = Players:GetPlayerFromCharacter(model)
	local status = if player
		then player:GetAttribute(Match.PlayerAttr.Status)
		else model:GetAttribute(Match.PlayerAttr.Status)
	return if typeof(status) == "string" then status else nil
end

return table.freeze(Competitors)
