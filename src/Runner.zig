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
engine: *zaudio.Engine,
playing: ?Playing = null,
arena: std.heap.ArenaAllocator,
songs: []const []const u8,
order: []usize,
cursor: usize = 0,
running: bool = true,

pub fn init(io: std.Io, gpa: std.mem.Allocator, args: std.process.Args) !Runner {
    const path = getPathArg(args) orelse "/home/gkozirev/music";
    var app = try App.init(io);
    try app.term.hideCursor();
    const dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);
    const engine = try zaudio.Engine.create(null);
    var arena = std.heap.ArenaAllocator.init(gpa);
    var songs_vec = std.ArrayList([]const u8).empty;
    defer songs_vec.deinit(gpa);
    var iter = dir.iterateAssumeFirstIteration();
    while (try iter.next(io)) |entry| {
        const name = try arena.allocator().dupe(u8, entry.name);
        try songs_vec.append(gpa, name);
    }
    const songs = try arena.allocator().dupe([]const u8, songs_vec.items);
    const order = try arena.allocator().alloc(usize, songs.len);
    for (0..order.len) |i| {
        order[i] = i;
    }
    return .{
        .app = app,
        .arena = arena,
        .path = path,
        .engine = engine,
        .order = order,
        .songs = songs,
    };
}

fn getPathArg(args: std.process.Args) ?[]const u8 {
    var iter = args.iterate();
    _ = iter.skip();
    return iter.next();
}

pub fn deinit(runner: *Runner) void {
    if (runner.playing) |playing| {
        runner.stopPlaying(playing) catch {
            std.log.err("failed to stop `mpv`", .{});
        };
    }
    runner.arena.deinit();
    runner.app.deinit();
    runner.engine.destroy();
    runner.* = undefined;
}

pub fn draw(runner: *Runner) !void {
    const start = try runner.getDrawStart();
    const size = try runner.app.term.getSize();
    const end = start + size.height;
    try runner.app.term.moveTo(1, 1);
    try runner.drawSong(start);
    for (start + 1..@min(end, runner.songs.len)) |i| {
        try runner.app.term.writeAll("\r\n");
        try runner.drawSong(i);
    }
}

fn drawSong(runner: *Runner, i: usize) !void {
    if (runner.cursor == i) {
        try runner.app.term.writeAll(">");
    } else {
        try runner.app.term.writeAll(" ");
    }
    try runner.app.term.print(" {s}", .{runner.songs[i]});
}

pub fn update(runner: *Runner) !void {
    if (runner.playing) |playing| {
        if (playing.sound.isAtEnd()) {
            try runner.stopPlaying(playing);
            try runner.play((playing.id + 1) % runner.songs.len);
        }
    }
}

fn getDrawStart(runner: *Runner) !usize {
    const size = try runner.app.term.getSize();
    const height = size.height;
    if (runner.cursor <= height / 2) {
        return 0;
    }
    if (runner.cursor >= runner.songs.len - height / 2) {
        return runner.songs.len - height;
    }
    return runner.cursor - height / 2;
}

pub fn handleInput(runner: *Runner, input: u8) !void {
    switch (input) {
        'q', 27 => runner.running = false,
        'j' => runner.cursor = (runner.cursor + 1) % runner.songs.len,
        'k' => runner.cursor = (runner.cursor + runner.songs.len - 1) % runner.songs.len,
        'l' => if (runner.playing) |playing| {
            try playing.sound.seekToSecond(5 + try playing.sound.getCursorInSeconds());
        },
        ' ' => try runner.togglePlay(),
        else => runner.app.dirty = false,
    }
}

fn togglePlay(runner: *Runner) !void {
    if (runner.playing) |playing| {
        if (playing.id != runner.cursor) {
            try runner.stopPlaying(playing);
            runner.shuffle(runner.cursor);
            try runner.play(0);
            return;
        }
        if (playing.sound.isPlaying()) {
            try pausePlaying(playing);
        } else {
            try resumePlaying(playing);
        }
    } else {
        runner.shuffle(runner.cursor);
        try runner.play(0);
    }
}

fn shuffle(runner: *Runner, id: usize) void {
    for (0..runner.order.len) |i| {
        runner.order[i] = i;
    }
    std.mem.swap(usize, &runner.order[0], &runner.order[id]);
    for (1..runner.order.len) |i| {
        var rand = std.Random.DefaultPrng.init(0);
        const random = rand.next() % (runner.order.len - 1) + 1;
        std.mem.swap(usize, &runner.order[i], &runner.order[random]);
    }
}

fn resumePlaying(playing: Playing) !void {
    try playing.sound.start();
}

fn pausePlaying(playing: Playing) !void {
    try playing.sound.stop();
}

fn stopPlaying(runner: *Runner, playing: Playing) !void {
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
    const name = runner.songs[runner.order[id]];
    @memcpy(buffer[runner.path.len + 1 ..][0..name.len], name);
    buffer[runner.path.len + 1 + name.len] = 0;
    return buffer[0 .. runner.path.len + 1 + name.len :0];
}
