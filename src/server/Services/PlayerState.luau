--!strict
-- Server-only bookkeeping per player: cooldowns and movement-validation history.
-- Nothing in here is replicated, so clients cannot read or tamper with it.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)

export type State = {
	LastDive: number,
	LastGrab: number,
	LastKnockdown: number,
	LastRespawnRequest: number,
	TeleportGraceUntil: number,
	LastPosition: Vector3?,
	LastGoodPosition: Vector3?,
	LastCheck: number,
	Strikes: number,
	ActionToken: number,
	RagdollToken: number,
	GrabToken: number,
}

local states: { [Player]: State } = {}

local PlayerState = {}

local function newState(): State
	return {
		LastDive = -math.huge,
		LastGrab = -math.huge,
		LastKnockdown = -math.huge,
		LastRespawnRequest = -math.huge,
		TeleportGraceUntil = 0,
		LastPosition = nil,
		LastGoodPosition = nil,
		LastCheck = 0,
		Strikes = 0,
		ActionToken = 0,
		RagdollToken = 0,
		GrabToken = 0,
	}
end

function PlayerState.Get(player: Player): State
	local existing = states[player]
	if existing then
		return existing
	end
	local state = newState()
	-- Don't keep state for players that already left (e.g. a delayed task firing late).
	if player.Parent == Players then
		states[player] = state
	end
	return state
end

-- Call after the server moves a character so the validator doesn't flag the jump as cheating.
function PlayerState.GrantTeleportGrace(player: Player)
	local state = PlayerState.Get(player)
	state.TeleportGraceUntil = os.clock() + Config.Validation.TeleportGrace
	state.LastPosition = nil
	state.Strikes = 0
end

function PlayerState.Init()
	Players.PlayerRemoving:Connect(function(player: Player)
		states[player] = nil
	end)
end

return PlayerState
