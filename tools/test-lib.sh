# Vendored from FormatCore tools/test-lib.sh by tools/sync.sh: edit it there, then sync.
# A library of the parts every suite runner of the format libraries repeats (KdlBeef's
# test-kdl-spec.sh, XmlBeef's test-xml-conformance.sh, JsonBeef's test-json-suite.sh): the binary
# check, a temporary directory, the log, running one case with a timeout and classifying its exit,
# golden error messages (UPDATE_GOLDEN), a list of expected failures (UPDATE_EXPECTED), and the
# PASS/FAIL footer. Case selection and oracles stay in each runner. Source it:
#   source "$(dirname "$0")/tools/test-lib.sh"
# Functions and variables are prefixed `tl_` / `TL_`.

# Exits with the usual message unless `bin` is an executable
tl_require_bin() { # bin [build-hint]
	if [ ! -x "$1" ]; then
		echo "ERROR: $1 not found or not executable. Build first with: ${2:-beefbuild}"
		exit 1
	fi
}

# Exits unless `path` exists, telling how to get it
tl_require() { # path fetch-hint
	if [ ! -e "$1" ]; then
		echo "ERROR: $1 not found. $2"
		exit 1
	fi
}

# A temporary directory in TL_TMP, removed when the script exits
tl_tmpdir() {
	TL_TMP=$(mktemp -d)
	trap 'rm -rf "$TL_TMP"' EXIT
}

# Starts the log TL_LOG with a header: title, date, binary, any other "key: value" lines given
tl_log_start() { # logfile title [lines...]
	TL_LOG="$1"
	{
		echo "=== $2 ==="
		echo "Date: $(date)"
		shift 2
		for line in "$@"; do
			echo "$line"
		done
		echo ""
	} > "$TL_LOG"
}

# Appends a block to the log: a "--- title ---" line, then each argument (a file's contents when it
# names a readable file, else the text itself), then a blank line
tl_log() { # title [file-or-text...]
	{
		echo "--- $1 ---"
		shift
		for part in "$@"; do
			if [ -f "$part" ]; then cat "$part"; else echo "$part"; fi
		done
		echo ""
	} >> "$TL_LOG"
}

# Exit statuses that mean "rejected the input" rather than a crash (default 1; XmlBeef adds 3 4)
TL_REJECT_CODES="${TL_REJECT_CODES:-1}"
# Seconds a case may run
TL_TIMEOUT="${TL_TIMEOUT:-10}"

# Runs one case under the timeout, its stdout to $TL_TMP/out and stderr to $TL_TMP/err; sets
# TL_STATUS and TL_CLASS: accepted (0), rejected (a TL_REJECT_CODES status), timeout (124) or crash
tl_run() { # command args...
	timeout "$TL_TIMEOUT" "$@" > "$TL_TMP/out" 2> "$TL_TMP/err"
	TL_STATUS=$?
	if [ $TL_STATUS -eq 0 ]; then
		TL_CLASS=accepted
	elif [ $TL_STATUS -eq 124 ]; then
		TL_CLASS=timeout
	elif [[ " $TL_REJECT_CODES " == *" $TL_STATUS "* ]]; then
		TL_CLASS=rejected
	else
		TL_CLASS=crash
	fi
}

# Whether the first line of `actual` (a file) equals the golden file; with UPDATE_GOLDEN set the golden
# file is rewritten from it instead (and the check passes): review the diff afterwards
tl_golden() { # golden-file actual-file
	if [ -n "${UPDATE_GOLDEN:-}" ]; then
		mkdir -p "$(dirname "$1")"
		head -1 "$2" > "$1"
		return 0
	fi
	head -1 "$2" | cmp -s - "$1"
}

# Expected failures: a file of "id<TAB>reason" lines (# comments allowed). An unlisted failure fails
# the run, and so does a listed case that passes (remove it from the list). UPDATE_EXPECTED=1 rewrites
# the list from the current failures, keeping known reasons ("TODO: reason" for new ones).
declare -A TL_EXPECTED=()
declare -A TL_FAILED=()
tl_expected_load() { # file
	TL_EXPECTED_FILE="$1"
	TL_EXPECTED=()
	TL_FAILED=()
	[ -f "$1" ] || return 0
	local id reason
	while IFS=$'\t' read -r id reason; do
		[[ -z "$id" || "$id" == \#* ]] && continue
		TL_EXPECTED[$id]="$reason"
	done < "$1"
}

# Records a failed case
tl_fail() { # id
	TL_FAILED[$1]=1
}

# Whether the case is an expected failure
tl_is_expected() { # id
	[ -n "${TL_EXPECTED[$1]+x}" ]
}

# Compares the failures with the list (or rewrites it); prints the surprises; returns 1 if any
tl_expected_verdict() { # [header line for a rewritten file]
	local id status=0
	if [ -n "${UPDATE_EXPECTED:-}" ]; then
		{
			echo "${1:-# Expected failures (id<TAB>reason)}"
			for id in $(printf '%s\n' "${!TL_FAILED[@]}" | sort); do
				printf '%s\t%s\n' "$id" "${TL_EXPECTED[$id]:-TODO: reason}"
			done
		} > "$TL_EXPECTED_FILE"
		echo "rewrote $TL_EXPECTED_FILE (${#TL_FAILED[@]} failures): review the diff"
		return 0
	fi
	for id in $(printf '%s\n' "${!TL_FAILED[@]}" | sort); do
		if ! tl_is_expected "$id"; then
			echo "unexpected failure: $id"
			status=1
		fi
	done
	for id in $(printf '%s\n' "${!TL_EXPECTED[@]}" | sort); do
		if [ -z "${TL_FAILED[$id]+x}" ]; then
			echo "expected failure passes (remove it from $TL_EXPECTED_FILE): $id"
			status=1
		fi
	done
	return $status
}

# The footer: FAIL (exit 1) when `failed` is not 0, else PASS (exit 0)
tl_finish() { # failed
	if [ "$1" -ne 0 ]; then
		echo "FAIL: see $TL_LOG"
		exit 1
	fi
	echo "PASS"
	exit 0
}
