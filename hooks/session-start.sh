#!/usr/bin/env bash
# claude-cloud-env session-start — runs at EVERY cloud session start/resume,
# AFTER Claude Code launches. Secrets and ephemeral state live here, never in
# bootstrap.sh (whose filesystem is snapshotted). stdout = additionalContext.
set -uo pipefail

[ "${CLAUDE_CODE_REMOTE:-}" = "true" ] || exit 0

REPO_RAW="https://raw.githubusercontent.com/LukeEvansTech/claude-cloud-env/main"
SELF="/opt/claude-cloud-env/session-start.sh"
log() { printf '%s\n' "$*"; }

# Self-update: the snapshot copy can be up to ~7 days stale.
if [ "${CCENV_UPDATED:-}" != "1" ] && [ -w "$SELF" ]; then
	if curl -fsSL --max-time 10 "${REPO_RAW}/hooks/session-start.sh" -o /tmp/ccenv-hook.sh 2>/dev/null &&
		! cmp -s /tmp/ccenv-hook.sh "$SELF"; then
		cp /tmp/ccenv-hook.sh "$SELF" && chmod +x "$SELF"
		CCENV_UPDATED=1 exec bash "$SELF"
	fi
fi

# --- op self-heal -----------------------------------------------------------
# Older snapshots' bootstrap.sh installed op via `mise use --global`, which
# only reaches PATH through /etc/profile.d — invisible to this hook's
# non-login shell (and to any subprocess resolving `op` via a bare PATH
# lookup). Direct-install it the same way current bootstrap.sh does, so
# already-built snapshots heal via this hook's self-update above without
# waiting for a cache rebuild.
# CCENV_SKIP_INSTALL=1 is test-only: it disables this block so the bats
# suite (which restricts PATH so `command -v op` fails on purpose) never
# triggers a real network download.
if [ "${CCENV_SKIP_INSTALL:-}" != "1" ] && ! command -v op >/dev/null 2>&1 && [ ! -x /usr/local/bin/op ]; then
	OP_VERSION="2.32.0"
	OP_BIN_DIR=/usr/local/bin
	if [ ! -w "$OP_BIN_DIR" ]; then
		OP_BIN_DIR="$HOME/.local/bin"
		install -d "$OP_BIN_DIR" 2>/dev/null
		export PATH="$OP_BIN_DIR:$PATH"
		log "op: /usr/local/bin not writable; self-healing to ${OP_BIN_DIR} instead."
	fi
	if curl -fsSL --max-time 15 "https://cache.agilebits.com/dist/1P/op2/pkg/v${OP_VERSION}/op_linux_amd64_v${OP_VERSION}.zip" \
		-o /tmp/ccenv-op.zip 2>/dev/null; then
		install -d /tmp/ccenv-op-install 2>/dev/null
		if command -v unzip >/dev/null 2>&1; then
			unzip -oq /tmp/ccenv-op.zip -d /tmp/ccenv-op-install op 2>/dev/null
		elif command -v busybox >/dev/null 2>&1; then
			busybox unzip -oq /tmp/ccenv-op.zip -d /tmp/ccenv-op-install op 2>/dev/null
		fi
		if [ -f /tmp/ccenv-op-install/op ] && install -m755 /tmp/ccenv-op-install/op "${OP_BIN_DIR}/op" 2>/dev/null; then
			log "op: self-healed — installed ${OP_VERSION} to ${OP_BIN_DIR}/op."
		else
			log "op: self-heal install FAILED (no unzip/busybox, or install denied) — op unavailable this session."
		fi
		rm -rf /tmp/ccenv-op.zip /tmp/ccenv-op-install
	else
		log "op: self-heal download FAILED — op unavailable this session."
	fi
fi

