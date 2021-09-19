const std = @import("std");
const zarc = @import("zarc");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var tests_dir = try std.fs.cwd().openDir("tests/tar", .{ .iterate = true });
    defer tests_dir.close();

    var main_extract_dir = try std.fs.cwd().makeOpenPath("tests/extract/tar", .{});
    defer main_extract_dir.close();

    var report = try std.fs.cwd().createFile("tests/tar.report.txt", .{});
    defer report.close();

    const writer = report.writer();

    var it = tests_dir.iterate();
    while (try it.next()) |entry| {
        var archive_file = try tests_dir.openFile(entry.name, .{});
        defer archive_file.close();

        var extract_dir = try main_extract_dir.makeOpenPath(entry.name, .{});
        defer extract_dir.close();

        const size = try archive_file.getEndPos();

        var archive = zarc.tar.Parser(std.fs.File.Reader).init(allocator, archive_file.reader());
        defer archive.deinit();

        try writer.print("File: {s}\n", .{entry.name});

        var timer = try std.time.Timer.start();
        try archive.load();
        const time = timer.read();

        const load_time = @intToFloat(f64, time) / 1e9;
        const read_speed = (@intToFloat(f64, size) * 2) / load_time;

        try writer.print("Runtime: {d:.3}ms\n\n", .{load_time * 1e3});
        try writer.print("Speed: {d:.3} MB/s\n", .{read_speed / 1e6});
        try writer.print("Total Size: {d}\n", .{size});
        try writer.print("Entries: {d}\n", .{archive.directory.items.len});
        try writer.print("Headers Size: {d}\n", .{archive.directory.items.len * @sizeOf(zarc.tar.Header)});

        // for (archive.entries.items) |hdr| {
        //     try writer.print("{} {s} {d}\n", .{ hdr.kind(), hdr.filename(), hdr.entrySize() });
        // }

        const start = timer.read();
        const total_written = try archive.extract(extract_dir, .{ .skip_components = 1 });
        const stop = timer.read();

        const extract_time = @intToFloat(f64, stop - start) / 1e9;
        const extract_speed = @intToFloat(f64, total_written) / extract_time;
        try writer.print("Extract Size: {d}\n", .{total_written});
        try writer.print("Extract Speed: {d:.3} MB/s\n", .{extract_speed / 1e6});

        try writer.writeAll("\n\n-----\n\n");
    }
}
