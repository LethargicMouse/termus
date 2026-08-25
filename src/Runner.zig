const std = @import("std");

const rt = @import("raw_term");
const zaudio = @import("zaudio");

const Playing = struct {
    sound: *zaudio.Sound,
    id: usize,
    now: u16 = 0,
    total: u16,
};

const Runner = @This();

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
        .arena = arena,
        .prng = prng,
        .path = path,
        .engine = engine,
        .order = order,
        .songs = songs,
    };
}

pub fn start(_: Runner, term: *rt.RawTerm) !void {
    try term.hideCursor();
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
    runner.engine.destroy();
    runner.* = undefined;
}

pub fn draw(runner: *Runner, term: *rt.RawTerm) !void {
    const from = try runner.getDrawStart(term.size.height);
    const height = term.size.height;
    const end = from + height;
    try term.goto(1, 1);
    try runner.drawSong(from, term);
    for (from + 1..@min(end, runner.songs.len)) |i| {
        try term.writeAll("\r\n");
        try runner.drawSong(i, term);
        try runner.drawBar(i, term);
    }
    if (runner.playing) |playing| {
        try runner.drawPlaying(playing, term);
    }

    try drawHelp(term);
}

fn drawHelp(term: *rt.RawTerm) !void {
    const x = getBarsX(term.size.width) + 3;
    var y = term.size.height - 1;
    try term.goto(x, y);
    try term.writeAll(
        "[/] - next/prev song | h/l - back/forward 5 secs | j/k - go down/up",
    );
    y -= 1;
    try term.goto(x, y);
    try term.writeAll("q - exit | r - random | space - play/pause | p - pause/play");
}

fn drawPlaying(runner: *Runner, playing: Playing, term: *rt.RawTerm) !void {
    const width = term.size.width;
    const x = getBarsX(width) + 3;
    var y: u16 = 2;
    try term.goto(x, y);
    const name = runner.songs[runner.order[playing.id]];
    try term.setDisplay(&.{.bold});
    try term.writeAll(name);
    y += 1;
    try term.goto(x, y);
    try term.print(
        "{d:0>2}:{d:0>2} / {d:0>2}:{d:0>2} ",
        .{ playing.now / 60, playing.now % 60, playing.total / 60, playing.total % 60 },
    );
    try term.writeByte('[');
    const len = width / 4;
    const frac = playing.now * len / playing.total;
    for (0..frac) |_| {
        try term.writeByte('=');
    }
    try term.go(.right, len - frac);
    try term.writeByte(']');
    try term.setDisplay(&.{.reset});
}

fn drawSong(runner: *Runner, i: usize, term: *rt.RawTerm) !void {
    const cursored = runner.cursor == i;
    const color = runner.getSongColor(i);
    try term.setDisplay(&.{
        .{ .fg = color },
    });
    if (cursored) {
        try term.setDisplay(&.{.bold});
        try term.writeAll(">");
    } else {
        try term.writeAll(" ");
    }
    const width = term.size.width;
    const len = @min(runner.songs[i].len, getBarsX(width) - 5 - 3);
    try term.print(" {s}", .{runner.songs[i][0..len]});
}

fn getSongColor(runner: Runner, i: usize) rt.RawTerm.ansi.Color {
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

fn drawBar(runner: *Runner, i: usize, term: *rt.RawTerm) !void {
    const width = term.size.width;
    const need = getBarsX(width);
    const now = @min(runner.songs[i].len + 3, need - 5);
    const shift = need - now;
    try term.go(.right, shift);
    try term.writeByte('|');
    try term.setDisplay(&.{.reset});
}

pub fn update(runner: *Runner, _: *rt.App) !bool {
    if (runner.playing) |*playing| {
        if (playing.sound.isAtEnd()) {
            try runner.playNext(playing.*);
            return true;
        }
        const now: u16 = @floor(try playing.sound.getCursorInSeconds());
        if (playing.now != now) {
            playing.now = now;
            return true;
        }
    }
    return false;
}

fn playNext(runner: *Runner, playing: Playing) !void {
    try runner.stopPlaying(playing);
    const next = (playing.id + 1) % runner.songs.len;
    try runner.play(next);
}

fn getDrawStart(runner: *Runner, height: u16) !usize {
    if (runner.cursor <= height / 2) {
        return 0;
    }
    if (runner.cursor >= runner.songs.len - height / 2) {
        return runner.songs.len - height;
    }
    return runner.cursor - height / 2;
}

pub fn handleInput(runner: *Runner, input: u8, _: *rt.App) !bool {
    switch (input) {
        'q', 27 => runner.running = false,
        'j' => runner.cursor = (runner.cursor + 1) % runner.songs.len,
        'k' => runner.cursor = (runner.cursor + runner.songs.len - 1) % runner.songs.len,
        ' ' => try runner.togglePlay(),
        'r' => try runner.playRandom(),
        else => if (runner.playing) |playing| {
            return runner.handleInputPlaying(input, playing);
        } else return false,
    }
    return true;
}

fn handleInputPlaying(runner: *Runner, input: u8, playing: Playing) !bool {
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
        else => return false,
    }
    return true;
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
