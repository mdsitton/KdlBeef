#!/bin/bash
# Vendored from FormatCore tools/test-leaks.sh by tools/sync.sh: edit it there, then sync.
# Leak check: runs the [Test] suite with LeakSanitizer preloaded and fails on any leak.
# Usage: ./test-leaks.sh
#
# Beef's realtime leak checker only exists on Windows (it needs the debug GC), so on Linux the
# suite runs under GCC's standalone LeakSanitizer instead. LSan intercepts malloc, which Beef uses
# only with the CRT allocator, so this runs the TestRelease config (the Debug allocator bypasses
# malloc). Reports go to test-leaks.log with file:line stacks.
#
# LSan treats memory as reachable while a stale pointer to it sits on a live stack, so it can miss
# a single leak on the very last code path. Leaks inside tests that run and return are caught.

LSAN_LIB="${LSAN_LIB:-/usr/lib/liblsan.so}"
LOGFILE="test-leaks.log"
CONFIG="TestRelease"

if [ ! -f "$LSAN_LIB" ]; then
	echo "ERROR: $LSAN_LIB not found. Install GCC's LeakSanitizer runtime (liblsan) or set LSAN_LIB."
	exit 1
fi

# Compile without the preload: the compiler itself is not leak-clean under LSan
echo "Building $CONFIG tests..."
if ! build_out=$(beefbuild -test -config=$CONFIG 2>&1); then
	echo "$build_out" | tail -20
	echo "ERROR: build or tests failed before the leak run"
	exit 1
fi

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

# beefbuild inherits the preload too; its own exit-time allocations are not ours
echo "leak:BeefBuild" > "$tmpdir/suppressions.txt"

echo "Running tests under LeakSanitizer..."
run_out=$(LD_PRELOAD="$LSAN_LIB" \
	LSAN_OPTIONS="exitcode=0:log_path=$tmpdir/report:suppressions=$tmpdir/suppressions.txt:fast_unwind_on_malloc=0:malloc_context_size=30:print_suppressions=0" \
	beefbuild -test -config=$CONFIG 2>&1)
run_status=$?
echo "$run_out" | grep -E '^Completed|ERROR' | grep -v LeakSanitizer

reports=("$tmpdir"/report.*)
: > "$LOGFILE"
leaks=0
if [ -e "${reports[0]}" ]; then
	for report in "${reports[@]}"; do
		if grep -q 'ERROR: LeakSanitizer: detected memory leaks' "$report"; then
			cat "$report" >> "$LOGFILE"
			leaks=$((leaks + 1))
		fi
	done
fi

if [ $run_status -ne 0 ]; then
	echo "FAIL: test run exited with status $run_status"
	exit 1
fi
if [ $leaks -gt 0 ]; then
	grep 'SUMMARY' "$LOGFILE"
	echo "FAIL: leaks detected, see $LOGFILE"
	exit 1
fi
echo "PASS: no leaks detected"
