#!/usr/bin/env bash
# meta:id coordinator-reconnect
# meta:description CONVERGE-012: a coordinator now actually attempts outbound redial against an unreachable member, instead of dialing once at restore and never trying again
# meta:nodes 2
# meta:networks 1
#
# Before CONVERGE-012, a coordinator's only outbound dial mechanism
# (dial_all_members) ran exactly once, at daemon/network restore; a
# member it lost mid-session was cleaned up (dead route removed) but
# never redialed, for the rest of that process's life -- see
# tetron/DO-NOT-COMMIT/oom-leak-investigation/
# FINDINGS_CoordinatorHasNoOutboundReconnectLoop_2026-08-15.md.
#
# This test isolates the specific, previously-completely-absent behavior:
# does the coordinator itself now *attempt* an outbound dial against a
# member that goes offline mid-session? It deliberately does not assert
# on which side's dial eventually "wins" the reconnection once the member
# comes back -- the member's own restart-triggered dial and the
# coordinator's CONVERGE-012 redial task both race for that, and
# attributing the win to one side specifically would need an asymmetric
# network-partition primitive this suite's topology.sh does not have yet
# (a real follow-up, not faked here). node2 is therefore left stopped for
# the whole test, never restarted -- this proves the coordinator retries
# on its own, not that it eventually wins a race.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source=../lib/topology.sh
source "$ROOT/lib/topology.sh"

require_cmd jq ssh scp

: "${TESTSUITE_TETRON_BINARY:=$ROOT/../tetron/target/release/tetron}"
: "${TESTSUITE_PHYSICAL_HOST:=}"

RUN_ID="coordinator-reconnect-$$"
BROUGHT_UP=0

cleanup() {
	[[ $BROUGHT_UP -eq 1 ]] && topology_down "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID"
}
trap cleanup EXIT

main() {
	if [[ ! -f "$TESTSUITE_TETRON_BINARY" ]]; then
		log_warn "coordinator-reconnect: no tetron binary at $TESTSUITE_TETRON_BINARY -- skipping"
		exit "$TESTSUITE_SKIP_CODE"
	fi

	load_hosts_conf "$ROOT/hosts.conf"
	if [[ -z "$TESTSUITE_PHYSICAL_HOST" ]]; then
		TESTSUITE_PHYSICAL_HOST="$(printf '%s\n' "${!TESTSUITE_HOSTS[@]}" | sort | head -n1)"
	fi
	log_info "using physical host: $TESTSUITE_PHYSICAL_HOST"

	topology_up "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" 2 || fatal "coordinator-reconnect: topology_up failed"
	BROUGHT_UP=1

	local node
	for node in node1 node2; do
		vm_upload "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" "$node" "$TESTSUITE_TETRON_BINARY" "/tmp/tetron" || fatal "coordinator-reconnect: vm_upload failed on $node"
		vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" "$node" "sudo install -m 0755 /tmp/tetron /usr/local/bin/tetron && sudo tetron install" || fatal "coordinator-reconnect: install failed on $node"
	done

	local create_out invite
	create_out="$(vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 "sudo tetron create --network-name coordreconnect --hostname node1")" || fatal "coordinator-reconnect: 'tetron create' failed on node1"
	invite="$(echo "$create_out" | grep -oE '[1-9A-HJ-NP-Za-km-z]{40,}' | tail -n1)"
	[[ -n "$invite" ]] || fatal "coordinator-reconnect: could not find an invite code"

	# Debug-level file logging: the per-attempt dial-failure line this test
	# asserts on is intentionally debug (matching the member-side reconnect
	# loop's own per-attempt log level, LOG-005's precedent) -- steady-state
	# retry noise, not an anomaly. LOG-004 live-reloads this with no restart.
	vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 "sudo tetron config set log-level debug" || fatal "coordinator-reconnect: could not set log-level debug on node1"

	vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node2 "sudo tetron join $invite --hostname node2" || fatal "coordinator-reconnect: 'tetron join' failed on node2"

	log_info "waiting for admission to propagate"
	sleep 15

	local status_json member_count
	status_json="$(vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 "tetron status --json")"
	member_count="$(json_get '.networks[0].member_count // 0' "$status_json")"
	if [[ "$member_count" != "1" ]]; then
		log_fail "coordinator-reconnect: expected node1 to see 1 member (node2) before stopping it, got member_count=$member_count"
		echo "$status_json" >&2
		exit 1
	fi
	log_pass "coordinator-reconnect: node1 (coordinator) sees node2 as a member after join"

	log_info "stopping node2's daemon (member goes offline mid-session; left stopped for the rest of this test)"
	vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node2 "sudo systemctl stop tetron" || fatal "coordinator-reconnect: could not stop tetron on node2"

	# The redial task's connect attempt is now bounded by RECONNECT_DIAL_TIMEOUT
	# (PER-DIAL-TIMEOUT-001, 10s, the same wrap dial_all_members uses), so a
	# first attempt against a now-silent peer resolves within ~10s instead of
	# pending on iroh's full internal handshake timeout. 60s still covers the
	# backoff waits plus a couple of bounded attempts with margin.
	log_info "waiting for node1 to notice the disconnect, run cleanup, and attempt at least one redial (60s)"
	sleep 60

	local cleanup_count
	cleanup_count="$(vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 "sudo grep -c 'removing dead peer' /var/log/tetron/tetron.log.* 2>/dev/null || true")"
	cleanup_count="${cleanup_count:-0}"
	if [[ "$cleanup_count" == "0" ]]; then
		log_fail "coordinator-reconnect: expected node1 to log 'removing dead peer' after node2 went offline, got none (pre-existing cleanup path may be broken, unrelated to CONVERGE-012)"
		exit 1
	fi
	log_pass "coordinator-reconnect: node1 ran its existing dead-peer cleanup ($cleanup_count line(s))"

	# A bounded dial to an offline member resolves either as a connect error
	# ("coordinator reconnect attempt failed") or, if it does not resolve within
	# RECONNECT_DIAL_TIMEOUT, as a timeout ("coordinator reconnect dial timed
	# out", PER-DIAL-TIMEOUT-001). Either line proves the coordinator attempted
	# an outbound redial on its own initiative, which is what CONVERGE-012 is
	# about; which one appears depends on how fast iroh gives up on the now-silent
	# peer, so accept both rather than asserting on one.
	local attempt_count
	attempt_count="$(vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 "sudo grep -cE 'coordinator reconnect attempt failed|coordinator reconnect dial timed out' /var/log/tetron/tetron.log.* 2>/dev/null || true")"
	attempt_count="${attempt_count:-0}"
	if [[ "$attempt_count" == "0" ]]; then
		log_info "coordinator-reconnect: diagnostic dump -- reconnect/coordinator lines:"
		vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" node1 "sudo grep -iE 'reconnect|coordinator' /var/log/tetron/tetron.log.* 2>/dev/null" >&2
		log_fail "coordinator-reconnect: expected node1 (coordinator) to log at least one outbound redial attempt (failed or timed out) against the offline member -- CONVERGE-012's redial task did not run"
		exit 1
	fi
	log_pass "coordinator-reconnect: node1 (coordinator) attempted $attempt_count outbound redial(s) against the offline member on its own initiative -- CONVERGE-012 is live"
}

main
