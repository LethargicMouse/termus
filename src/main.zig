const std = @import("std");

const runApp = @import("raw_term").runApp;

const Runner = @import("Runner.zig");

pub fn main(init: std.process.Init) !u8 {
    run(init) catch |err| switch (err) {
        else => return err,
    };
    return 0;
}

fn run(init: std.process.Init) !void {
    var runner = try Runner.init(init.io, init.minimal.args);
    defer runner.deinit();
    try runApp(&runner);
}
