const std = @import("std");

const RawTerm = @import("raw_term").RawTerm;

const Song = struct {
    name: []const u8,
};

const App = @This();

io: std.Io,
term: RawTerm,
dirty: bool = true,

pub fn init(io: std.Io) !App {
    const term = try RawTerm.init(io);
    return .{
        .io = io,
        .term = term,
    };
}

pub fn deinit(app: *App) void {
    app.term.deinit();
    app.* = undefined;
}
