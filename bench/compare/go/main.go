// Go KDL benchmark: kdlbench <gokdl2|kdly> <parse|write> <file> <min-samples>
//
//	kdlbench typed gokdl2 <read|write> <file> <min-samples> - typed mapping, see typed.go
//
//	gokdl2 - github.com/njreid/gokdl2: ParseWithOptions (Version v2) into its document;
//	         write is GenerateWithOptions with Version 2 (its default output is KDL v1)
//	kdly   - codeberg.org/shimeoki/kdly: Parser.Parse into its lossless syntax tree;
//	         write is Formatter.Format
//
// Prints the node count as a check line. Timings follow the shared rule (see measure and ../run.sh).
package main

import (
	"bytes"
	"fmt"
	"os"
	"sort"
	"strconv"
	"time"

	"codeberg.org/shimeoki/kdly"
	kdl "github.com/njreid/gokdl2"
	"github.com/njreid/gokdl2/document"
)

// measure warms up for at least 1 s (at least one run), then times single runs until at least
// minSamples were taken and at least 60% lie within ±10% of their median ("converged"), or 10 s of
// measuring or 1000 samples have passed. Returns the median sample in ns.
func measure(minSamples int, op func()) (median float64, n int, converged bool) {
	warm := time.Now()
	for {
		op()
		if time.Since(warm) >= time.Second {
			break
		}
	}
	start := time.Now()
	var samples []float64
	for {
		t0 := time.Now()
		op()
		samples = append(samples, float64(time.Since(t0).Nanoseconds()))
		sorted := append([]float64(nil), samples...)
		sort.Float64s(sorted)
		n = len(sorted)
		if n%2 == 1 {
			median = sorted[n/2]
		} else {
			median = (sorted[n/2-1] + sorted[n/2]) / 2
		}
		if n >= minSamples {
			within := 0
			for _, s := range samples {
				if s >= median*0.9 && s <= median*1.1 {
					within++
				}
			}
			if float64(within) >= 0.6*float64(n) {
				return median, n, true
			}
		}
		if n >= 1000 || time.Since(start) >= 10*time.Second {
			return median, n, false
		}
	}
}

func countGokdl2(nodes []*document.Node) int {
	n := 0
	for _, node := range nodes {
		n += 1 + countGokdl2(node.Children)
	}
	return n
}

// kdly keeps slashdashed nodes and blocks in its syntax tree; only live ones count
func countKdly(nodes []kdly.Node) int {
	n := 0
	for _, node := range nodes {
		if node.Slashdash != nil {
			continue
		}
		n++
		for _, block := range node.Blocks {
			if block.Slashdash == nil {
				n += countKdly(block.Nodes)
			}
		}
	}
	return n
}

func main() {
	if len(os.Args) > 1 && os.Args[1] == "typed" {
		runTyped(os.Args[2:])
		return
	}
	if len(os.Args) < 5 {
		fmt.Fprintln(os.Stderr, "usage: kdlbench <gokdl2|kdly> <parse|write> <file> <min-samples>")
		os.Exit(2)
	}
	lib, mode := os.Args[1], os.Args[2]
	data, err := os.ReadFile(os.Args[3])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	minSamples, _ := strconv.Atoi(os.Args[4])

	fail := func(err error) {
		fmt.Fprintln(os.Stderr, "parse error:", err)
		os.Exit(1)
	}
	var parse func() int
	var write func() int
	switch lib {
	case "gokdl2":
		opts := kdl.ParseOptions{Version: kdl.ParseVersionV2}
		doc, err := kdl.ParseWithOptions(bytes.NewReader(data), opts)
		if err != nil {
			fail(err)
		}
		parse = func() int {
			d, err := kdl.ParseWithOptions(bytes.NewReader(data), opts)
			if err != nil {
				fail(err)
			}
			return countGokdl2(d.Nodes)
		}
		write = func() int {
			var buf bytes.Buffer
			if err := kdl.GenerateWithOptions(doc, &buf, kdl.GenerateOptions{Indent: "    ", Version: 2}); err != nil {
				fail(err)
			}
			return buf.Len()
		}
	case "kdly":
		doc, err := kdly.NewParser(bytes.NewReader(data)).Parse()
		if err != nil {
			fail(err)
		}
		parse = func() int {
			d, err := kdly.NewParser(bytes.NewReader(data)).Parse()
			if err != nil {
				fail(err)
			}
			return countKdly(d.Nodes)
		}
		write = func() int {
			var buf bytes.Buffer
			if err := kdly.NewFormatter(&buf).Format(doc); err != nil {
				fail(err)
			}
			return buf.Len()
		}
	default:
		fmt.Fprintln(os.Stderr, "unknown library", lib)
		os.Exit(2)
	}

	fmt.Printf("nodes: %d\n", parse())
	size := len(data)
	var median float64
	var n int
	var converged bool
	if mode == "parse" {
		median, n, converged = measure(minSamples, func() { parse() })
	} else {
		median, n, converged = measure(minSamples, func() { size = write() })
	}
	ms := median / 1e6
	status := "capped"
	if converged {
		status = "converged"
	}
	fmt.Printf("%.3f ms/op %.1f MB/s (n=%d, %s)\n", ms, float64(size)/1048576.0/(ms/1000.0), n, status)
}
