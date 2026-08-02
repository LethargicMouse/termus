const std = @import("std");

const App = @import("App.zig");

pub fn main(init: std.process.Init) !u8 {
    run(init) catch |err| switch (err) {
        else => return err,
    };
    return 0;
}

fn run(init: std.process.Init) !void {
    var app = try App.init(init.io);
    defer app.deinit();
    try app.run();
}
