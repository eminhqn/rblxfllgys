--!strict
-- CollectionService tag names. Tags (instead of fixed paths) let clients pick objects up as they
-- stream in and out, which is required with StreamingEnabled.

return table.freeze({
	Bloblet = "Bloblet", -- every player character
	Spinner = "Spinner", -- rotating hazard model (see HazardMath)
	BouncePad = "BouncePad", -- part that launches Bloblets upward; attribute Power: number
})
