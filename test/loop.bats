#!/usr/bin/env bats

# bin/loop against a fake curl: inserts are captured to a file, queries answer
# from $FAKE_QUERY (empty file = no record), FAKE_CURL_FAIL=1 fails every call.
setup() {
	LOOP="${BATS_TEST_DIRNAME}/../bin/loop"
	mkdir -p "$BATS_TEST_TMPDIR/bin"
	cat >"$BATS_TEST_TMPDIR/bin/curl" <<'EOF'
#!/usr/bin/env bash
[ "${FAKE_CURL_FAIL:-}" = 1 ] && exit 6
case "$*" in
*/insert/jsonline*)
	cat >>"$FAKE_INSERTS"
	printf '%s' "${FAKE_INSERT_CODE:-200}"
	;;
*/select/logsql/query*rec:=*)
	# The read-back of a record just written: answer with that record.
	if [ -n "${FAKE_READBACK:-}" ]; then printf '%s' "$FAKE_READBACK"; elif [ -s "$FAKE_QUERY" ]; then tail -n 1 "$FAKE_INSERTS"; fi
	printf '\n%s' "${FAKE_QUERY_CODE:-200}"
	;;
*/select/logsql/query*)
	cat "$FAKE_QUERY"
	printf '\n%s' "${FAKE_QUERY_CODE:-200}"
	;;
esac
EOF
	chmod +x "$BATS_TEST_TMPDIR/bin/curl"
	export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
	export FAKE_INSERTS="$BATS_TEST_TMPDIR/inserts.jsonl" FAKE_QUERY="$BATS_TEST_TMPDIR/query.out"
	export LOOPS_VLOGS_URL="https://logs.example.test" LOOPS_PROXY="" LOOPS_RETRY_SLEEP=0
	export LOOPS_STATE_DIR="$BATS_TEST_TMPDIR/state"
	unset CLAUDE_CODE_REMOTE FAKE_CURL_FAIL FAKE_INSERT_CODE FAKE_QUERY_CODE FAKE_READBACK
	echo '{"_time":"2026-01-01T00:00:00Z","event":"finish","outcome":"nothing","_msg":"prev","state":"{\"n\":1}"}' >"$FAKE_QUERY"
}

last_insert() { tail -n 1 "$FAKE_INSERTS"; }

@test "start records the declared sources and prints the last run with its state" {
	run "$LOOP" start demo --every 6h --sources "B, a"
	[ "$status" -eq 0 ]
	[[ "$output" == *"LAST RUN:"* ]]
	[[ "$output" == *'"n": 1'* ]]
	[ "$(last_insert | jq -r '.event + " " + .sources + " " + .max_age_s')" = "start a,b 43800" ]
}

@test "start says none when there is no earlier record" {
	: >"$FAKE_QUERY"
	run "$LOOP" start demo --every 15m --sources a
	[[ "$output" == *"LAST RUN: none"* ]]
}

@test "a failed query is unknown, never a first run" {
	FAKE_QUERY_CODE=502 run "$LOOP" start demo --every 15m --sources a
	[ "$status" -ne 0 ]
	[[ "$output" == *"LAST RUN: UNKNOWN"* ]]
	[[ "$output" != *"LAST RUN: none"* ]]
}

@test "a clean finish keeps its success outcome" {
	"$LOOP" start demo --every 1h --sources "a,b"
	run "$LOOP" finish demo --outcome nothing --covered "a,b" --summary "quiet"
	[ "$status" -eq 0 ]
	[ "$(last_insert | jq -r .outcome)" = "nothing" ]
}

@test "a blocked source turns a claimed success into partial" {
	"$LOOP" start demo --every 1h --sources "a,b"
	run "$LOOP" finish demo --outcome nothing --covered a --blocked "b: 403" --summary "quiet"
	[ "$status" -eq 0 ]
	[ "$(last_insert | jq -r .outcome)" = "partial" ]
	[[ "$output" == *"downgraded"* ]]
}

@test "a source in neither list turns a claimed success into partial" {
	"$LOOP" start demo --every 1h --sources "a,b"
	run "$LOOP" finish demo --outcome changed --covered a --summary "found one"
	[ "$(last_insert | jq -r '.outcome + " " + .unaccounted')" = "partial b" ]
}

@test "a finish with no start cannot be a success" {
	run "$LOOP" finish demo --outcome nothing --covered a --summary "quiet"
	[ "$(last_insert | jq -r .outcome)" = "partial" ]
}

@test "failed stays failed" {
	"$LOOP" start demo --every 1h --sources a
	run "$LOOP" finish demo --outcome failed --summary "secrets unreadable"
	[ "$(last_insert | jq -r .outcome)" = "failed" ]
}

