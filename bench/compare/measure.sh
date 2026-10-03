# Vendored from FormatCore bench-kit/measure.sh by tools/sync.sh: edit it there, then sync.
# Repeating a benchmark cell in fresh processes until they agree, sourced by run.sh and its siblings
# (XmlBeef's bench/compare/measure.sh and JsonBeef's inline settle()/cell(), merged).
#
# Each harness already samples one process until its samples converge (60% within ±10% of their
# median: bench-core.h, FormatCore.Testing's Bench.Measure). Between processes the figure still moves
# with the machine's load, memory layout, hash seeds and clocks, so a cell is rerun in fresh processes
# until it settles: at least REPEATS runs (default 3), then on until REPEATS of the runs that converged
# lie within ±TOLERANCE percent (default 10) of the converged runs' median, at most MAX_RUNS runs
# (default 9). The cell reports the median of the runs in that band. A cell that never settled reports
# the median of its converged runs (of all its runs if none converged), marked `~`: noise, not a
# measurement to trust. No quiet machine is assumed: a loaded one takes more runs, not a refusal.
# (The tolerance was ±5% in XmlBeef and ±10% in JsonBeef; FormatCore's AGENTS.md rule is ±10%.)

REPEATS="${REPEATS:-3}"
MAX_RUNS="${MAX_RUNS:-${MAX_REPEATS:-9}}"
TOLERANCE="${TOLERANCE:-10}"
if [ "$MAX_RUNS" -lt "$REPEATS" ]; then MAX_RUNS=$REPEATS; fi

# The median of the values (one per line on stdin)
median() {
	sort -g | awk '{a[NR] = $1} END {print (NR % 2) ? a[(NR + 1) / 2] : (a[NR / 2] + a[NR / 2 + 1]) / 2}'
}

# The verdict on the runs so far, given one "<value> <converged 0|1>" line per run: "settled" and the
# (1-based) runs in the ±TOLERANCE band around the converged runs' median when at least `need`
# converged runs lie in it; otherwise "unsettled" and the runs to report (the converged ones, or all)
settle_verdict() { # need
	awk -v need="$1" -v t="$TOLERANCE" '
		{ v[NR] = $1; c[NR] = $2 }
		END {
			n = 0
			for (i = 1; i <= NR; i++) if (c[i]) s[++n] = v[i]
			if (n == 0) {
				for (i = 1; i <= NR; i++) list = list " " i
				print "unsettled" list
				exit
			}
			for (i = 2; i <= n; i++) {
				x = s[i]
				for (j = i - 1; j >= 1 && s[j] > x; j--) s[j + 1] = s[j]
				s[j + 1] = x
			}
			m = (n % 2) ? s[(n + 1) / 2] : (s[n / 2] + s[n / 2 + 1]) / 2
			k = 0
			for (i = 1; i <= NR; i++) {
				if (!c[i]) continue
				converged = converged " " i
				if (v[i] >= m * (1 - t / 100) && v[i] <= m * (1 + t / 100)) { k++; band = band " " i }
			}
			print (k >= need) ? "settled" band : "unsettled" converged
		}'
}

# Runs `command args...` (one process) until the runs settle. The command prints one line:
# "<value> <converged 0|1> [more values...]" (the value settles; the others, such as ms/op or peak RSS,
# are reported as medians over the same runs), or a lone "<value>" (taken as converged), or FAIL, DNF
# or n/a, which end the cell. Prints the medians, then `~` if the cell never settled.
settle() { # command args...
	local lines=() line r i verdict
	for ((r = 0; r < MAX_RUNS; r++)); do
		line=$("$@")
		case "$line" in
		FAIL* | DNF* | n/a*)
			echo "$line"
			return
			;;
		esac
		read -r -a fields <<< "$line"
		if [ ${#fields[@]} -lt 2 ]; then
			fields+=(1)
		fi
		lines+=("${fields[*]}")
		if [ $((r + 1)) -ge "$REPEATS" ]; then
			verdict=$(printf '%s\n' "${lines[@]}" | settle_verdict "$REPEATS")
			if [[ "$verdict" == settled* ]]; then break; fi
		fi
	done
	if [ -z "${verdict:-}" ]; then
		verdict=$(printf '%s\n' "${lines[@]}" | settle_verdict "$REPEATS")
	fi
	local kept=() field count out=() mark=""
	for i in ${verdict#* }; do
		kept+=("${lines[i - 1]}")
	done
	read -r -a fields <<< "${kept[0]}"
	count=${#fields[@]}
	for ((field = 1; field <= count; field++)); do
		# Field 2 is the converged flag
		[ $field -eq 2 ] && continue
		out+=("$(printf '%s\n' "${kept[@]}" | awk -v f=$field '{print $f}' | median)")
	done
	# `~` on a lone value ("123.4~", XmlBeef's cells), a field of its own after several (JsonBeef's)
	if [[ "$verdict" == unsettled* ]]; then
		mark="~"
		[ ${#out[@]} -gt 1 ] && mark=" ~"
	fi
	echo "${out[*]}$mark"
}

# Parses a harness's output (the result line of bench-core.h / Bench.PrintResult, and maxrss's line
# when present) into settle's format: "<MB/s> <converged 0|1> <ms/op> [<peak RSS KiB>]"
harness_result() { # output
	local mbps ms rss converged=0
	mbps=$(grep -oE '[0-9.]+ MB/s' <<< "$1" | head -1 | awk '{print $1}')
	ms=$(grep -oE '[0-9.]+ ms/op' <<< "$1" | head -1 | awk '{print $1}')
	rss=$(grep -oE '^maxrss: [0-9]+' <<< "$1" | tail -1 | awk '{print $2}')
	if grep -q ', converged)' <<< "$1"; then converged=1; fi
	if [ -z "$mbps" ]; then
		echo FAIL
		return
	fi
	echo "$mbps $converged $ms${rss:+ $rss}"
}
