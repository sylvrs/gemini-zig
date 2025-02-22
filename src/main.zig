const std = @import("std");
const tls = @import("tls");

const PROTOCOL = "gemini://";
const PORT = 1965;

const Terminal = struct {
    pub const Writer = std.io.Writer(*Terminal, std.io.AnyWriter.Error, write);
    const Color = enum(u8) {
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
    pub fn init(stream: std.io.AnyWriter) Terminal {
        return .{ .stream = stream };
    }

    /// Writes the sequence into the provided stream
    fn printSequence(self: *Terminal, format: []const u8) !void {
        try self.stream.print(Color.Sequence, .{format});
    }

    /// Clears the terminal
    pub fn clear(self: *Terminal) !void {
        try self.writeCustom("\x1B[2J\x1B[H");
    }

    /// Resets the terminal via a reset sequence
    pub fn reset(self: *Terminal) !void {
        try self.writeCustom("\x1B[0m");
    }

    pub fn setBackground(self: *Terminal, color: Color) !void {
        self.bg = color;
        var buf = [_]u8{0} ** 2;
        const fmt = try std.fmt.bufPrint(&buf, "{d}", .{Color.BackgroundOffset + @intFromEnum(color)});
        try self.printSequence(fmt);
    }

    pub fn setForeground(self: *Terminal, color: Color) !void {
        self.fg = color;
        var buf = [_]u8{0} ** 2;
        const fmt = try std.fmt.bufPrint(&buf, "{d}", .{Color.ForegroundOffset + @intFromEnum(color)});
        try self.printSequence(fmt);
    }

    pub fn writeCustom(self: *Terminal, bytes: []const u8) !void {
        _ = try self.stream.write(bytes);
    }

    pub fn info(self: *Terminal, comptime fmt: []const u8, args: anytype) !void {
        try self.setForeground(.cyan);
        try self.writer().print("[info] " ++ fmt, args);
        try self.reset();
    }

    pub fn err(self: *Terminal, comptime fmt: []const u8, args: anytype) !void {
        try self.setForeground(.red);
        try self.writer().print("[err] " ++ fmt, args);
        try self.reset();
    }

    const PrintOptions = struct { bg: Color = .inherit, fg: Color = .inherit };

    pub fn print(self: *Terminal, comptime fmt: []const u8, args: anytype, opts: PrintOptions) !void {
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

    pub fn write(self: *Terminal, bytes: []const u8) std.io.AnyWriter.Error!usize {
        return try self.stream.write(bytes);
    }

    pub fn writer(self: *Terminal) Writer {
        return .{ .context = self };
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const ally = gpa.allocator();

    const stdin = std.io.getStdIn().reader();
    var terminal = Terminal.init(std.io.getStdErr().writer().any());

    // we'll automatically append if the URL given isn't a full address (e.g., /docs)
    var last_visited_url: ?[]const u8 = null;

    while (true) {
        // Clear screen before doing anything
        try terminal.clear();

        if (last_visited_url) |url| {
            try terminal.print("Please enter a URL to connect to ({s}): ", .{url}, .{ .fg = .yellow });
        } else {
            try terminal.print("Please enter a URL to connect to: ", .{}, .{ .fg = .yellow });
        }

        const path = try stdin.readUntilDelimiterOrEofAlloc(ally, '\n', 2048) orelse continue;
        // create path with protocol if our given URL doesn't start with it
        const full_path = if (!std.mem.startsWith(u8, path, PROTOCOL)) path: {
            defer ally.free(path);
            break :path try std.mem.concat(ally, u8, &.{ PROTOCOL, path });
        } else path;
        defer ally.free(full_path);

        const uri = std.Uri.parse(full_path) catch |err| {
            terminal.err("Failed parsing URI: {}", .{err}) catch unreachable;
            try terminal.print("\nPress Enter to continue", .{}, .{ .fg = .yellow });
            // wait for input
            _ = try stdin.readByte();
            continue;
        };
        const encoded_host = uri.host.?.percent_encoded;

        // Establish tcp connection
        var tcp = std.net.tcpConnectToHost(ally, encoded_host, PORT) catch {
            terminal.err("Unable to connect to host: {s}", .{full_path}) catch unreachable;
            try terminal.print("\nPress Enter to continue", .{}, .{ .fg = .yellow });
            // wait for input
            _ = try stdin.readByte();
            continue;
        };
        defer tcp.close();

        // Load system root certificates
        var root_ca = try tls.config.CertBundle.fromSystem(ally);
        defer root_ca.deinit(ally);

        var conn = try tls.client(tcp, .{
            .host = encoded_host,
            .root_ca = root_ca,
            .cipher_suites = tls.config.cipher_suites.tls13,
            .insecure_skip_verify = true,
        });

        // Send request
        try conn.writer().print("{}\r\n", .{uri});

        // Get response & split as needed
        const response: []const u8 = (try conn.next()).?;
        var res_iterator = std.mem.splitScalar(u8, response, ' ');

        // Parse code & separate response type
        const code = try std.fmt.parseInt(u16, res_iterator.next().?, 10);
        const res_type = std.mem.trim(u8, res_iterator.rest(), "\r\n");

        if (code != 20) {
            try terminal.err("[{d}] {s}", .{ code, res_type });
            try terminal.print("\nPress Enter to continue", .{}, .{ .fg = .yellow });
            _ = try stdin.readByte();
            continue;
        }

        // Print response
        while (try conn.next()) |data| {
            var line_iterator = std.mem.splitAny(u8, data, "\n");

            while (line_iterator.next()) |line| {
                // print new lines for empty lines
                if (line.len == 0) {
                    _ = try terminal.write("\n");
                    continue;
                }

                // TODO: We should do something more intricate but this works for now (Lexer?)
                const color: Terminal.Color = if (line[0] == '#')
                    .cyan
                else if (line[0] == '*')
                    .yellow
                else if (std.mem.startsWith(u8, line, "=>"))
                    .green
                else
                    .white;
                try terminal.print("{s}\n", .{line}, .{ .fg = color });
            }
        }

        // free our last visited URL
        if (last_visited_url) |url| {
            ally.free(url);
        }
        // reallocate for new URL
        last_visited_url = try ally.dupe(u8, full_path);

        try terminal.print("\nPress Enter to continue", .{}, .{ .fg = .yellow });
        // wait for input
        _ = try stdin.readByte();
    }
}