@test "an undelivered record exits 3 and says so" {
	"$LOOP" start demo --every 1h --sources a
	FAKE_INSERT_CODE=503 run "$LOOP" finish demo --outcome nothing --covered a --summary "quiet"
	[ "$status" -eq 3 ]
	[[ "$output" == *"RECORD NOT DELIVERED"* ]]
}

@test "an insert that cannot be read back is not delivered" {
	"$LOOP" start demo --every 1h --sources a
	: >"$FAKE_QUERY"
	run "$LOOP" finish demo --outcome nothing --covered a --summary "quiet"
	[ "$status" -eq 3 ]
}

@test "state must be valid JSON within the size limit" {
	"$LOOP" start demo --every 1h --sources a
	echo 'not json' >"$BATS_TEST_TMPDIR/s.json"
	run "$LOOP" finish demo --outcome nothing --covered a --summary q --state "$BATS_TEST_TMPDIR/s.json"
	[ "$status" -eq 2 ]
	: >"$BATS_TEST_TMPDIR/s.json"
	run "$LOOP" finish demo --outcome nothing --covered a --summary q --state "$BATS_TEST_TMPDIR/s.json"
	[ "$status" -eq 2 ]
	printf '{"a":1}\n{"b":2}\n' >"$BATS_TEST_TMPDIR/s.json"
	run "$LOOP" finish demo --outcome nothing --covered a --summary q --state "$BATS_TEST_TMPDIR/s.json"
	[ "$status" -eq 2 ]
	jq -n '{x: ("y" * 5000)}' >"$BATS_TEST_TMPDIR/s.json"
	run "$LOOP" finish demo --outcome nothing --covered a --summary q --state "$BATS_TEST_TMPDIR/s.json"
	[ "$status" -eq 2 ]
}

@test "rejects a bad slug, a bad outcome and a missing server" {
	run "$LOOP" start "Bad Slug" --every 1h --sources a
	[ "$status" -eq 2 ]
	run "$LOOP" finish demo --outcome ok --summary q
	[ "$status" -eq 2 ]
	LOOPS_VLOGS_URL="" run "$LOOP" last demo
	[ "$status" -eq 2 ]
}

@test "retire writes a retire event" {
	run "$LOOP" retire demo
	[ "$status" -eq 0 ]
	[ "$(last_insert | jq -r .event)" = "retire" ]
}

@test "a flag with no value exits 2 instead of hanging" {
	run timeout 5 "$LOOP" start demo --every
	[ "$status" -eq 2 ]
	run timeout 5 "$LOOP" finish demo --outcome nothing --summary
	[ "$status" -eq 2 ]
}

@test "the gateway pin uses the URL's own port" {
	cat >"$BATS_TEST_TMPDIR/bin/curl" <<'EOF2'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_ARGS"
printf '\n200'
EOF2
	export FAKE_ARGS="$BATS_TEST_TMPDIR/args"
	LOOPS_VLOGS_URL="https://logs.example.test:9443" LOOPS_GATEWAY=192.0.2.7 run "$LOOP" last demo
	grep -q -- '--resolve logs.example.test:9443:192.0.2.7' "$FAKE_ARGS"
	LOOPS_GATEWAY=192.0.2.7 run "$LOOP" last demo
	grep -q -- '--resolve logs.example.test:443:192.0.2.7' "$FAKE_ARGS"
}

@test "a 200 that is not the record does not confirm delivery" {
	"$LOOP" start demo --every 1h --sources a
	FAKE_READBACK='<html>Sign in</html>' run "$LOOP" finish demo --outcome nothing --covered a --summary q
	[ "$status" -eq 3 ]
	FAKE_READBACK='{"run":"other","event":"finish","rec":"other"}' run "$LOOP" finish demo --outcome nothing --covered a --summary q
	[ "$status" -eq 3 ]
}

@test "a last-run lookup that returns a non-record is unknown" {
	echo '<html>Sign in</html>' >"$FAKE_QUERY"
	run "$LOOP" last demo
	[ "$status" -eq 4 ]
}

@test "malformed durations are refused" {
	run "$LOOP" start demo --every 1h --max-age 1h30s --sources a
	[ "$status" -eq 2 ]
	run "$LOOP" start demo --every h --sources a
	[ "$status" -eq 2 ]
	run "$LOOP" start demo --every 08h --sources a
	[ "$status" -eq 2 ]
}

@test "start fails when its local state cannot be saved" {
	mkdir -p "$LOOPS_STATE_DIR/demo.json"
	run "$LOOP" start demo --every 1h --sources a
	[ "$status" -eq 2 ]
}
