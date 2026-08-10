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
		HN="claude-$(basename "$(pwd)" | tr -cd 'a-zA-Z0-9-' | cut -c1-20)-${CLAUDE_CODE_REMOTE_SESSION_ID:0:8}"
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
	if [ -n "${OP_SERVICE_ACCOUNT_TOKEN:-}" ] && [ ! -f talos/clusterconfig/talosconfig ]; then
		if mise exec -- just talos gen-config; then
			log "Talos: talosconfig generated from 1Password talsecret."
			CP_NODE="$(mise exec -- yq -r '[.nodes[] | select(.controlPlane == true)][0].ipAddress' talos/talconfig.yaml 2>/dev/null || true)"
			if [ -n "$CP_NODE" ] && [ "$CP_NODE" != "null" ]; then
				# Phase 0 verdict (Task 2): talosctl's gRPC client honours only
				# HTTPS_PROXY, not ALL_PROXY/SOCKS (SOCKS times out). Also clear
				# no_proxy/NO_PROXY — see the tailnet-join comment above.
				if no_proxy='' NO_PROXY='' HTTPS_PROXY=http://localhost:1055 mise exec -- talosctl kubeconfig --nodes "$CP_NODE" --force; then
					log "Talos: kubeconfig fetched from ${CP_NODE}."
				else
					log "Talos: kubeconfig fetch FAILED — run manually: talosctl kubeconfig --nodes ${CP_NODE} --force"
				fi
			fi
		else
			log "Talos: gen-config FAILED — check OP_SERVICE_ACCOUNT_TOKEN and op connectivity."
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
  direct (no route) for exactly the hosts you need. Prefix EVERY
  tailnet-bound command with:
    no_proxy='' NO_PROXY='' HTTPS_PROXY=http://localhost:1055
  This one prefix works for curl, kubectl, and talosctl. A SOCKS5 proxy is
  also up on the same port, but talosctl's gRPC client ignores
  ALL_PROXY/SOCKS and times out — always use the HTTPS_PROXY form above.
- MagicDNS does NOT resolve here (resolv.conf points elsewhere) — use
  tailnet or LAN IPs from `tailscale status`, not hostnames.
- SSH to tailnet hosts: no_proxy='' NO_PROXY='' ssh -o ProxyCommand='tailscale nc %h %p' user@host
  (or tailscale ssh user@host). Check connectivity: tailscale status.
- Secrets: op CLI is authenticated via OP_SERVICE_ACCOUNT_TOKEN (read-only,
  scoped vaults). Use op run / op read. Never print secret values.
CTX

printf '%s\n' "$PROFILE_LINE"
