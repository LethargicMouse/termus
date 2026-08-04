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
running: bool = true,
dirty: bool = true,

pub fn init(io: std.Io) !App {
    const term = try RawTerm.init(io);
    const dir = try std.Io.Dir.openDirAbsolute(io, "/home/gkozirev/music", .{ .iterate = true });
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
    while (app.running) {
        if (app.dirty) {
            try app.draw();
            try app.flush();
        }
        try app.update();
    }
}

fn draw(app: *App) !void {
    try app.term.clearScreen();
    try app.term.moveTo(1, 1);
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
}

fn update(app: *App) !void {
    const minput = try app.term.readByte();
    if (minput) |input| {
        app.dirty = true;
        try app.handleInput(input);
    }
}

fn handleInput(app: *App, input: u8) !void {
    switch (input) {
        'q', 27 => app.running = false,
        'j' => app.cursor = (app.cursor + 1) % 50,
        'k' => app.cursor = (app.cursor + 50 - 1) % 50,
        else => app.dirty = false,
    }
}

fn flush(app: *App) !void {
    try app.term.flush();
    app.dirty = false;
}