# --- GitHub token sanity check ----------------------------------------------
# mise sends GITHUB_TOKEN on release/asset lookups for BOTH the aqua backend
# and the github backend (talos-cluster resolves two tools — flate, yayamlls — # codespell:ignore flate
# via github:) AND on fetching each backend's signature/attestation data
# (aqua: cosign, SLSA, minisign, GitHub Artifact Attestations; github: SLSA,
# GitHub Artifact Attestations — confirmed as separate settings with no
# cascade from aqua.*, e.g. `MISE_GITHUB_SLSA` doesn't touch `aqua.slsa`).
# The token is not merely a rate-limit nicety: when aqua believes it is
# authenticated it resolves a release asset through the GitHub *API*
# (…/releases/assets/<id>), and unauthenticated it falls back to the plain
# public release-download URL, which is not API-gated. So a token the API
# refuses takes the whole install down rather than just slowing it — this
# hook's own `mise exec -- just talos gen-config` below included.
#
# The sandbox supplies no usable token, and NOT in the way this check
# originally assumed. GITHUB_TOKEN/GH_TOKEN hold the literal sentinel
# `proxy-injected`; the egress proxy enforces GitHub access itself rather
# than passing a credential through to GitHub. Measured in a live cloud
# session on 2026-08-31:
#
#   - api.github.com/rate_limit answers 200 with an IDENTICAL synthetic body
#     whether or not an Authorization header is sent (same quota, same reset
#     timestamp, a 15000 limit no anonymous caller would ever get). The proxy
#     answers it directly; the request never reaches GitHub.
#   - EVERY api.github.com/repos/… call returns 403 — authenticated or
#     anonymous, third-party repositories AND this session's own sources.
#     Only the message differs ("Use add_repo to request access" for a
#     third-party repository, an org-level gate for our own).
#
# So the previous probe (curl …/rate_limit) was measuring the proxy, not the
# token, and could only ever answer "the token is fine". mise then kept it
# and 403'd on the first uncached tool: on 2026-08-31 `just talos gen-config`
# died on aqua:zizmorcore/zizmor with `github auth: yes` and
# `GitHub access to this repository is not enabled for this session`, which
# reads like a missing repository rather than a token that should have been
# dropped. Never probe an unscoped endpoint for this again — check the
# sentinel first (deterministic, no network), then fall back to a capability
# probe against a THIRD-PARTY repository, which is what mise actually needs.
#
# When the token is unusable, every mise invocation in this script gets
# prefixed with GITHUB_TOKEN='' GH_TOKEN='' — which is what makes aqua take
# the public release-download path — and both backends' signature/attestation
# verification gets disabled (clearing the token alone still fails there:
# those APIs need *some* credential, unlike the release download). talos-
# cluster pins tool checksums via its committed mise.lock, so artifact
# integrity is still enforced by the lockfile without live attestation calls.

# Token values that are not credentials. Space-separated, overridable so a
# sandbox that renames its sentinel needs no edit here.
CCENV_GH_TOKEN_SENTINELS="${CCENV_GH_TOKEN_SENTINELS:-proxy-injected}"

# A third-party repository this environment will never have as a session
# source, on the releases API — the exact capability mise needs. Overridable
# for the same reason.
CCENV_GH_PROBE_URL="${CCENV_GH_PROBE_URL:-https://api.github.com/repos/cli/cli/releases/latest}"

ccenv_gh_token_ok() {
	[ -n "${GITHUB_TOKEN:-}" ] || return 1
	# Substring match on a space-padded list: no word splitting, so this
	# stays clean under shellcheck and needs no IFS juggling.
	case " ${CCENV_GH_TOKEN_SENTINELS} " in
	*" ${GITHUB_TOKEN} "*) return 1 ;;
	esac
	# No -S: a refused token here is the EXPECTED path, not an error — -S
	# would print curl's own error text to stderr for that expected case.
	# Any non-2xx (401, the proxy's 403, a network failure) fails closed and
	# drops the token, which is the branch that actually installs tools.
	curl -fs -m 8 -o /dev/null -H "Authorization: token ${GITHUB_TOKEN}" "$CCENV_GH_PROBE_URL"
}

