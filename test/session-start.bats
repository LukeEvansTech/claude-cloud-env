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
	# test to be safe to run anywhere. CCENV_SKIP_INSTALL=1 is test-only
	# (documented in the hook itself): the restricted PATH above makes
	# `command -v op` fail on purpose, which would otherwise trigger the
	# op self-heal's real network download during tests.
	unset CLAUDE_ENV_PROFILE OP_SERVICE_ACCOUNT_TOKEN INTERNAL_DOMAIN_RE
	cd "$BATS_TEST_TMPDIR"
	PATH="/usr/bin:/bin" CLAUDE_CODE_REMOTE=true CCENV_SKIP_INSTALL=1 run bash "$script"
	[ "$status" -eq 0 ]
	[[ "$output" == *"Profile: none"* ]]
}

@test "detects talos profile from talos/talconfig.yaml marker" {
	local script="${BATS_TEST_DIRNAME}/../hooks/session-start.sh"
	unset CLAUDE_ENV_PROFILE OP_SERVICE_ACCOUNT_TOKEN INTERNAL_DOMAIN_RE
	cd "$BATS_TEST_TMPDIR"
	mkdir -p talos
	: >talos/talconfig.yaml
	PATH="/usr/bin:/bin" CLAUDE_CODE_REMOTE=true CCENV_SKIP_INSTALL=1 run bash "$script"
	[ "$status" -eq 0 ]
	[[ "$output" == *"Profile: talos"* ]]
}

# CCENV_SKIP_INSTALL=1 short-circuits ccenv_gh_token_ok (see the hook's
# GitHub-token-sanity-check comment) the same way it gates the op self-heal
# — no curl call ever fires — but it deterministically takes the
# "token is bad" branch, so this exercises the real .mise.local.toml-writing
# code path without any network access.
@test "talos profile clears placeholder GitHub token and disables aqua verification in .mise.local.toml" {
	local script="${BATS_TEST_DIRNAME}/../hooks/session-start.sh"
	unset CLAUDE_ENV_PROFILE OP_SERVICE_ACCOUNT_TOKEN INTERNAL_DOMAIN_RE
	cd "$BATS_TEST_TMPDIR"
	mkdir -p talos
	: >talos/talconfig.yaml
	PATH="/usr/bin:/bin" CLAUDE_CODE_REMOTE=true CCENV_SKIP_INSTALL=1 run bash "$script"
	[ "$status" -eq 0 ]
	[ -f .mise.local.toml ]
	grep -q '^GITHUB_TOKEN = ""$' .mise.local.toml
	grep -q '^GH_TOKEN = ""$' .mise.local.toml
	grep -q '^\[settings\]$' .mise.local.toml
	grep -q '^aqua.github_attestations = false$' .mise.local.toml
}

# ccenv_hostname (tailnet hostname derivation) — the function is defined
# unconditionally near the top of the script, so sourcing it under the same
# safe harness as above (restricted PATH, CCENV_SKIP_INSTALL=1) defines it
# without ever entering the tailscaled-gated join block that calls it. This
# lets these tests exercise the real function instead of a reimplementation.
# The script's own stdout from the sourced run is discarded; only the
# explicit ccenv_hostname call below is asserted on.
_source_hook_and_call_ccenv_hostname() {
	local script="${BATS_TEST_DIRNAME}/../hooks/session-start.sh"
	unset CLAUDE_ENV_PROFILE OP_SERVICE_ACCOUNT_TOKEN INTERNAL_DOMAIN_RE
	cd "$BATS_TEST_TMPDIR" || return 1
	PATH="/usr/bin:/bin" CLAUDE_CODE_REMOTE=true CCENV_SKIP_INSTALL=1 \
		bash -c 'source "$1" >/dev/null 2>&1; ccenv_hostname "$2" "$3"' _ "$script" "$1" "$2"
}

@test "ccenv_hostname strips underscores from the session-ID segment and lowercases" {
	run _source_hook_and_call_ccenv_hostname "containers" "cse_01Xf"
	[ "$status" -eq 0 ]
	[ "$output" = "claude-containers-cse01xf" ]
}

@test "ccenv_hostname collapses an all-invalid session ID to a trailing-hyphen-free label" {
	run _source_hook_and_call_ccenv_hostname "containers" "________"
	[ "$status" -eq 0 ]
	[ "$output" = "claude-containers" ]
}

@test "ccenv_hostname falls back to claude-session when both segments are empty" {
	run _source_hook_and_call_ccenv_hostname "___" "________"
	[ "$status" -eq 0 ]
	[ "$output" = "claude-session" ]
}

@test "ccenv_hostname still produces a valid label when the basename is empty" {
	run _source_hook_and_call_ccenv_hostname "/" "cse_01Xf"
	[ "$status" -eq 0 ]
	[ "$output" = "claude-cse01xf" ]
}

@test "ccenv_hostname handles an unset session ID" {
	run _source_hook_and_call_ccenv_hostname "containers" ""
	[ "$status" -eq 0 ]
	[ "$output" = "claude-containers" ]
}
