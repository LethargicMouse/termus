const std = @import("std");

const zaudio = @import("zaudio");

const rt = @import("raw_term");

const Runner = @import("Runner.zig");

pub fn main(init: std.process.Init) !u8 {
    run(init) catch |err| switch (err) {
        else => return err,
    };
    return 0;
}

fn run(init: std.process.Init) !void {
    zaudio.init(init.gpa);
    defer zaudio.deinit();

    var app = try rt.App.init(init.io, init.gpa);
    defer app.deinit();

    var runner = try Runner.init(init.io, init.gpa, init.minimal.args);
    defer runner.deinit();

    try app.run(&runner);
}