# CCENV_SKIP_INSTALL=1 (test-only, see op self-heal above) short-circuits
# this check too — ccenv_gh_token_ok is never actually called (so curl never
# fires) when it's set, keeping the bats suite network-free.
# --- how mise installs here -------------------------------------------------
# Clearing the token is NOT enough on its own, and the verification-disabling
# that used to live here was actively the wrong move. Both measured in live
# cloud sessions on 2026-08-31:
#
#   - EVERY api.github.com/repos/... call is 403 in this sandbox, so any mise
#     operation that RESOLVES a version dies regardless of the token. `--locked`
#     fixes that outright: it installs from the URLs already recorded in
#     mise.lock and makes no API calls at all ("Require lockfile URLs to be
#     present during installation ... This prevents API calls to GitHub, aqua
#     registry, etc." — `mise install --help`). Same thing via MISE_LOCKED=1.
#   - Disabling cosign/SLSA/attestations did not help and actively HURT.
#     mise.lock records `provenance = "cosign"` for some tools, and installing
#     those with verification disabled trips mise's downgrade-attack
#     protection, so the install FAILS. Sigstore is not behind the sandbox's
#     GitHub gate: `MISE_AQUA_COSIGN=true mise install -y --locked
#     aqua:mikefarah/yq` printed "✓ Cosign verified" and installed cleanly,
#     where the same command with cosign disabled failed.
#
# So: lock the installs, and leave supply-chain verification ON.
#
# MISE_LOCKED is only added when the repo actually commits a lockfile —
# `--locked` on a repo without one fails every install, and the opentofu
# profile's repos do not all ship a mise.lock.
CCENV_MISE_ENV_PREFIX=""
if [ "${CCENV_SKIP_INSTALL:-}" = "1" ] || ! ccenv_gh_token_ok; then
	CCENV_MISE_ENV_PREFIX="GITHUB_TOKEN= GH_TOKEN="
	[ "${CCENV_SKIP_INSTALL:-}" = "1" ] ||
		log "GitHub token: unusable against the GitHub API — mise runs with GITHUB_TOKEN/GH_TOKEN cleared."
else
	log "GitHub token: usable against the GitHub API — left in place for mise."
fi
if [ -f mise.lock ]; then
	CCENV_MISE_ENV_PREFIX="${CCENV_MISE_ENV_PREFIX:+$CCENV_MISE_ENV_PREFIX }MISE_LOCKED=1"
	[ "${CCENV_SKIP_INSTALL:-}" = "1" ] ||
		log "mise: installing with MISE_LOCKED=1 (mise.lock URLs only, no GitHub API calls); signature verification left enabled."
fi

# Derive a DNS-label-safe tailnet hostname from the repo basename and the
# session ID. Live evidence: `tailscale up` failed with `"claude-...-cse_01Xf"
# is not a valid DNS label: contains invalid character '_'` — real session
# IDs commonly contain '_' (e.g. cse_01Xf), which RFC 1123 DNS labels
# forbid. Every input segment is character-filtered before assembly (the
# SID takes a wider 12-char slice first so filtering doesn't shorten it to
# nothing before the final cut to 8), and the assembled result is
# re-sanitised as a whole — lowercased, doubled hyphens collapsed,
# leading/trailing hyphens stripped, length-capped at 63 — since
# concatenation alone can still produce an invalid edge (e.g. a trailing
# '-' when the SID segment strips to nothing).
ccenv_hostname() {
	local repo_arg="${1:-}" sid_arg="${2:-}" repo_seg sid_seg hn
	repo_seg="$(basename "$repo_arg" | tr -cd 'a-zA-Z0-9-' | cut -c1-20)"
	sid_seg="$(printf '%s' "${sid_arg:0:12}" | tr -cd 'a-zA-Z0-9-' | cut -c1-8)"
	hn="claude-${repo_seg}-${sid_seg}"
	hn="$(printf '%s' "$hn" | tr '[:upper:]' '[:lower:]' | sed -E 's/-{2,}/-/g; s/^-+//; s/-+$//' | cut -c1-63)"
	if [ -z "$hn" ] || [ "$hn" = "claude" ]; then
		hn="claude-session"
	fi
	printf '%s' "$hn"
}

