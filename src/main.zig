const std = @import("std");

pub fn main(init: std.process.Init) !u8 {
    run(init) catch |err| switch (err) {
        else => return err,
    };
    return 0;
}

fn run(init: std.process.Init) !void {
    _ = init;
}
