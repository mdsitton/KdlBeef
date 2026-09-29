# KDL implementations compared

Produced by run.sh on 2026-09-29 (Linux x86-64, single thread; pinned versions in fetch.sh). Inputs from gen-inputs.py; html-standard and html-standard-compact are the kdl-org/kdl benchmark documents. FAIL = parse error or a node count that differs from the reference; DNF = past 60 s; n/a = no writer.

The KdlBeef columns come from a later run on the same machine with the same rule (`ONLY="KdlBeef|KdlBeef events" ./run.sh`, after the stream cursor landed): **KdlBeef** reads into a `KdlDocument` and writes it canonically; **KdlBeef events** is a pass of the `KdlReader` over every event, with no document (the counterpart of ckdl's C core). Both read from memory.

### Parsing (MB/s of input, higher is better)

| input | KdlBeef | KdlBeef events | ckdl | kdlpp | kdl-rs | gokdl2 | kdly | kdl4j | @bgotink/kdl | kdljs | KdlSharp | ckdl (Python) | kdl-py | zig-kdl |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| ui | 250.2 | 320.2 | 46.2 | 29.8 | 3.4 | FAIL | 27.2 | 22.7 | 14.7 | 6.8 | 19.4 | 21.5 | 0.6 | FAIL |
| config | 209.4 | 299.3 | 32.6 | 22.6 | 2.4 | FAIL | 21.8 | 20.7 | 12.2 | 5.4 | 13.1 | 14.9 | 0.4 | 1.1 |
| strings | 290.6 | 341.3 | 37.6 | 33.7 | 2.3 | 39.5 | 48.1 | 34.2 | 17.5 | 12.6 | 29.7 | 23.9 | 0.5 | 1.8 |
| numbers | 138.9 | 178.3 | 48.9 | 32.1 | 3.1 | FAIL | 20.1 | 17.4 | 12.0 | 6.2 | 14.5 | 25.3 | 0.5 | 3.6 |
| html-standard | 233.1 | 305.7 | 37.6 | 23.0 | 2.4 | FAIL | 27.6 | 20.2 | 11.8 | 5.3 | 16.5 | 14.9 | DNF | FAIL |
| html-standard-compact | 232.0 | 311.2 | 38.3 | 23.6 | 2.5 | FAIL | 29.2 | 22.2 | 13.4 | 5.7 | 16.4 | 15.8 | DNF | FAIL |

### Writing a parsed document (MB/s of output, higher is better)

| input | KdlBeef | KdlBeef events | ckdl | kdlpp | kdl-rs | gokdl2 | kdly | kdl4j | @bgotink/kdl | kdljs | KdlSharp | ckdl (Python) | kdl-py | zig-kdl |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| ui | 329.9 | n/a | n/a | 99.8 | 127.0 | FAIL | 51.9 | 54.4 | 97.1 | 32.7 | 161.3 | 60.2 | 2.7 | n/a |
| config | 375.3 | n/a | n/a | 94.4 | 119.6 | FAIL | 48.0 | 60.4 | 73.4 | 20.4 | 140.0 | 48.2 | 2.4 | n/a |
| strings | 471.1 | n/a | n/a | 83.8 | 356.0 | 143.2 | 140.6 | 67.7 | 310.7 | 13.0 | 159.1 | 68.3 | 10.0 | n/a |
| numbers | 321.1 | n/a | n/a | 65.7 | 112.2 | FAIL | 36.6 | 151.8 | 71.5 | 44.8 | 93.1 | 40.0 | 6.3 | n/a |
| html-standard | 403.2 | n/a | n/a | 101.9 | 79.8 | FAIL | 71.0 | 41.7 | 73.3 | 24.6 | 231.8 | 81.7 | DNF | n/a |
| html-standard-compact | 406.6 | n/a | n/a | 99.1 | 89.5 | FAIL | 73.8 | 45.5 | 87.7 | 19.6 | 183.7 | 72.6 | 3.9 | n/a |
