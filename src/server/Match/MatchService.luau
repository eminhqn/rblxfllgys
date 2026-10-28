--!strict
-- Lobby -> matchmaking -> rounds -> winner.
--
-- Matchmaking: players press PLAY to join the queue. Once MinPlayers are queued a countdown
-- starts (shortened when the queue fills up to MaxPlayers). A match then plays rounds picked by
-- MiniGameRegistry, shrinking the field by each round type's qualify share, until a Final crowns
-- the winner on the lobby podium. A party (PartyService) queues and plays together: PLAY or
-- CANCEL from any member counts for all of them, and team rounds keep them on one team unless
-- that would make the teams uneven (they're told when that happens).
--
-- Bots (Server/Bots): when the countdown ends with fewer than Config.Bots.FillTo players, bots
-- fill the match. With bots on, one player pressing PLAY is enough to start the countdown. Bots
-- play every round like players (BotBrain drives them while a round is on), and a bot that's
-- knocked out simply leaves; they all go when the match is over.
--
-- Items (ItemService): players pick the items they want while each round loads, and they start
-- working at GO. A player knocked out mid-round who has a RESPAWN is offered it for a few seconds
-- (RespawnOfferUntil); taking it drops them back in next to someone still in the round.
--
-- Spectating (SpectateService): a knocked-out player is moved to the lobby and watches the match.
-- They can go back to the lobby, and from there watch again while the match is on (KnockedOut).
-- A player who qualifies mid-round watches the players still going while they wait.
--
-- Revives: until the final, a knocked-out player can REVIVE (ReviveOpen) into the round after the
-- one they went out in, using a RESPAWN, or buying one revive a match if they have none (the
-- server shows the purchase: PurchaseService). The next round waits for anyone just knocked out
-- to decide (Config.Items.ReviveTime, and while they're buying), so going out at the very end of
-- a round still gives you the time; once that round starts it's too late. Revived players watch
-- until it starts. If the match ends first (nobody through, or one player through: they win, a
-- revive never takes that away), the revive is handed back as a RESPAWN.
--
-- Everything clients need is published as attributes (see Shared/Match). The only per-tick work
-- is the mini-game Update loop, which runs a few times a second and only during a round.

local HttpService = game:GetService("HttpService")
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local Config = require(Shared.Config)
local Match = require(Shared.Match)
local Remotes = require(Shared.Remotes)
local Teams = require(Shared.Teams)

local BotBrain = require(script.Parent.Parent.Bots.BotBrain)
local BotRoster = require(script.Parent.Parent.Bots.BotRoster)
local Bots = require(script.Parent.Parent.Bots.Bots)

local Services = script.Parent.Parent.Services
local CharacterService = require(Services.CharacterService)
local ItemService = require(Services.ItemService)
local LobbyService = require(Services.LobbyService)
local PartyService = require(Services.PartyService)
local ProgressService = require(Services.ProgressService)
local PurchaseService = require(Services.PurchaseService)
local TeamService = require(Services.TeamService)
local RateLimiter = require(script.Parent.Parent.Util.RateLimiter)

local ArenaUtil = require(script.Parent.ArenaUtil)
local MiniGameRegistry = require(script.Parent.MiniGameRegistry)
local RoundContext = require(script.Parent.RoundContext)
local SpectateService = require(script.Parent.SpectateService)
local Types = require(script.Parent.Types)

local MatchService = {}

local matchConfig = Config.Match
local botsConfig = Config.Bots
local MIN_PLAYERS = if RunService:IsStudio()
	then matchConfig.MinPlayersInStudio
	elseif botsConfig.Enabled then 1
	else matchConfig.MinPlayers
local COVER_DELAY = 0.45 -- lets client screens finish covering before anything teleports
local REVIVE_PURCHASE_HOLD = 30 -- the most the next round waits while someone's buying a revive
local REVIVE_RECEIPT_GRACE = 6 -- and once they've bought it, for the purchase to come through
local OFFER_FREEZE_DELAY = 1 -- seconds into a respawn offer before the knocked-out Bloblet stops

local Attr = Match.Attr
local PlayerAttr = Match.PlayerAttr

local state: Folder = Match.GetFolder()
local arenas: Folder

local queue: { Player } = {}
local matchRunning = false
local matchPlayers: { [Player]: boolean } = {}
local currentControl: RoundContext.Control? = nil
local countdownToken = 0

local queueLimiter = RateLimiter.new(4, 2)
local spectateLimiter = RateLimiter.new(6, 4)
local lobbyLimiter = RateLimiter.new(3, 1)
local respawnLimiter = RateLimiter.new(4, 2)
local watchLimiter = RateLimiter.new(3, 1)
local reviveLimiter = RateLimiter.new(3, 2)

local offers: { [Player]: number } = {} -- open respawn offers: player -> token
local offerToken = 0
local respawnsThisRound: { [Player]: number } = {}
local onRevived: ((player: Player) -> ())? = nil -- the current round's bookkeeping
local revivesThisMatch: { [Player]: number } = {}
local pendingRevives: { Player } = {} -- revived, waiting for the next round to start
local refreshRevive: (player: Player) -> ()
local reviveRound = 0 -- the round a revive joins right now (the next one), 0 = none
local reviveFor: { [Player]: number } = {} -- the round each knocked-out player can revive into
local reviveDeadlines: { [Player]: number } = {} -- the next round waits for them till (os.clock())
local buyingUntil: { [Player]: number } = {} -- and while they're buying one (os.clock())

local function serverNow(): number
	return Workspace:GetServerTimeNow()
end

local function setPhase(phase: Match.Phase, duration: number?)
	-- The end time first, so it's already there when clients react to the new phase.
	state:SetAttribute(Attr.PhaseEndsAt, if duration then serverNow() + duration else 0)
	state:SetAttribute(Attr.Phase, phase)
end

local function getPhase(): Match.Phase
	return (state:GetAttribute(Attr.Phase) or "Idle") :: Match.Phase
end

local function setStatus(player: Player, status: Match.Status)
	player:SetAttribute(PlayerAttr.Status, status)
end

local function connected(list: { Player }): { Player }
	local result: { Player } = {}
	for _, player in list do
		if player.Parent == Players then
			table.insert(result, player)
		end
	end
	return result
end

-- How many go through: the type's share, but always at least one in and one out.
local function qualifyTarget(alive: number, fraction: number): number
	if alive <= 1 then
		return alive
	end
	return math.clamp(math.floor(alive * fraction + 0.5), 1, alive - 1)
end

-- Team scores go to clients as one JSON attribute, in the usual team order.
local function publishTeamScores(scores: { [string]: number }?, total: number?)
	if not scores then
		state:SetAttribute(Attr.TeamScores, "")
		return
	end
	local list = {}
	for _, def in Teams.List do
		local score = scores[def.Id]
		if score then
			table.insert(list, { Id = def.Id, Score = score })
		end
	end
	state:SetAttribute(Attr.TeamScores, HttpService:JSONEncode({ Total = total, Scores = list }))
end

local function formatSeconds(seconds: number): string
	local whole = math.max(0, math.ceil(seconds))
	return string.format("%d:%02d", whole // 60, whole % 60)
end

local function refreshLobbyScreen()
	local phase = getPhase()
	local queued = #queue
	local text: string
	if phase == "Winner" then
		local winnerName = state:GetAttribute(Attr.WinnerName)
		text = if typeof(winnerName) == "string" and winnerName ~= ""
			then `{winnerName} wins the match!`
			else "Match over: no winner this time"
	elseif matchRunning then
		local round = state:GetAttribute(Attr.RoundNumber)
		local name = state:GetAttribute(Attr.RoundName)
		text = `Match in progress · Round {tostring(round)}: {tostring(name)}`
		if queued > 0 then
			text ..= ` · {queued} queued for the next one`
		end
	elseif phase == "Queue" then
		local endsAt = state:GetAttribute(Attr.PhaseEndsAt)
		local remaining = if typeof(endsAt) == "number" then endsAt - serverNow() else 0
		text = `Next match in {formatSeconds(remaining)} · {queued} queued`
	elseif queued > 0 then
		text = `{queued} / {MIN_PLAYERS} players queued · press PLAY to join`
	else
		text = "Press PLAY to join a match"
	end
	LobbyService.SetStatus(text)
end

local function updateQueueAttributes()
	state:SetAttribute(Attr.QueueCount, #queue)
	state:SetAttribute(Attr.QueueMin, MIN_PLAYERS)
	state:SetAttribute(Attr.QueueMax, Config.MaxPlayers)
end

-- Team rounds over: nobody's party is split any more.
local function clearTeams(players: { Player })
	TeamService.ClearTeams()
	for _, player in players do
		player:SetAttribute(PlayerAttr.PartySplit, nil)
	end
end

local function removeFromQueue(player: Player)
	local index = table.find(queue, player)
	if index then
		table.remove(queue, index)
	end
	player:SetAttribute(PlayerAttr.Queued, false)
end

-------------------------------------------------------------------------------------------------
-- Rounds
-------------------------------------------------------------------------------------------------

-- Could this knocked-out player revive right now? Only into the round after the one they went out
-- in (none after the final, or when the match is about to end), and only RevivesPerMatch times a
-- match.
local function reviveAllowed(player: Player): boolean
	if not matchRunning or player.Parent ~= Players or Bots.Is(player) then
		return false
	end
	if player:GetAttribute(PlayerAttr.KnockedOut) ~= true then
		return false
	end
	return reviveRound ~= 0
		and reviveFor[player] == reviveRound
		and (revivesThisMatch[player] or 0) < Config.Items.RevivesPerMatch
end

-- And they have a way to: a RESPAWN, a revive they can still buy, or one they're buying.
local function canStillRevive(player: Player): boolean
	return reviveAllowed(player)
		and (
			ItemService.Count(player, "Respawn") > 0
			or (Config.Items.ReviveProductId ~= 0 and player:GetAttribute(PlayerAttr.ReviveBought) ~= true)
			or (buyingUntil[player] or 0) > os.clock()
		)
end

function refreshRevive(player: Player)
	if player.Parent == Players then
		player:SetAttribute(PlayerAttr.ReviveOpen, if reviveAllowed(player) then true else nil)
	end
end

local function refreshRevives()
	for player in matchPlayers do
		refreshRevive(player)
	end
end

-- Brings a knocked-out player back for the match's next round, using one of their RESPAWNS (or
-- the revive they've just bought: `bought`). They watch the match until then, like everyone
-- waiting for the next round.
local function revive(player: Player, bought: boolean?): boolean
	if not reviveAllowed(player) or (not bought and not ItemService.Take(player, "Respawn")) then
		return false
	end
	revivesThisMatch[player] = (revivesThisMatch[player] or 0) + 1
	table.insert(pendingRevives, player)
	reviveDeadlines[player] = nil
	buyingUntil[player] = nil
	player:SetAttribute(PlayerAttr.KnockedOut, nil)
	player:SetAttribute(PlayerAttr.InMatch, true)
	refreshRevive(player)
	if not SpectateService.IsSpectating(player) then
		SpectateService.Begin(player) -- (before the status, so their screen goes straight to watching)
	end
	setStatus(player, "Qualified")
	Remotes.Event("ReviveEvent"):FireClient(player, "Revived")
	return true
end

-- Anyone revived since the last round joins the next one.
local function joinRevived(alive: { Player }): { Player }
	for _, player in pendingRevives do
		if
			player.Parent == Players
			and player:GetAttribute(PlayerAttr.InMatch) == true
			and not table.find(alive, player)
		then
			table.insert(alive, player)
		end
	end
	table.clear(pendingRevives)
	return alive
end

-- The match is over before revived players got their round: they get their RESPAWN back.
local function returnRevives()
	for _, player in pendingRevives do
		if player.Parent == Players then
			ItemService.Add(player, "Respawn", 1)
			Remotes.Event("ReviveEvent"):FireClient(player, "Returned")
		end
	end
	table.clear(pendingRevives)
end

-- The round's over. Anyone just knocked out who could REVIVE into the next round gets ReviveTime
-- from when they were out to decide (and however long they're buying one): the next round waits
-- for them, as a revive always joins the round after the one you went out in. Going back to the
-- lobby lets the match get on (you can still revive from there until the next round starts).
local function waitForRevives()
	local shownUntil = 0
	while true do
		local now = os.clock()
		local holdUntil = 0
		for player, deadline in reviveDeadlines do
			if canStillRevive(player) then
				holdUntil = math.max(holdUntil, deadline)
			end
		end
		for player, buying in buyingUntil do
			if reviveAllowed(player) then
				holdUntil = math.max(holdUntil, buying)
			end
		end
		local left = holdUntil - now
		if left <= 0 then
			return
		end
		if math.abs(holdUntil - shownUntil) > 0.5 then
			shownUntil = holdUntil
			setPhase("RoundOver", left) -- (the round-over timer shows the wait)
		end
		task.wait(math.min(left, 0.2))
	end
end

-- Qualified mid-round: once they've seen their finish, they watch the players still going while
-- they wait for the next round.
local function watchWhileWaiting(player: Player, control: RoundContext.Control)
	if Bots.Is(player) or getPhase() ~= "Playing" then
		return
	end
	task.delay(matchConfig.QualifiedSpectateDelay, function()
		if
			player.Parent == Players
			and currentControl == control
			and getPhase() == "Playing"
			and player:GetAttribute(PlayerAttr.Status) == "Qualified"
		then
			SpectateService.Begin(player)
		end
	end)
end

-- Lets a knocked-out player see their fall, then brings them back to the lobby to spectate. A
-- knocked-out bot just goes.
local function sendOut(player: Player)
	task.delay(matchConfig.EliminatedRespawnDelay, function()
		if player.Parent ~= Players or player:GetAttribute(PlayerAttr.Status) ~= "Eliminated" then
			return
		end
		if Bots.Is(player) then
			BotRoster.Despawn(player)
			return
		end
		CharacterService.Spawn(player)
		SpectateService.Begin(player)
		-- Out of the arena now: they can watch from the lobby again later, or revive (and the next
		-- round gives them time to).
		player:SetAttribute(PlayerAttr.KnockedOut, true)
		reviveDeadlines[player] = os.clock() + Config.Items.ReviveTime
		refreshRevive(player)
	end)
end

local function closeOffer(player: Player, used: boolean)
	if not offers[player] then
		return
	end
	offers[player] = nil
	if player.Parent == Players then
		player:SetAttribute(PlayerAttr.RespawnOfferUntil, nil)
	end
	if not used then
		sendOut(player)
	end
end

local function closeAllOffers()
	for player in table.clone(offers) do
		closeOffer(player, false)
	end
end

-- Could this knocked-out player use a respawn right now?
local function respawnAllowed(player: Player): boolean
	local control = currentControl
	if not control or getPhase() ~= "Playing" or player.Parent ~= Players or control.IsDone() then
		return false
	end
	if state:GetAttribute(Attr.RoundType) == "Final" and not Config.Items.RespawnInFinal then
		return false
	end
	return (respawnsThisRound[player] or 0) < Config.Items.RespawnsPerRound
		and ItemService.Count(player, "Respawn") > 0
		and control.CanRevive(player)
end

-- Offers a respawn for a few seconds. False if there's nothing to offer.
local function offerRespawn(player: Player): boolean
	if not respawnAllowed(player) then
		return false
	end
	offerToken += 1
	local token = offerToken
	offers[player] = token
	local window = Config.Items.RespawnOfferTime
	player:SetAttribute(PlayerAttr.RespawnOfferUntil, serverNow() + window)
	-- Once they've seen their fall, their Bloblet waits where it is (not falling out of the world).
	task.delay(OFFER_FREEZE_DELAY, function()
		local character = player.Character
		local root = if character then character.PrimaryPart else nil
		if offers[player] == token and root then
			root.Anchored = true
		end
	end)
	task.delay(window, function()
		if offers[player] == token then
			closeOffer(player, false)
		end
	end)
	return true
end

local function onEliminated(player: Player)
	reviveFor[player] = reviveRound -- (the round after this one)
	setStatus(player, "Eliminated")
	player:SetAttribute(PlayerAttr.InMatch, false)
	SpectateService.OnPlayerOut(player)
	if not offerRespawn(player) then
		sendOut(player)
	end
end

-- The player answered their respawn offer.
local function onRespawnChoice(player: Player, use: unknown)
	if not respawnLimiter:Allow(player) or typeof(use) ~= "boolean" or not offers[player] then
		return
	end
	local control = currentControl
	if
		not use
		or not control
		or player:GetAttribute(PlayerAttr.Status) ~= "Eliminated"
		or not respawnAllowed(player)
		or not control.Revive(player)
	then
		closeOffer(player, false)
		return
	end
	if not ItemService.Take(player, "Respawn") then
		warn(`[MatchService] {player.Name} respawned without a respawn to use`)
	end
	respawnsThisRound[player] = (respawnsThisRound[player] or 0) + 1
	closeOffer(player, true)
	player:SetAttribute(PlayerAttr.InMatch, true)
	setStatus(player, "Playing")
	local hook = onRevived
	if hook then
		hook(player)
	end
	local root = control.Context.GetRoot(player)
	if root then
		Remotes.Event("ItemEffect"):FireAllClients("Revive", root.Position)
	end
end

local function safeCall(label: string, callback: () -> ()): boolean
	local ok, err = pcall(function(): string?
		callback()
		return nil
	end)
	if not ok then
		warn(`[MatchService] {label} failed: {err}`)
	end
	return ok
end

local function waitUntil(clockTime: number)
	local remaining = clockTime - os.clock()
	if remaining > 0 then
		task.wait(remaining)
	end
end

-- Plays one round and returns the players who qualified.
local function runRound(
	module: Types.MiniGameModule,
	players: { Player },
	roundNumber: number,
	solo: boolean
): { Player }
	local info = module.Info
	-- This round's players are set: from now on, a revive joins the round after it.
	reviveRound = if info.Type == "Final" then 0 else roundNumber + 1
	table.clear(reviveDeadlines)
	table.clear(buyingUntil)
	local fraction = if info.Type == "Final" then 0 else matchConfig.QualifyFraction[info.Type]
	local target = if info.Type == "Final" then 1 else qualifyTarget(#players, fraction)

	local arena = Instance.new("Model")
	arena.Name = `Arena_{info.Id}`
	arena.Parent = arenas

	-- When play got going and when each player went out, for time survived.
	local playingSince: number? = nil
	local outAt: { [Player]: number } = {}

	local control: RoundContext.Control
	control = RoundContext.new(info, players, target, arena, CFrame.new(matchConfig.ArenaOrigin), {
		OnQualified = function(player: Player)
			setStatus(player, "Qualified")
			SpectateService.OnPlayerDone(player)
			watchWhileWaiting(player, control)
		end,
		OnEliminated = function(player: Player)
			outAt[player] = serverNow()
			onEliminated(player)
		end,
		OnChanged = function()
			state:SetAttribute(Attr.CounterText, control.GetCounterText())
			SpectateService.Refresh()
		end,
		OnTeamScores = publishTeamScores,
		OnAnnounce = function(text: string, teamId: string?)
			state:SetAttribute(
				Attr.Announcement,
				HttpService:JSONEncode({ Text = text, Team = teamId, At = serverNow() })
			)
		end,
	})
	currentControl = control
	local context = control.Context
	table.clear(respawnsThisRound)
	onRevived = function(player: Player)
		outAt[player] = nil -- back in: their time survived keeps counting
	end

	if info.Type == "Team" then
		local teams, split = TeamService.AssignRandomTeams(players, info.TeamCount or 2, PartyService.GetPartyId)
		context.Teams = teams
		-- Their party couldn't stay together without uneven teams: their screens say so.
		for _, player in split do
			player:SetAttribute(PlayerAttr.PartySplit, true)
		end
	end

	state:SetAttribute(Attr.RoundNumber, roundNumber)
	state:SetAttribute(Attr.RoundName, info.DisplayName)
	state:SetAttribute(Attr.RoundId, info.Id)
	state:SetAttribute(Attr.RoundType, info.Type)
	state:SetAttribute(Attr.RoundRules, info.Rules)
	state:SetAttribute(Attr.CounterText, control.GetCounterText())
	for _, player in players do
		SpectateService.Stop(player) -- (qualified or revived players were watching)
		setStatus(player, "Playing")
	end
	ProgressService.RoundStarted(players, info.Type)
	-- Until GO everyone in the round can pick the items they want to use in it.
	ItemService.OpenPicks(players)

	-- Loading: screens cover, the arena is built and everyone is moved in (frozen).
	setPhase("Loading", matchConfig.LoadingTime)
	refreshRevives() -- (players out of earlier rounds have missed theirs)
	refreshLobbyScreen()
	local loadingEnds = os.clock() + matchConfig.LoadingTime
	task.wait(COVER_DELAY)

	local miniGame: Types.MiniGame? = nil
	local setupOk = safeCall(`{info.Id}.new/Setup`, function()
		local created = module.new(context)
		miniGame = created
		created.Setup()
	end)
	local active = miniGame
	if not setupOk or not active then
		-- A broken mini-game shouldn't end the match: everyone goes through.
		ItemService.RoundEnded(players)
		clearTeams(players)
		publishTeamScores(nil)
		currentControl = nil
		arena:Destroy()
		return connected(players)
	end
	-- Where the arena is (its solid parts, not the scenery round it), so clients can fly the
	-- camera over it during the intro.
	local boundsCenter, boundsSize = ArenaUtil.SolidBounds(arena)
	if boundsCenter and boundsSize then
		state:SetAttribute(Attr.ArenaCenter, boundsCenter)
		state:SetAttribute(Attr.ArenaSize, boundsSize)
	end
	waitUntil(loadingEnds)

	-- Intro: round card and countdown.
	setPhase("Intro", matchConfig.IntroTime)
	task.wait(matchConfig.IntroTime)

	-- Playing.
	playingSince = serverNow()
	control.SetStarted(serverNow())
	control.ReleaseAll()
	ItemService.RoundStarted(context.GetAlive())
	setPhase("Playing", info.Duration)
	safeCall(`{info.Id}.Start`, active.Start)
	BotBrain.BeginRound(context, active, control.HandleReset)

	local endsAt = os.clock() + info.Duration
	local interval = 1 / matchConfig.UpdateRate
	local last = os.clock()
	while true do
		task.wait(interval)
		local now = os.clock()
		local ok, result = pcall(active.Update, now - last)
		last = now
		if not ok then
			warn(`[MatchService] {info.Id}.Update failed: {result}`)
			break
		end
		if result == true or control.IsDone() or now >= endsAt then
			break
		end
	end
	BotBrain.EndRound()
	safeCall(`{info.Id}.End`, active.End)
	local playEndedAt = serverNow()
	onRevived = nil
	closeAllOffers()

	local qualified: { Player } = {}
	safeCall(`{info.Id}.GetQualified`, function()
		for _, player in active.GetQualified() do
			if player.Parent == Players and table.find(players, player) and not table.find(qualified, player) then
				table.insert(qualified, player)
			end
		end
	end)

	-- Round over: freeze the survivors, eliminate everyone else.
	setPhase("RoundOver", matchConfig.RoundOverTime)
	control.FreezeAll()
	for _, player in qualified do
		if not context.IsAlive(player) then
			-- e.g. the last Bloblet to fall in a Final: they're back in, not out.
			SpectateService.Stop(player)
			player:SetAttribute(PlayerAttr.InMatch, true)
		end
		setStatus(player, "Qualified")
	end
	for _, player in players do
		if context.IsAlive(player) and not table.find(qualified, player) then
			context.Eliminate(player)
		end
	end
	state:SetAttribute(Attr.CounterText, control.GetCounterText())
	if #qualified < 2 and not solo then
		reviveRound = 0 -- no next round: the match ends after this one
		refreshRevives()
	end

	-- Gumdrops, stats and daily challenges for everyone who took part.
	for _, player in connected(players) do
		local survived = 0
		local since = playingSince
		if since then
			local stoppedAt = outAt[player] or playEndedAt
			survived = math.clamp(stoppedAt - since, 0, info.Duration)
		end
		ProgressService.RoundEnded(player, info.Type, table.find(qualified, player) ~= nil, roundNumber, survived)
	end
	-- After the rewards (DOUBLE REWARDS counts for this round): items stop working.
	ItemService.RoundEnded(players)
	task.wait(matchConfig.RoundOverTime)
	if reviveRound ~= 0 then
		waitForRevives()
	end

	if info.Type == "Team" then
		clearTeams(players)
	end
	publishTeamScores(nil)
	state:SetAttribute(Attr.Announcement, "")
	state:SetAttribute(Attr.ArenaCenter, nil)
	state:SetAttribute(Attr.ArenaSize, nil)
	currentControl = nil
	arena:Destroy()
	return connected(qualified)
end

-------------------------------------------------------------------------------------------------
-- Matches
-------------------------------------------------------------------------------------------------

local evaluateQueue: () -> ()

local function finishMatch(winner: Player?, rounds: number)
	reviveRound = 0
	returnRevives()
	state:SetAttribute(Attr.WinnerName, if winner then winner.DisplayName else "")
	state:SetAttribute(Attr.WinnerUserId, if winner then winner.UserId else 0)
	if winner then
		setStatus(winner, "Winner")
	end
	-- The winner's Crowns, and everyone's results screen (shown once they're back in the lobby).
	ProgressService.MatchEnded(winner, rounds)
	local inMatch: { Player } = {}
	for player in matchPlayers do
		table.insert(inMatch, player)
	end
	ItemService.MatchEnded(inMatch)
	setPhase("Winner", matchConfig.WinnerTime)
	refreshRevives()
	refreshLobbyScreen()
	task.wait(COVER_DELAY)

	-- Everyone still competing comes back to the lobby; the winner gets the podium.
	SpectateService.StopAll()
	for player in matchPlayers do
		if player.Parent == Players and player:GetAttribute(PlayerAttr.InMatch) == true then
			player:SetAttribute(PlayerAttr.InMatch, false)
			if player == winner then
				CharacterService.Spawn(player, LobbyService.GetWinnerSpot())
			elseif Bots.Is(player) then
				BotRoster.Despawn(player) -- bots don't hang about in the lobby
			else
				CharacterService.Spawn(player)
			end
		end
	end
	arenas:ClearAllChildren()
	local everyone: { Player } = {}
	for player in matchPlayers do
		table.insert(everyone, player)
	end
	clearTeams(everyone)

	task.wait(math.max(0, matchConfig.WinnerTime - COVER_DELAY))

	-- The celebration's over: the winner steps down from the podium and goes back to the lobby
	-- decks like everyone else (their screen has just covered).
	if winner and winner.Parent == Players and not Bots.Is(winner) then
		CharacterService.Spawn(winner)
	end
	for player in matchPlayers do
		if player.Parent == Players then
			setStatus(player, "None")
			player:SetAttribute(PlayerAttr.InMatch, false)
			player:SetAttribute(PlayerAttr.Spectating, 0)
			player:SetAttribute(PlayerAttr.KnockedOut, nil)
			player:SetAttribute(PlayerAttr.ReviveOpen, nil)
			player:SetAttribute(PlayerAttr.ReviveBought, nil)
		end
	end
	table.clear(matchPlayers)
	table.clear(revivesThisMatch)
	table.clear(reviveFor)
	table.clear(reviveDeadlines)
	table.clear(buyingUntil)
	BotRoster.ReleaseAll()
	for _, key in { Attr.RoundName, Attr.RoundId, Attr.RoundType, Attr.RoundRules, Attr.CounterText, Attr.WinnerName } do
		state:SetAttribute(key, "")
	end
	state:SetAttribute(Attr.RoundNumber, 0)
	state:SetAttribute(Attr.WinnerUserId, 0)
	state:SetAttribute(Attr.PlayersInMatch, 0)
	matchRunning = false
	setPhase("Idle")
	evaluateQueue()
end

local function runMatch(players: { Player })
	matchRunning = true
	table.clear(matchPlayers)
	ProgressService.MatchStarted(players)
	for _, player in players do
		removeFromQueue(player)
		matchPlayers[player] = true
		player:SetAttribute(PlayerAttr.InMatch, true)
		player:SetAttribute(PlayerAttr.Spectating, 0)
		setStatus(player, "Playing")
	end
	updateQueueAttributes()
	state:SetAttribute(Attr.PlayersInMatch, #players)

	-- Testing alone in Studio plays every round instead of winning instantly.
	local soloTest = RunService:IsStudio() and #players == 1
	local alive = players
	local played: { [string]: boolean } = {}
	local winner: Player? = nil
	local roundNumber = 0

	while true do
		alive = connected(alive)
		if #alive == 0 then
			break
		end
		if #alive == 1 and not soloTest then
			winner = alive[1]
			break
		end
		alive = joinRevived(alive)
		roundNumber += 1
		local module = MiniGameRegistry.PickNext(roundNumber, #alive, played)
		if not module then
			winner = if #alive == 1 then alive[1] else nil
			break
		end
		played[module.Info.Id] = true
		alive = runRound(module, alive, roundNumber, soloTest)
		if module.Info.Type == "Final" then
			winner = alive[1]
			break
		end
	end

	finishMatch(winner, roundNumber)
end

local function startCountdown()
	countdownToken += 1
	local token = countdownToken
	local countdown = if RunService:IsStudio()
		then matchConfig.StudioQueueCountdown
		elseif botsConfig.Enabled and #queue < matchConfig.MinPlayers then botsConfig.QueueCountdown
		else matchConfig.QueueCountdown
	setPhase("Queue", countdown)
	task.spawn(function()
		while countdownToken == token do
			local endsAt = state:GetAttribute(Attr.PhaseEndsAt)
			local remaining = if typeof(endsAt) == "number" then endsAt - serverNow() else 0
			if remaining <= 0 then
				break
			end
			refreshLobbyScreen()
			task.wait(math.min(1, remaining))
		end
		if countdownToken ~= token then
			return -- cancelled
		end
		countdownToken += 1
		-- First come, first in, but a party only comes in whole.
		local players: { Player } = {}
		local taken: { [Player]: boolean } = {}
		for _, player in connected(queue) do
			if taken[player] then
				continue
			end
			local group: { Player } = {}
			for _, member in PartyService.GetMembers(player) do
				if member.Parent == Players and table.find(queue, member) and not taken[member] then
					table.insert(group, member)
				end
			end
			if #players + #group <= Config.MaxPlayers then
				for _, member in group do
					taken[member] = true
					table.insert(players, member)
				end
			end
		end
		if #players < MIN_PLAYERS then
			setPhase("Idle")
			refreshLobbyScreen()
			return
		end
		-- Not enough players: bots make up the numbers.
		if botsConfig.Enabled and #players < botsConfig.FillTo then
			local names: { [string]: boolean } = {}
			for _, player in players do
				names[player.DisplayName] = true
			end
			for _, bot in BotRoster.Fill(botsConfig.FillTo - #players, names) do
				table.insert(players, bot)
			end
		end
		runMatch(players)
	end)
end

function evaluateQueue()
	updateQueueAttributes()
	if not matchRunning then
		local phase = getPhase()
		if #queue >= MIN_PLAYERS then
			if phase ~= "Queue" then
				startCountdown()
			elseif #queue >= Config.MaxPlayers then
				-- Full: don't keep everyone waiting.
				local endsAt = state:GetAttribute(Attr.PhaseEndsAt)
				local soon = serverNow() + matchConfig.FullQueueCountdown
				if typeof(endsAt) == "number" and endsAt > soon then
					state:SetAttribute(Attr.PhaseEndsAt, soon)
				end
			end
		elseif phase == "Queue" then
			countdownToken += 1 -- cancel
			setPhase("Idle")
		end
	end
	refreshLobbyScreen()
end

-------------------------------------------------------------------------------------------------
-- Remotes and setup
-------------------------------------------------------------------------------------------------

local function addToQueue(player: Player)
	if player.Parent ~= Players or player:GetAttribute(PlayerAttr.InMatch) == true then
		return -- gone, or already competing
	end
	if not table.find(queue, player) then
		table.insert(queue, player)
	end
	player:SetAttribute(PlayerAttr.Queued, true)
end

local function onRequestQueue(player: Player, wantsToPlay: unknown)
	if not queueLimiter:Allow(player) or typeof(wantsToPlay) ~= "boolean" then
		return
	end
	if player:GetAttribute(PlayerAttr.InMatch) == true then
		return -- already competing
	end
	-- The whole party queues (or stops queueing) together.
	for _, member in PartyService.GetMembers(player) do
		if wantsToPlay then
			addToQueue(member)
		elseif member:GetAttribute(PlayerAttr.InMatch) ~= true then
			removeFromQueue(member)
		end
	end
	evaluateQueue()
end

-- Someone joined a party whose players are queued: they're in the queue too.
local function onPartyChanged(player: Player)
	if player.Parent ~= Players or table.find(queue, player) then
		return
	end
	for _, member in PartyService.GetMembers(player) do
		if member ~= player and table.find(queue, member) then
			addToQueue(player)
			evaluateQueue()
			return
		end
	end
end

local function onRequestSpectate(player: Player, direction: unknown)
	if not spectateLimiter:Allow(player) or typeof(direction) ~= "number" then
		return
	end
	if not SpectateService.IsSpectating(player) then
		return
	end
	SpectateService.Step(player, if direction < 0 then -1 else 1)
end

-- Knocked out and back in the lobby: watch the match again.
local function onRequestWatchMatch(player: Player)
	if not watchLimiter:Allow(player) then
		return
	end
	local phase = getPhase()
	if
		not matchRunning
		or phase == "Winner"
		or player:GetAttribute(PlayerAttr.KnockedOut) ~= true
		or player:GetAttribute(PlayerAttr.Status) ~= "None"
	then
		return
	end
	SpectateService.Begin(player) -- (before the status, so their screen goes straight to watching)
	setStatus(player, "Eliminated")
end

-- REVIVE: with a RESPAWN it's used; with none, the revive is offered to buy (and the next round
-- waits while they decide).
local function onRequestRevive(player: Player)
	if not reviveLimiter:Allow(player) or not reviveAllowed(player) then
		return
	end
	if ItemService.Count(player, "Respawn") > 0 then
		revive(player)
		return
	end
	local productId = Config.Items.ReviveProductId
	if productId == 0 or player:GetAttribute(PlayerAttr.ReviveBought) == true then
		return
	end
	buyingUntil[player] = os.clock() + REVIVE_PURCHASE_HOLD
	local ok, err = pcall(function()
		MarketplaceService:PromptProductPurchase(player, productId)
	end)
	if not ok then
		buyingUntil[player] = nil
		warn(`[MatchService] Couldn't offer {player.Name} a revive: {err}`)
	end
end

-- The revive purchase screen closed: bought (the purchase is on its way), or not.
local function onPurchaseFinished(userId: number, productId: number, purchased: boolean)
	if productId ~= Config.Items.ReviveProductId then
		return
	end
	local player = Players:GetPlayerByUserId(userId)
	if not player or not buyingUntil[player] then
		return
	end
	if purchased then
		buyingUntil[player] = os.clock() + REVIVE_RECEIPT_GRACE
	else
		buyingUntil[player] = nil
	end
end

local function onRequestReturnToLobby(player: Player)
	if not lobbyLimiter:Allow(player) then
		return
	end
	if player:GetAttribute(PlayerAttr.Status) ~= "Eliminated" then
		return
	end
	reviveDeadlines[player] = nil -- (the next round needn't wait for them)
	SpectateService.Stop(player)
	setStatus(player, "None")
end

local function onPlayerAdded(player: Player)
	player:SetAttribute(PlayerAttr.Status, "None")
	player:SetAttribute(PlayerAttr.InMatch, false)
	player:SetAttribute(PlayerAttr.Queued, false)
	player:SetAttribute(PlayerAttr.Spectating, 0)
end

function MatchService.Init()
	MiniGameRegistry.Init()
	SpectateService.Init()

	local existing = Workspace:FindFirstChild("Arenas")
	if existing and existing:IsA("Folder") then
		arenas = existing
	else
		arenas = Instance.new("Folder")
		arenas.Name = "Arenas"
		arenas.Parent = Workspace
	end

	setPhase("Idle")
	publishTeamScores(nil)
	state:SetAttribute(Attr.RoundNumber, 0)
	state:SetAttribute(Attr.PlayersInMatch, 0)
	state:SetAttribute(Attr.WinnerUserId, 0)
	state:SetAttribute(Attr.WinnerSpot, LobbyService.GetWinnerSpot())
	updateQueueAttributes()

	Players.PlayerAdded:Connect(onPlayerAdded)
	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end
	Players.PlayerRemoving:Connect(function(player: Player)
		offers[player] = nil
		respawnsThisRound[player] = nil
		revivesThisMatch[player] = nil
		reviveFor[player] = nil
		reviveDeadlines[player] = nil
		buyingUntil[player] = nil
		local pending = table.find(pendingRevives, player)
		if pending then
			table.remove(pendingRevives, pending)
		end
		removeFromQueue(player)
		if matchPlayers[player] then
			matchPlayers[player] = nil
			local control = currentControl
			if control then
				control.RemovePlayer(player)
			end
		end
		evaluateQueue()
	end)

	CharacterService.SetMatchResetHandler(function(player: Player)
		local control = currentControl
		if control and getPhase() == "Playing" then
			control.HandleReset(player)
		end
	end)

	Remotes.Event("RequestQueue").OnServerEvent:Connect(onRequestQueue)
	PartyService.Changed:Connect(onPartyChanged)
	Remotes.Event("RequestSpectate").OnServerEvent:Connect(onRequestSpectate)
	Remotes.Event("RequestReturnToLobby").OnServerEvent:Connect(onRequestReturnToLobby)
	Remotes.Event("RequestRespawnChoice").OnServerEvent:Connect(onRespawnChoice)
	Remotes.Event("RequestWatchMatch").OnServerEvent:Connect(onRequestWatchMatch)
	Remotes.Event("RequestRevive").OnServerEvent:Connect(onRequestRevive)
	MarketplaceService.PromptProductPurchaseFinished:Connect(onPurchaseFinished)
	-- A revive just bought (one a match): it brings them back straight away.
	PurchaseService.SetReviveHandler(function(player: Player): boolean
		if matchRunning and matchPlayers[player] then
			player:SetAttribute(PlayerAttr.ReviveBought, true)
		end
		return revive(player, true)
	end)

	refreshLobbyScreen()
end

return MatchService
