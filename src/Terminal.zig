const std = @import("std");

const Self = @This();

pub const Writer = std.io.Writer(*Self, std.io.AnyWriter.Error, write);

pub const Color = enum(u8) {
    // The sequence that defines the color in the terminal
    const Sequence = "\x1b[{s}m";
    const ForegroundOffset = 30;
    const BackgroundOffset = 40;

    black = 0,
    red = 1,
    green = 2,
    yellow = 3,
    blue = 4,
    magenta = 5,
    cyan = 6,
    white = 7,
    /// `inherit` keeps the color of the terminal the same; this is the default state
    inherit = 0xff,
};
/// The stream we write to
stream: std.io.AnyWriter,
/// The current color definitions
bg: Color = .inherit,
fg: Color = .inherit,

/// Initialzes a terminal with the given writer
pub fn init(stream: std.io.AnyWriter) Self {
    return .{ .stream = stream };
}

/// Writes the sequence into the provided stream
fn printSequence(self: *Self, format: []const u8) !void {
    try self.stream.print(Color.Sequence, .{format});
}

/// Clears the terminal
pub fn clear(self: *Self) !void {
    try self.writeCustom("\x1B[2J\x1B[H");
}

/// Resets the terminal via a reset sequence
pub fn reset(self: *Self) !void {
    try self.writeCustom("\x1B[0m");
}

pub fn setBackground(self: *Self, color: Color) !void {
    self.bg = color;
    var buf = [_]u8{0} ** 2;
    const fmt = try std.fmt.bufPrint(&buf, "{d}", .{Color.BackgroundOffset + @intFromEnum(color)});
    try self.printSequence(fmt);
}

pub fn setForeground(self: *Self, color: Color) !void {
    self.fg = color;
    var buf = [_]u8{0} ** 2;
    const fmt = try std.fmt.bufPrint(&buf, "{d}", .{Color.ForegroundOffset + @intFromEnum(color)});
    try self.printSequence(fmt);
}

pub fn writeCustom(self: *Self, bytes: []const u8) !void {
    _ = try self.stream.write(bytes);
}

pub fn info(self: *Self, comptime fmt: []const u8, args: anytype) !void {
    try self.print("[info] " ++ fmt, args, .{ .fg = .cyan });
}

pub fn err(self: *Self, comptime fmt: []const u8, args: anytype) !void {
    try self.print("[err] " ++ fmt, args, .{ .fg = .red });
}

const PrintOptions = struct { bg: Color = .inherit, fg: Color = .inherit };

pub fn print(self: *Self, comptime fmt: []const u8, args: anytype, opts: PrintOptions) !void {
    var changed: bool = false;
    if (opts.bg != .inherit) {
        try self.setBackground(opts.bg);
        changed = true;
    }
    if (opts.fg != .inherit) {
        try self.setForeground(opts.fg);
        changed = true;
    }

    try self.writer().print(fmt, args);

    if (changed) try self.reset();
}

pub fn write(self: *Self, bytes: []const u8) std.io.AnyWriter.Error!usize {
    return try self.stream.write(bytes);
}

pub fn writer(self: *Self) Writer {
    return .{ .context = self };
}
