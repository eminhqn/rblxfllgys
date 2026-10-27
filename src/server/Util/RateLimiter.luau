--!strict
-- Per-player token bucket. Every remote handler checks one of these first, so a client spamming
-- a remote costs the server almost nothing.

local Players = game:GetService("Players")

local Bots = require(script.Parent.Parent.Bots.Bots)

export type RateLimiter = {
	Allow: (self: RateLimiter, player: Player) -> boolean,
}

type Bucket = {
	Tokens: number,
	Updated: number,
}

local RateLimiter = {}

-- `capacity` requests may burst at once; tokens refill at `refillPerSecond`.
function RateLimiter.new(capacity: number, refillPerSecond: number): RateLimiter
	local buckets: { [Player]: Bucket } = {}

	local function forget(player: Player)
		buckets[player] = nil
	end
	Players.PlayerRemoving:Connect(forget)
	Bots.Removing:Connect(forget)

	local function allow(_self: RateLimiter, player: Player): boolean
		local now = os.clock()
		local bucket = buckets[player]
		if not bucket then
			bucket = { Tokens = capacity, Updated = now }
			buckets[player] = bucket
		end
		bucket.Tokens = math.min(capacity, bucket.Tokens + (now - bucket.Updated) * refillPerSecond)
		bucket.Updated = now
		if bucket.Tokens < 1 then
			return false
		end
		bucket.Tokens -= 1
		return true
	end

	return { Allow = allow }
end

return RateLimiter
