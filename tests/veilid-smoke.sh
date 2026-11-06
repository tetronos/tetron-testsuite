#!/usr/bin/env bash
# meta:id veilid-smoke
# meta:description Live connectivity check for the Veilid transport (VEILID-001..019, external-daemon architecture): install the tetron-veilid companion daemon on both nodes, create --veilid -> restart -> join --veilid -> restart -> restart node1 again (confound-free steady-state check, VEILID-012) -> asserts a Veilid path candidate with real traffic appears in tetron status --json's paths[], on both sides.
# meta:nodes 2
# meta:networks 1
#
# Requires a tetron binary built with `--features veilid`
# (`cargo build --release --features veilid` in the tetron repo). Not part
# of run-list.txt by default -- run explicitly: ./bin/tetron-testsuite veilid-smoke
#
# UPDATED 2026-09-14 for VEILID-017..019 (tetron/spec/core.py): tetron's
# own veilid-transport crate no longer embeds a Veilid node -- it is a
# thin client to an external `tetron-veilid` companion daemon (a separate
# addon repo, ~/code/tetron-veilid), the same shape --tor already has to a
# local Tor daemon. This test now installs a real tetron-veilid instance
# (the actual released binary, fetched from GitHub the same way a real
# user's install would) on each node *before* tetron itself ever runs
# --veilid -- without it, `tetron create/join --veilid` still succeeds
# (the roster/CLI plumbing doesn't require the daemon to be reachable),
# but the custom transport itself never carries any traffic, since
# there is nothing at 127.0.0.1:5959 to connect to.
#
# Both nodes' Veilid transport only starts on the *second* daemon boot
# for a given node (the shared endpoint's custom transports are fixed at
# process startup, before --veilid has even reached config on the first
# create/join against an already-running daemon) -- unaffected by the
# external-daemon rewrite, since this is tetron's own startup sequencing,
# not veilid-transport's internals. Each `tetron restart` below is not
# incidental cleanup, it is the step that actually starts Veilid.
#
# Unlike the pre-VEILID-017 embedded design, tetron-veilid itself is never
# restarted here, only tetron -- so unlike the old design's "every restart
# is a brand-new Veilid identity" behavior (VEILID-019's own docstring:
# "a fresh tetron-veilid process is a fresh Veilid identity"), each node's
# Veilid identity should now stay stable across tetron's own restarts,
# since the daemon that owns that identity never itself restarts. This
# test does not yet rely on that (keeps the original conservative
# multi-restart structure and settle windows below) -- worth revisiting
# once this is confirmed reliable, since it may mean the timing margins
# here are now more generous than actually needed.
#
# Asserts a Veilid PATH CANDIDATE with real activity appears in paths[],
# not that conn_type itself becomes "Veilid": these two VMs share a LAN,
# so Direct is always reachable too, and tetron's own choose_path_index
# (daemon/mesh/select.rs) deliberately ranks Direct > Relay > Tor > Veilid
# -- Direct will always win the SELECTED slot here, correctly, by design.
# A dedicated Veilid-only topology (isolating direct+relay so Veilid is
# the only viable path) is what it would take to see conn_type itself
# become "Veilid" live; not attempted by this test.
#
# Neither node's embedded Veilid identity is persisted across a restart
# (a separate, known limitation), so the two restarts above each race a
# brand-new identity against the connection re-forming -- the hardest
# timing this mechanism ever faces, not the steady-state case a real,
# long-running node settles into once its identity is known and
# published. A third restart, of node1 (the coordinator) only, checks
# that steady-state case with no propagation race left to lose: node1's
# restore path reloads its roster from the already-published signed
# blob, which by then already has node2's still-valid `veilid_node_id`
# from the settle after node2's own restart.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source=../lib/topology.sh
source "$ROOT/lib/topology.sh"

require_cmd jq ssh scp

