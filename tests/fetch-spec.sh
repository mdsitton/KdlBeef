#!/bin/bash
# Fetches the official KDL specification repository (kdl-org/kdl) at a pinned commit into
# tests/kdl-spec/ (git-ignored). It holds SPEC.md, the full-document test suite
# (tests/kdl-spec/tests/test_cases/{input,expected_kdl}) and the benchmark documents
# (tests/kdl-spec/tests/benchmarks). The spec and tests are CC BY-SA 4.0, so they are fetched rather
# than vendored into this MIT repository. Bump KDL_SPEC_COMMIT deliberately and rerun the suite.
set -euo pipefail
KDL_SPEC_COMMIT="${KDL_SPEC_COMMIT:-89c1087d5e7f530de328f18b6a0fad54ca8ea227}"   # 2026-08-31
DIR="$(cd "$(dirname "$0")" && pwd)/kdl-spec"

if [ -d "$DIR/.git" ] && [ "$(git -C "$DIR" rev-parse HEAD)" = "$KDL_SPEC_COMMIT" ]; then
	echo "kdl-spec already at $KDL_SPEC_COMMIT"
	exit 0
fi
rm -rf "$DIR"
git init -q "$DIR"
git -C "$DIR" remote add origin https://github.com/kdl-org/kdl.git
git -C "$DIR" fetch -q --depth 1 origin "$KDL_SPEC_COMMIT"
git -C "$DIR" checkout -q FETCH_HEAD
echo "kdl-spec at $KDL_SPEC_COMMIT: $(ls "$DIR/tests/test_cases/input" | wc -l) test inputs"
