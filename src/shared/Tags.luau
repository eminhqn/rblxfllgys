--!strict
-- CollectionService tag names. Tags (instead of fixed paths) let clients pick objects up as they
-- stream in and out, which is required with StreamingEnabled.

return table.freeze({
	Bloblet = "Bloblet", -- every player character
	Spinner = "Spinner", -- rotating hazard model (see HazardMath)
	BouncePad = "BouncePad", -- part that launches Bloblets upward; attribute Power: number
	Riser = "Riser", -- part that rises over time (e.g. Rising Tide water); see HazardMath.RiserOffset
	Wobbler = "Wobbler", -- platform that tilts back and forth; see HazardMath.WobbleAngle
	FallingTile = "FallingTile", -- model that shakes, then drops at its FallAt time (Cloud Crown)
	Conveyor = "Conveyor", -- belt model; its "Belt" part carries Bloblets along its LookVector at Speed
	Mover = "Mover", -- model sliding back and forth; see HazardMath.MoverOffset
	Crate = "Crate", -- falling crate model; see HazardMath.CratePose
	Roller = "Roller", -- giant balloon rolling (or hopping) across an arena; see HazardMath.RollerPose
	PaintPickup = "PaintPickup", -- Paint Grab power-up; clients burst it when it gets a SplashColor
	Swinger = "Swinger", -- model that swings or tilts about its pivot part; see HazardMath.SwingAngles
	Spikes = "Spikes", -- spike trap that pops up (or stays up); see HazardMath.SpikeRise
	Jelly = "Jelly", -- jelly tile that sinks while stood on (Jiggly Jelly); see HazardMath.JellyLevel
	Slider = "Slider", -- model sliding along an axis at a speed the server sets; see HazardMath.SliderOffset
	Leaderboard = "Leaderboard", -- lobby leaderboard screen part; attribute Board: Shared/Leaderboards id
})