# --- tailnet join (ephemeral tagged node, userspace networking) -----------
# The sandbox's no_proxy/NO_PROXY covers 100.64.0.0/10 and all RFC1918
# ranges (Phase 0), so every tailnet-bound command below clears both —
# otherwise proxy-honouring tools bypass localhost:1055 and dial direct,
# which never routes to anything behind a subnet router.
if command -v tailscaled >/dev/null 2>&1; then
	if ! pgrep -x tailscaled >/dev/null 2>&1; then
		nohup tailscaled --tun=userspace-networking \
			--socks5-server=localhost:1055 \
			--outbound-http-proxy-listen=localhost:1055 \
			--state=mem: >/tmp/tailscaled.log 2>&1 &
		for _ in $(seq 1 30); do
			[ -S /var/run/tailscale/tailscaled.sock ] && break
			sleep 0.5
		done
	fi
	if [ -n "${TS_OAUTH_CLIENT_SECRET:-}" ] && ! tailscale status >/dev/null 2>&1; then
		HN="$(ccenv_hostname "$(pwd)" "${CLAUDE_CODE_REMOTE_SESSION_ID:-}")"
		# --accept-routes: the cluster and all LAN devices sit behind subnet
		# routers, not directly on the tailnet (Phase 0) — without this flag
		# nothing infra-side is reachable even once joined.
		if no_proxy='' NO_PROXY='' tailscale up \
			--auth-key="${TS_OAUTH_CLIENT_SECRET}?ephemeral=true&preauthorized=true" \
			--advertise-tags=tag:claude-cloud \
			--accept-routes \
			--hostname="$HN" --timeout 60s; then
			log "Tailnet: joined as ${HN} (ephemeral, tag:claude-cloud)."
		else
			log "Tailnet: JOIN FAILED — see /tmp/tailscaled.log; continuing without tailnet."
		fi
	fi
fi

# --- git identity ----------------------------------------------------------
# The cloud harness commits as `Claude <noreply@anthropic.com>`, so every
# squash-merge lands on GitHub with Claude as the author and GitHub appends a
# `Co-authored-by: Claude` trailer. Author cloud commits as the account owner
# instead — the GitHub noreply address attributes to the account without
# exposing a mailbox. GIT_AUTHOR_*/GIT_COMMITTER_* env vars override git
# config, so if the harness exports them this block cannot win: say so, and
# tell the session how to clear them per command.
CCENV_GIT_NAME="Luke Evans"
CCENV_GIT_EMAIL="17546908+LukeEvansTech@users.noreply.github.com"
if command -v git >/dev/null 2>&1; then
	git config --global user.name "$CCENV_GIT_NAME"
	git config --global user.email "$CCENV_GIT_EMAIL"
	if [ -n "${GIT_AUTHOR_NAME:-}${GIT_AUTHOR_EMAIL:-}${GIT_COMMITTER_NAME:-}${GIT_COMMITTER_EMAIL:-}" ]; then
		log "Git identity: harness exports GIT_AUTHOR_*/GIT_COMMITTER_* (${GIT_AUTHOR_NAME:-unset} <${GIT_AUTHOR_EMAIL:-unset}>), which OVERRIDE git config — commits will not be authored as ${CCENV_GIT_NAME}. Prefix every commit with: env -u GIT_AUTHOR_NAME -u GIT_AUTHOR_EMAIL -u GIT_COMMITTER_NAME -u GIT_COMMITTER_EMAIL git commit ..."
	else
		log "Git identity: commits author as ${CCENV_GIT_NAME} <${CCENV_GIT_EMAIL}> (git config --global)."
	fi
fi

# --- profile detection -----------------------------------------------------
# The catalog is a single repo checkout now, so the profile is auto-detected
# from on-disk markers. CLAUDE_ENV_PROFILE, if set non-empty, overrides
# detection outright — an escape hatch for unusual repos (e.g. a fork laid
# out differently, or local testing) where the markers below don't apply.
PROFILE="${CLAUDE_ENV_PROFILE:-}"
if [ -n "$PROFILE" ]; then
	PROFILE_LINE="Profile: ${PROFILE} (override via CLAUDE_ENV_PROFILE)"
elif [ -f talos/talconfig.yaml ]; then
	PROFILE="talos"
	PROFILE_LINE="Profile: talos (auto-detected from talos/talconfig.yaml)"
elif [ -f .env.cloud ]; then
	PROFILE="opentofu"
	PROFILE_LINE="Profile: opentofu (auto-detected from .env.cloud)"