: "${TESTSUITE_TETRON_BINARY:=$ROOT/../tetron/target/release/tetron}"
: "${TESTSUITE_PHYSICAL_HOST:=}"
# Own-identity resolution + full public-network attach (both backgrounded,
# non-blocking as of the VEILID-005 fix -- see spec/core.py) has taken
# 2+ minutes in VM testing; restart, then poll status until responsive
# (fast now -- the daemon no longer blocks its own startup on this), then
# wait this much longer for identity/attach/admission/reconverge to land.
: "${TESTSUITE_VEILID_SETTLE_SECS:=240}"
# Settle window for the third, node1-only restart (VEILID-012 follow-up
# check). Shorter than the main settle above: this dial has no new
# identity to propagate (node2's is already published), so it only needs
# to cover reconnect + reconverge, not a fresh Veilid attach + gossip
# round trip on the far side too.
#
# 240s, not 120s: VEILID-016 (tetron/spec/core.py) found live that Veilid
# path *validation* itself -- not just identity propagation -- can
# legitimately take 50+ seconds in the worst case (DHT route resolution
# to the peer, independent of this node's own attach completing), and a
# retry after a lost ping needs a similar window of its own. A 120s
# window sometimes ended mid-retry with the path still pending rather
# than validated -- a test-timing false negative, not a product defect;
# confirmed by re-running the same scenario at 240s, 5/5 passed.
: "${TESTSUITE_VEILID_RESETTLE_SECS:=240}"
# Sibling addon repo -- templates/ referenced directly (same cross-repo
# path convention tetron-relay already uses for ../tetron/Cargo.lock).
# Not the tetron-veilid CLI's own bin/tetron-veilid: that tool's SSH
# transport assumes a plain "user@host" hosts.conf target, which doesn't
# fit vagrant's own dynamic per-run port/identity -- reimplemented inline
# here with vm_run/vm_upload instead, the same pattern already proven in
# tetron-veilid/DO-NOT-COMMIT/verify-e2e.sh.
: "${TESTSUITE_TETRON_VEILID_REPO:=$ROOT/../tetron-veilid}"

RUN_ID="veilid-smoke-$$"
BROUGHT_UP=0

cleanup() {
	[[ $BROUGHT_UP -eq 1 ]] && topology_down "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID"
}
trap cleanup EXIT

# remote_exec_b64 <node> <script-text> -- runs a multi-line/quoted script on
# a VM via vm_run. Needed because a plain command string passed through
# vm_run has to survive vagrant ssh's own `-c "$*"` layer intact --
# confirmed live in earlier Veilid spike work that embedded double quotes
# get corrupted/word-split there. Base64 has no shell metacharacters, so
# it survives unmodified (same fix used in
# tetron/DO-NOT-COMMIT/veilid-spike/*.sh and tetron-veilid/DO-NOT-COMMIT/
# verify-e2e.sh).
remote_exec_b64() {
	local node="$1" script="$2" b64
	b64="$(printf '%s' "$script" | base64 -w0)"
	vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" "$node" "echo $b64 | base64 -d | bash"
}

