#!/usr/bin/env bash
# meta:id presence-gated-redial
# meta:description PARTITION-REDIAL-001/MANUAL-REDIAL-001: a coordinator parks (stops dialing) a member unseen longer than reconnect-presence.max-stale instead of churning iroh discovery against it forever; an online member is unaffected; `tetron reconnect` forces a one-shot redial of a parked peer
# meta:nodes 3
# meta:networks 1
#
# Reproduces the dead-majority cost behind PARTITION-REDIAL-001
# (tetron/DO-NOT-COMMIT/PLAN_tetron_lazy-resilient-peer-connectivity_
# 2026-10-08.md, and the aorus field evidence in
# project_dead_peer_handling_lazy_conn). Both reconnect loops
# (join::spawn_reconnect_loop, coordinator::spawn_coordinator_dial_retry)
# dial an offline peer with NO per-call timeout, so a dial to a dead peer
# pends on iroh's long internal discovery/handshake timeout -- on a roster
# whose majority is offline this is a continuous ~1 Hz-per-peer churn that
# never accomplishes anything. PARTITION-REDIAL-001 presence-gates each dial:
# a peer whose roster last_seen is older than reconnect-presence.max-stale is
# *parked* (the dial is skipped) so no connect() is left pending. It parks,
# never un-members -- the parked peer is still reached by the inbound path,
# the peer address cache (CACHE-001), outbound traffic, or MANUAL-REDIAL-001's
# `tetron reconnect` one-shot full dial.
#
# Topology (3 nodes, 1 network):
#   node1  coordinator / node under test
#   node2  member that STAYS online for the whole test (control: an online
#          peer must never be parked, and must stay connected)
#   node3  member that is stopped mid-session (treatment: once its last_seen
#          ages past max-stale, node1 must park its redial)
#
# Assertions, all against node1's debug file log:
#   (a) node1 logs "parking coordinator redial" against node3's mesh IP --
#       the presence gate engaged and the dial to the offline member is being
#       skipped (the churn is stopped). On a pre-gate binary this line does
#       not exist at all; the gate's whole job is to produce it.
#   (b) node1 NEVER parks node2 (no parking line carries node2's IP) and node2
#       is still connected in node1's status at the end -- the gate is scoped
#       to disconnected peers and does not touch a live connection.
#   (c) after `tetron reconnect` on node1, a fresh dial_all_members attempt is
#       logged against the still-offline node3 ("dial timed out"/"could not
#       dial member yet; reconnect loop will retry") -- MANUAL-REDIAL-001's
#       one-shot dial bypassed the park. These two lines come ONLY from
#       dial_all_members, which on the coordinator (never restarted here) runs
#       nowhere else, so their count going 0 -> >=1 is unambiguous.
#
# Timing: max-stale is set LOW (10s) on node1 before node3 is stopped, so the
# task spawned on node3's disconnect reads it (config is loaded fresh per
# reconnect task). The gate is re-checked each loop iteration after the dial
# returns, so parking engages within a dial-timeout or two of node3 going
# offline; the 120s settle below is far more than enough regardless of how
# slowly iroh resolves the first (pre-park) dial of the dead peer.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source=../lib/topology.sh
source "$ROOT/lib/topology.sh"

require_cmd jq ssh scp

: "${TESTSUITE_TETRON_BINARY:=$ROOT/../tetron/target/release/tetron}"
: "${TESTSUITE_PHYSICAL_HOST:=}"
# Presence window set on node1. Low (10s) so the gate engages promptly after
# node3 goes offline. 0 would DISABLE the gate (a CONTROL run: node3 would then
# be dialed forever and assertion (a) would correctly fail on this same binary).
: "${PRESENCE_MAX_STALE:=10}"

RUN_ID="presence-gated-redial-$$"
BROUGHT_UP=0
NODES=(node1 node2 node3)
declare -A NODE_IP

cleanup() {
	[[ $BROUGHT_UP -eq 1 ]] && topology_down "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID"
}
trap cleanup EXIT

# Count lines matching an extended-regex across node1's rolled log files.
node1_log_count() {
	local pattern="$1"
	local n
	n="$(vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 "sudo grep -ohE '$pattern' /var/log/tetron/tetron.log.* 2>/dev/null | wc -l || true")"
	# Strip any stray whitespace/newlines wc may emit through the ssh layers.
	echo "${n//[^0-9]/}"
}

