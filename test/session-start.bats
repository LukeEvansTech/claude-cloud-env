#!/usr/bin/env bats

# Every test runs in its own subshell; point HOME and GIT_CONFIG_GLOBAL at the
# per-test tmpdir so the hook's `git config --global` (run by the cloud-path
# tests, and by the ccenv_hostname tests when they source the hook) writes a
# throwaway .gitconfig, never the developer's real one. GIT_CONFIG_GLOBAL is
# set explicitly: a machine that uses it to select a git identity would
# otherwise still route writes to the real file even with HOME overridden.
setup() {
	export HOME="$BATS_TEST_TMPDIR" GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/.gitconfig"
	unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
}

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
@test "talos profile clears the placeholder GitHub token in .mise.local.toml" {
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
}

# Regression guard. Disabling verification is not merely unnecessary here, it
# BREAKS installs: mise.lock records `provenance = "cosign"` for some tools and
# installing those with cosign off trips mise's downgrade-attack protection.
# Measured 2026-08-31 — with cosign ENABLED and --locked, the same install
# printed "✓ Cosign verified" and succeeded. Never write these back.
@test "talos profile never disables signature or attestation verification" {
	local script="${BATS_TEST_DIRNAME}/../hooks/session-start.sh"
	unset CLAUDE_ENV_PROFILE OP_SERVICE_ACCOUNT_TOKEN INTERNAL_DOMAIN_RE
	cd "$BATS_TEST_TMPDIR"
	mkdir -p talos
	: >talos/talconfig.yaml
	PATH="/usr/bin:/bin" CLAUDE_CODE_REMOTE=true CCENV_SKIP_INSTALL=1 run bash "$script"
	[ "$status" -eq 0 ]
	if grep -Eq '(cosign|slsa|minisign|attestations)[[:space:]]*=[[:space:]]*false' .mise.local.toml; then
		echo "verification was disabled in .mise.local.toml: $(cat .mise.local.toml)" >&2
		return 1
	fi
	# ...and the env prefix handed to mise must not disable it either.
	if [[ "$output" == *"MISE_AQUA_COSIGN=false"* ]]; then
		echo "env prefix disabled cosign: $output" >&2
		return 1
	fi
}

@test "talos profile locks installs to mise.lock when the repo commits one" {
	local script="${BATS_TEST_DIRNAME}/../hooks/session-start.sh"
	unset CLAUDE_ENV_PROFILE OP_SERVICE_ACCOUNT_TOKEN INTERNAL_DOMAIN_RE
	cd "$BATS_TEST_TMPDIR"
	mkdir -p talos
	: >talos/talconfig.yaml
	: >mise.lock
	PATH="/usr/bin:/bin" CLAUDE_CODE_REMOTE=true CCENV_SKIP_INSTALL=1 run bash "$script"
	[ "$status" -eq 0 ]
	grep -q '^\[settings\]$' .mise.local.toml
	grep -q '^locked = true$' .mise.local.toml
}

