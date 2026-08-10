#!/usr/bin/env bash
# claude-cloud-env bootstrap — body of every cloud environment's setup script.
# Runs as root on Ubuntu 24.04 BEFORE Claude Code launches; the resulting
# filesystem is snapshotted and reused ~7 days. TOOLS ONLY — never secrets.
#
# NOTE: the setup script's working directory and session user were NOT
# captured by the Phase 0 probe (only tool presence was confirmed). The
# root/etc/profile.d approach and the cwd-search fallback below are best
# guesses pending a future probe; adjust per the inline comments if a
# session ever contradicts them.
set -euo pipefail

REPO_RAW="https://raw.githubusercontent.com/LukeEvansTech/claude-cloud-env/main"
TS_VERSION="1.102.2"
OP_VERSION="2.32.0"

log() { printf '[claude-cloud-env] %s\n' "$*"; }

if ! command -v mise >/dev/null 2>&1; then
	log "installing mise"
	curl -fsSL https://mise.run | MISE_INSTALL_PATH=/usr/local/bin/mise sh
fi

if ! command -v tailscaled >/dev/null 2>&1; then
	log "installing tailscale ${TS_VERSION}"
	curl -fsSL "https://pkgs.tailscale.com/stable/tailscale_${TS_VERSION}_amd64.tgz" -o /tmp/ts.tgz
	tar -xzf /tmp/ts.tgz -C /tmp
	install -m755 "/tmp/tailscale_${TS_VERSION}_amd64/tailscale" /usr/local/bin/
	install -m755 "/tmp/tailscale_${TS_VERSION}_amd64/tailscaled" /usr/local/sbin/
	rm -rf /tmp/ts.tgz "/tmp/tailscale_${TS_VERSION}_amd64"
fi

# Direct binary install to /usr/local/bin (PATH-independent), matching the
# tailscale install above — NOT `mise use --global`, which puts op in mise's
# shims dir. Shims are only on PATH via /etc/profile.d/claude-cloud-env.sh,
# which non-login session shells (and any subprocess resolving `op` via a
# bare PATH lookup) never source, making op invisible where it's needed.
if ! command -v op >/dev/null 2>&1; then
	log "installing 1password-cli ${OP_VERSION}"
	curl -fsSL "https://cache.agilebits.com/dist/1P/op2/pkg/v${OP_VERSION}/op_linux_amd64_v${OP_VERSION}.zip" -o /tmp/op.zip
	if ! command -v unzip >/dev/null 2>&1 && ! command -v busybox >/dev/null 2>&1; then
		log "unzip not found; installing via apt-get"
		apt-get install -y -qq unzip
	fi
	install -d /tmp/op-install
	if command -v unzip >/dev/null 2>&1; then
		unzip -oq /tmp/op.zip -d /tmp/op-install op
	elif command -v busybox >/dev/null 2>&1; then
		log "unzip not found; using busybox unzip"
		busybox unzip -oq /tmp/op.zip -d /tmp/op-install op
	else
		log "ERROR: no unzip or busybox available to extract op archive"
		exit 1
	fi
	install -m755 /tmp/op-install/op /usr/local/bin/op
	rm -rf /tmp/op.zip /tmp/op-install
fi

install -d /opt/claude-cloud-env
curl -fsSL "${REPO_RAW}/hooks/session-start.sh" -o /opt/claude-cloud-env/session-start.sh
chmod +x /opt/claude-cloud-env/session-start.sh

# mise shims for non-interactive shells (assumes the setup script runs as
# root, per Task 1's runbook — Phase 0 did not confirm the session user;
# if a session ever shows a different user, install mise data under a
# shared dir instead: export MISE_DATA_DIR=/opt/mise in this profile.d file
# and re-run). Still useful for other mise-managed tools; op is installed
# directly to /usr/local/bin above and no longer depends on this.
cat >/etc/profile.d/claude-cloud-env.sh <<'EOF'
export PATH="$HOME/.local/share/mise/shims:$PATH"
EOF

# Warm the repo toolchain if the checkout declares one. Phase 0 did not
# confirm the setup script's cwd, so fall back to searching common checkout
# locations if the toolchain file isn't in the cwd already.
if [ ! -f mise.toml ] && [ ! -f .mise.toml ]; then
	for d in /workspace/* /root/workspace/* "$HOME"/*/; do
		if [ -f "$d/mise.toml" ] || [ -f "$d/.mise.toml" ]; then cd "$d" && break; fi
	done
fi
if [ -f mise.toml ] || [ -f .mise.toml ]; then
	log "warming mise toolchain from $(pwd)"
	mise trust || true
	mise install --yes || log "WARN: mise install failed; sessions install lazily"
fi

log "bootstrap complete"
