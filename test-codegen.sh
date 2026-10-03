#!/bin/bash
# Vendored from FormatCore tools/test-codegen.sh by tools/sync.sh: edit it there, then sync.
# A typed-mapping generator's build-time checks (XmlBeef's test-codegen.sh, generalized): every fixture
# of the fixtures file is built alone (beefbuild -define=FIXTURE_<name>) and must fail with the text its
# `// FIXTURE <name>: <text>` line gives, or build when the text is OK. (A [Test] cannot observe a build
# that stops.)
# Usage: ./test-codegen.sh [fixture names...]
#   CODEGEN_WS        the fixture workspace (default: tests/codegen)
#   CODEGEN_FIXTURES  the fixtures file (default: $CODEGEN_WS/src/Fixtures.bf)
set -uo pipefail
cd "$(dirname "$0")"
WS="${CODEGEN_WS:-tests/codegen}"
FIXTURES="${CODEGEN_FIXTURES:-$WS/src/Fixtures.bf}"
LOG=test-codegen.log
: > "$LOG"
if [ ! -f "$FIXTURES" ]; then
	echo "ERROR: $FIXTURES not found"
	exit 1
fi

mapfile -t lines < <(grep -E '^// FIXTURE [A-Za-z0-9]+: ' "$FIXTURES")
pass=0
failures=()
for line in "${lines[@]}"; do
	rest=${line#// FIXTURE }
	name=${rest%%:*}
	expect=${rest#*: }
	if [ $# -gt 0 ] && [[ ! " $* " == *" $name "* ]]; then
		continue
	fi
	output=$(beefbuild -workspace="$WS" -define="FIXTURE_$name" 2>&1)
	status=$?
	{ echo "--- $name (exit $status): expect $expect"; echo "$output"; } >> "$LOG"
	if [ "$expect" = "OK" ]; then
		if [ $status -eq 0 ]; then
			pass=$((pass + 1))
		else
			failures+=("$name (did not build)")
		fi
	elif [ $status -ne 0 ] && grep -qF -- "$expect" <<< "$output"; then
		pass=$((pass + 1))
	else
		failures+=("$name")
	fi
done
total=$((pass + ${#failures[@]}))
echo "Codegen fixtures: $pass/$total as expected"
if [ ${#failures[@]} -gt 0 ]; then
	echo "failures: ${failures[*]}"
	echo "FAIL: see $LOG"
	exit 1
fi
echo "PASS"
