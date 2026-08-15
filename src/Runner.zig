const std = @import("std");

const zaudio = @import("zaudio");

const App = @import("App.zig");

const Playing = struct {
    sound: *zaudio.Sound,
    id: usize,
};

const Runner = @This();

app: App,
path: []const u8,
dir: std.Io.Dir,
engine: *zaudio.Engine,
playing: ?Playing = null,
entry_count: usize,
cursor: usize = 0,
running: bool = true,

pub fn init(io: std.Io, args: std.process.Args) !Runner {
    const path = getPathArg(args) orelse "/home/gkozirev/music";
    var app = try App.init(io);
    try app.term.hideCursor();
    const dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    var entry_count: usize = 0;
    var iter = dir.iterateAssumeFirstIteration();
    while (try iter.next(io)) |_| {
        entry_count += 1;
    }
    const engine = try zaudio.Engine.create(null);
    return .{
        .app = app,
        .path = path,
        .dir = dir,
        .entry_count = entry_count,
        .engine = engine,
    };
}

fn getPathArg(args: std.process.Args) ?[]const u8 {
    var iter = args.iterate();
    _ = iter.skip();
    return iter.next();
}

pub fn deinit(runner: *Runner) void {
    if (runner.playing) |*playing| {
        runner.stopPlaying(playing) catch {
            std.log.err("failed to stop `mpv`", .{});
        };
    }
    runner.dir.close(runner.app.io);
    runner.app.deinit();
    runner.engine.destroy();
    runner.* = undefined;
}

pub fn draw(runner: *Runner) !void {
    var iter = runner.dir.iterate();
    const start = try runner.getDrawStart();
    const size = try runner.app.term.getSize();
    const end = start + size.height;
    var i: usize = 0;
    while (i != start) : (i += 1) {
        _ = try iter.next(runner.app.io);
    }
    try runner.app.term.moveTo(1, 1);
    while (try iter.next(runner.app.io)) |entry| : (i += 1) {
        if (i == end) break;
        if (i != start) {
            try runner.app.term.writeAll("\r\n");
        }
        if (runner.cursor == i) {
            try runner.app.term.writeAll(">");
        } else {
            try runner.app.term.writeAll(" ");
        }
        try runner.app.term.print(" {s}", .{entry.name});
    }
}

pub fn update(runner: *Runner) !void {
    if (runner.playing) |*playing| {
        if (playing.sound.isAtEnd()) {
            try runner.stopPlaying(playing);
            try runner.play((playing.id + 1) % runner.entry_count);
        }
    }
}

fn getDrawStart(runner: *Runner) !usize {
    const size = try runner.app.term.getSize();
    const height = size.height;
    if (runner.cursor <= height / 2) {
        return 0;
    }
    if (runner.cursor >= runner.entry_count - height / 2) {
        return runner.entry_count - height;
    }
    return runner.cursor - height / 2;
}

pub fn handleInput(runner: *Runner, input: u8) !void {
    switch (input) {
        'q', 27 => runner.running = false,
        'j' => runner.cursor = (runner.cursor + 1) % runner.entry_count,
        'k' => runner.cursor = (runner.cursor + runner.entry_count - 1) % runner.entry_count,
        ' ' => try runner.togglePlay(),
        else => runner.app.dirty = false,
    }
}

fn togglePlay(runner: *Runner) !void {
    if (runner.playing) |*playing| {
        if (playing.id != runner.cursor) {
            try runner.stopPlaying(playing);
            try runner.play(runner.cursor);
            return;
        }
        if (playing.sound.isPlaying()) {
            try pausePlaying(playing);
        } else {
            try resumePlaying(playing);
        }
    } else {
        try runner.play(runner.cursor);
    }
}

fn resumePlaying(playing: *Playing) !void {
    try playing.sound.start();
}

fn pausePlaying(playing: *Playing) !void {
    try playing.sound.stop();
}

fn stopPlaying(runner: *Runner, playing: *Playing) !void {
    playing.sound.destroy();
    runner.playing = null;
}

fn play(runner: *Runner, id: usize) !void {
    var buffer: [256]u8 = undefined;
    const path = try runner.getPath(id, &buffer);
    const sound = try runner.engine.createSoundFromFile(path, .{ .flags = .{
        .stream = true,
    } });
    try sound.start();
    runner.playing = .{
        .sound = sound,
        .id = id,
    };
}

fn getPath(runner: *Runner, id: usize, buffer: []u8) ![:0]const u8 {
    @memcpy(buffer[0..runner.path.len], runner.path);
    buffer[runner.path.len] = '/';
    const name_len = try runner.getEntryName(id, buffer[runner.path.len + 1 ..]);
    return buffer[0 .. runner.path.len + 1 + name_len :0];
}

fn getEntryName(runner: *Runner, id: usize, buffer: []u8) !usize {
    var iter = runner.dir.iterate();
    var i: usize = 0;
    while (try iter.next(runner.app.io)) |entry| : (i += 1) {
        if (i == id) {
            // it remains valid until `next` is called again so it's ok
            @memcpy(buffer[0..entry.name.len], entry.name);
            buffer[entry.name.len] = 0;
            return entry.name.len;
        }
    }
    return error.CursorOutOfScope;
}
