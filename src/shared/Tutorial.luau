--!strict
-- The tutorial's steps, in order. TutorialService (server) runs the course and decides when each
-- step is done; the client's TutorialController shows the step and the button for it. New players
-- are offered it once; anyone can play it again from the lobby MENU.

export type Action = "Move" | "Jump" | "Dive" | "Grab" | "Kick" | "Bounce"

export type Step = {
	Action: Action,
	Text: string,
}

local Tutorial = {}

Tutorial.Steps = table.freeze({
	{ Action = "Move", Text = "WALK TO THE GLOWING RING" },
	{ Action = "Jump", Text = "JUMP UP ONTO THE STEP" },
	{ Action = "Dive", Text = "JUMP, THEN DIVE IN THE AIR TO FLY OVER THE GAP" },
	{ Action = "Grab", Text = "GRAB THE PINK DUMMY (HOLD GRAB NEXT TO IT)" },
	{ Action = "Kick", Text = "KICK THE YELLOW DUMMY" },
	{ Action = "Bounce", Text = "BOUNCE ON THE TRAMPOLINE UP TO THE FINISH" },
} :: { Step })

return table.freeze(Tutorial)
