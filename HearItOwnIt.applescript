-- "Hear it → Own it": runs after the Shortcut's "Recognize Music" (Shazam) action.
-- Input: text "Artist|Title". Finds the song on YouTube, downloads it in the background
-- (with progress window), asks which playlist(s) to add it to meanwhile, then imports and notifies.

property scriptDir : ""
property hudFile : "" -- the orb window the Shortcut opened while Shazam listened, or ""
property noPlaylist : "No playlist"
property newPlaylist : "New playlist…"

-- argv: {input} or {input, folder with the scripts} (the launcher passes the folder)
-- or {"Artist|Title", folder, playlist} from hearit_queue.sh ("" or "No playlist" = none)
on run argv
	set input to item 1 of argv
	-- from the Shortcut it's a list; from osascript (hearit_queue.sh) it's plain text
	if class of input is not list then set input to {input}
	if (count of argv) ≥ 2 then
		set scriptDir to item 2 of argv
	else
		set scriptDir to (POSIX path of (path to home folder)) & "Developer/Projects/Hear it, Own it"
	end if
	-- Run from the Shortcut, take over the orb window hearit_listen.sh opened.
	set hudFile to ""
	if (count of argv) < 3 then set hudFile to takeHud()

	-- Songs saved by the "Hear it Later" iPhone shortcut: hearit_queue.sh passes the
	-- playlist picked on the phone as a 3rd argument. Run from the Shortcut, start the
	-- queue so anything still waiting downloads too.
	set queuedPlaylist to missing value
	if (count of argv) ≥ 3 then
		set queuedPlaylist to item 3 of argv
	else
		startQueue()
	end if

	-- 1) Read the Shazam result
	set songArtist to ""
	set songTitle to ""
	try
		set raw to (item 1 of input) as text
		set AppleScript's text item delimiters to "|"
		set songArtist to text item 1 of raw
		set songTitle to (text items 2 thru -1 of raw) as text
	end try
	set AppleScript's text item delimiters to ""
	if songTitle is "" then
		hud("CLOSE")
		display notification "Shazam couldn't identify the song. Try again closer to the speaker." with title "Hear it → Own it" sound name "Basso"
		return "Not recognized"
	end if
	-- Songs from the iPhone only notify when they're added or something goes wrong.
	set fromPhone to (queuedPlaylist is not missing value)
	if hudFile is not "" then
		hud("TITLE " & songTitle & " — " & songArtist)
		hud("STATUS Finding it on YouTube…")
	else if not fromPhone then
		display notification songTitle & " — " & songArtist with title "Heard it! Finding it on YouTube…"
	end if

	-- 2) Start the download in the background so you can pick playlists meanwhile
	set base to do shell script "mktemp -u /tmp/hearit.XXXXXX"
	set outFile to base & ".out"
	set errFile to base & ".err"
	set codeFile to base & ".code"
	-- HEARIT_HUD tells ytmusic.sh to keep using the orb window instead of opening one
	do shell script "( HEARIT_HUD=" & quoted form of hudFile & " " & quoted form of (scriptDir & "/hearit.sh") & " " & quoted form of songArtist & " " & quoted form of songTitle & " > " & quoted form of outFile & " 2> " & quoted form of errFile & "; echo $? > " & quoted form of (codeFile & ".tmp") & "; mv " & quoted form of (codeFile & ".tmp") & " " & quoted form of codeFile & " ) > /dev/null 2>&1 &"

	-- 3) Ask for playlists while downloading (queued songs picked theirs on the iPhone)
	if queuedPlaylist is missing value then
		set chosen to pickPlaylists(songTitle & " — " & songArtist)
	else if queuedPlaylist is "" or queuedPlaylist is noPlaylist then
		set chosen to {}
	else
		set chosen to {queuedPlaylist}
	end if

	-- 4) Wait for the download to finish
	repeat until (do shell script "test -f " & quoted form of codeFile & " && echo y || echo n") is "y"
		delay 0.3
	end repeat
	set exitCode to (do shell script "cat " & quoted form of codeFile) as integer
	set result_ to do shell script "cat " & quoted form of outFile
	set errText to do shell script "tail -n 1 " & quoted form of errFile & " 2>/dev/null || true"
	do shell script "rm -f " & quoted form of outFile & " " & quoted form of errFile & " " & quoted form of codeFile

	if exitCode is not 0 or result_ is "" then
		if errText is "" then set errText to "Unknown error"
		hud("CLOSE")
		display notification errText with title "Couldn't get " & songTitle
		return "Failed"
	end if

	set AppleScript's text item delimiters to "|"
	set parts to text items of result_
	set AppleScript's text item delimiters to ""
	set filePath to item 2 of parts
	set alreadyHad to (item 1 of parts is "EXISTS")

	-- 5) Get the track in Music (import if new, find it if it already exists)
	set theTrack to missing value
	tell application "Music"
		if alreadyHad and (count of parts) >= 4 then
			try
				set matches to (every file track of library playlist 1 whose name is (item 4 of parts))
				repeat with i from 1 to count of matches
					set t to item i of matches
					try
						set loc to POSIX path of ((location of t) as alias)
						if loc ends with (do shell script "basename " & quoted form of filePath) then
							set theTrack to t
							exit repeat
						end if
					end try
				end repeat
			end try
			if theTrack is not missing value and (count of parts) >= 5 and item 5 of parts is "1" then
				try
					refresh theTrack
				end try
			end if
		end if
		if theTrack is missing value then set theTrack to add (POSIX file filePath)
	end tell

	-- 6) Add to the chosen playlists
	set addedTo to addToPlaylists(theTrack, chosen)

	-- 7) Notify
	set playlistText to ""
	if (count of addedTo) > 0 then
		set AppleScript's text item delimiters to ", "
		set playlistText to " → " & (addedTo as text)
		set AppleScript's text item delimiters to ""
	end if

	if alreadyHad then
		if not fromPhone then display notification "You already had this one" & playlistText with title songTitle & " — " & songArtist sound name "Tink"
	else
		display notification "Heard it, now you own it" & playlistText with title songTitle & " — " & songArtist
	end if
	return result_
