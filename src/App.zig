const std = @import("std");

const RawTerm = @import("raw_term").RawTerm;

const Song = struct {
    name: []const u8,
};

const App = @This();

io: std.Io,
term: RawTerm,
dir: std.Io.Dir,
entry_count: usize,
cursor: usize = 0,
is_running: bool = true,

pub fn init(io: std.Io) !App {
    const term = try RawTerm.init(io);
    const dir = try std.Io.Dir.openDirAbsolute(io, "/home/gkozirev/music/all", .{ .iterate = true });
    var entry_count: usize = 0;
    var iter = dir.iterateAssumeFirstIteration();
    while (try iter.next(io)) |_| {
        entry_count += 1;
    }
    return .{
        .io = io,
        .term = term,
        .dir = dir,
        .entry_count = entry_count,
    };
}

pub fn deinit(app: *App) void {
    app.term.deinit();
    app.dir.close(app.io);
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
    var iter = app.dir.iterate();
    var i: usize = 0;
    while (try iter.next(app.io)) |entry| : (i += 1) {
        if (i == 50) break; // tmp
        if (app.cursor == i) {
            try app.term.writeAll(">");
        } else {
            try app.term.writeAll(" ");
        }
        try app.term.print(" {s}\r\n", .{entry.name});
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
