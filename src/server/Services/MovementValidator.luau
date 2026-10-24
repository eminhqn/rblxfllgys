--!strict
-- Sanity-checks client-simulated movement twice a second (no per-frame server loop).
--
-- Clients own their Bloblet's physics so movement feels instant, which means a modified client
-- could try to speed-hack or teleport. Sustained impossible horizontal speed snaps the character
-- back to its last good position. Falling out of the world respawns it.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Config = require(Shared.Config)
local MathUtil = require(Shared.MathUtil)
local Match = require(Shared.Match)

local CharacterService = require(script.Parent.CharacterService)
local PlayerState = require(script.Parent.PlayerState)

local MovementValidator = {}

local function checkPlayer(player: Player, now: number)
	local character = player.Character
	local root = if character then character.PrimaryPart else nil
	if not character or not root or not character.Parent then
		return
	end
	local position = root.Position
	local limits = Config.Validation

	-- Lobby bounds only. Anyone with a match status (competing, or just eliminated and about to be
	-- moved back by MatchService) is handled by the match instead.
	local status = player:GetAttribute(Match.PlayerAttr.Status)
	local inMatch = status ~= nil and status ~= "None"
	if
		not inMatch
		and (position.Y < limits.OutOfBoundsY or MathUtil.flat(position).Magnitude > limits.OutOfBoundsRadius)
	then
		CharacterService.Respawn(player)
		return
	end

	local state = PlayerState.Get(player)
	local lastPosition = state.LastPosition
	if now < state.TeleportGraceUntil or lastPosition == nil then
		state.LastPosition = position
		state.LastGoodPosition = position
		state.LastCheck = now
		return
	end

	local elapsed = math.max(now - state.LastCheck, 1e-3)
	local horizontalSpeed = MathUtil.flat(position - lastPosition).Magnitude / elapsed
	if horizontalSpeed > limits.MaxHorizontalSpeed then
		state.Strikes += 1
	else
		state.Strikes = math.max(0, state.Strikes - 1)
		state.LastGoodPosition = position
	end

	if state.Strikes >= limits.StrikesBeforeCorrection then
		local goodPosition = state.LastGoodPosition or position
		warn(`[MovementValidator] {player.Name} moved {math.floor(horizontalSpeed)} studs/s; correcting`)
		character:PivotTo(CFrame.new(goodPosition) * root.CFrame.Rotation)
		PlayerState.GrantTeleportGrace(player)
		return
	end

	state.LastPosition = position
	state.LastCheck = now
end

function MovementValidator.Init()
	task.spawn(function()
		while true do
			task.wait(Config.Validation.CheckInterval)
			local now = os.clock()
			for _, player in Players:GetPlayers() do
				checkPlayer(player, now)
			end
		end
	end)
end

return MovementValidator