# `--locked`/MISE_LOCKED=1 fails every install when there is no lockfile to
# read URLs from, so it must stay conditional — not every participating repo
# commits one.
@test "no lockfile means no locked setting" {
	local script="${BATS_TEST_DIRNAME}/../hooks/session-start.sh"
	unset CLAUDE_ENV_PROFILE OP_SERVICE_ACCOUNT_TOKEN INTERNAL_DOMAIN_RE
	cd "$BATS_TEST_TMPDIR"
	mkdir -p talos
	: >talos/talconfig.yaml
	PATH="/usr/bin:/bin" CLAUDE_CODE_REMOTE=true CCENV_SKIP_INSTALL=1 run bash "$script"
	[ "$status" -eq 0 ]
	if grep -q 'locked = true' .mise.local.toml; then
		echo "locked was set with no mise.lock present: $(cat .mise.local.toml)" >&2
		return 1
	fi
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

@test "sets the cloud session git identity to the account owner" {
	local script="${BATS_TEST_DIRNAME}/../hooks/session-start.sh"
	unset CLAUDE_ENV_PROFILE OP_SERVICE_ACCOUNT_TOKEN INTERNAL_DOMAIN_RE
	cd "$BATS_TEST_TMPDIR"
	PATH="/usr/bin:/bin" CLAUDE_CODE_REMOTE=true CCENV_SKIP_INSTALL=1 run bash "$script"
	[ "$status" -eq 0 ]
	[ "$(git config --global user.name)" = "Luke Evans" ]
	[ "$(git config --global user.email)" = "17546908+LukeEvansTech@users.noreply.github.com" ]
	[[ "$output" == *"Git identity: commits author as Luke Evans"* ]]
}

@test "warns when the harness exports GIT_AUTHOR_* env vars (they override git config)" {
	local script="${BATS_TEST_DIRNAME}/../hooks/session-start.sh"
	unset CLAUDE_ENV_PROFILE OP_SERVICE_ACCOUNT_TOKEN INTERNAL_DOMAIN_RE
	cd "$BATS_TEST_TMPDIR"
	GIT_AUTHOR_NAME=Claude GIT_AUTHOR_EMAIL=noreply@anthropic.com PATH="/usr/bin:/bin" CLAUDE_CODE_REMOTE=true CCENV_SKIP_INSTALL=1 run bash "$script"
	[ "$status" -eq 0 ]
	[[ "$output" == *"Git identity: harness exports GIT_AUTHOR_*/GIT_COMMITTER_* (Claude <noreply@anthropic.com>)"* ]]
	[[ "$output" == *"env -u GIT_AUTHOR_NAME"* ]]
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

# ccenv_gh_token_ok — the probe deciding whether mise keeps the sandbox's
# GITHUB_TOKEN. Sourced under the same safe harness as ccenv_hostname above
# (restricted PATH, CCENV_SKIP_INSTALL=1, so the script's own call is
# short-circuited by the `||` and never fires), then invoked directly against
# a stub `curl` that ALWAYS succeeds. The always-succeeding stub is the whole
# point: with a probe that cannot fail, the only thing left that can return
# non-zero is the sentinel check, so these tests pin the sentinel and the
# probe URL rather than a network outcome. The stub also records the URLs it
# was handed, which is how the "never probe an unscoped endpoint" rule is
# enforced mechanically instead of by comment.
_call_ccenv_gh_token_ok() {
	local script="${BATS_TEST_DIRNAME}/../hooks/session-start.sh"
	local stub="$BATS_TEST_TMPDIR/stub"
	mkdir -p "$stub"
	cat >"$stub/curl" <<-'STUB'
		#!/bin/sh
		for a in "$@"; do
			case "$a" in https://*) printf '%s\n' "$a" >>"$CCENV_TEST_CURL_LOG" ;; esac
		done
		exit 0
	STUB
	chmod +x "$stub/curl"
	: >"$BATS_TEST_TMPDIR/curl.log"
	cd "$BATS_TEST_TMPDIR" || return 1
	CCENV_TEST_CURL_LOG="$BATS_TEST_TMPDIR/curl.log" PATH="$stub:/usr/bin:/bin" \
		CLAUDE_CODE_REMOTE=true CCENV_SKIP_INSTALL=1 \
		bash -c 'source "$1" >/dev/null 2>&1; ccenv_gh_token_ok' _ "$script"
}

@test "ccenv_gh_token_ok rejects the sandbox's proxy-injected sentinel without any network call" {
	unset CLAUDE_ENV_PROFILE OP_SERVICE_ACCOUNT_TOKEN INTERNAL_DOMAIN_RE
	GITHUB_TOKEN=proxy-injected run _call_ccenv_gh_token_ok
	[ "$status" -ne 0 ]
	# Must decide from the value alone: the sandbox's proxy answers
	# /rate_limit 200 regardless, so any network probe would say "fine".
	[ ! -s "$BATS_TEST_TMPDIR/curl.log" ]
}

@test "ccenv_gh_token_ok probes a third-party repository, never an unscoped endpoint" {
	unset CLAUDE_ENV_PROFILE OP_SERVICE_ACCOUNT_TOKEN INTERNAL_DOMAIN_RE
	GITHUB_TOKEN=ghp_pretend_this_one_is_real run _call_ccenv_gh_token_ok
	[ "$status" -eq 0 ]
	grep -q '/repos/.*/releases/latest' "$BATS_TEST_TMPDIR/curl.log"
	# /rate_limit is unscoped — it cannot distinguish a repo-scoped token
	# from an unrestricted one, which is the bug this replaced. Spelled as
	# an if/return rather than a leading `!`, which shellcheck rejects in
	# bats files (SC2314) because a negated command only fails the test
	# when it happens to be the last one.
	if grep -q 'rate_limit' "$BATS_TEST_TMPDIR/curl.log"; then
		echo "probe used an unscoped endpoint: $(cat "$BATS_TEST_TMPDIR/curl.log")" >&2
		return 1
	fi
}

@test "ccenv_gh_token_ok honours CCENV_GH_TOKEN_SENTINELS and CCENV_GH_PROBE_URL overrides" {
	unset CLAUDE_ENV_PROFILE OP_SERVICE_ACCOUNT_TOKEN INTERNAL_DOMAIN_RE
	GITHUB_TOKEN=some-future-sentinel CCENV_GH_TOKEN_SENTINELS="proxy-injected some-future-sentinel" \
		run _call_ccenv_gh_token_ok
	[ "$status" -ne 0 ]

	GITHUB_TOKEN=ghp_pretend_this_one_is_real \
		CCENV_GH_PROBE_URL=https://api.github.com/repos/jqlang/jq/releases/latest \
		run _call_ccenv_gh_token_ok
	[ "$status" -eq 0 ]
	grep -q 'jqlang/jq' "$BATS_TEST_TMPDIR/curl.log"
}

@test "ccenv_gh_token_ok rejects an unset token before probing" {
	unset CLAUDE_ENV_PROFILE OP_SERVICE_ACCOUNT_TOKEN INTERNAL_DOMAIN_RE GITHUB_TOKEN
	run _call_ccenv_gh_token_ok
	[ "$status" -ne 0 ]
	[ ! -s "$BATS_TEST_TMPDIR/curl.log" ]
}

# Cloud sandboxes are reused between runs and .mise.local.toml is gitignored,
# so a copy written by an older hook survives the repo re-fetch. The
# GITHUB_TOKEN guard would then skip the rewrite and keep the stale
# verification-disabling settings — which is exactly what happened live on
# 2026-08-31, making a correctly-shipped fix look like it had not worked.
@test "a stale .mise.local.toml disabling verification is discarded and regenerated" {
	local script="${BATS_TEST_DIRNAME}/../hooks/session-start.sh"
	unset CLAUDE_ENV_PROFILE OP_SERVICE_ACCOUNT_TOKEN INTERNAL_DOMAIN_RE
	cd "$BATS_TEST_TMPDIR"
	mkdir -p talos
	: >talos/talconfig.yaml
	: >mise.lock
	# Exactly what the previous hook version wrote.
	printf '[env]\nGITHUB_TOKEN = ""\nGH_TOKEN = ""\n\n[settings]\naqua.cosign = false\naqua.slsa = false\ngithub.slsa = false\n' >.mise.local.toml
	PATH="/usr/bin:/bin" CLAUDE_CODE_REMOTE=true CCENV_SKIP_INSTALL=1 run bash "$script"
	[ "$status" -eq 0 ]
	if grep -Eq '(cosign|slsa|minisign|attestations)[[:space:]]*=[[:space:]]*false' .mise.local.toml; then
		echo "stale verification-disabling settings survived: $(cat .mise.local.toml)" >&2
		return 1
	fi
	grep -q '^locked = true$' .mise.local.toml
}

# `mise exec` / a bare `mise install` resolve the repository's entire manifest,
# which cannot succeed under --locked: several tools are pinned to "latest" and
# carry no lockfile URL. Measured 2026-08-31 — the whole-manifest resolve failed
# in seconds while naming individual pinned tools installed them cleanly. Guard
# the shape rather than the outcome, since the talos actions need a real
# OP_SERVICE_ACCOUNT_TOKEN and cannot run here.
@test "gen-config never resolves the whole toolchain via mise exec or just" {
	local script="${BATS_TEST_DIRNAME}/../hooks/session-start.sh"
	local code
	# Strip comments: the rationale above these calls necessarily NAMES the
	# very commands it is banning, so a naive grep matches its own docs.
	code="$(grep -v '^[[:space:]]*#' "$script")"
	if grep -q 'mise exec -- just talos gen-config' <<<"$code"; then
		echo "hook still shells out to 'just talos gen-config', which drags in the whole manifest" >&2
		return 1
	fi
	if grep -Eq 'mise exec -- (yq|talosctl)' <<<"$code"; then
		echo "hook still invokes yq/talosctl through 'mise exec --', which re-resolves the manifest" >&2
		return 1
	fi
	# The tools it does install must be named explicitly, not implied.
	grep -q 'mise install -y aqua:siderolabs/talos aqua:mikefarah/yq' "$script"
}

@test "gen-config resolves tool paths through mise which, not shims" {
	local script="${BATS_TEST_DIRNAME}/../hooks/session-start.sh"
	grep -q 'ccenv_mise_bin talhelper' "$script"
	grep -q 'ccenv_mise_bin talosctl' "$script"
	# talhelper is baked into the snapshot; installing it needs a release
	# listing, which the sandbox 403s.
	if grep -q 'mise install.*talhelper' "$script"; then
		echo "hook tries to install talhelper; it is snapshot-baked and its release listing is 403 here" >&2
		return 1
	fi
}

# Invoking talosctl at an absolute path is what stops mise re-resolving the
# manifest, but it also drops the [env] block .mise.toml declares — including
# TALOSCONFIG. Measured 2026-08-31: gen-config succeeded and the kubeconfig
# step still failed for exactly that reason.
@test "talosctl is invoked with TALOSCONFIG set explicitly" {
	local script="${BATS_TEST_DIRNAME}/../hooks/session-start.sh"
	local code
	code="$(grep -v '^[[:space:]]*#' "$script")"
	# shellcheck disable=SC2016 # deliberate: this matches the LITERAL source
	# text, which contains an unexpanded ${PWD}. Expanding it here would make
	# the assertion match this test's own cwd instead of the hook's code.
	grep -q 'TALOSCONFIG="${PWD}/talos/clusterconfig/talosconfig"' <<<"$code"
	# shellcheck disable=SC2016 # same: literal source match, not an expansion
	grep -q 'KUBECONFIG="${PWD}/kubeconfig"' <<<"$code"
}
