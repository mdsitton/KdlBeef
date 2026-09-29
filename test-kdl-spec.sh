#!/bin/bash
# Official KDL test suite: every tests/kdl-spec/tests/test_cases/input/*.kdl through KdlTester.
# Usage: ./test-kdl-spec.sh            (Debug binary)
#        BIN=./build/Release_Linux64/KdlTester/KdlTester ./test-kdl-spec.sh
#
# A `*_fail.kdl` case must be rejected (exit 1) with the error message in tests/errors/<name>.err
# (golden files: `line:column: message`; UPDATE_GOLDEN=1 rewrites them from the current output, then
# review the diff). Every other case must be accepted and its canonical output must equal
# expected_kdl/<name> byte for byte. A crash (exit other than 0 or 1) or a timeout
# is always a failure. Details of each failure go to test-kdl-spec.log.
#
# Every case runs three times: through a KdlDocument (the default), straight from the reader's events
# (KdlTester -events), and through a document read from a Stream with a 16-byte buffer (KdlTester
# -stream 16). MODES="document" (or events, stream) runs some.
#
# Fetch the suite first with tests/fetch-spec.sh.

BIN="${BIN:-./build/Debug_Linux64/KdlTester/KdlTester}"
SUITE="${SUITE:-tests/kdl-spec/tests/test_cases}"
GOLDEN="tests/errors"
LOGFILE="test-kdl-spec.log"

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

{
	echo "=== KDL spec suite log ==="
	echo "Date: $(date)"
	echo "Binary: $BIN"
	echo "Suite: $SUITE"
	echo ""
} > "$LOGFILE"

failed=0
for mode in ${MODES:-document events stream}; do
flag=""
[ "$mode" = events ] && flag="-events"
# A 16-byte buffer: refills land inside tokens, strings, escapes, CRLFs and multi-byte characters
[ "$mode" = stream ] && flag="-stream 16"
valid_pass=0
valid_total=0
fail_pass=0
fail_total=0
crashes=0

for input in "$SUITE"/input/*.kdl; do
	file=$(basename "$input")
	name="$file [$mode]"
	timeout 10 "$BIN" $flag "$input" > "$tmpdir/out" 2> "$tmpdir/err"
	status=$?
	if [ $status -gt 1 ]; then
		crashes=$((crashes + 1))
		{
			echo "--- CRASH ($status): $name ---"
			cat "$tmpdir/err"
			echo ""
		} >> "$LOGFILE"
	fi

	if [[ "$file" == *_fail.kdl ]]; then
		fail_total=$((fail_total + 1))
		golden="$GOLDEN/${file%.kdl}.err"
		if [ $status -eq 1 ]; then
			if [ -n "${UPDATE_GOLDEN:-}" ]; then
				cp "$tmpdir/err" "$golden"
				fail_pass=$((fail_pass + 1))
			elif cmp -s "$tmpdir/err" "$golden"; then
				fail_pass=$((fail_pass + 1))
			else
				{
					echo "--- ERROR MESSAGE CHANGED: $name ---"
					echo "Expected ($golden):"
					cat "$golden" 2>/dev/null || echo "(missing)"
					echo "Actual:"
					cat "$tmpdir/err"
					echo ""
				} >> "$LOGFILE"
			fi
		elif [ $status -eq 0 ]; then
			{
				echo "--- ACCEPTED INVALID: $name ---"
				cat "$input"
				echo ""
				echo "Output:"
				cat "$tmpdir/out"
				echo ""
			} >> "$LOGFILE"
		fi
		continue
	fi

	valid_total=$((valid_total + 1))
	expected="$SUITE/expected_kdl/$file"
	if [ $status -eq 1 ]; then
		{
			echo "--- REJECTED VALID: $name ---"
			cat "$input"
			echo ""
			echo "Error: $(cat "$tmpdir/err")"
			echo ""
		} >> "$LOGFILE"
	elif [ $status -eq 0 ]; then
		if cmp -s "$tmpdir/out" "$expected"; then
			valid_pass=$((valid_pass + 1))
		else
			{
				echo "--- MISMATCH: $name ---"
				echo "Input:"
				cat "$input"
				echo ""
				echo "Expected:"
				cat "$expected"
				echo "Actual:"
				cat "$tmpdir/out"
				echo ""
			} >> "$LOGFILE"
		fi
	fi
done

echo "[$mode] valid cases:   $valid_pass/$valid_total match expected_kdl"
echo "[$mode] invalid cases: $fail_pass/$fail_total rejected with the golden message"
if [ $crashes -gt 0 ]; then
	echo "[$mode] crashes:       $crashes"
fi
if [ $valid_pass -ne $valid_total ] || [ $fail_pass -ne $fail_total ] || [ $crashes -gt 0 ]; then
	failed=1
fi
done

if [ $failed -ne 0 ]; then
	echo "FAIL: see $LOGFILE"
	exit 1
fi
echo "PASS"
