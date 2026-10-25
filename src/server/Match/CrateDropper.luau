--!strict
-- Drops crates onto parts of a course at a steady rate. Each crate lands at a random spot in one of
-- the drop zones, rides the zone's belt (if any) to its far end and smashes there.
--
-- The server only creates each crate with its timings (see Hazards.Crate) and deletes it later;
-- every client animates the target circle, the fall and the slide itself and decides its own hits.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)

local Hazards = require(script.Parent.Parent.Builders.Hazards)
local Types = require(script.Parent.Types)

export type Zone = {
	Top: CFrame, -- centre of the surface; LookVector = the way a belt carries crates
	Size: Vector2, -- (width, length along LookVector)
	SlideSpeed: number, -- 0 = smash on landing
}

export type Dropper = {
	Update: (dt: number) -> (),
}

local EDGE_INSET = 3 -- keep landing spots this far inside a zone
local MAX_ALIVE = 40

local CrateDropper = {}

-- `interval` is the time between crates across all zones (bigger zones get more of them).
function CrateDropper.new(context: Types.RoundContext, zones: { Zone }, interval: number): Dropper
	local random = context.Random
	local totalArea = 0
	for _, zone in zones do
		totalArea += zone.Size.X * zone.Size.Y
	end
	local timer = 0
	local alive = 0

	local function pickZone(): Zone
		local roll = random:NextNumber(0, totalArea)
		for _, zone in zones do
			roll -= zone.Size.X * zone.Size.Y
			if roll <= 0 then
				return zone
			end
		end
		return zones[#zones]
	end

	local function drop()
		local zone = pickZone()
		local halfWidth = math.max(0, zone.Size.X / 2 - EDGE_INSET)
		local halfLength = math.max(0, zone.Size.Y / 2 - EDGE_INSET)
		local x = random:NextNumber(-halfWidth, halfWidth)
		local z = random:NextNumber(-halfLength, halfLength)
		local yaw = random:NextNumber(-0.4, 0.4)
		local landing = zone.Top * CFrame.new(x, 0, z) * CFrame.Angles(0, yaw, 0)

		local slideVelocity = Vector3.zero
		local slideTime = 0
		if zone.SlideSpeed ~= 0 then
			-- Ride to the far end of the belt (LookVector is local -Z).
			local remaining = if zone.SlideSpeed > 0 then z + zone.Size.Y / 2 else zone.Size.Y / 2 - z
			slideVelocity = zone.Top.LookVector * zone.SlideSpeed
			slideTime = math.max(0, remaining - Config.Crates.Size / 2) / math.abs(zone.SlideSpeed)
		end

		local crates = Config.Crates
		local lead = crates.ReplicationLead + crates.WarningTime + crates.FallTime
		local crate = Hazards.Crate(context.Arena, landing, context.GetServerTime() + lead, slideVelocity, slideTime)
		alive += 1
		task.delay(lead + slideTime + crates.RemoveAfter, function()
			alive -= 1
			if crate.Parent then
				crate:Destroy()
			end
		end)
	end

	return {
		Update = function(dt: number)
			if #zones == 0 or totalArea <= 0 then
				return
			end
			timer += dt
			while timer >= interval do
				timer -= interval
				if alive < MAX_ALIVE then
					drop()
				end
			end
		end,
	}
end

return CrateDropper
