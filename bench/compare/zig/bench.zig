// zig-kdl benchmark: zig-kdl parse <file> <min-samples>
// zig-kdl is a pull (event) parser with no document: one parse runs Parser.next to the end of the input,
// touching every event (payloads are raw source slices). Prints the node count as a check line. It has
// no writer, so there is no write mode. Built with -O ReleaseFast.
const std = @import("std");
const kdl = @import("kdl");

const Measurement = struct { median_ns: f64, samples: usize, converged: bool };

/// The shared rule (see ../run.sh): warm up for at least 1 s, then time single runs until at least
/// `min_samples` were taken and at least 60% lie within ±10% of their median, or 10 s / 1000 samples.
fn measure(io: std.Io, gpa: std.mem.Allocator, min_samples: usize, context: anytype, comptime op: fn (@TypeOf(context)) void) !Measurement {
    const warm = std.Io.Timestamp.now(io, .awake);
    while (true) {
        op(context);
        if (warm.untilNow(io, .awake).nanoseconds >= std.time.ns_per_s) break;
    }
    var samples: std.ArrayList(f64) = .empty;
    defer samples.deinit(gpa);
    var sorted: std.ArrayList(f64) = .empty;
    defer sorted.deinit(gpa);
    const start = std.Io.Timestamp.now(io, .awake);
    while (true) {
        const t0 = std.Io.Timestamp.now(io, .awake);
        op(context);
        try samples.append(gpa, @floatFromInt(t0.untilNow(io, .awake).nanoseconds));
        sorted.clearRetainingCapacity();
        try sorted.appendSlice(gpa, samples.items);
        std.mem.sort(f64, sorted.items, {}, std.sort.asc(f64));
        const n = sorted.items.len;
        const median = if (n % 2 == 1) sorted.items[n / 2] else (sorted.items[n / 2 - 1] + sorted.items[n / 2]) / 2;
        if (n >= min_samples) {
            var within: usize = 0;
            for (samples.items) |s| {
                if (s >= median * 0.9 and s <= median * 1.1) within += 1;
            }
            if (@as(f64, @floatFromInt(within)) >= 0.6 * @as(f64, @floatFromInt(n)))
                return .{ .median_ns = median, .samples = n, .converged = true };
        }
        if (n >= 1000 or start.untilNow(io, .awake).nanoseconds >= 10 * std.time.ns_per_s)
            return .{ .median_ns = median, .samples = n, .converged = false };
    }
}

const Context = struct { text: [:0]const u8, nodes: usize = 0, failed: bool = false };

fn parseAll(ctx: *Context) void {
    var parser = kdl.Parser.init(ctx.text);
    var nodes: usize = 0;
    while (true) {
        const event = parser.next() catch {
            ctx.failed = true;
            return;
        };
        switch (event) {
            .node => nodes += 1,
            .invalid => {
                ctx.failed = true;
                return;
            },
            .eof => break,
            else => {},
        }
    }
    ctx.nodes = nodes;
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 4 or !std.mem.eql(u8, args[1], "parse")) {
        std.debug.print("usage: zig-kdl parse <file> <min-samples>\n", .{});
        std.process.exit(if (args.len >= 2 and std.mem.eql(u8, args[1], "write")) 3 else 2);
    }
    const io = init.io;
    const gpa = init.gpa;
    const raw = try std.Io.Dir.cwd().readFileAlloc(io, args[2], gpa, .unlimited);
    defer gpa.free(raw);
    const text = try gpa.dupeZ(u8, raw);
    defer gpa.free(text);
    const min_samples = try std.fmt.parseInt(usize, args[3], 10);

    var ctx: Context = .{ .text = text };
    parseAll(&ctx);
    if (ctx.failed) {
        std.debug.print("parse error (zig-kdl reports only an invalid event)\n", .{});
        std.process.exit(1);
    }
    std.debug.print("nodes: {d}\n", .{ctx.nodes});
    const m = try measure(io, gpa, min_samples, &ctx, parseAll);
    const ms = m.median_ns / 1e6;
    const mbps = @as(f64, @floatFromInt(text.len)) / 1048576.0 / (ms / 1000.0);
    std.debug.print("{d:.3} ms/op {d:.1} MB/s (n={d}, {s})\n", .{ ms, mbps, m.samples, if (m.converged) "converged" else "capped" });
}
