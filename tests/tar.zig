const std = @import("std");
const zarc = @import("zarc");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var tests_dir = try std.fs.cwd().openDir("tests/tar", .{ .iterate = true });
    defer tests_dir.close();

    var extract_dir = try std.fs.cwd().makeOpenPath("tests/extract", .{});
    defer extract_dir.close();

    var report = try std.fs.cwd().createFile("tests/tar.report.txt", .{});
    defer report.close();

    const writer = report.writer();

    var it = tests_dir.iterate();
    while (try it.next()) |entry| {
        var archive_file = try tests_dir.openFile(entry.name, .{});
        defer archive_file.close();

        const size = try archive_file.getEndPos();

        var timer = try std.time.Timer.start();
        var archive = zarc.reader.tar.ArchiveReader(std.fs.File.Reader).init(allocator, archive_file.reader());
        defer archive.deinit();

        try archive.load();
        const time = timer.read();

        try writer.print("File: {s}\n", .{entry.name});
        try writer.print("Runtime: {d:.3}ms\n\n", .{@intToFloat(f64, time) / 1e6});
        try writer.print("Total Size: {d}\n", .{size});
        try writer.print("Entries: {d} ({d})\n", .{ archive.entries.items.len, archive.entries.items.len * @sizeOf(zarc.format.tar.Entry) });
        try writer.print("Strings Size: {d}\n", .{archive.string_buffer.len});

        var new_extract_dir = try extract_dir.makeOpenPath(entry.name, .{});
        defer new_extract_dir.close();

        timer.reset();
        try archive.extractToDirectory(allocator, .{}, new_extract_dir);
        const time_extract = timer.read();

        try writer.print("Extract Time: {d:.3}ms\n\n", .{@intToFloat(f64, time_extract) / 1e6});

        try writer.writeAll("\n\n-----\n\n");
    }
}
