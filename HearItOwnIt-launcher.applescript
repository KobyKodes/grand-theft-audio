on run {input, parameters}
	-- Scripts live in ~/Developer/Projects/Grand Theft Audio on the Mac they were written on,
	-- otherwise wherever hearit_setup.sh unpacked them.
	set homeDir to POSIX path of (path to home folder)
	set appDir to homeDir & "Developer/Projects/Grand Theft Audio"
	try
		do shell script "test -f " & quoted form of (appDir & "/hearit.sh")
	on error
		set appDir to homeDir & "Library/Application Support/HearItOwnItRedesign"
	end try
	return run script (POSIX file (appDir & "/HearItOwnIt.scpt")) with parameters {input, appDir}
end run
