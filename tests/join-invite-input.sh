#!/usr/bin/env bash
# meta:id join-invite-input
# meta:description tetron join - (stdin) and --invite-file admit members; bad input fails without echoing the invite (JOIN-INPUT-001/002)
# meta:nodes 3
# meta:networks 1
#
# node1 creates a network. node2 joins by piping the invite into
# `tetron join -`. node3 joins with `--invite-file` from a 0600 root file,
# the way the TetronOS first-boot unit does, and the file must still exist
# afterwards (tetron never deletes it). node1 must then see node2 and node3.
# Negative checks on node3: a corrupted invite on stdin and an empty file
# both fail, and the error output never contains the invite text.
# The invite still crosses the vm_run command line here (printf); this test
# proves the tetron side, not the harness.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source=../lib/topology.sh
source "$ROOT/lib/topology.sh"

require_cmd jq ssh scp

: "${TESTSUITE_TETRON_BINARY:=$ROOT/../tetron/target/release/tetron}"
: "${TESTSUITE_PHYSICAL_HOST:=}"

RUN_ID="join-invite-input-$$"
BROUGHT_UP=0
PENDING=/etc/tetron/pending-invite

cleanup() {
	[[ $BROUGHT_UP -eq 1 ]] && topology_down "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID"
}
trap cleanup EXIT

run() { vm_run "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" "$@"; }

main() {
	if [[ ! -f "$TESTSUITE_TETRON_BINARY" ]]; then
		log_warn "join-invite-input: no tetron binary at $TESTSUITE_TETRON_BINARY (build one with 'cargo build --release' in the tetron repo, or set TESTSUITE_TETRON_BINARY) -- skipping"
		exit "$TESTSUITE_SKIP_CODE"
	fi
	if ! "$TESTSUITE_TETRON_BINARY" join --help 2>/dev/null | grep -q -- '--invite-file'; then
		log_warn "join-invite-input: tetron binary predates JOIN-INPUT-001/002 (no --invite-file) -- skipping"
		exit "$TESTSUITE_SKIP_CODE"
	fi

	load_hosts_conf "$ROOT/hosts.conf"
	if [[ -z "$TESTSUITE_PHYSICAL_HOST" ]]; then
		TESTSUITE_PHYSICAL_HOST="$(printf '%s\n' "${!TESTSUITE_HOSTS[@]}" | sort | head -n1)"
	fi
	log_info "using physical host: $TESTSUITE_PHYSICAL_HOST"

	topology_up "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" 3 || fatal "join-invite-input: topology_up failed"
	BROUGHT_UP=1

	local node
	for node in node1 node2 node3; do
		vm_upload "$TESTSUITE_PHYSICAL_HOST" "$RUN_ID" "$node" "$TESTSUITE_TETRON_BINARY" "/tmp/tetron" || fatal "join-invite-input: vm_upload failed on $node"
		run "$node" "sudo install -m 0755 /tmp/tetron /usr/local/bin/tetron && sudo tetron install" || fatal "join-invite-input: install failed on $node"
	done

	local create_out invite1 invite2
	create_out="$(run node1 "sudo tetron create --network-name inputtest --hostname node1")" || fatal "join-invite-input: 'tetron create' failed on node1"
	invite1="$(echo "$create_out" | grep -oE '[1-9A-HJ-NP-Za-km-z]{40,}' | tail -n1)"
	[[ -n "$invite1" ]] || { log_fail "join-invite-input: no invite in 'tetron create' output"; echo "$create_out" >&2; exit 1; }
	invite2="$(json_get '.invite_key // empty' "$(run node1 "sudo tetron invite inputtest create --json")")"
	[[ -n "$invite2" ]] || fatal "join-invite-input: 'tetron invite create --json' gave no invite_key"

	# Negative 1: corrupted invite on stdin fails and does not echo the input.
	local bad out
	bad="${invite2%?}$([[ "${invite2: -1}" == "2" ]] && echo 3 || echo 2)"
	if out="$(run node3 "printf '%s\n' '$bad' | sudo tetron join - --hostname node3" 2>&1)"; then
		log_fail "join-invite-input: corrupted invite on stdin was accepted"; echo "$out" >&2; exit 1
	fi
	if grep -qF -- "$bad" <<<"$out"; then
		log_fail "join-invite-input: error output echoes the invite text"; exit 1
	fi
	log_pass "join-invite-input: corrupted invite on stdin rejected without echoing it"

	# Negative 2: empty invite file fails and names the path.
	run node3 "sudo install -m 0600 /dev/null $PENDING" || fatal "join-invite-input: could not write empty $PENDING"
	if out="$(run node3 "sudo tetron join --invite-file $PENDING --hostname node3" 2>&1)"; then
		log_fail "join-invite-input: empty invite file was accepted"; exit 1
	fi
	grep -qF -- "$PENDING" <<<"$out" || { log_fail "join-invite-input: empty-file error does not name the path"; echo "$out" >&2; exit 1; }
	log_pass "join-invite-input: empty invite file rejected, error names the path"

	# node2: stdin.
	run node2 "printf '%s\n' '$invite1' | sudo tetron join - --hostname node2" || fatal "join-invite-input: 'tetron join -' failed on node2"
	log_pass "join-invite-input: node2 joined with 'tetron join -'"

	# node3: --invite-file from a 0600 root file; the file must survive.
	run node3 "printf '%s\n' '$invite2' | sudo install -m 0600 /dev/stdin $PENDING" || fatal "join-invite-input: could not write $PENDING"
	run node3 "sudo tetron join --invite-file $PENDING --hostname node3" || fatal "join-invite-input: 'tetron join --invite-file' failed on node3"
	run node3 "sudo test -s $PENDING" || { log_fail "join-invite-input: tetron removed or emptied $PENDING"; exit 1; }
	log_pass "join-invite-input: node3 joined with --invite-file, file left in place"

	log_info "waiting for admission to propagate"
	sleep 8

	local status_json member_count hosts
	status_json="$(run node1 "tetron status --json")"
	member_count="$(json_get '.networks[0].member_count // 0' "$status_json")"
	hosts="$(json_get '[.networks[0].peers[].hostname] | sort | join(",")' "$status_json")"
	if [[ "$member_count" != "2" || "$hosts" != "node2,node3" ]]; then
		log_fail "join-invite-input: expected node1 to see node2,node3, got member_count=$member_count hosts=$hosts"
		echo "$status_json" >&2
		exit 1
	fi
	log_pass "join-invite-input: node1 sees node2 and node3 as members"
}

main
