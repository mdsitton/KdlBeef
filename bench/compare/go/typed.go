// Typed-mapping benchmark: kdlbench typed gokdl2 <read|write> <file> <min-samples>
//
// Decodes the UI markup input (gen-inputs.py `ui`) into Go structs with gokdl2's struct-tag mapping
// (kdl.Unmarshal) and encodes them back with kdl.MarshalWithOptions (Version 2 output).
//
// gokdl2's mapping cannot express an ordered list of heterogeneous child nodes: a `,children` field
// must be a map or a struct, and repeated nodes bind by name to one `,multiple` slice per node name.
// So each window/container holds one slice per child kind, and the order across kinds is lost (the
// order within a kind is kept). Type annotations ((px)) are ignored on read and not written back.
package main

import (
	"fmt"
	"os"
	"strconv"

	kdl "github.com/njreid/gokdl2"
)

type UIDoc struct {
	Windows []Window `kdl:"window,multiple"`
}

type Window struct {
	Title     string      `kdl:",arg"`
	Width     int64       `kdl:"width"`
	Height    int64       `kdl:"height"`
	Resizable bool        `kdl:"resizable"`
	Columns   []Container `kdl:"column,multiple"`
	Rows      []Container `kdl:"row,multiple"`
	Stacks    []Container `kdl:"stack,multiple"`
	Grids     []Container `kdl:"grid,multiple"`
}

type Container struct {
	Spacing     int64 `kdl:"spacing"`
	Padding     int64 `kdl:"padding"`
	GridColumns int64 `kdl:"columns,omitempty"` // grid only

	Columns []Container `kdl:"column,multiple"`
	Rows    []Container `kdl:"row,multiple"`
	Stacks  []Container `kdl:"stack,multiple"`
	Grids   []Container `kdl:"grid,multiple"`

	Labels     []Label    `kdl:"label,multiple"`
	Buttons    []Button   `kdl:"button,multiple"`
	Textboxes  []Textbox  `kdl:"textbox,multiple"`
	Checkboxes []Checkbox `kdl:"checkbox,multiple"`
	Sliders    []Slider   `kdl:"slider,multiple"`
	Images     []Image    `kdl:"image,multiple"`
	Icons      []Icon     `kdl:"icon,multiple"`
	Spacers    []Spacer   `kdl:"spacer,multiple"`
}

type Label struct {
	Text  string `kdl:",arg"`
	Style string `kdl:"style"`
	Size  int64  `kdl:"size"`
}

type Button struct {
	Text    string `kdl:",arg"`
	ID      string `kdl:"id"`
	OnClick string `kdl:"on-click"`
	Enabled bool   `kdl:"enabled"`
}

type Textbox struct {
	ID          string `kdl:"id"`
	Placeholder string `kdl:"placeholder"`
	MaxLength   int64  `kdl:"max-length"`
}

type Checkbox struct {
	Text    string `kdl:",arg"`
	Checked bool   `kdl:"checked"`
}

type Slider struct {
	Min   int64   `kdl:"min"`
	Max   int64   `kdl:"max"`
	Value float64 `kdl:"value"`
	Step  float64 `kdl:"step"`
}

type Image struct {
	Src    string `kdl:"src"`
	Width  int64  `kdl:"width"`
	Height int64  `kdl:"height"`
}

type Icon struct {
	Name string `kdl:",arg"`
	Tint int64  `kdl:"tint"`
}

type Spacer struct {
	Size int64 `kdl:",arg"`
}

func checkContainers(lists [4][]Container, count *int, sum *int64) {
	for k, list := range lists {
		for i := range list {
			c := &list[i]
			*count++
			*sum += c.Spacing + c.Padding
			if k == 3 { // grid
				*sum += c.GridColumns
			}
			checkContainers([4][]Container{c.Columns, c.Rows, c.Stacks, c.Grids}, count, sum)
			for _, w := range c.Labels {
				*count++
				*sum += int64(len(w.Text)) + w.Size
			}
			for _, w := range c.Buttons {
				*count++
				*sum += int64(len(w.ID))
				if w.Enabled {
					*sum++
				}
			}
			for _, w := range c.Textboxes {
				*count++
				*sum += w.MaxLength
			}
			for _, w := range c.Checkboxes {
				*count++
				if w.Checked {
					*sum++
				}
			}
			for _, w := range c.Sliders {
				*count++
				*sum += w.Max + int64(w.Value*1000.0)
			}
			for _, w := range c.Images {
				*count++
				*sum += w.Width + w.Height
			}
			for _, w := range c.Icons {
				*count++
				*sum += w.Tint
			}
			for _, w := range c.Spacers {
				*count++
				*sum += w.Size
			}
		}
	}
}

func checkUI(d *UIDoc) (count int, sum int64) {
	for i := range d.Windows {
		w := &d.Windows[i]
		count++
		sum += w.Width + w.Height
		checkContainers([4][]Container{w.Columns, w.Rows, w.Stacks, w.Grids}, &count, &sum)
	}
	return
}

func runTyped(args []string) {
	if len(args) < 4 {
		fmt.Fprintln(os.Stderr, "usage: kdlbench typed gokdl2 <read|write> <file> <min-samples>")
		os.Exit(2)
	}
	lib, mode := args[0], args[1]
	if lib != "gokdl2" {
		fmt.Fprintln(os.Stderr, "unknown library", lib)
		os.Exit(2)
	}
	if mode != "read" && mode != "write" {
		fmt.Fprintln(os.Stderr, "unknown mode", mode)
		os.Exit(2)
	}
	data, err := os.ReadFile(args[2])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	minSamples, _ := strconv.Atoi(args[3])

	fail := func(what string, err error) {
		fmt.Fprintln(os.Stderr, what+" error:", err)
		os.Exit(1)
	}
	// kdl.Unmarshal parses with automatic version selection (v2 first, v1 only if v2 fails; this
	// input uses #true/#false, so only v2 can accept it); there is no option to force v2 here
	read := func(b []byte) *UIDoc {
		var d UIDoc
		if err := kdl.Unmarshal(b, &d); err != nil {
			fail("unmarshal", err)
		}
		return &d
	}
	opts := kdl.MarshalOptions{GeneratorOptions: kdl.DefaultGenerateOptions}
	opts.GeneratorOptions.Indent = "    "
	opts.GeneratorOptions.Version = 2 // the default output is KDL v1
	write := func(d *UIDoc) []byte {
		out, err := kdl.MarshalWithOptions(d, opts)
		if err != nil {
			fail("marshal", err)
		}
		return out
	}

	doc := read(data)
	count, sum := checkUI(doc)
	fmt.Printf("check: %d %d\n", count, sum)
	out := write(doc)
	if os.Getenv("KDLBENCH_DUMP") != "" {
		_ = os.WriteFile(os.Getenv("KDLBENCH_DUMP"), out, 0o644)
	}
	count2, sum2 := checkUI(read(out))
	fmt.Printf("re-read check: %d %d\n", count2, sum2)

	size := len(data)
	var median float64
	var n int
	var converged bool
	if mode == "read" {
		median, n, converged = measure(minSamples, func() { read(data) })
	} else {
		var buf []byte
		median, n, converged = measure(minSamples, func() { buf = write(doc) })
		size = len(buf)
	}
	ms := median / 1e6
	status := "capped"
	if converged {
		status = "converged"
	}
	fmt.Printf("%.3f ms/op %.1f MB/s (n=%d, %s)\n", ms, float64(size)/1048576.0/(ms/1000.0), n, status)
}
