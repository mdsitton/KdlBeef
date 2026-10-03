# Vendored from FormatCore bench-kit/merge.sh by tools/sync.sh: edit it there, then sync.
# Partial reruns of a benchmark, sourced by run.sh and its siblings (JsonBeef's, XmlBeef's and
# TomlBeef's bench/compare/merge.sh, merged).
#
# With ONLY set to an extended regular expression matched against whole implementation names (for
# example ONLY='yyjson|simdjson.*', or ONLY='KdlBeef.*'), a script measures only the matching ones and
# copies every other cell from its saved results file. It prints the merged tables and, if the run
# succeeded, writes them back to that file, so there is no need to redirect the output. Without ONLY a
# script measures everything and only prints.

# Whether `name` is measured in this run: always without ONLY, else when it matches ONLY
selected() { # name
	[ -z "${ONLY:-}" ] || grep -qxE -- "$ONLY" <<< "$1"
}

# With ONLY, runs the calling script again (with the same arguments) as a child that does the work,
# saves the child's output over `results-file` if it succeeded, and exits. The saved file is read by
# the child and only replaced after it has finished. Returns at once without ONLY, and in the child.
merge_into() { # results-file script-args...
	RESULTS_FILE="$1"
	shift
	if [ -z "${ONLY:-}" ] || [ -n "${MERGE_CHILD:-}" ]; then
		return 0
	fi
	if [ ! -f "$RESULTS_FILE" ]; then
		echo "ONLY merges into $RESULTS_FILE, which does not exist yet: run without ONLY first" >&2
		exit 1
	fi
	local tmp status
	tmp=$(mktemp)
	MERGE_CHILD=1 bash "$0" "$@" | tee "$tmp"
	status=${PIPESTATUS[0]}
	if [ "$status" -eq 0 ]; then
		# Copied over, not moved: the results file keeps its mode (mktemp's file is private)
		cat "$tmp" > "$RESULTS_FILE"
		rm -f "$tmp"
	else
		rm -f "$tmp"
		echo "not saved: the run failed ($status)" >&2
	fi
	exit "$status"
}

# A saved cell: the column headed `column` in the row whose first cell is `row`, from whichever
# Markdown table in RESULTS_FILE has that column first; "?" if the file has no such cell
saved_cell() { # row column
	awk -F'|' -v row="$1" -v col="$2" '
		function trim(s) { gsub(/^ +| +$/, "", s); return s }
		!/^\|/ { header = 0; at = 0; next }
		!header { header = 1; at = 0; for (c = 2; c < NF; c++) if (trim($c) == col) at = c; next }
		at && trim($2) == row { print trim($at); found = 1; exit }
		END { if (!found) print "?" }' "$RESULTS_FILE"
}

# A saved cell of one table: as saved_cell, in the Markdown table under the heading line `heading`
# (for example "### `dom`: MB/s": tracks or modes that share row and column names); "?" if none
saved_table_cell() { # heading row column
	awk -F'|' -v title="$1" -v row="$2" -v col="$3" '
		function trim(s) { gsub(/^ +| +$/, "", s); return s }
		/^#+ / { inside = ($0 == title); header = 0; at = 0; next }
		!inside { next }
		!/^\|/ { header = 0; at = 0; next }
		!header { header = 1; at = 0; for (c = 2; c < NF; c++) if (trim($c) == col) at = c; next }
		at && trim($2) == row { print trim($at); found = 1; exit }
		END { if (!found) print "?" }' "$RESULTS_FILE"
}

# A saved row, whole, whose first cell is `row`, from the first table that has one (nothing if none)
saved_row() { # row
	awk -F'|' -v row="$1" '
		function trim(s) { gsub(/^ +| +$/, "", s); return s }
		/^\|/ && trim($2) == row { print; exit }' "$RESULTS_FILE"
}

# The notes above the first "## " or deeper heading of RESULTS_FILE (kept by a partial rerun), without
# trailing blank lines
saved_preamble() {
	awk '/^##+ / { exit } { lines[++n] = $0 } END { while (n > 0 && lines[n] == "") n--; for (i = 1; i <= n; i++) print lines[i] }' "$RESULTS_FILE"
}
