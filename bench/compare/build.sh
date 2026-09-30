#!/bin/bash
# Builds every comparison harness into bin/ (git-ignored). Run fetch.sh first. C and C++ use -O3
# without -march=native (generic x86-64, like Beef's Release builds). Pass harness names to build only
# those: ckdl rust knus go java js cs python zig (KdlBeef is built at the repository root).
set -euo pipefail
C="$(cd "$(dirname "$0")" && pwd)"
D="$C/deps"
B="$C/bin"
mkdir -p "$B"

TARGETS=("$@")
want() { [ ${#TARGETS[@]} -eq 0 ] || [[ " ${TARGETS[*]} " == *" $1 "* ]]; }
step() { echo "== $1"; }

if want ckdl; then
	step "ckdl (C) and kdlpp (C++)"
	cmake -S "$D/ckdl" -B "$C/c/build" -DCMAKE_BUILD_TYPE=Release -DBUILD_KDLPP=ON -DBUILD_TESTS=OFF > /dev/null
	cmake --build "$C/c/build" -j 8 > /dev/null
	cc -O3 -std=gnu11 -I"$D/ckdl/include" -I"$C/c/build/include" -o "$B/ckdl" "$C/c/ckdl.c" "$C/c/build/libkdl.a" -lm
	c++ -O3 -std=c++20 -I"$D/ckdl/include" -I"$C/c/build/include" -I"$D/ckdl/bindings/cpp/include" \
		-I"$C/c/build/bindings/cpp/include" -o "$B/kdlpp" "$C/cpp/kdlpp.cpp" \
		"$C/c/build/bindings/cpp/libkdlpp.a" "$C/c/build/libkdl.a" -lm
fi
if want rust; then
	step "rust (kdl-rs)"
	# Built from its directory so rustup picks the pinned toolchain in rust-toolchain.toml
	(cd "$C/rust" && cargo build -q --release --target-dir "$C/rust/target")
	cp "$C/rust/target/release/kdlbench" "$B/rust-kdlbench"
fi
if want knus; then
	step "rust (knus)"
	(cd "$C/knus" && cargo build -q --release --target-dir "$C/knus/target")
	cp "$C/knus/target/release/knusbench" "$B/knusbench"
fi
if want go; then
	step "go (gokdl2, kdly, dasel)"
	# dasel's KDL parser is in an internal package: go/daselhook/hook.go.in joins the dasel clone
	# virtually, through an overlay, as a package that may import it (deps/ stays untouched)
	printf '{"Replace":{"%s":"%s"}}\n' "$D/dasel/parsing/kdl/kdlbenchhook/hook.go" "$C/go/daselhook/hook.go.in" \
		> "$B/dasel-overlay.json"
	(cd "$C/go" && go build -overlay "$B/dasel-overlay.json" -o "$B/go-kdlbench" .)
fi
if want java; then
	step "java (kdl4j)"
	(cd "$C/java" && gradle -q --console=plain installDist)
	rm -rf "$B/java" && cp -r "$C/java/build/install/kdlbench" "$B/java"
fi
if want js; then
	step "javascript (@bgotink/kdl, kdljs)"
	(cd "$D/kdljs" && npm install --silent --no-audit --no-fund --ignore-scripts)
	(cd "$C/js" && npm install --silent --no-audit --no-fund --ignore-scripts)
fi
if want cs; then
	step "c# (KdlSharp)"
	dotnet build -v q -nologo -c Release -o "$B/kdlsharp" "$C/cs/KdlSharpBench.csproj" > /dev/null
fi
if want python; then
	step "python (kdl-py, ckdl bindings)"
	[ -x "$C/python/.venv/bin/python" ] || python3 -m venv "$C/python/.venv"
	# ckdl's scikit-build leaves _skbuild in the clone, which breaks a later rebuild
	rm -rf "$D/ckdl/_skbuild"
	"$C/python/.venv/bin/pip" install -q "$D/kdlpy" "$D/ckdl"
fi
if want zig; then
	step "zig (zig-kdl)"
	(cd "$C/zig" && "$D/zig/zig" build-exe -O ReleaseFast --dep kdl -Mroot=bench.zig -Mkdl="$D/zig-kdl/src/root.zig" \
		-femit-bin="$B/zig-kdl" --cache-dir "$C/zig/.zig-cache" --global-cache-dir "$C/zig/.zig-cache")
fi
