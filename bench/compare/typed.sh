#!/bin/bash
# Typed serialization: each library reads inputs/ui.kdl (the generated UI markup, see gen-inputs.py
# `ui`) into its own native types declared to match (windows, containers, eight widget kinds), and
# writes them back to KDL. Only libraries with a typed mapping take part. Every harness prints the same
# checksum line after reading (every node's count and a sum over its values), and again after
# re-reading its own output, so all of them bind the same values.
# Times are ms per operation (the written text differs in layout between libraries, so write MB/s
# would reward longer output). Timings follow the rule in run.sh; each cell is the median of REPEATS
# processes (default 3); a run past LIMIT seconds (default 60) is DNF.
# Usage: typed.sh [min-samples]   (after ./fetch.sh && ./build.sh && ./gen-inputs.py, and
# `beefbuild -config=Release` at the repository root for KdlBeef)
set -uo pipefail
C="$(cd "$(dirname "$0")" && pwd)"
B="$C/bin"
N="${1:-5}"
REPEATS="${REPEATS:-3}"
LIMIT="${LIMIT:-60}"
IN="$C/inputs/ui.kdl"
CHECK="check: 63681 49219647931"
KT="$C/../../build/Release_Linux64/KdlTester/KdlTester"

# Median over REPEATS runs of a harness's "<ms> ms/op" figure; DNF past the limit, FAIL on an error or
# a checksum that differs, "n/a" when the library cannot do it (exit 3)
median() { # command...
	local values=() out status
	for ((r = 0; r < REPEATS; r++)); do
		out=$(timeout "$LIMIT" "$@" 2>&1)
		status=$?
		if [ $status -eq 124 ]; then echo DNF; return; fi
		if [ $status -eq 3 ]; then echo "n/a"; return; fi
		if [ $status -ne 0 ] || ! grep -q "^$CHECK" <<< "$out" || { grep -q "^re-read" <<< "$out" && ! grep -q "^re-read $CHECK" <<< "$out"; }; then
			echo FAIL
			return
		fi
		values+=("$(grep -oE '[0-9.]+ ms/op' <<< "$out" | tail -1 | awk '{print $1}')")
	done
	printf '%s\n' "${values[@]}" | sort -g | awk '{a[NR] = $1} END {print (NR % 2) ? a[(NR + 1) / 2] : (a[NR / 2] + a[NR / 2 + 1]) / 2}'
}

mbps() { # ms -> MB/s of the input
	awk -v ms="$1" -v bytes="$(stat -c %s "$IN")" 'BEGIN { if (ms + 0 > 0) printf "%.1f", bytes / 1048576 / (ms / 1000); else print "" }'
}

row() { # name language how read-command... -- write-command...
	local name="$1" language="$2" how="$3"
	shift 3
	local read=() write=()
	while [ "$1" != "--" ]; do read+=("$1"); shift; done
	shift
	write=("$@")
	local r w
	r=$(median "${read[@]}")
	w=$(median "${write[@]}")
	echo "| $name | $language | $how | $r | $(mbps "$r") | $w |"
}

echo "input: ui.kdl, $(stat -c %s "$IN") bytes, 63,681 windows, containers and widgets"
echo
echo "| library | language | mapping | read (ms) | read (MB/s) | write (ms) |"
echo "|---|---|---|---:|---:|---:|"
row KdlBeef Beef "[KdlObject], compile time" "$KT" -bench-typed read "$IN" "$N" -- "$KT" -bench-typed write "$IN" "$N"
row "KdlBeef (no positions)" Beef "[KdlObject], compile time" "$KT" -bench-typed read-plain "$IN" "$N" -- "$KT" -bench-typed write "$IN" "$N"
row kdl-rs Rust "serde derive, compile time" "$B/rust-kdlbench" typed read "$IN" "$N" -- "$B/rust-kdlbench" typed write "$IN" "$N"
row gokdl2 Go "struct tags, run-time reflection" "$B/go-kdlbench" typed gokdl2 read "$IN" "$N" -- "$B/go-kdlbench" typed gokdl2 write "$IN" "$N"
row KdlSharp "C#" "attributes, run-time reflection" "$B/kdlsharp/KdlSharpBench" typed read "$IN" "$N" -- "$B/kdlsharp/KdlSharpBench" typed write "$IN" "$N"