end run


-- Shows your playlists (recently used first). Returns a list of names, possibly empty.
on pickPlaylists(songLabel)
	tell application "Music"
		try
			set allNames to name of every user playlist whose smart is false and special kind is none
		on error
			set allNames to {}
		end try
	end tell

	-- recently used playlists go to the top (shared with the YouTube → Music shortcut)
	set recents to {}
	try
		set recents to paragraphs of (do shell script "cat " & quoted form of (scriptDir & "/.recent_playlists") & " 2>/dev/null || true")
	end try
	set ordered to {}
	repeat with r in recents
		set r to contents of r
		if r is not "" and allNames contains r and ordered does not contain r then set end of ordered to r
	end repeat
	repeat with n in allNames
		set n to contents of n
		if ordered does not contain n then set end of ordered to n
	end repeat

	-- With the orb window up, pick in it (under the progress) instead of a dialog.
	set fromHud to pickInHud(ordered)
	if fromHud is not missing value then return fromHud

	set picked to choose from list ({noPlaylist, newPlaylist} & ordered) with title "Hear it → Own it" with prompt "Add “" & songLabel & "” to a playlist?" & return & "Hold ⌘ to pick several." default items {noPlaylist} OK button name "Add" cancel button name "Skip" with multiple selections allowed
	if picked is false then return {}

	set result_ to {}
	repeat with p in picked
		set p to contents of p
		if p is newPlaylist then
			try
				set newName to text returned of (display dialog "Name for the new playlist:" default answer "" with title "New playlist" buttons {"Cancel", "Create"} default button "Create")
				if newName is not "" then set end of result_ to newName
			end try
		else if p is not noPlaylist then
			set end of result_ to p
		end if
	end repeat
	return result_
end pickPlaylists


