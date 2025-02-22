const std = @import("std");
const tls = @import("tls");
const Terminal = @import("Terminal.zig");

const PROTOCOL = "gemini://";
const PORT = 1965;

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
