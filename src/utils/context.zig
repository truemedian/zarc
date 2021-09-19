const std = @import("std");
const utils = @import("../utils.zig");

pub fn mixin(comptime Parser: type, comptime Reader: type) type {
    const ReaderCtx = std.meta.fieldInfo(Reader, .context).field_type;
    const isSeekable = @hasDecl(ReaderCtx, "seekBy") and @hasDecl(ReaderCtx, "seekTo") and @hasDecl(ReaderCtx, "getPos") and @hasDecl(ReaderCtx, "getEndPos");

    if (!isSeekable) @compileError("Reader must wrap a seekable context");

    return struct {
        pub const ReaderContext = ReaderCtx;

        pub const BufferedReader = std.io.BufferedReader(8192, Reader);
        pub const LimitedBufferedReader = utils.LimitedReader(BufferedReader.Reader);

        pub inline fn buffered(self: *Parser) BufferedReader {
            return BufferedReader{ .unbuffered_reader = self.reader };
        }

        pub inline fn limited(reader: BufferedReader.Reader, size: usize) LimitedBufferedReader {
            return LimitedBufferedReader.init(reader, size);
        }

        pub inline fn seekTo(self: *Parser, offset: u64) !void {
            try self.reader.context.seekTo(offset);
        }

        pub inline fn seekBy(self: *Parser, offset: i64) !void {
            try self.reader.context.seekBy(offset);
        }

        pub inline fn getPos(self: *Parser) !u64 {
            return try self.reader.context.getPos();
        }

        pub inline fn getEndPos(self: *Parser) !u64 {
            return try self.reader.context.getEndPos();
        }

        pub fn bufferedSeekBy(self: *Parser, buffer: *BufferedReader, offset: i64) !void {
            if (offset == 0) return;

            if (offset > 0) {
                const u_offset = @intCast(u64, offset);

                if (u_offset <= buffer.fifo.count) {
                    buffer.fifo.discard(u_offset);
                } else if (u_offset <= buffer.fifo.count + buffer.fifo.buf.len) {
                    const left = u_offset - buffer.fifo.count;

                    buffer.fifo.discard(buffer.fifo.count);
                    try buffer.reader().skipBytes(left, .{ .buf_size = 8192 });
                } else {
                    const left = u_offset - buffer.fifo.count;

                    buffer.fifo.discard(buffer.fifo.count);
                    try self.seekBy(@intCast(i64, left));
                }
            } else {
                const left = offset - @intCast(i64, buffer.fifo.count);

                buffer.fifo.discard(buffer.fifo.count);
                try self.seekBy(left);
            }
        }

        pub fn bufferedGetPos(self: *Parser, buffer: *BufferedReader) !u64 {
            const pos = try self.reader.context.getPos();

            return pos - buffer.fifo.count;
        }

        pub fn bufferedSeekTo(self: *Parser, buffer: *BufferedReader, pos: u64) !void {
            const offset = @intCast(i64, pos) - @intCast(i64, try self.bufferedGetPos(buffer));

            try self.bufferedSeekBy(buffer, offset);
        }
    };
}
