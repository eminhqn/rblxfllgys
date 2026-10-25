--!strict
-- Updates without kicking anyone. When you publish a new version (or restart servers from the
-- Creator Dashboard), Roblox closes the old servers. Instead of everyone being dropped:
--   1. each closing server sends its players together to a temporary holding server (a reserved
--      server of this same place), saving their data on the way out as usual;
--   2. the holding server runs none of the game, just an "updating" screen, and after a few
--      seconds (so the old servers are gone) sends everyone on to a normal server, which is now
--      running the new version.
--
-- Nothing happens in Studio. The holding server is recognised as a reserved server with no
-- owner: this game doesn't use reserved servers for anything else, so if you ever add some,
-- give them teleport data and check it here too.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TeleportService = game:GetService("TeleportService")

local Match = require(ReplicatedStorage.Shared.Match)

local SoftShutdown = {}

local HOLD_TIME = 8 -- seconds in the holding server before moving on
local RETRY_DELAY = 4
local SHUTDOWN_WAIT = 25 -- the most a closing server waits for its players to leave

function SoftShutdown.IsHoldingServer(): boolean
	return game.PrivateServerId ~= "" and game.PrivateServerOwnerId == 0
end

local function teleport(players: { Player }, options: TeleportOptions?): boolean
	local ok, err = pcall(function()
		TeleportService:TeleportAsync(game.PlaceId, players, options)
	end)
	if not ok then
		warn(`[SoftShutdown] Teleport failed: {err}`)
	end
	return ok
end

-- The holding server: show the updating screen, wait a moment, then send everyone to a normal
-- server. Anyone whose teleport fails is tried again.
function SoftShutdown.RunHoldingServer()
	ReplicatedStorage:SetAttribute(Match.HoldingServerAttribute, true)
	local arrived: { [Player]: number } = {}
	local function onPlayerAdded(player: Player)
		arrived[player] = os.clock()
	end
	Players.PlayerAdded:Connect(onPlayerAdded)
	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end
	Players.PlayerRemoving:Connect(function(player: Player)
		arrived[player] = nil
	end)
	TeleportService.TeleportInitFailed:Connect(function(player: Player)
		if arrived[player] then
			arrived[player] = os.clock() - HOLD_TIME + RETRY_DELAY -- try again shortly
		end
	end)

	task.spawn(function()
		while true do
			task.wait(1)
			local ready: { Player } = {}
			local now = os.clock()
			for player, time in arrived do
				if now - time >= HOLD_TIME then
					table.insert(ready, player)
					arrived[player] = math.huge -- sent; reset by TeleportInitFailed if it fails
				end
			end
			-- Together, so groups who came from the same server land in the same new one.
			if #ready > 0 and not teleport(ready) then
				for _, player in ready do
					if player.Parent == Players then
						arrived[player] = now - HOLD_TIME + RETRY_DELAY
					end
				end
			end
		end
	end)
end

-- On normal servers: when the server is closing with players in it, move them to a holding server.
function SoftShutdown.Init()
	if RunService:IsStudio() or game.PlaceId == 0 then
		return
	end
	game:BindToClose(function()
		if #Players:GetPlayers() == 0 then
			return
		end
		local ok, code = pcall(function(): string
			return (TeleportService:ReserveServer(game.PlaceId))
		end)
		if not ok then
			warn(`[SoftShutdown] Couldn't reserve a holding server: {code}`)
			return
		end
		local options = Instance.new("TeleportOptions")
		options.ReservedServerAccessCode = code
		options:SetTeleportData({ WobbleSoftShutdown = true })
		teleport(Players:GetPlayers(), options)
		-- Anyone who joins while we're closing goes too.
		Players.PlayerAdded:Connect(function(player: Player)
			teleport({ player }, options)
		end)
		-- Players leaving save their data (DataService); give them time to go.
		local deadline = os.clock() + SHUTDOWN_WAIT
		while #Players:GetPlayers() > 0 and os.clock() < deadline do
			task.wait(0.5)
		end
	end)
end

return SoftShutdown
