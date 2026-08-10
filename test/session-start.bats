#!/usr/bin/env bats

@test "exits 0 silently when not in a cloud session" {
	unset CLAUDE_CODE_REMOTE
	run bash hooks/session-start.sh
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "exits 0 silently when CLAUDE_CODE_REMOTE is not 'true'" {
	CLAUDE_CODE_REMOTE=false run bash hooks/session-start.sh
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}
