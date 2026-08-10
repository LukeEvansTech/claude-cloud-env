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

@test "reports no profile when no marker file is present" {
	local script="${BATS_TEST_DIRNAME}/../hooks/session-start.sh"
	# Unset so a stray value in the calling environment can't skew
	# detection, and restrict PATH so tailscaled/op aren't found even if
	# installed on the host — the tailnet block and the
	# OP_SERVICE_ACCOUNT_TOKEN-gated talos actions must stay inert for this
	# test to be safe to run anywhere.
	unset CLAUDE_ENV_PROFILE OP_SERVICE_ACCOUNT_TOKEN INTERNAL_DOMAIN_RE
	cd "$BATS_TEST_TMPDIR"
	PATH="/usr/bin:/bin" CLAUDE_CODE_REMOTE=true run bash "$script"
	[ "$status" -eq 0 ]
	[[ "$output" == *"Profile: none"* ]]
}

@test "detects talos profile from talos/talconfig.yaml marker" {
	local script="${BATS_TEST_DIRNAME}/../hooks/session-start.sh"
	unset CLAUDE_ENV_PROFILE OP_SERVICE_ACCOUNT_TOKEN INTERNAL_DOMAIN_RE
	cd "$BATS_TEST_TMPDIR"
	mkdir -p talos
	: >talos/talconfig.yaml
	PATH="/usr/bin:/bin" CLAUDE_CODE_REMOTE=true run bash "$script"
	[ "$status" -eq 0 ]
	[[ "$output" == *"Profile: talos"* ]]
}
