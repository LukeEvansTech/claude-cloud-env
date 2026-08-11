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
# The cloud sandbox injects a placeholder GITHUB_TOKEN/GH_TOKEN (~14 chars)
# that GitHub rejects with 401 "Bad credentials" on any authenticated call.
# mise sends that token on release lookups for BOTH the aqua backend and
# the github backend (talos-cluster resolves two tools — flate, yayamlls — # codespell:ignore flate
# via github:) AND on fetching each backend's signature/attestation data
# (aqua: cosign, SLSA, minisign, GitHub Artifact Attestations; github: SLSA,
# GitHub Artifact Attestations — confirmed as separate settings with no
# cascade from aqua.*, e.g. `MISE_GITHUB_SLSA` doesn't touch `aqua.slsa`),
# so every `mise exec`/`mise install` for a tool that isn't already cached
# fails outright — including this hook's own `mise exec -- just talos
# gen-config` below. Probe the token once: if it's missing or bad, every
# mise invocation in this script gets prefixed with GITHUB_TOKEN=''
# GH_TOKEN='' (falls back to anonymous GitHub API access, ~60 req/h) and
# both backends' signature/attestation verification gets disabled
# (clearing the token alone still 401s there — GitHub's attestations API
# needs *some* credential, unlike its releases API; reproduced empirically
# with a real bad token against a real, uncached github: tool). talos-
# cluster pins tool checksums via its committed mise.lock, so artifact
# integrity is still enforced via the lockfile without live attestation
# calls.
ccenv_gh_token_ok() {
	[ -n "${GITHUB_TOKEN:-}" ] || return 1
	# No -S: a bad token 401ing here is the EXPECTED path, not an error —
	# -S would print curl's own error text to stderr for that expected case.
	curl -fs -m 8 -o /dev/null -H "Authorization: token ${GITHUB_TOKEN}" https://api.github.com/rate_limit
}

# CCENV_SKIP_INSTALL=1 (test-only, see op self-heal above) short-circuits
# this check too — ccenv_gh_token_ok is never actually called (so curl never
# fires) when it's set, keeping the bats suite network-free.
CCENV_MISE_ENV_PREFIX=""
if [ "${CCENV_SKIP_INSTALL:-}" = "1" ] || ! ccenv_gh_token_ok; then
	CCENV_MISE_ENV_PREFIX="GITHUB_TOKEN= GH_TOKEN= MISE_AQUA_COSIGN=false MISE_AQUA_SLSA=false MISE_AQUA_MINISIGN=false MISE_AQUA_GITHUB_ATTESTATIONS=false MISE_GITHUB_SLSA=false MISE_GITHUB_GITHUB_ATTESTATIONS=false"
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
	# and only clearing the token in the real process env fixed it). The
	# aqua.*/github.* verify toggles below don't have this limitation —
	# mise reads settings from [settings] (or real env vars), never through
	# the [env]-merge path, so they DO apply to mise's own installs
	# regardless of who's asking.
	if [ -n "$CCENV_MISE_ENV_PREFIX" ] && { [ ! -f .mise.local.toml ] || ! grep -q '^GITHUB_TOKEN' .mise.local.toml; }; then
		[ -f .mise.local.toml ] || printf '[env]\n' >.mise.local.toml
		printf 'GITHUB_TOKEN = ""\nGH_TOKEN = ""\n\n[settings]\naqua.cosign = false\naqua.slsa = false\naqua.minisign = false\naqua.github_attestations = false\ngithub.slsa = false\ngithub.github_attestations = false\n' >>.mise.local.toml
		log "Talos: .mise.local.toml updated — GITHUB_TOKEN/GH_TOKEN cleared for mise-spawned children only (does NOT cover mise's own installs; prefix those commands directly) and aqua/github signature+attestation verification disabled (sandbox token 401s; mise.lock checksums still enforce integrity)."
	fi
	if [ -f .mise.local.toml ]; then
		# Hook-written config is untrusted until `mise trust` runs — mise
		# refuses to parse an untrusted file, silently ignoring everything
		# written above. This heals both the write above and any older
		# snapshot that wrote this file without ever trusting it.
		mise trust --quiet .mise.local.toml || mise trust --quiet || true
	fi
	if [ -n "${OP_SERVICE_ACCOUNT_TOKEN:-}" ] && [ ! -f talos/clusterconfig/talosconfig ]; then
		# shellcheck disable=SC2086 # CCENV_MISE_ENV_PREFIX is an intentional word-split env-assignment list consumed by `env`.
		if env $CCENV_MISE_ENV_PREFIX mise exec -- just talos gen-config; then
			log "Talos: talosconfig generated from 1Password talsecret."
			# shellcheck disable=SC2086
			CP_NODE="$(env $CCENV_MISE_ENV_PREFIX mise exec -- yq -r '[.nodes[] | select(.controlPlane == true)][0].ipAddress' talos/talconfig.yaml 2>/dev/null || true)"
			if [ -n "$CP_NODE" ] && [ "$CP_NODE" != "null" ]; then
				# Phase 0 verdict (Task 2): talosctl's gRPC client honours only
				# HTTPS_PROXY, not ALL_PROXY/SOCKS (SOCKS times out). Also clear
				# no_proxy/NO_PROXY — see the tailnet-join comment above. The
				# proxy vars are a literal prefix (parsed once, at write time);
				# CCENV_MISE_ENV_PREFIX is a second, independent env prefix
				# applied to the `env` call it wraps — both coexist fine since
				# each is consumed by a different command in the pipeline.
				# shellcheck disable=SC2086
				if no_proxy='' NO_PROXY='' http_proxy='' https_proxy=http://localhost:1055 HTTPS_PROXY=http://localhost:1055 env $CCENV_MISE_ENV_PREFIX mise exec -- talosctl kubeconfig --nodes "$CP_NODE" --force; then
					log "Talos: kubeconfig fetched from ${CP_NODE}."
				else
					log "Talos: kubeconfig fetch FAILED — run manually: talosctl kubeconfig --nodes ${CP_NODE} --force"
				fi
			fi
		else
			# Distinguish op failure from mise/toolchain resolution failure —
			# live evidence showed op was fine while this message blamed it;
			# the real cause was mise's aqua lookups 401ing on the sandbox's
			# placeholder GITHUB_TOKEN.
			if op whoami >/dev/null 2>&1; then
				log "Talos: gen-config FAILED — op is reachable and authorised, so this is a mise/toolchain resolution failure (check GitHub token / rate limits, not OP_SERVICE_ACCOUNT_TOKEN)."
			else
				log "Talos: gen-config FAILED — op is unreachable or unauthorised; check OP_SERVICE_ACCOUNT_TOKEN and op connectivity."
			fi
		fi
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
