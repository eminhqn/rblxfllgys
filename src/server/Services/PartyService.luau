--!strict
-- Parties: a few players (Config.Social.PartyMaxSize) who play together. A party queues for
-- matches together (MatchService) and is always put on the same team in team rounds
-- (TeamService).
--
-- Anyone in a party can invite another player in the server; the invite lasts
-- Config.Social.PartyInviteTime seconds. Accepting moves you out of any party you were in. A party
-- with one player left is closed. Clients ask through the RequestParty remote, and every request
-- is checked here. Each player's PartyId attribute says which party they're in, so clients can
-- list the members; PartyEvent tells players what just happened (see Shared/Remotes).

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Config = require(Shared.Config)
local Match = require(Shared.Match)
local MathUtil = require(Shared.MathUtil)
local Remotes = require(Shared.Remotes)
local Signal = require(Shared.Signal)

local RateLimiter = require(script.Parent.Parent.Util.RateLimiter)

local PartyService = {}

-- A player's party changed (they joined, left, or their party closed).
PartyService.Changed = Signal.new() :: Signal.Signal<Player>

type Party = {
	Id: string,
	Members: { Player },
}

local parties: { [string]: Party } = {}
local partyOf: { [Player]: Party } = {}
local invites: { [Player]: { [Player]: number } } = {} -- invited player -> who invited them -> expiry
local limiter = RateLimiter.new(8, 2)

local function notify(player: Player, kind: string, userId: number)
	if player.Parent == Players then
		Remotes.Event("PartyEvent"):FireClient(player, kind, userId)
	end
end

local function setParty(player: Player, party: Party?)
	if party then
		partyOf[player] = party
	else
		partyOf[player] = nil
	end
	if player.Parent == Players then
		player:SetAttribute(Match.PlayerAttr.Party, if party then party.Id else "")
	end
	PartyService.Changed:Fire(player)
end

local function leave(player: Player)
	local party = partyOf[player]
	if not party then
		return
	end
	local index = table.find(party.Members, player)
	if index then
		table.remove(party.Members, index)
	end
	setParty(player, nil)
	for _, member in party.Members do
		notify(member, "Left", player.UserId)
	end
	if #party.Members <= 1 then
		-- Nobody to play with: the party closes.
		for _, member in party.Members do
			setParty(member, nil)
		end
		table.clear(party.Members)
		parties[party.Id] = nil
	end
end

local function sizeOf(player: Player): number
	local party = partyOf[player]
	return if party then #party.Members else 1
end

-- Puts `player` in `host`'s party (starting one if the host has none). False if it's full.
local function join(player: Player, host: Player): boolean
	local party = partyOf[host]
	if party and party == partyOf[player] then
		return true
	end
	if sizeOf(host) >= Config.Social.PartyMaxSize then
		return false
	end
	leave(player)
	local current = partyOf[host]
	if not current then
		local created: Party = { Id = HttpService:GenerateGUID(false), Members = { host } }
		parties[created.Id] = created
		setParty(host, created)
		current = created
	end
	table.insert(current.Members, player)
	setParty(player, current)
	for _, member in current.Members do
		notify(member, "Joined", player.UserId)
	end
	return true
end

local function invite(player: Player, target: Player)
	if target == player or (partyOf[player] and partyOf[player] == partyOf[target]) then
		return
	end
	if sizeOf(player) >= Config.Social.PartyMaxSize then
		notify(player, "Full", player.UserId)
		return
	end
	local pending = invites[target]
	if not pending then
		pending = {}
		invites[target] = pending
	end
	local now = os.clock()
	local expires = pending[player]
	if expires and expires > now then
		return -- already asked
	end
	pending[player] = now + Config.Social.PartyInviteTime
	notify(target, "Invited", player.UserId)
	notify(player, "InviteSent", target.UserId)
end

-- Takes the invite from `host` to `player` if it's still open.
local function takeInvite(player: Player, host: Player): boolean
	local pending = invites[player]
	local expires = if pending then pending[host] else nil
	if pending then
		pending[host] = nil
	end
	return expires ~= nil and expires > os.clock()
end

local function onRequest(player: Player, action: unknown, userId: unknown)
	if not limiter:Allow(player) or typeof(action) ~= "string" then
		return
	end
	if action == "Leave" then
		leave(player)
		return
	end
	if typeof(userId) ~= "number" or not MathUtil.isFiniteNumber(userId) then
		return
	end
	local other = Players:GetPlayerByUserId(userId)
	if not other then
		return
	end
	if action == "Invite" then
		invite(player, other)
	elseif action == "Accept" then
		if not takeInvite(player, other) then
			notify(player, "Expired", other.UserId)
		elseif not join(player, other) then
			notify(player, "Full", other.UserId)
		end
	elseif action == "Decline" then
		if takeInvite(player, other) then
			notify(other, "Declined", player.UserId)
		end
	end
end

-- The id of the party the player is in, or nil.
function PartyService.GetPartyId(player: Player): string?
	local party = partyOf[player]
	return if party then party.Id else nil
end

-- Everyone in the player's party, the player included ({ player } if they aren't in one).
function PartyService.GetMembers(player: Player): { Player }
	local party = partyOf[player]
	return if party then table.clone(party.Members) else { player }
end

function PartyService.Init()
	local function onPlayerAdded(player: Player)
		player:SetAttribute(Match.PlayerAttr.Party, "")
	end
	Players.PlayerAdded:Connect(onPlayerAdded)
	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end
	Players.PlayerRemoving:Connect(function(player: Player)
		leave(player)
		invites[player] = nil
		for _, pending in invites do
			pending[player] = nil
		end
	end)
	Remotes.Event("RequestParty").OnServerEvent:Connect(onRequest)
end

return PartyService
