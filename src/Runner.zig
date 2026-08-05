const std = @import("std");

const App = @import("App.zig");

const Runner = @This();

app: App,
dir: std.Io.Dir,
entry_count: usize,
cursor: usize = 0,
running: bool = true,

pub fn init(io: std.Io) !Runner {
    var app = try App.init(io);
    try app.term.hideCursor();
    const dir = try std.Io.Dir.openDirAbsolute(io, "/home/gkozirev/music", .{ .iterate = true });
    var entry_count: usize = 0;
    var iter = dir.iterateAssumeFirstIteration();
    while (try iter.next(io)) |_| {
        entry_count += 1;
    }
    return .{
        .app = app,
        .dir = dir,
        .entry_count = entry_count,
    };
}

pub fn deinit(runner: *Runner) void {
    runner.dir.close(runner.app.io);
    runner.app.deinit();
    runner.* = undefined;
}

pub fn draw(runner: *Runner) !void {
    try runner.app.term.moveTo(1, 1);
    var iter = runner.dir.iterate();
    var i: usize = 0;
    while (try iter.next(runner.app.io)) |entry| : (i += 1) {
        if (i == 50) break; // tmp
        if (runner.cursor == i) {
            try runner.app.term.writeAll(">");
        } else {
            try runner.app.term.writeAll(" ");
        }
        try runner.app.term.print(" {s}\r\n", .{entry.name});
    }
}

pub fn handleInput(runner: *Runner, input: u8) !void {
    switch (input) {
        'q', 27 => runner.running = false,
        'j' => runner.cursor = (runner.cursor + 1) % 50,
        'k' => runner.cursor = (runner.cursor + 50 - 1) % 50,
        else => runner.app.dirty = false,
    }
}
