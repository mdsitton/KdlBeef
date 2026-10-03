#!/bin/bash
# Vendored from FormatCore tools/win-test.sh by tools/sync.sh: edit it there, then sync.
# Windows tests: the [Test] suite under the Proton-hosted Windows BeefBuild, in the Test (Debug checks)
# and TestRelease configs, one after the other. The Windows Debug runtime also checks for leaks when the
# test process exits (exit code 2147483651 after every test passed means a leak: AGENTS.md).
# Usage: ./win-test.sh [configs...]       (default: Test TestRelease)
#   BEEFBUILD_WIN  the wrapper to use (default: ~/development/beef-proton/bin/beefbuild-win)
set -uo pipefail
cd "$(dirname "$0")"
WIN="${BEEFBUILD_WIN:-$HOME/development/beef-proton/bin/beefbuild-win}"
if [ ! -x "$WIN" ]; then
	echo "ERROR: $WIN not found (set BEEFBUILD_WIN)"
	exit 1
fi
configs=("$@")
if [ ${#configs[@]} -eq 0 ]; then
	configs=(Test TestRelease)
fi
LOG=win-test.log
: > "$LOG"
failed=0
for config in "${configs[@]}"; do
	args=(-test)
	if [ "$config" != Test ]; then
		args+=("-config=$config")
	fi
	output=$("$WIN" "${args[@]}" 2>&1)
	status=$?
	{ echo "--- $config (exit $status)"; echo "$output"; } >> "$LOG"
	summary=$(grep -E '^Completed|Failed [0-9]+ test' <<< "$output" | tr '\n' ' ')
	if [ $status -eq 0 ]; then
		echo "$config: PASS $summary"
	else
		echo "$config: FAIL (exit $status) $summary"
		failed=1
	fi
done
if [ $failed -ne 0 ]; then
	echo "FAIL: see $LOG"
	exit 1
fi
echo "PASS"