else
	PROFILE_LINE="Profile: none"
fi

# --- per-profile secret-derived state -------------------------------------
case "$PROFILE" in
talos)
	# Heal a .mise.local.toml left by an older hook. Cloud sandboxes are
	# REUSED between runs and this file is gitignored, so it survives the
	# per-run repo re-fetch — and the `grep -q '^GITHUB_TOKEN'` guard below
	# then sees a "already written" file and skips the rewrite, silently
	# preserving the verification-disabling settings that break locked
	# installs. Observed live on 2026-08-31: the hook script self-updated
	# correctly (no `cosign = false` anywhere in it) while the generated
	# file still carried `aqua.cosign = false` from the previous run, so
	# gen-config kept failing for a fix that had actually shipped.
	# Deleting is safe: everything in it is regenerated below from
	# INTERNAL_DOMAIN_RE and the current settings.
	if [ -f .mise.local.toml ] && grep -Eq '^[[:space:]]*(aqua|github)\.[a-z_]+[[:space:]]*=[[:space:]]*false' .mise.local.toml; then
		rm -f .mise.local.toml
		log "Talos: discarded a stale .mise.local.toml from an older hook (it disabled signature verification, which breaks --locked installs); regenerating."
	fi
	if [ -n "${INTERNAL_DOMAIN_RE:-}" ] && [ ! -f .mise.local.toml ]; then
		printf '[env]\nINTERNAL_DOMAIN_RE = '\''%s'\''\n' "${INTERNAL_DOMAIN_RE}" >.mise.local.toml
		log "Talos: .mise.local.toml written (identifier guard active)."
	fi
	# GITHUB_TOKEN/GH_TOKEN under [env] only reach processes mise SPAWNS as
	# children (mise exec's target command, a `mise run` task's
	# subprocesses — e.g. `gh`). They do NOT cover mise's OWN GitHub calls
	# (release lookups, install resolution): mise reads the real process
	# env for those before merging this file's [env] section, so a bare
	# in-session `mise install`/`mise exec` still sees the sandbox's bad
	# token unless the COMMAND ITSELF is prefixed with GITHUB_TOKEN=''
	# GH_TOKEN='' (see the CTX bullet below — this is REQUIRED, not just
	# helpful; reproduced empirically: a bad process-level token plus this
	# exact [env]-cleared config still 401'd on a fresh github: install,
	# and only clearing the token in the real process env fixed it).
	#
	# `locked = true` in [settings] is the durable half of the fix above: it
	# applies to a bare in-session `mise install` too, not just the commands
	# this hook prefixes. NOTHING here disables signature verification any
	# more — doing so is what broke installs of lockfile entries carrying
	# `provenance = "cosign"`.
	if [ -n "$CCENV_MISE_ENV_PREFIX" ] && { [ ! -f .mise.local.toml ] || ! grep -q '^GITHUB_TOKEN' .mise.local.toml; }; then
		[ -f .mise.local.toml ] || printf '[env]\n' >.mise.local.toml
		printf 'GITHUB_TOKEN = ""\nGH_TOKEN = ""\n' >>.mise.local.toml
		if [ -f mise.lock ]; then
			printf '\n[settings]\nlocked = true\n' >>.mise.local.toml
		fi
		log "Talos: .mise.local.toml updated — GITHUB_TOKEN/GH_TOKEN cleared for mise-spawned children only (does NOT cover mise's own installs; prefix those commands directly); installs locked to mise.lock URLs with signature verification left enabled."
	fi
	if [ -f .mise.local.toml ]; then
		# Hook-written config is untrusted until `mise trust` runs — mise
		# refuses to parse an untrusted file, silently ignoring everything
		# written above. This heals both the write above and any older
		# snapshot that wrote this file without ever trusting it.
		mise trust --quiet .mise.local.toml || mise trust --quiet || true
	fi
	# Generate the config WITHOUT `mise exec -- just talos gen-config`.
	#
	# `mise exec` (and a bare `mise install`) resolves the repository's ENTIRE
	# ~30-tool manifest, and under `--locked` that fails outright: eight tools
	# in .mise.toml are pinned to "latest" and so carry no lockfile URL to
	# install from. Measured 2026-08-31 — the whole-manifest resolve failed in
	# seconds with `talosctl unavailable (install failed)`, while naming
	# individual PINNED tools installed them cleanly, both reporting
	# "✓ Cosign verified".
	#
	# So: install only the pinned tools this profile needs, resolve each
	# binary to an absolute path once, and invoke those paths directly. No
	# shim and no `mise exec` at run time, either of which can re-enter
	# manifest resolution. talhelper is deliberately NOT installed — it is
	# baked into the environment snapshot already.
	#
	# This inlines what `just talos gen-config` does (op fetch, LUKS fallback,
	# talhelper genconfig). That is a deliberate coupling to talos-cluster's
	# recipe: going through `just` would drag in `just` itself plus `gum` for
	# its logging, and `gum` is one of the "latest"-pinned tools that cannot
	# be installed here at all.
	ccenv_mise_bin() {
		# shellcheck disable=SC2086 # intentional word-split env-assignment list
		env $CCENV_MISE_ENV_PREFIX mise which "$1" 2>/dev/null
	}
	if [ -n "${OP_SERVICE_ACCOUNT_TOKEN:-}" ] && [ ! -f talos/clusterconfig/talosconfig ]; then
		# shellcheck disable=SC2086 # CCENV_MISE_ENV_PREFIX is an intentional word-split env-assignment list consumed by `env`.
		env $CCENV_MISE_ENV_PREFIX mise install -y aqua:siderolabs/talos aqua:mikefarah/yq >/dev/null 2>&1 || true
		CCENV_TALHELPER="$(ccenv_mise_bin talhelper)"
		CCENV_YQ="$(ccenv_mise_bin yq)"
		CCENV_TALOSCTL="$(ccenv_mise_bin talosctl)"
		CCENV_GENCONFIG=""
		if [ -n "$CCENV_TALHELPER" ] && [ -x "$CCENV_TALHELPER" ]; then
			CCENV_TALSECRET="$(mktemp)"
			if op document get talsecret --vault Talos >"$CCENV_TALSECRET" 2>/dev/null &&
				[ -s "$CCENV_TALSECRET" ] &&
				TALOS_LUKS_FALLBACK="$(op read 'op://Talos/talos-luks-fallback/password' 2>/dev/null)" &&
				[ -n "$TALOS_LUKS_FALLBACK" ]; then
				export TALOS_LUKS_FALLBACK
				if "$CCENV_TALHELPER" genconfig \
					--config-file talos/talconfig.yaml \
					--secret-file "$CCENV_TALSECRET" \
					--out-dir talos/clusterconfig; then
					CCENV_GENCONFIG=1
				fi
				unset TALOS_LUKS_FALLBACK
			fi
			rm -f "$CCENV_TALSECRET"
			unset CCENV_TALSECRET
		fi
		if [ -n "$CCENV_GENCONFIG" ]; then
			log "Talos: talosconfig generated from 1Password talsecret."
			CP_NODE=""
			if [ -n "$CCENV_YQ" ] && [ -x "$CCENV_YQ" ]; then
				CP_NODE="$("$CCENV_YQ" -r '[.nodes[] | select(.controlPlane == true)][0].ipAddress' talos/talconfig.yaml 2>/dev/null || true)"
			fi
			if [ -n "$CP_NODE" ] && [ "$CP_NODE" != "null" ] && [ -n "$CCENV_TALOSCTL" ]; then
				# Phase 0 verdict (Task 2): talosctl's gRPC client honours only
				# HTTPS_PROXY, not ALL_PROXY/SOCKS (SOCKS times out). Also clear
				# no_proxy/NO_PROXY — see the tailnet-join comment above. The
				# proxy vars are a literal prefix (parsed once, at write time);
				# CCENV_MISE_ENV_PREFIX is a second, independent env prefix
				# applied to the `env` call it wraps — both coexist fine since
				# each is consumed by a different command in the pipeline.
				if no_proxy='' NO_PROXY='' http_proxy='' https_proxy=http://localhost:1055 HTTPS_PROXY=http://localhost:1055 "$CCENV_TALOSCTL" kubeconfig --nodes "$CP_NODE" --force; then
					log "Talos: kubeconfig fetched from ${CP_NODE}."
				else
					log "Talos: kubeconfig fetch FAILED — run manually: talosctl kubeconfig --nodes ${CP_NODE} --force"
				fi
			elif [ -z "$CCENV_TALOSCTL" ]; then
				log "Talos: kubeconfig SKIPPED — talosctl did not install (aqua:siderolabs/talos); talosconfig is still usable once talosctl is available."
			fi
		else
			# Attribute the failure to the thing that actually failed. Live
			# evidence has twice shown this message blaming the wrong
			# component, so each branch names a distinct, checkable cause.
			if [ -z "$CCENV_TALHELPER" ]; then
				log "Talos: gen-config FAILED — talhelper is not available in this environment (it is normally baked into the snapshot); nothing to do with op or the GitHub token."
			elif op whoami >/dev/null 2>&1; then
				log "Talos: gen-config FAILED — talhelper ran and op is reachable and authorised, so this is talhelper/talconfig, not a credential or toolchain problem."
			else
				log "Talos: gen-config FAILED — op is unreachable or unauthorised; check OP_SERVICE_ACCOUNT_TOKEN and op connectivity."
			fi
		fi
		unset CCENV_TALHELPER CCENV_YQ CCENV_TALOSCTL CCENV_GENCONFIG
	fi
	;;