-- Adds the track to each named playlist (creating it if needed). Returns the names it was added to.
on addToPlaylists(theTrack, names)
	set addedTo to {}
	if theTrack is missing value or (count of names) is 0 then return addedTo
	-- Loop OUTSIDE the Music tell block: reading list items inside it sends
	-- the request to Music, which fails with "Expected a reference".
	tell application "Music" to set pid to persistent ID of theTrack
	repeat with i from 1 to count of names
		set n to item i of names
		try
			tell application "Music"
				if not (exists user playlist n) then make new user playlist with properties {name:n}
				set pl to user playlist n
				if (count of (tracks of pl whose persistent ID is pid)) is 0 then duplicate theTrack to pl
			end tell
			set end of addedTo to n
		on error errMsg
			display notification errMsg with title "Couldn't add to " & n
		end try
	end repeat

	-- remember for next time (most recent first, max 8)
	if (count of addedTo) > 0 then
		set AppleScript's text item delimiters to linefeed
		set newest to addedTo as text
		set AppleScript's text item delimiters to ""
		set f to quoted form of (scriptDir & "/.recent_playlists")
		do shell script "{ printf '%s\\n' " & quoted form of newest & "; cat " & f & " 2>/dev/null; } | awk 'NF && !seen[$0]++' | head -n 8 > " & f & ".tmp && mv " & f & ".tmp " & f
	end if
	return addedTo
end addToPlaylists


-- Starts hearit_queue.sh (songs saved by the "Hear it Later" iPhone shortcut) in the
-- background. Without it (Hear it Later not set up), this does nothing.
on startQueue()
	set q to quoted form of (scriptDir & "/hearit_queue.sh")
	do shell script "if [ -x " & q & " ]; then " & q & " > /dev/null 2>&1 & fi"
end startQueue


-- The orb window's file from hearit_listen.sh, or "" if there's none or it has closed.
-- Claims it, so a later run can't pick up the same window.
on takeHud()
	set cur to quoted form of ((POSIX path of (path to home folder)) & "Library/Caches/HearItOwnIt/current")
	try
		return do shell script "f=$(cat " & cur & " 2>/dev/null); rm -f " & cur & "; if [ -n \"$f\" ] && [ -f \"$f\" ]; then echo \"$f\"; fi"
	on error
		return ""
	end try
end takeHud

-- Sends one line to the orb window (see ytprogress.swift for the commands).
on hud(cmd)
	if hudFile is "" then return
	set f to quoted form of hudFile
	try
		do shell script "if [ -f " & f & " ]; then printf '%s\\n' " & quoted form of cmd & " >> " & f & "; fi"
	end try
end hud

-- Shows the playlist picker in the orb window and waits for the choice. Returns the
-- names picked ({} if skipped), or missing value if there's no window to ask in.
on pickInHud(names)
	if hudFile is "" then return missing value
	set f to quoted form of hudFile
	if (do shell script "[ -f " & f & " ] && echo y || echo n") is "n" then return missing value
	set listFile to do shell script "mktemp /tmp/hearit.pick.XXXXXX"
	set AppleScript's text item delimiters to linefeed
	set namesText to names as text
	set AppleScript's text item delimiters to ""
	do shell script "printf '%s\\n' " & quoted form of namesText & " > " & quoted form of listFile
	hud("PICK " & listFile)
	set answer to quoted form of (listFile & ".answer")
	-- The window writes <list>.answer when you add or skip. If it goes away first
	-- (Shortcut stopped), fall back to the dialog.
	repeat
		set got to do shell script "if [ -f " & answer & " ]; then echo a; elif [ -f " & f & " ]; then echo w; else echo gone; fi"
		if got is "a" then exit repeat
		if got is "gone" then
			do shell script "rm -f " & quoted form of listFile
			return missing value
		end if
		delay 0.2
	end repeat
	set picked to paragraphs of (do shell script "cat " & answer)
	do shell script "rm -f " & quoted form of listFile & " " & answer
	set result_ to {}
	repeat with p in picked
		if contents of p is not "" then set end of result_ to contents of p
	end repeat
	return result_
end pickInHud
