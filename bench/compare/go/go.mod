module kdlbeef/bench/compare

go 1.27

require (
	codeberg.org/shimeoki/kdly v0.0.0
	github.com/njreid/gokdl2 v0.0.0
	github.com/tomwright/dasel/v3 v3.0.0
)

// The pinned clones fetched by ../fetch.sh
replace codeberg.org/shimeoki/kdly => ../deps/kdly

replace github.com/njreid/gokdl2 => ../deps/gokdl2

replace github.com/tomwright/dasel/v3 => ../deps/dasel
