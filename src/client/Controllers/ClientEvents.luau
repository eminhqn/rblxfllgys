--!strict
-- Local events about the player's own Bloblet. Movement fires them; sound, camera shake, UI and
-- hazard visuals listen, so none of those modules need to know about each other.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Signal = require(ReplicatedStorage.Shared.Signal)

return table.freeze({
	Jumped = Signal.new() :: Signal.Signal<()>,
	DoubleJumped = Signal.new() :: Signal.Signal<()>, -- a DOUBLE JUMP in mid-air
	Landed = Signal.new() :: Signal.Signal<number>, -- impact speed (studs/s)
	Dived = Signal.new() :: Signal.Signal<()>,
	DiveCooldownStarted = Signal.new() :: Signal.Signal<number>, -- cooldown length (s)
	GrabStarted = Signal.new() :: Signal.Signal<()>,
	KnockedDown = Signal.new() :: Signal.Signal<number>, -- strength 0-1
	GotUp = Signal.new() :: Signal.Signal<()>,
	Bounced = Signal.new() :: Signal.Signal<BasePart>, -- the pad
	Kicked = Signal.new() :: Signal.Signal<()>,
	KickCooldownStarted = Signal.new() :: Signal.Signal<number>, -- cooldown length (s)
	Slapped = Signal.new() :: Signal.Signal<()>, -- we swung a slap (SLAPS item)
	SlapCooldownStarted = Signal.new() :: Signal.Signal<number>, -- cooldown length (s)
	Splashed = Signal.new() :: Signal.Signal<()>, -- fell into water
	Teleported = Signal.new() :: Signal.Signal<()>, -- the server moved us (round start, respawn)
	PowerUp = Signal.new() :: Signal.Signal<string>, -- we grabbed a Paint Grab power-up (its Kind)
})
