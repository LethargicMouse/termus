const std = @import("std");

const App = @import("App.zig");

const Playing = struct {
    child: std.process.Child,
    id: usize,
    paused: bool = false,
};

const Runner = @This();

app: App,
dir: std.Io.Dir,
playing: ?Playing = null,
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
    if (runner.playing) |*playing| {
        runner.stopPlaying(playing) catch {
            std.log.err("failed to stop `mpv`", .{});
        };
    }
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
        ' ' => try runner.togglePlay(),
        else => runner.app.dirty = false,
    }
}

fn togglePlay(runner: *Runner) !void {
    if (runner.playing) |*playing| {
        if (playing.id != runner.cursor) {
            try runner.stopPlaying(playing);
            try runner.play();
            return;
        }
        if (playing.paused) {
            try resumePlaying(playing);
        } else {
            try pausePlaying(playing);
        }
    } else {
        try runner.play();
    }
}

fn resumePlaying(playing: *Playing) !void {
    try std.posix.kill(playing.child.id.?, .CONT);
    playing.paused = false;
}

fn pausePlaying(playing: *Playing) !void {
    try std.posix.kill(playing.child.id.?, .STOP);
    playing.paused = true;
}

fn stopPlaying(runner: *Runner, playing: *Playing) !void {
    if (playing.paused) {
        try resumePlaying(playing);
    }
    playing.child.kill(runner.app.io);
    runner.playing = null;
}

fn play(runner: *Runner) !void {
    var buffer: [256]u8 = undefined;
    const current = try runner.getCurrent(&buffer);
    const child = try std.process.spawn(runner.app.io, .{
        .argv = &.{ "mpv", "--no-video", current },
        .cwd = .{ .dir = runner.dir },
        .stdin = .ignore,
        .stderr = .ignore,
        .stdout = .ignore,
    });
    runner.playing = .{
        .child = child,
        .id = runner.cursor,
    };
}

fn getCurrent(runner: *Runner, buffer: []u8) ![]const u8 {
    var iter = runner.dir.iterate();
    var i: usize = 0;
    while (try iter.next(runner.app.io)) |entry| : (i += 1) {
        if (i == runner.cursor) {
            // it remains valid until `next` is called again so it's ok
            @memcpy(buffer[0..entry.name.len], entry.name);
            return buffer[0..entry.name.len];
        }
    }
    return error.CursorOutOfScope;
}
