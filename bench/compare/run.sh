#!/bin/bash
# Runs every KDL implementation on every input and prints two Markdown tables: parsing (MB/s of input)
# and writing a parsed document back to text (MB/s of output), higher is better.
#
# Measurement rule, shared by every harness (c/bench.h, rust, go, java, js, cs, python, zig):
#   1. Warm up: run the operation for at least 1 s (at least once), for native code and JITs alike.
#   2. Sample: time single operations until at least N samples (default 5) were taken and at least
#      60% of them lie within ±10% of their median ("converged"), or 10 s of measuring or 1000
#      samples have passed ("capped"). Report the median sample.
#   3. Repeat: run each cell REPEATS times (default 3) in fresh processes and take the median.
# Every harness prints "nodes: N" (all nodes, children included) after its first parse; a count that
# differs from the reference (ckdl's) is FAIL, like a parse error. DNF: a run past LIMIT seconds
# (default 60). n/a: the library has no writer (ckdl's C core and zig-kdl are event parsers).
# Setup: ./fetch.sh && ./build.sh && ./gen-inputs.py   Usage: run.sh [min-samples] [inputs...]
# KdlBeef's rows need the Release KdlTester: beefbuild -config=Release at the repository root.
# ONLY="KdlBeef|KdlBeef events" restricts the run to those columns.
set -uo pipefail
C="$(cd "$(dirname "$0")" && pwd)"
B="$C/bin"
N="${1:-5}"
shift || true
REPEATS="${REPEATS:-3}"
LIMIT="${LIMIT:-60}"
PY="$C/python/.venv/bin/python"

if [ $# -gt 0 ]; then
	inputs=("$@")
else
	inputs=(ui config strings numbers html-standard html-standard-compact)
fi

# name|command prefix (the harness takes <parse|write> <file> <min-samples> after it)
# KdlBeef: the Release KdlTester (beefbuild -config=Release at the repository root)
KT="$C/../../build/Release_Linux64/KdlTester/KdlTester"
LIBS=(
	"KdlBeef|$KT -bench"
	"KdlBeef events|$KT -bench-events"
	"ckdl|$B/ckdl"
	"kdlpp|$B/kdlpp"
	"kdl-rs|$B/rust-kdlbench"
	"gokdl2|$B/go-kdlbench gokdl2"
	"kdly|$B/go-kdlbench kdly"
	"kdl4j|$B/java/bin/kdlbench"
	"@bgotink/kdl|node $C/js/bench.mjs bgotink"
	"kdljs|node $C/js/bench.mjs kdljs"
	"KdlSharp|$B/kdlsharp/KdlSharpBench"
	"ckdl (Python)|$PY $C/python/bench.py ckdl"
	"kdl-py|$PY $C/python/bench.py kdlpy"
	"zig-kdl|$B/zig-kdl"
)

# One cell: the median MB/s over REPEATS runs, or FAIL / DNF / n/a
cell() { # expected-nodes mode file command...
	local expected="$1" mode="$2" file="$3" values=() out status
	shift 3
	for ((r = 0; r < REPEATS; r++)); do
		# Both streams: the Zig harness prints its results to stderr
		out=$(timeout "$LIMIT" "$@" "$mode" "$file" "$N" 2>&1)
		status=$?
		if [ $status -eq 124 ]; then echo DNF; return; fi
		if [ $status -eq 3 ]; then echo "n/a"; return; fi
		if [ $status -ne 0 ] || [ "$(grep -oE '^nodes: [0-9]+' <<< "$out" | awk '{print $2}')" != "$expected" ]; then
			echo FAIL
			return
		fi
		values+=("$(grep -oE '[0-9.]+ MB/s' <<< "$out" | head -1 | awk '{print $1}')")
	done
	printf '%s\n' "${values[@]}" | sort -g | awk '{a[NR] = $1} END {print (NR % 2) ? a[(NR + 1) / 2] : (a[NR / 2] + a[NR / 2 + 1]) / 2}'
}

# ONLY="name1|name2" runs just those implementations (e.g. ONLY="KdlBeef|KdlBeef events")
if [ -n "${ONLY:-}" ]; then
	selected=()
	for lib in "${LIBS[@]}"; do
		if [[ "|$ONLY|" == *"|${lib%%|*}|"* ]]; then
			selected+=("$lib")
		fi
	done
	LIBS=("${selected[@]}")
fi

header="| input |"
rule="|---|"
for lib in "${LIBS[@]}"; do
	header+=" ${lib%%|*} |"
	rule+="---:|"
done

for mode in parse write; do
	if [ "$mode" = parse ]; then
		echo "### Parsing (MB/s of input, higher is better)"
	else
		echo "### Writing a parsed document (MB/s of output, higher is better)"
	fi
	echo
	echo "$header"
	echo "$rule"
	for input in "${inputs[@]}"; do
		file="$C/inputs/$input.kdl"
		expected=$("$B/ckdl" parse "$file" 1 2>/dev/null | grep -oE '^nodes: [0-9]+' | awk '{print $2}')
		row="| $input |"
		for lib in "${LIBS[@]}"; do
			# Word splitting of the command prefix is intended
			# shellcheck disable=SC2086
			row+=" $(cell "$expected" "$mode" "$file" ${lib#*|}) |"
		done
		echo "$row"
	done
	echo
done