main() {
	if [[ ! -f "$TESTSUITE_TETRON_BINARY" ]]; then
		log_warn "presence-gated-redial: no tetron binary at $TESTSUITE_TETRON_BINARY -- skipping"
		exit "$TESTSUITE_SKIP_CODE"
	fi

	load_hosts_conf "$ROOT/hosts.conf"
	if [[ -z "$TESTSUITE_PHYSICAL_HOST" ]]; then
		TESTSUITE_PHYSICAL_HOST="$(printf '%s\n' "${!TESTSUITE_HOSTS[@]}" | sort | head -n1)"
	fi
	log_info "using physical host: $TESTSUITE_PHYSICAL_HOST"

	topology_up "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" 3 || fatal "presence-gated-redial: topology_up failed"
	BROUGHT_UP=1

	local node
	for node in "${NODES[@]}"; do
		vm_upload "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" "$node" "$TESTSUITE_TETRON_BINARY" "/tmp/tetron" || fatal "presence-gated-redial: vm_upload failed on $node"
		vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" "$node" "sudo install -m 0755 /tmp/tetron /usr/local/bin/tetron && sudo tetron install" || fatal "presence-gated-redial: install failed on $node"
	done

	local create_out invite
	create_out="$(vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 "sudo tetron create --network-name presencetest --hostname node1")" || fatal "presence-gated-redial: 'tetron create' failed on node1"
	invite="$(echo "$create_out" | grep -oE '[1-9A-HJ-NP-Za-km-z]{40,}' | tail -n1)"
	[[ -n "$invite" ]] || fatal "presence-gated-redial: could not find an invite code in 'tetron create' output: $create_out"

	vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node2 "sudo tetron join $invite --hostname node2" || fatal "presence-gated-redial: 'tetron join' failed on node2"

	# Invites are single-use (LIVE-001/BLOB-001) -- node2 consumed the one
	# 'tetron create' auto-minted, so node3 needs its own.
	local invite2_out invite2
	invite2_out="$(vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 "sudo tetron invite presencetest create --json")" || fatal "presence-gated-redial: 'tetron invite create' failed on node1"
	invite2="$(json_get '.invite_key // empty' "$invite2_out")"
	[[ -n "$invite2" ]] || fatal "presence-gated-redial: could not find an invite_key in 'tetron invite create' output: $invite2_out"
	vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node3 "sudo tetron join $invite2 --hostname node3" || fatal "presence-gated-redial: 'tetron join' failed on node3"

	log_info "waiting for admission to propagate"
	sleep 15

	local status_json member_count
	status_json="$(vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 "tetron status --json")"
	member_count="$(json_get '.networks[0].member_count // 0' "$status_json")"
	if [[ "$member_count" != "2" ]]; then
		log_fail "presence-gated-redial: expected node1 to see 2 members (node2+node3) before the test, got member_count=$member_count"
		echo "$status_json" >&2
		exit 1
	fi
	NODE_IP[node2]="$(json_get '.networks[0].peers[] | select(.hostname=="node2") | .ip' "$status_json")"
	NODE_IP[node3]="$(json_get '.networks[0].peers[] | select(.hostname=="node3") | .ip' "$status_json")"
	[[ -n "${NODE_IP[node2]}" && -n "${NODE_IP[node3]}" ]] || fatal "presence-gated-redial: could not resolve node2/node3 mesh IPs: $status_json"
	log_pass "presence-gated-redial: node1 sees node2 (${NODE_IP[node2]}) and node3 (${NODE_IP[node3]}) as members"

	# Debug file logging (the parking + dial-attempt lines are debug, matching
	# the reconnect loop's own steady-state level; LOG-004 live-reloads this).
	vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 "sudo tetron config set log-level debug" || fatal "presence-gated-redial: could not set log-level debug on node1"
	# Set the presence window BEFORE stopping node3: the coordinator reconnect
	# task that spawns on node3's disconnect loads config fresh at task start,
	# so it must already be written when node3 drops.
	vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 "sudo tetron config set reconnect-presence.max-stale $PRESENCE_MAX_STALE" || fatal "presence-gated-redial: could not set reconnect-presence.max-stale on node1"

	# Baseline the dial_all_members attempt count on node1 (expected 0 -- the
	# coordinator never ran dial_all_members here: it created the network and
	# admitted node2/node3 inbound, and is never restarted).
	local dial_baseline
	dial_baseline="$(node1_log_count 'dial timed out; reconnect loop will retry|could not dial member yet; reconnect loop will retry')"
	log_info "presence-gated-redial: dial_all_members attempt baseline on node1 = $dial_baseline"

	log_info "stopping node3's daemon (member goes offline mid-session; left stopped the rest of the test)"
	vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node3 "sudo systemctl stop tetron" || fatal "presence-gated-redial: could not stop tetron on node3"

	# node3.last_seen is stamped at this disconnect; the gate parks it once
	# now - last_seen > max-stale (10s). The pre-park first dial may pend on
	# iroh's internal timeout, so wait generously for parking to engage.
	log_info "waiting for node1 to age node3 past max-stale and park its redial (120s)"
	sleep 120

	# (a) node1 parked node3's redial.
	local parked_node3
	parked_node3="$(vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 "sudo grep -hE 'parking coordinator redial' /var/log/tetron/tetron.log.* 2>/dev/null | grep -cE 'ip=${NODE_IP[node3]}([^0-9]|\$)' || true")"
	parked_node3="${parked_node3//[^0-9]/}"
	if [[ "${parked_node3:-0}" -lt 1 ]]; then
		log_info "presence-gated-redial: diagnostic dump -- node1 reconnect/parking lines:"
		vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 "sudo grep -iE 'parking|coordinator reconnect|reconnecting in|dormant' /var/log/tetron/tetron.log.* 2>/dev/null | tail -n 80" >&2
		log_fail "presence-gated-redial: node1 never parked node3's redial (no 'parking coordinator redial' line with ip=${NODE_IP[node3]}) -- the presence gate did not engage"
		exit 1
	fi
	log_pass "presence-gated-redial: node1 parked node3's redial ($parked_node3 line(s)) -- PARTITION-REDIAL-001 gate engaged, offline-peer dial churn stopped"

	# (b) node2 (online) was never parked, and is still connected.
	local parked_node2
	parked_node2="$(vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 "sudo grep -hE 'parking coordinator redial' /var/log/tetron/tetron.log.* 2>/dev/null | grep -cE 'ip=${NODE_IP[node2]}([^0-9]|\$)' || true")"
	parked_node2="${parked_node2//[^0-9]/}"
	if [[ "${parked_node2:-0}" -ne 0 ]]; then
		log_fail "presence-gated-redial: node1 parked the ONLINE node2 ($parked_node2 line(s) with ip=${NODE_IP[node2]}) -- the gate must never touch a live peer"
		exit 1
	fi
	status_json="$(vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 "tetron status --json")"
	local node2_connected
	node2_connected="$(json_get '.networks[0].peers[] | select(.hostname=="node2") | (.connection != null)' "$status_json")"
	if [[ "$node2_connected" != "true" ]]; then
		log_fail "presence-gated-redial: node2 (online member) is not connected in node1's status after the park window -- the gate disrupted a live peer"
		echo "$status_json" >&2
		exit 1
	fi
	log_pass "presence-gated-redial: node1 never parked node2 and node2 stayed connected -- the gate is scoped to disconnected peers"

	# (c) `tetron reconnect` forces a one-shot dial of the parked node3.
	log_info "running 'tetron reconnect' on node1 to force-dial the parked node3 (MANUAL-REDIAL-001)"
	vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 "sudo tetron reconnect" || fatal "presence-gated-redial: 'tetron reconnect' failed on node1"
	# dial_all_members bounds each dial at DIAL_TIMEOUT (10s); wait past that.
	log_info "waiting for the forced dial of the offline node3 to resolve (25s)"
	sleep 25

	local dial_after
	dial_after="$(node1_log_count 'dial timed out; reconnect loop will retry|could not dial member yet; reconnect loop will retry')"
	if [[ "${dial_after:-0}" -le "${dial_baseline:-0}" ]]; then
		log_info "presence-gated-redial: diagnostic dump -- node1 dial/reconnect lines after 'tetron reconnect':"
		vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 "sudo grep -iE 'dial|reconnect|full mesh' /var/log/tetron/tetron.log.* 2>/dev/null | tail -n 60" >&2
		log_fail "presence-gated-redial: 'tetron reconnect' did not force a fresh dial of the parked node3 (dial_all_members attempts stayed at $dial_baseline, after=$dial_after) -- MANUAL-REDIAL-001 did not bypass the park"
		exit 1
	fi
	log_pass "presence-gated-redial: 'tetron reconnect' forced a fresh dial of the parked node3 (dial_all_members attempts $dial_baseline -> $dial_after) -- MANUAL-REDIAL-001 bypassed the gate"
}

main
