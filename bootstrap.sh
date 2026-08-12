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

# Pre-warm the talos-cluster toolchain into the shared mise data dir (same
# shared-user assumption as the cwd warm-up above: bootstrap runs as root,
# and tool installs land under root's mise data dir, which sessions reuse).
# The env snapshot every session starts from is built by whichever repo's
# setup script runs first — that's rarely talos-cluster, so its sessions
# otherwise start with nothing cached and cold-install ~30 tools against
# GitHub's 60/h anonymous rate limit (see hooks/session-start.sh's
# GitHub-token comment for why the sandbox's injected token can't help:
# it's a placeholder GitHub rejects with 401, so this clears it and skips
# aqua AND github backend signature/attestation verification here too —
# talos-cluster resolves two tools via github: as well as aqua:, and the
# two backends' verify settings are separate with no cascade between them
# — talos-cluster's committed mise.lock still enforces checksum integrity
# on install). Never fatal: every step falls back to a WARN so a failed
# pre-warm can't break the snapshot build.
if command -v mise >/dev/null 2>&1; then
	log "pre-warming talos-cluster toolchain into shared mise cache"
	# Idempotent: a re-run (e.g. a cache-rebuild retry) with the checkout
	# already present skips straight to trust+install instead of
	# re-cloning. GIT_TERMINAL_PROMPT=0 stops git hanging on a credential
	# prompt in this non-interactive script; `-c credential.helper=`
	# disables any inherited credential helper for the clone, and
	# GITHUB_TOKEN/GH_TOKEN are cleared too — the sandbox's placeholder
	# token can 401 even a public, unauthenticated clone if a helper or
	# these vars feed it to git, silently voiding the pre-warm.
	CLONE_OK=0
	if [ -d /opt/ccenv-warm/talos-cluster ]; then
		CLONE_OK=1
	elif GIT_TERMINAL_PROMPT=0 GITHUB_TOKEN='' GH_TOKEN='' git clone -c credential.helper= --depth 1 https://github.com/LukeEvansTech/talos-cluster /opt/ccenv-warm/talos-cluster; then
		CLONE_OK=1
	else
		log "WARN: talos toolchain pre-warm failed (non-fatal)"
	fi
	if [ "$CLONE_OK" = "1" ]; then
		# `&&`-chained explicitly rather than relying on `set -e`: inside a
		# subshell that's itself the LHS of `||`, bash suspends errexit for
		# the whole subshell (a documented gotcha), so a failed `mise trust`
		# would otherwise NOT stop `mise install` from still running.
		(
			cd /opt/ccenv-warm/talos-cluster &&
				GITHUB_TOKEN='' GH_TOKEN='' MISE_AQUA_COSIGN=false MISE_AQUA_SLSA=false MISE_AQUA_MINISIGN=false MISE_AQUA_GITHUB_ATTESTATIONS=false MISE_GITHUB_SLSA=false MISE_GITHUB_GITHUB_ATTESTATIONS=false mise trust --quiet &&
				GITHUB_TOKEN='' GH_TOKEN='' MISE_AQUA_COSIGN=false MISE_AQUA_SLSA=false MISE_AQUA_MINISIGN=false MISE_AQUA_GITHUB_ATTESTATIONS=false MISE_GITHUB_SLSA=false MISE_GITHUB_GITHUB_ATTESTATIONS=false mise install --yes
		) || log "WARN: talos toolchain pre-warm failed (non-fatal)"
	fi
fi

# Pre-warm the terraform toolchain (opentofu, tflint) into the shared mise
# data dir, same rationale as the talos-cluster warm above: a live cloud
# session on a terraform repo found api.github.com proxy-gatekept (403) at
# SESSION time, so mise couldn't self-install these tools there — but
# snapshot-BUILD time (here) reaches the GitHub API fine. Pinned to
# 1.12.5/0.64.0, what the day-one terraform repos (terraform-nextdns,
# terraform-tailscale) declare in mise.toml. Other terraform repos pin
# slightly different versions (e.g. terraform-github: opentofu 1.12.3,
# tflint 0.63.1) and will cold-install those on first use — deliberate,
# only the day-one pins are warmed here. `mise install TOOL@VERSION` (no
# config file) installs straight into the shared data dir, unlike the
# trust+install pair above which reads a checked-out mise.toml. Same
# env-var pattern as the talos warm: clears GITHUB_TOKEN/GH_TOKEN (the
# sandbox's placeholder token 401s even unauthenticated requests) and
# disables aqua/github backend signature verification. Never fatal: each
# install falls back to a WARN.
if command -v mise >/dev/null 2>&1; then
	log "pre-warming terraform toolchain (opentofu, tflint) into shared mise cache"
	GITHUB_TOKEN='' GH_TOKEN='' MISE_AQUA_COSIGN=false MISE_AQUA_SLSA=false MISE_AQUA_MINISIGN=false MISE_AQUA_GITHUB_ATTESTATIONS=false MISE_GITHUB_SLSA=false MISE_GITHUB_GITHUB_ATTESTATIONS=false mise install --yes opentofu@1.12.5 || log "WARN: opentofu pre-warm failed (non-fatal)"
	GITHUB_TOKEN='' GH_TOKEN='' MISE_AQUA_COSIGN=false MISE_AQUA_SLSA=false MISE_AQUA_MINISIGN=false MISE_AQUA_GITHUB_ATTESTATIONS=false MISE_GITHUB_SLSA=false MISE_GITHUB_GITHUB_ATTESTATIONS=false mise install --yes tflint@0.64.0 || log "WARN: tflint pre-warm failed (non-fatal)"
fi

log "bootstrap complete"
