const std = @import("std");

pub fn LimitedReader(comptime ReaderType: type) type {
    return struct {
        unlimited_reader: ReaderType,
        limit: usize,
        pos: usize = 0,

        pub const Error = ReaderType.Error;
        pub const Reader = std.io.Reader(*Self, Error, read);

        const Self = @This();

        pub fn init(unlimited_reader: ReaderType, limit: usize) Self {
            return .{
                .unlimited_reader = unlimited_reader,
                .limit = limit,
            };
        }

        fn read(self: *Self, dest: []u8) Error!usize {
            if (self.pos >= self.limit) return 0;

            const left = std.math.min(self.limit - self.pos, dest.len);
            const num_read = try self.unlimited_reader.read(dest[0..left]);

            self.pos += num_read;

            return num_read;
        }

        pub fn reader(self: *Self) Reader {
            return .{ .context = self };
        }
    };
}

pub fn Seeker(comptime Reader: type) type {
    return struct {
        pub const Context = std.meta.fieldInfo(Reader, .context).field_type;
        comptime {
            const is_seekable = @hasDecl(Context, "seekBy") and @hasDecl(Context, "seekTo") and @hasDecl(Context, "getPos");
            if (!is_seekable) @compileError("Reader must wrap a seekable context");
        }
        pub const BufferedReader = std.io.BufferedReader(8192, Reader);

        pub fn seekBy(reader: Reader, buffered: *BufferedReader, offset: i64) !void {
            if (offset == 0) return;

            if (offset > 0) {
                const u_offset = @intCast(u64, offset);

                if (u_offset <= buffered.fifo.count) {
                    buffered.fifo.discard(u_offset);
                } else if (u_offset <= buffered.fifo.count + buffered.fifo.buf.len) {
                    const left = u_offset - buffered.fifo.count;

                    buffered.fifo.discard(buffered.fifo.count);
                    try buffered.reader().skipBytes(left, .{ .buf_size = 8192 });
                } else {
                    const left = u_offset - buffered.fifo.count;

                    buffered.fifo.discard(buffered.fifo.count);
                    try reader.context.seekBy(@intCast(i64, left));
                }
            } else {
                const left = offset - @intCast(i64, buffered.fifo.count);

                buffered.fifo.discard(buffered.fifo.count);
                try reader.context.seekBy(left);
            }
        }

        pub fn getPos(reader: Reader, buffered: *BufferedReader) !u64 {
            const pos = try reader.context.getPos();

            return pos - buffered.fifo.count;
        }

        pub fn seekTo(reader: Reader, buffered: *BufferedReader, pos: u64) !void {
            const offset = @intCast(i64, pos) - @intCast(i64, try getPos(reader, buffered));

            try seekBy(reader, buffered, offset);
        }
    };
}
