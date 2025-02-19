const std = @import("std");
const tls = @import("tls");

const PROTOCOL = "gemini://";
const PORT = 1965;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const ally = gpa.allocator();

    const stdin = std.io.getStdIn().reader();
    const stderr = std.io.getStdErr().writer();

    while (true) {
        // Clear screen before doing anything
        try stderr.writeAll("\x1B[2J\x1B[H");

        try stderr.writeAll("Please enter a URL to connect to: ");

        var path_buf = [_]u8{0} ** 1024;
        var fbs = std.io.fixedBufferStream(&path_buf);
        const fbs_writer = fbs.writer();

        try stdin.streamUntilDelimiter(fbs_writer, '\n', null);
        const path = fbs.getWritten();

        var full_path_buf = [_]u8{0} ** 1024;
        const full_path = try std.fmt.bufPrint(&full_path_buf, "{s}{s}", .{ PROTOCOL, path });

        const uri = std.Uri.parse(full_path) catch |err| {
            std.log.err("Failed parsing URI: {}", .{err});
            return;
        };
        const encoded_host = uri.host.?.percent_encoded;

        // Establish tcp connection
        var tcp = try std.net.tcpConnectToHost(ally, encoded_host, PORT);
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
            std.log.err("[{d}] {s}", .{ code, res_type });

            try stderr.writeAll("\nPress Enter to continue");
            _ = try stdin.readByte();
            continue;
        }

        // Print response
        while (try conn.next()) |data| {
            try stderr.print("{s}", .{data});
        }

        try stderr.writeAll("\nPress Enter to continue");
        // wait for input
        _ = try stdin.readByte();
    }
}
