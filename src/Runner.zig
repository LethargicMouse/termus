const std = @import("std");

const RawTerm = @import("raw_term").RawTerm;
const zaudio = @import("zaudio");

const App = @import("App.zig");

const Playing = struct {
    sound: *zaudio.Sound,
    id: usize,
    now: u16 = 0,
    total: u16,
};

const Runner = @This();

app: App,
path: []const u8,
engine: *zaudio.Engine,
playing: ?Playing = null,
arena: std.heap.ArenaAllocator,
prng: std.Random.DefaultPrng,
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
    var seed: u64 = undefined;
    io.random(std.mem.asBytes(&seed));
    const prng = std.Random.DefaultPrng.init(seed);
    return .{
        .app = app,
        .arena = arena,
        .prng = prng,
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
    const height = runner.app.term.size.height;
    const end = start + height;
    try runner.app.term.goto(1, 1);
    try runner.drawSong(start);
    for (start + 1..@min(end, runner.songs.len)) |i| {
        try runner.app.term.writeAll("\r\n");
        try runner.drawSong(i);
        try runner.drawBar(i);
    }
    if (runner.playing) |playing| {
        try runner.drawPlaying(playing);
    }

    try runner.drawHelp();
}

fn drawHelp(runner: *Runner) !void {
    const x = getBarsX(runner.app.term.size.width) + 3;
    var y = runner.app.term.size.height - 1;
    try runner.app.term.goto(x, y);
    try runner.app.term.writeAll(
        "[/] - next/prev song | h/l - back/forward 5 secs | j/k - go down/up",
    );
    y -= 1;
    try runner.app.term.goto(x, y);
    try runner.app.term.writeAll("q - exit | r - random | space - play/pause | p - pause/play");
}

fn drawPlaying(runner: *Runner, playing: Playing) !void {
    const width = runner.app.term.size.width;
    const x = getBarsX(width) + 3;
    var y: u16 = 2;
    try runner.app.term.goto(x, y);
    const name = runner.songs[runner.order[playing.id]];
    try runner.app.term.setColor(.default, true);
    try runner.app.term.writeAll(name);
    y += 1;
    try runner.app.term.goto(x, y);
    try runner.app.term.print(
        "{d:0>2}:{d:0>2} / {d:0>2}:{d:0>2} ",
        .{ playing.now / 60, playing.now % 60, playing.total / 60, playing.total % 60 },
    );
    try runner.app.term.writeByte('[');
    const len = width / 4;
    const frac = playing.now * len / playing.total;
    for (0..frac) |_| {
        try runner.app.term.writeByte('=');
    }
    try runner.app.term.go(.right, len - frac);
    try runner.app.term.writeByte(']');
    try runner.app.term.setColor(.default, false);
}

fn drawSong(runner: *Runner, i: usize) !void {
    const cursored = runner.cursor == i;
    const bold = cursored;
    const color = runner.getSongColor(i);
    try runner.app.term.setColor(color, bold);
    if (cursored) {
        try runner.app.term.writeAll(">");
    } else {
        try runner.app.term.writeAll(" ");
    }
    const width = runner.app.term.size.width;
    const len = @min(runner.songs[i].len, getBarsX(width) - 5 - 3);
    try runner.app.term.print(" {s}", .{runner.songs[i][0..len]});
}

fn getSongColor(runner: Runner, i: usize) RawTerm.Color {
    if (runner.playing) |playing| {
        if (runner.order[playing.id] == i) {
            return .white;
        }
    }
    return .default;
}

fn getBarsX(width: u16) u16 {
    return width / 3;
}

fn drawBar(runner: *Runner, i: usize) !void {
    const width = runner.app.term.size.width;
    const need = getBarsX(width);
    const now = @min(runner.songs[i].len + 3, need - 5);
    const shift = need - now;
    try runner.app.term.go(.right, shift);
    try runner.app.term.writeByte('|');
}

pub fn update(runner: *Runner) !void {
    if (runner.playing) |*playing| {
        if (playing.sound.isAtEnd()) {
            try runner.playNext(playing.*);
            runner.app.dirty = true;
        } else {
            const now: u16 = @floor(try playing.sound.getCursorInSeconds());
            if (playing.now != now) {
                playing.now = now;
                runner.app.dirty = true;
            }
        }
    }
}

fn playNext(runner: *Runner, playing: Playing) !void {
    try runner.stopPlaying(playing);
    const next = (playing.id + 1) % runner.songs.len;
    try runner.play(next);
}

fn getDrawStart(runner: *Runner) !usize {
    const height = runner.app.term.size.height;
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
        ' ' => try runner.togglePlay(),
        'r' => try runner.playRandom(),
        else => runner.app.dirty = false,
    }
    if (runner.app.dirty) {
        return;
    }
    if (runner.playing) |playing| {
        runner.app.dirty = true;
        switch (input) {
            'p' => if (playing.sound.isPlaying()) {
                try pausePlaying(playing);
            } else {
                try resumePlaying(playing);
            },
            'h' => try playing.sound.seekToSecond(playing.now -| 5),
            'l' => try playing.sound.seekToSecond(playing.now + 5),
            ']' => try runner.playNext(playing),
            '[' => {
                try runner.stopPlaying(playing);
                try runner.play(playing.id -| 1);
            },
            else => runner.app.dirty = false,
        }
    }
}

fn togglePlay(runner: *Runner) !void {
    if (runner.playing) |playing| {
        if (runner.order[playing.id] != runner.cursor) {
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
    runner.prng.random().shuffle(usize, runner.order[1..]);
}

fn playRandom(runner: *Runner) !void {
    const id = runner.prng.random().intRangeLessThan(usize, 0, runner.songs.len);
    runner.shuffle(id);
    try runner.play(0);
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
    const total: u16 = @floor(try sound.getLengthInSeconds());
    try sound.start();
    runner.playing = .{
        .sound = sound,
        .id = id,
        .total = total,
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