# install_tetron_veilid_on <node> -- installs the real, released
# tetron-veilid binary (fetched from GitHub, the same way an actual user's
# install would work) as a loopback-only systemd companion, using
# tetron-veilid's own real config/unit templates. Idempotent: safe to call
# on an already-provisioned node.
install_tetron_veilid_on() {
	local node="$1"
	log_info "installing tetron-veilid companion daemon on $node"

	local arch
	arch="$(vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" "$node" "uname -m" | tr -d '[:space:]')"
	case "$arch" in
	x86_64) arch="x86_64" ;;
	aarch64 | arm64) arch="aarch64" ;;
	*) fatal "veilid-smoke: unsupported architecture '$arch' on $node" ;;
	esac

	remote_exec_b64 "$node" "
		set -e
		api_url='https://api.github.com/repos/tetronos/tetron-veilid/releases/latest'
		release_json=\$(curl -fsSL \"\$api_url\")
		asset_url=\$(echo \"\$release_json\" | grep -o '\"browser_download_url\": *\"[^\"]*tetron-veilid-server-linux-${arch}-[^\"]*\\.tar\\.gz\"' | head -n1 | sed 's/.*\"\\(https[^\"]*\\)\"/\\1/')
		[ -n \"\$asset_url\" ] || { echo 'no matching tetron-veilid release asset found for linux-${arch}' >&2; exit 1; }
		sha_url=\"\${asset_url}.sha256\"
		tmpdir=\$(mktemp -d)
		curl -fsSL \"\$asset_url\" -o \"\$tmpdir/asset.tar.gz\"
		if curl -fsSL \"\$sha_url\" -o \"\$tmpdir/asset.tar.gz.sha256\" 2>/dev/null; then
			( cd \"\$tmpdir\" && sed 's/tetron-veilid-server.*\\.tar\\.gz/asset.tar.gz/' asset.tar.gz.sha256 | sha256sum -c - ) \\
				|| { echo 'tetron-veilid checksum verification failed' >&2; exit 1; }
		fi
		tar -xzf \"\$tmpdir/asset.tar.gz\" -C \"\$tmpdir\"
		[ -x \"\$tmpdir/tetron-veilid-server\" ] || { echo 'tetron-veilid-server binary not found in release tarball' >&2; exit 1; }
		sudo id tetron-veilid >/dev/null 2>&1 || sudo useradd --system --no-create-home --shell /usr/sbin/nologin tetron-veilid
		sudo install -d -o root -g tetron-veilid -m 0750 /etc/tetron-veilid
		sudo install -d -o tetron-veilid -g tetron-veilid -m 0750 /var/lib/tetron-veilid
		sudo install -m 0755 \"\$tmpdir/tetron-veilid-server\" /usr/local/bin/tetron-veilid-server
		rm -rf \"\$tmpdir\"
	" || fatal "veilid-smoke: tetron-veilid binary install failed on $node"

	local conf_tmpl="$TESTSUITE_TETRON_VEILID_REPO/templates/veilid-server.conf.tmpl"
	local unit_tmpl="$TESTSUITE_TETRON_VEILID_REPO/templates/tetron-veilid.service.tmpl"
	[[ -f "$conf_tmpl" && -f "$unit_tmpl" ]] || fatal "veilid-smoke: tetron-veilid templates not found under $TESTSUITE_TETRON_VEILID_REPO/templates -- set TESTSUITE_TETRON_VEILID_REPO if it's checked out elsewhere"

	local rendered_conf
	rendered_conf="$(mktemp)"
	sed "s|__LISTEN_ADDRESS__|127.0.0.1:5959|g" "$conf_tmpl" >"$rendered_conf"
	vm_upload "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" "$node" "$rendered_conf" "/tmp/veilid-server.conf" || fatal "veilid-smoke: config upload failed on $node"
	rm -f "$rendered_conf"
	vm_upload "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" "$node" "$unit_tmpl" "/tmp/tetron-veilid.service" || fatal "veilid-smoke: unit upload failed on $node"

	remote_exec_b64 "$node" "
		set -e
		sudo install -o root -g tetron-veilid -m 0640 /tmp/veilid-server.conf /etc/tetron-veilid/veilid-server.conf
		sudo install -m 0644 /tmp/tetron-veilid.service /etc/systemd/system/tetron-veilid.service
		sudo systemctl daemon-reload
		sudo systemctl enable --now tetron-veilid.service
		rm -f /tmp/veilid-server.conf /tmp/tetron-veilid.service
	" || fatal "veilid-smoke: tetron-veilid config/service install failed on $node"

	# Loopback-only client_api (VEILID-017's own design) means we can't
	# check port 5959 from the controller -- confirm the service is
	# actually running instead, the failure mode that would otherwise
	# surface confusingly later as "no Veilid path candidate at all".
	remote_exec_b64 "$node" "sudo systemctl is-active --quiet tetron-veilid.service" \
		|| fatal "veilid-smoke: tetron-veilid.service is not active on $node after install -- check 'sudo journalctl -u tetron-veilid' there"
	log_info "tetron-veilid is up on $node"
}

# wait_daemon_responsive <node> -- poll until `tetron status --json` succeeds
# again after a restart (proxy for "the daemon rebound and is answering IPC",
# not for "Veilid finished attaching" -- callers still sleep afterward for that).
wait_daemon_responsive() {
	local node="$1" tries=0
	while ((tries < 30)); do
		if vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" "$node" "tetron status --json" >/dev/null 2>&1; then
			return 0
		fi
		sleep 2
		((tries++))
	done
	return 1
}

main() {
	if [[ ! -f "$TESTSUITE_TETRON_BINARY" ]]; then
		log_warn "veilid-smoke: no tetron binary at $TESTSUITE_TETRON_BINARY (build one with 'cargo build --release --features veilid' in the tetron repo, or set TESTSUITE_TETRON_BINARY) -- skipping"
		exit "$TESTSUITE_SKIP_CODE"
	fi
	if [[ ! -f "$TESTSUITE_TETRON_VEILID_REPO/templates/veilid-server.conf.tmpl" ]]; then
		log_warn "veilid-smoke: tetron-veilid repo not found at $TESTSUITE_TETRON_VEILID_REPO (clone it as a sibling of tetron-testsuite, or set TESTSUITE_TETRON_VEILID_REPO) -- skipping"
		exit "$TESTSUITE_SKIP_CODE"
	fi

	load_hosts_conf "$ROOT/hosts.conf"
	if [[ -z "$TESTSUITE_PHYSICAL_HOST" ]]; then
		TESTSUITE_PHYSICAL_HOST="$(printf '%s\n' "${!TESTSUITE_HOSTS[@]}" | sort | head -n1)"
	fi
	log_info "using physical host: $TESTSUITE_PHYSICAL_HOST"

	topology_up "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" 2 || fatal "veilid-smoke: topology_up failed -- VMs never came up, no point running checks against them"
	BROUGHT_UP=1

	local node
	for node in node1 node2; do
		vm_upload "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" "$node" "$TESTSUITE_TETRON_BINARY" "/tmp/tetron" || fatal "veilid-smoke: vm_upload failed on $node"
		vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" "$node" "sudo install -m 0755 /tmp/tetron /usr/local/bin/tetron && sudo tetron install" || fatal "veilid-smoke: install failed on $node"
		# Must be up before tetron ever restarts with --veilid -- without
		# it, create/join --veilid still succeeds (roster/CLI plumbing
		# doesn't require the daemon reachable) but the custom transport
		# never carries traffic, since nothing answers 127.0.0.1:5959.
		install_tetron_veilid_on "$node"
	done

	local create_out invite
	create_out="$(vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 "sudo tetron create --network-name veilidtest --hostname node1 --veilid")" || fatal "veilid-smoke: 'tetron create --veilid' failed on node1"
	invite="$(echo "$create_out" | grep -oE '[1-9A-HJ-NP-Za-km-z]{40,}' | tail -n1)"
	if [[ -z "$invite" ]]; then
		log_fail "veilid-smoke: could not find an invite code in 'tetron create' output:"
		echo "$create_out" >&2
		exit 1
	fi

	log_info "restarting node1 so its Veilid transport actually starts (VEILID-004 self-heals its roster entry on this boot)"
	vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 "sudo tetron restart" || fatal "veilid-smoke: restart failed on node1"
	wait_daemon_responsive node1 || fatal "veilid-smoke: node1 daemon did not come back up after restart"
	log_info "waiting up to ${TESTSUITE_VEILID_SETTLE_SECS}s for node1's Veilid attach"
	sleep "$TESTSUITE_VEILID_SETTLE_SECS"

	vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node2 "sudo tetron join $invite --hostname node2 --veilid" || fatal "veilid-smoke: 'tetron join --veilid' failed on node2"

	log_info "restarting node2 so its Veilid transport actually starts (its reconnect MeshHello carries the real veilid_node_id, VEILID-003)"
	vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node2 "sudo tetron restart" || fatal "veilid-smoke: restart failed on node2"
	wait_daemon_responsive node2 || fatal "veilid-smoke: node2 daemon did not come back up after restart"
	log_info "waiting up to ${TESTSUITE_VEILID_SETTLE_SECS}s for node2's Veilid attach + reconnect + admission propagation"
	sleep "$TESTSUITE_VEILID_SETTLE_SECS"

	# VEILID-007/012 follow-up: this test's own restarts above race a
	# *newly-published* identity against the connection re-forming even
	# though the tetron-veilid daemon backing that identity is not itself
	# restarted (see the file header's note on VEILID-017..019) -- the
	# roster still has to propagate the (now-stable) veilid_node_id
	# through a fresh join/reconnect regardless, so this remains the
	# hardest timing this mechanism faces, not the steady-state case. Once
	# an identity is learned and published, though, it stays valid for the
	# rest of that process's life -- so a *second* restart of the
	# coordinator (node1) is a clean, confound-free check of the real,
	# permanent behavior: node1's restore path (`dial_all_members`)
	# reloads its roster from the already-published signed blob, which
	# already has node2's still-valid `veilid_node_id` from the settle
	# above, before it ever dials -- no new propagation to race against.
	# If the Veilid candidate still doesn't show up here, the gap is
	# real, not a timing artifact of this test's own two cold starts.
	log_info "restarting node1 again (coordinator only) -- node2's identity is unchanged and already published, so this dial has no propagation race left to lose"
	vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 "sudo tetron restart" || fatal "veilid-smoke: second restart failed on node1"
	wait_daemon_responsive node1 || fatal "veilid-smoke: node1 daemon did not come back up after second restart"
	log_info "waiting up to ${TESTSUITE_VEILID_RESETTLE_SECS}s for node1's reconnect to node2"
	sleep "$TESTSUITE_VEILID_RESETTLE_SECS"

	# check_veilid_path_activity <node-label> <status-json> -- looks for a
	# Veilid entry in paths[] with real received activity (has_activity),
	# not just an attempted-but-unvalidated candidate. This is the actual
	# end-to-end proof the mechanism works: real traffic reached a peer
	# over the custom transport. Whether it's the SELECTED conn_type is a
	# separate question this same-LAN topology can't test -- see the file
	# header comment.
	check_veilid_path_activity() {
		local label="$1" status_json="$2"
		local peer_hostname conn_type has_veilid_activity
		peer_hostname="$(json_get '.networks[0].peers[0].hostname // empty' "$status_json")"
		conn_type="$(json_get '.networks[0].peers[0].connection.conn_type // "None"' "$status_json")"
		has_veilid_activity="$(json_get '[.networks[0].peers[0].connection.paths[]? // empty | select(.conn_type == "Veilid" and .has_activity == true)] | length > 0' "$status_json")"
		log_info "$label sees peer '$peer_hostname', selected conn_type=$conn_type, veilid path with activity=$has_veilid_activity"
		if [[ "$peer_hostname" != "node1" && "$peer_hostname" != "node2" ]]; then
			log_fail "veilid-smoke: $label does not see the other node as a member at all"
			echo "$status_json" >&2
			return 1
		fi
		if [[ "$has_veilid_activity" != "true" ]]; then
			log_fail "veilid-smoke: $label has no Veilid path candidate with real activity -- roster/dial-path wiring did not actually route traffic through the custom transport"
			echo "$status_json" >&2
			return 1
		fi
		log_pass "veilid-smoke: $label carried real traffic over a Veilid path candidate"
		return 0
	}

	local status_json
	status_json="$(vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 "tetron status --json")"
	check_veilid_path_activity "node1" "$status_json" || exit 1

	status_json="$(vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node2 "tetron status --json")"
	check_veilid_path_activity "node2" "$status_json" || exit 1
}

main
