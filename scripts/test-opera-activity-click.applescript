-- Smoke test: activate Opera and click a global screen point (e.g. the Activity link).
-- Edit CLICK_GLOBAL_X and CLICK_GLOBAL_Y to match a point from Clicky logs
-- (`Computer use mapping ... → global=(x, y)`) or from Accessibility Inspector / a screen ruler.
--
-- Run from Terminal:
--   osascript scripts/test-opera-activity-click.applescript
--
-- Notes:
-- - Coordinates are AppKit global desktop coordinates (origin bottom-left of the primary display),
--   same space as NSEvent.mouseLocation and System Events `click at`.
-- - On external / left monitors, X or Y are often negative — that is expected.

property CLICK_GLOBAL_X : -1837
property CLICK_GLOBAL_Y : 232

property DELAY_AFTER_ACTIVATE_SECONDS : 0.4

on run
	set clickX to CLICK_GLOBAL_X
	set clickY to CLICK_GLOBAL_Y

	tell application "Opera" to activate
	delay DELAY_AFTER_ACTIVATE_SECONDS

	tell application "System Events"
		if not (exists process "Opera") then
			display dialog "Opera is not running or the process name differs. In Activity Monitor, confirm the name is exactly \"Opera\"." buttons {"OK"} default button "OK" with icon stop
			return
		end if
		tell process "Opera"
			set frontmost to true

			-- Debug: window 1 position/size (top-left of window in global coords, height/width)
			try
				set windowPosition to position of window 1
				set windowSize to size of window 1
				log "Opera window 1 position: " & (item 1 of windowPosition as string) & ", " & (item 2 of windowPosition as string)
				log "Opera window 1 size: " & (item 1 of windowSize as string) & " x " & (item 2 of windowSize as string)
			end try

			log "Clicking at global (" & (clickX as string) & ", " & (clickY as string) & ")"
			click at {clickX, clickY}
		end tell
	end tell
end run
