--!strict
-- Eliminated players can watch anyone still competing, then return to the lobby when they like.
--
-- The server decides who you watch and points your streaming focus at them
-- (Player.ReplicationFocus), so their part of the world loads for you even though your own
-- Bloblet is back in the lobby. The client just follows the SpectatingUserId attribute.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Match = require(ReplicatedStorage.Shared.Match)

local Bots = require(script.Parent.Parent.Bots.Bots)

local SpectateService = {}

local watching: { [Player]: Player } = {}

-- Everyone still competing, bots included.
local function candidates(): { Player }
	local list: { Player } = {}
	local everyone = Players:GetPlayers()
	for _, bot in Bots.All() do
		table.insert(everyone, bot)
	end
	for _, player in everyone do
		if player:GetAttribute(Match.PlayerAttr.InMatch) == true then
			table.insert(list, player)
		end
	end
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

-- Starts watching the first player still competing (or nobody, if the match is over).
function SpectateService.Begin(spectator: Player)
	setTarget(spectator, candidates()[1])
end

-- Moves to the previous (-1) or next (1) competing player.
function SpectateService.Step(spectator: Player, direction: number)
	local list = candidates()
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
	watching[spectator] = nil
	spectator:SetAttribute(Match.PlayerAttr.Spectating, 0)
	spectator.ReplicationFocus = nil
end

function SpectateService.StopAll()
	for spectator in table.clone(watching) do
		SpectateService.Stop(spectator)
	end
end

function SpectateService.IsSpectating(player: Player): boolean
	return if watching[player] then true else false
end

-- Someone was eliminated or left: anyone watching them moves on to another player.
function SpectateService.OnPlayerOut(player: Player)
	watching[player] = nil
	for spectator, target in table.clone(watching) do
		if target == player then
			SpectateService.Step(spectator, 1)
		end
	end
end

-- Characters can be rebuilt between rounds; keep everyone's streaming focus on the live one.
function SpectateService.Refresh()
	for spectator, target in watching do
		focusOn(spectator, target)
	end
end

function SpectateService.Init()
	Players.PlayerRemoving:Connect(SpectateService.OnPlayerOut)
	Bots.Removing:Connect(SpectateService.OnPlayerOut)
end

return SpectateService