opentofu)
	if [ -f .env.cloud ] && [ ! -f .env ]; then
		cp .env.cloud .env
		log "OpenTofu: .env created from committed .env.cloud (op:// refs; resolve via 'op run --env-file=.env -- <cmd>')."
	fi
	;;
esac

cat <<'CTX'
Cloud session networking (from claude-cloud-env session-start hook):
- Tailnet via userspace tailscaled; SOCKS5 + HTTP proxy on localhost:1055.
  All tailnet traffic is DERP-relayed in this sandbox (no UDP), and subnet
  routes for your subnet-routed LANs are accepted at join (--accept-routes).
- The sandbox's own no_proxy/NO_PROXY covers 100.64.0.0/10 and all RFC1918
  ranges, which makes proxy-honouring tools bypass localhost:1055 and dial
  direct (no route) for exactly the hosts you need. The sandbox also
  pre-exports a lowercase http_proxy/https_proxy (its own agent proxy),
  which many tools — curl included — prefer over the uppercase form, so
  both cases must be overridden. Prefix EVERY tailnet-bound command with:
    no_proxy='' NO_PROXY='' http_proxy='' https_proxy=http://localhost:1055 HTTPS_PROXY=http://localhost:1055
  This one prefix works for curl, kubectl, and talosctl. A SOCKS5 proxy is
  also up on the same port, but talosctl's gRPC client ignores
  ALL_PROXY/SOCKS and times out — always use the HTTPS_PROXY form above.
- MagicDNS does NOT resolve here (resolv.conf points elsewhere) — use
  tailnet or LAN IPs from `tailscale status`, not hostnames.
- SSH to tailnet hosts: no_proxy='' NO_PROXY='' ssh -o ProxyCommand='tailscale nc %h %p' user@host
  (or tailscale ssh user@host). Check connectivity: tailscale status.
- Secrets: op CLI is authenticated via OP_SERVICE_ACCOUNT_TOKEN (read-only,
  scoped vaults). Use op run / op read. Never print secret values.
- GitHub: the sandbox's injected GITHUB_TOKEN/GH_TOKEN can be a placeholder
  that GitHub rejects with 401 Bad credentials. This is REQUIRED, not just
  helpful: prefix EVERY `mise install`/`mise exec`/gh/aqua-touching command
  with GITHUB_TOKEN='' GH_TOKEN='' whenever it 401s — falls back to
  anonymous GitHub API access, capped at ~60 requests/hour. The
  .mise.local.toml this hook writes does NOT cover this for commands you
  run yourself: it only clears the token for processes mise spawns as
  children, not for mise's own installs, which read the real (bad) token
  straight from the process environment.
CTX

printf '%s\n' "$PROFILE_LINE"
