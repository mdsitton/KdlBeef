#!/bin/bash
# PreserveStyle round trip: every valid input of the official suite (and the HTML-standard benchmark
# documents), read with KdlMetadataMode.PreserveStyle and written back, must equal the input byte for
# byte. Read from memory and through a Stream with a 16-byte buffer.
# Usage: ./test-roundtrip.sh            (Debug binary)
#        BIN=./build/Release_Linux64/KdlTester/KdlTester ./test-roundtrip.sh
# Details of each failure go to test-roundtrip.log. Fetch the suite first with tests/fetch-spec.sh.

BIN="${BIN:-./build/Debug_Linux64/KdlTester/KdlTester}"
SUITE="${SUITE:-tests/kdl-spec/tests/test_cases}"
BENCHMARKS="tests/kdl-spec/tests/benchmarks"
LOGFILE="test-roundtrip.log"

if [ ! -x "$BIN" ]; then
	echo "ERROR: $BIN not found or not executable. Build first with: beefbuild"
	exit 1
fi
if [ ! -d "$SUITE/input" ]; then
	echo "ERROR: $SUITE/input not found. Fetch the suite with: tests/fetch-spec.sh"
	exit 1
fi

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
echo "=== PreserveStyle round-trip log ($(date), $BIN) ===" > "$LOGFILE"

failed=0
for mode in memory stream; do
	flags="-preserve"
	[ "$mode" = stream ] && flags="-preserve -stream 16"
	pass=0
	total=0
	for input in "$SUITE"/input/*.kdl "$BENCHMARKS"/*.kdl; do
		[[ "$input" == *_fail.kdl ]] && continue
		[ -f "$input" ] || continue
		total=$((total + 1))
		timeout 60 "$BIN" $flags "$input" > "$tmpdir/out" 2> "$tmpdir/err"
		status=$?
		if [ $status -eq 0 ] && cmp -s "$tmpdir/out" "$input"; then
			pass=$((pass + 1))
		else
			{
				echo "--- $(basename "$input") [$mode] (exit $status) ---"
				cat "$tmpdir/err"
				cmp "$tmpdir/out" "$input" 2>&1 | head -1
				echo ""
			} >> "$LOGFILE"
		fi
	done
	echo "[$mode] $pass/$total round-trip byte for byte"
	[ $pass -ne $total ] && failed=1
done

if [ $failed -ne 0 ]; then
	echo "FAIL: see $LOGFILE"
	exit 1
fi
echo "PASS"
