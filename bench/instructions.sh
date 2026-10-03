#!/bin/bash
# Vendored from FormatCore bench-kit/instructions.sh by tools/sync.sh: edit it there, then sync.
# Instructions per input byte (user space) of a Release tester's passes, per benchmark input: a measure
# that, unlike time, does not depend on the machine's load, for comparing small changes that timing
# noise would hide (XmlBeef's and JsonBeef's bench/instructions.sh, generalized). It is not speed:
# memory traffic and branch misses are not in it. Timed figures come from bench/compare/run.sh.
#
# Each cell is two runs of the tester's fixed-iteration loop that differ by five iterations, so reading
# the input and starting up cancel out: (count(6) - count(1)) / 5 / bytes.
#
# The repository describes its tester in bench/instructions.conf (sourced; bash):
#   TESTER=./build/Release_Linux64/KdlTester/KdlTester      the Release tester (build it first)
#   INPUT_DIR=bench/compare/inputs                           where the inputs are
#   EXTENSIONS=(kdl)                                         tried in order after the input's name
#   INPUTS=(small medium large)                              the default inputs
#   MODES=(events document "stream4k:stream buffer=4096")    columns: [label:]mode [options...]
#   BUILD_HINT="beefbuild -config=Release"                   printed when the tester is missing
#   and optionally a function instructions_command <mode> <path> <iterations> [options...] that runs
#   one loop (default: "$TESTER" -bench-loop <mode> <path> <iterations> [options...]); return 3 from a
#   check function instructions_skip <mode> <path> to print `-` for a cell.
#
# Usage: bash bench/instructions.sh [input names...]
#   MODES="events document" limits the columns; EVENT=cycles counts CPU cycles instead (closer to
#   speed, as it sees branch misses and memory stalls, but it varies with the load: compare runs taken
#   back to back).
set -uo pipefail
cd "$(dirname "$0")/.."
CONF=bench/instructions.conf
if [ ! -f "$CONF" ]; then
	echo "ERROR: $CONF not found (it names the tester, inputs and modes)"
	exit 1
fi
TESTER=""
INPUT_DIR=bench/compare/inputs
EXTENSIONS=()
INPUTS=()
MODES_DEFAULT=()
BUILD_HINT="beefbuild -config=Release"
instructions_command() { # mode path iterations options...
	local mode=$1 path=$2 iterations=$3
	shift 3
	"$TESTER" -bench-loop "$mode" "$path" "$iterations" "$@"
}
instructions_skip() { # mode path
	return 1
}
MODES_ENV="${MODES:-}"
MODES=()
# shellcheck source=/dev/null
source "$CONF"
MODES_DEFAULT=("${MODES[@]}")

if ! command -v perf > /dev/null; then
	echo "ERROR: perf not found"
	exit 1
fi
if [ -z "$TESTER" ] || [ ! -x "$TESTER" ]; then
	echo "ERROR: tester '$TESTER' missing: $BUILD_HINT first"
	exit 1
fi
if [ $# -gt 0 ]; then
	inputs=("$@")
else
	inputs=("${INPUTS[@]}")
fi
if [ -n "$MODES_ENV" ]; then
	read -r -a modes <<< "$MODES_ENV"
else
	modes=("${MODES_DEFAULT[@]}")
fi
EVENT="${EVENT:-instructions}"
# The child that runs one loop sources the configuration again (it may define instructions_command)
export TESTER
export -f instructions_command

# The user-space count of one loop (the child shell's own start-up is in both runs: it cancels out)
count() { # mode path iterations options...
	perf stat -x, -e "$EVENT:u" bash -c 'source "$0"; instructions_command "$@"' "$CONF" "$@" 2>&1 > /dev/null | grep "$EVENT" | cut -d, -f1
}

label_of() { # column spec
	local spec=$1
	if [[ "${spec%% *}" == *:* ]]; then echo "${spec%%:*}"; else echo "${spec%% *}"; fi
}

line=$(printf '%-15s' input)
for spec in "${modes[@]}"; do
	line+=$(printf ' %9s' "$(label_of "$spec")")
done
echo "$line"
for name in "${inputs[@]}"; do
	path=""
	for ext in "${EXTENSIONS[@]}" ""; do
		candidate="$INPUT_DIR/$name${ext:+.$ext}"
		if [ -e "$candidate" ]; then
			path=$candidate
			break
		fi
	done
	if [ -z "$path" ]; then
		echo "$name: no input in $INPUT_DIR"
		continue
	fi
	bytes=$(du -sb --apparent-size "$path" | cut -f1)
	line=$(printf '%-15s' "$name")
	for spec in "${modes[@]}"; do
		run=$spec
		[[ "${spec%% *}" == *:* ]] && run=${spec#*:}
		read -r -a parts <<< "$run"
		mode=${parts[0]}
		options=("${parts[@]:1}")
		if instructions_skip "$mode" "$path"; then
			line+=$(printf ' %9s' -)
			continue
		fi
		one=$(count "$mode" "$path" 1 "${options[@]}")
		six=$(count "$mode" "$path" 6 "${options[@]}")
		if [ -z "$one" ] || [ -z "$six" ]; then
			line+=$(printf ' %9s' FAIL)
			continue
		fi
		line+=$(awk -v a="$one" -v b="$six" -v n="$bytes" 'BEGIN { printf " %9.2f", (b - a) / 5 / n }')
	done
	echo "$line"
done
