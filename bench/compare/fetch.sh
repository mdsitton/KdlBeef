#!/bin/bash
# Clones every KDL implementation the comparison benchmark builds against into deps/ (git-ignored), each
# pinned to a commit so runs are comparable, plus the Zig compiler zig-kdl needs. The harnesses build
# the libraries from these clones (Cargo path dependency, go.mod replace, a Gradle source set, npm
# file: dependencies, a .NET project reference, pip installs, CMake). The KDL spec and test suite are
# fetched separately by ../../tests/fetch-spec.sh (gen-inputs.py reads its benchmark documents).
set -euo pipefail
C="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$C/deps"
fetch() { # name url commit
	local dir="$C/deps/$1"
	if [ ! -d "$dir/.git" ]; then
		git init -q "$dir"
		git -C "$dir" remote add origin "$2"
	fi
	if [ "$(git -C "$dir" rev-parse HEAD 2>/dev/null)" != "$3" ]; then
		git -C "$dir" fetch -q --depth 1 origin "$3"
		git -C "$dir" checkout -q --detach FETCH_HEAD
	fi
	echo "$1 $(git -C "$dir" rev-parse --short HEAD)"
}
# Pinned 2026-09-29 (the newest commit of each at the time)
fetch kdl-rs      https://github.com/kdl-org/kdl-rs.git          0a63c6ce0ad3b0a8897acd120c5cc340ba450da8  # kdl 6.7.1
fetch ckdl        https://github.com/tjol/ckdl.git               c9c33fe64446287215e80705545139d92a48f829
fetch gokdl2      https://github.com/njreid/gokdl2.git           480095946544154988699f1469299887e4a637e7
fetch kdly        https://codeberg.org/shimeoki/kdly.git         1cacbe5c26ab1abb51371579c8842e8114bcb2ac
fetch kdl4j       https://github.com/kdl-org/kdl4j.git           ecd15a71d292410be8cffcc062042cec0202c170  # 1.0.1
fetch bgotink-kdl https://github.com/bgotink/kdl.git             10bb7765da8f0a9c2c65107de3e102a16d82f1e4  # @bgotink/kdl 0.4.0
fetch kdljs       https://github.com/kdl-org/kdljs.git           d7d95b92ee01528686d8002071f5106247ad16fb  # 0.3.0
fetch KdlSharp    https://github.com/AndreyAkinshin/KdlSharp.git 7d2e972e4001e1d4f8df98268cb2859c169a29b3
fetch kdlpy       https://github.com/tabatkins/kdlpy.git         d9a220762fb9f55e4f59296256221084c26f54da  # kdl-py 1.2.0
fetch zig-kdl     https://codeberg.org/desttinghim/zig-kdl.git   22fa7655d70de1f447c864921ab847effec355f3
# The spec repository as well, for reading alongside the implementations (the suite itself comes
# from tests/fetch-spec.sh at the same commit)
fetch kdl         https://github.com/kdl-org/kdl.git             89c1087d5e7f530de328f18b6a0fad54ca8ea227

# Zig itself (zig-kdl's harness uses Zig 0.16 APIs), verified against the published checksum
ZIG_VERSION=0.16.0
ZIG_SHA256=70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00
if [ ! -x "$C/deps/zig/zig" ]; then
	tarball="$C/deps/zig-$ZIG_VERSION.tar.xz"
	curl -fsSL -o "$tarball" "https://ziglang.org/download/$ZIG_VERSION/zig-x86_64-linux-$ZIG_VERSION.tar.xz"
	echo "$ZIG_SHA256  $tarball" | sha256sum -c --quiet -
	mkdir -p "$C/deps/zig"
	tar -xJf "$tarball" -C "$C/deps/zig" --strip-components=1
	rm "$tarball"
fi
echo "zig $("$C/deps/zig/zig" version)"
