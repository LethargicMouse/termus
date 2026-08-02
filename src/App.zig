const std = @import("std");

const RawTerm = @import("raw_term").RawTerm;

const Song = struct {
    name: []const u8,
};

const App = @This();

term: RawTerm,
songs: []const Song,
songs_arena: std.heap.ArenaAllocator,
cursor: usize = 0,
is_running: bool = true,

pub fn init(io: std.Io, gpa: std.mem.Allocator) !App {
    const term = try RawTerm.init(io);
    var songs_arena = std.heap.ArenaAllocator.init(gpa);
    const songs = try getMusic(io, gpa, &songs_arena);
    return .{
        .term = term,
        .songs = songs,
        .songs_arena = songs_arena,
    };
}

fn getMusic(
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
) ![]const Song {
    var dir = try std.Io.Dir.openDirAbsolute(io, "/home/gkozirev/music/all/", .{ .iterate = true });
    defer dir.close(io);
    var vec = std.ArrayList(Song).empty;
    defer vec.deinit(gpa);
    var iter = dir.iterateAssumeFirstIteration();
    while (try iter.next(io)) |entry| {
        if (entry.kind == .file) {
            const name = try arena.allocator().alloc(u8, entry.name.len);
            @memcpy(name, entry.name);
            try vec.append(gpa, .{
                .name = name,
            });
        }
    }
    const songs = try arena.allocator().alloc(Song, vec.items.len);
    @memcpy(songs, vec.items);
    return songs;
}

pub fn deinit(app: *App) void {
    app.term.deinit();
    app.songs_arena.deinit();
    app.* = undefined;
}

pub fn run(app: *App) !void {
    try app.term.hideCursor();
    while (app.is_running) {
        try app.draw();
        try app.update();
    }
}

fn draw(app: *App) !void {
    try app.term.clearScreen();
    for (app.songs[0..50], 0..) |song, i| {
        if (app.cursor == i) {
            try app.term.writeAll(">");
        } else {
            try app.term.writeAll(" ");
        }
        try app.term.print(" {s}\r\n", .{song.name});
    }
    try app.term.flush();
}

fn update(app: *App) !void {
    const input = try app.term.readByte();
    switch (input) {
        'q', 27 => app.is_running = false,
        'j' => app.cursor = (app.cursor + 1) % 50,
        'k' => app.cursor = (app.cursor + 50 - 1) % 50,
        else => {},
    }
}

