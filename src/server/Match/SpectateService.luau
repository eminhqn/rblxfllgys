--!strict
-- Spectating: players knocked out of a match watch anyone still in it (and can go back to the
-- lobby, and come back to watch again, whenever they like), and players who've qualified, or been
-- revived, watch while they wait for the next round.
--
-- The server decides who you watch, preferring players still competing in the round, and points
-- your streaming focus at them (Player.ReplicationFocus), so their part of the world loads for you
-- even though your own Bloblet is elsewhere. The client just follows the SpectatingUserId
-- attribute.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Match = require(ReplicatedStorage.Shared.Match)

local Bots = require(script.Parent.Parent.Bots.Bots)

local SpectateService = {}

local spectators: { [Player]: boolean } = {} -- everyone spectating
local watching: { [Player]: Player } = {} -- and who each of them is watching (if anyone)

-- Who `spectator` can watch: players still playing the round (or, between rounds, anyone still
-- in the match), bots included. Never themselves.
local function candidates(spectator: Player): { Player }
	local inMatch: { Player } = {}
	local playing: { Player } = {}
	local everyone = Players:GetPlayers()
	for _, bot in Bots.All() do
		table.insert(everyone, bot)
	end
	for _, player in everyone do
		if player ~= spectator and player:GetAttribute(Match.PlayerAttr.InMatch) == true then
			table.insert(inMatch, player)
			if player:GetAttribute(Match.PlayerAttr.Status) == "Playing" then
				table.insert(playing, player)
			end
		end
	end
	local list = if #playing > 0 then playing else inMatch
	table.sort(list, function(a: Player, b: Player)
		return a.UserId < b.UserId
	end)
	return list
end

local function focusOn(spectator: Player, target: Player?)
	local character = if target then target.Character else nil
	local root = if character then character.PrimaryPart else nil
	spectator.ReplicationFocus = root
	if root then
		local position = root.Position
		task.spawn(function()
			pcall(function()
				spectator:RequestStreamAroundAsync(position, 2)
			end)
		end)
	end
end

local function setTarget(spectator: Player, target: Player?)
	if target then
		watching[spectator] = target
	else
		watching[spectator] = nil
	end
	spectator:SetAttribute(Match.PlayerAttr.Spectating, if target then target.UserId else 0)
	focusOn(spectator, target)
end

-- Starts spectating, watching the first player still competing (or nobody for now).
function SpectateService.Begin(spectator: Player)
	spectators[spectator] = true
	setTarget(spectator, candidates(spectator)[1])
end

-- Moves to the previous (-1) or next (1) player they can watch.
function SpectateService.Step(spectator: Player, direction: number)
	local list = candidates(spectator)
	if #list == 0 then
		setTarget(spectator, nil)
		return
	end
	local current = watching[spectator]
	local index = if current then table.find(list, current) or 0 else 0
	index = (index - 1 + direction) % #list + 1
	setTarget(spectator, list[index])
end

function SpectateService.Stop(spectator: Player)
	spectators[spectator] = nil
	watching[spectator] = nil
	if spectator.Parent == Players then
		spectator:SetAttribute(Match.PlayerAttr.Spectating, 0)
		spectator.ReplicationFocus = nil
	end
end

function SpectateService.StopAll()
	for spectator in table.clone(spectators) do
		SpectateService.Stop(spectator)
	end
end

function SpectateService.IsSpectating(player: Player): boolean
	return spectators[player] == true
end

-- Someone finished the round (qualified): anyone watching them moves on to someone still going.
function SpectateService.OnPlayerDone(player: Player)
	for spectator, target in table.clone(watching) do
		if target == player then
			SpectateService.Step(spectator, 1)
		end
	end
end

-- Someone was eliminated or left: they stop spectating (if they were), and anyone watching them
-- moves on to another player.
function SpectateService.OnPlayerOut(player: Player)
	spectators[player] = nil
	watching[player] = nil
	SpectateService.OnPlayerDone(player)
end

-- Characters can be rebuilt between rounds; keep everyone's streaming focus on the live one, and
-- give anyone who had nobody to watch someone once there is.
function SpectateService.Refresh()
	for spectator in spectators do
		local target = watching[spectator]
		if target then
			focusOn(spectator, target)
		else
			local first = candidates(spectator)[1]
			if first then
				setTarget(spectator, first)
			end
		end
	end
end

function SpectateService.Init()
	Players.PlayerRemoving:Connect(SpectateService.OnPlayerOut)
	Bots.Removing:Connect(SpectateService.OnPlayerOut)
end

return SpectateService
