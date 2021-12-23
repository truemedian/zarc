const std = @import("std");

const common = @import("../common.zig");
const format = @import("../format.zig");

const tar = format.tar;

const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

pub fn ArchiveReader(comptime Reader: type) type {
    const Seek = common.Seeker(Reader);
    const LimitedReader = common.LimitedReader(Seek.BufferedReader.Reader);

    return struct {
        const Self = @This();

        allocator: Allocator,

        // Buffer used to provide an allocator for strings. This saves many allocations in large gnu or pax archives.
        string_buffer: []u8 = undefined,

        reader: Reader,

        reuse_entry: bool = false,
        entries: std.ArrayListUnmanaged(tar.Entry) = .{},

        global_pax: tar.PaxExtensions = .{},

        pub fn init(allocator: Allocator, reader: Reader) Self {
            return .{
                .allocator = allocator,
                .reader = reader,
            };
        }

        pub fn deinit(self: *Self) void {
            self.global_pax.deinit(self.allocator);
            for (self.entries.items) |*entry| {
                entry.pax_ext.deinit(self.allocator);
            }

            self.entries.deinit(self.allocator);

            // This is not safe if deinit is called twice or before load.
            self.allocator.free(self.string_buffer);
        }

        const PreprocessResult = struct {
            // This is an overestimate as it includes the size number, an extra space, and an extra newline for every pax entry.
            pax_strings_size: usize = 0,

            // This is the size of all .gnu_long_name and .gnu_long_link fields.
            gnu_strings_size: usize = 0,

            // This is the total number of entries that we care about.
            num_entries: usize = 0,
        };

        fn preprocess(self: *Self) !void {
            var entry: tar.Entry = .{ .header = undefined };

            var buffered = Seek.BufferedReader{ .unbuffered_reader = self.reader };
            const reader = buffered.reader();

            var result = PreprocessResult{};

            while (true) {
                const num_read = try reader.readAll(&entry.header.any);
                if (num_read != 512) return error.EndOfStream;

                if (std.mem.allEqual(u8, &entry.header.any, 0)) {
                    break;
                }

                const len = try entry.header.getSize();
                const aligned_len = std.mem.alignForward(len, 512);

                switch (entry.header.unix7.typeflag) {
                    .pax_global, .pax_local => {
                        // Should we take the time to parse this and get this number to be exact?
                        result.pax_strings_size += len;
                    },
                    .gnu_long_link, .gnu_long_name => {
                        // Subtract 1 because gnu fields have a trailing nul we don't need.
                        result.gnu_strings_size += len - 1;
                    },
                    else => {
                        result.num_entries += 1;
                    },
                }

                try Seek.seekBy(self.reader, &buffered, @intCast(i64, aligned_len));
            }

            // Reset the reader to the start of the stream.
            try self.reader.context.seekTo(0);

            self.string_buffer = try self.allocator.alloc(u8, result.pax_strings_size + result.gnu_strings_size);
            try self.entries.ensureTotalCapacity(self.allocator, result.num_entries);
        }

        pub fn load(self: *Self) !void {
            try self.preprocess();

            var string_allocator_impl = std.heap.FixedBufferAllocator.init(self.string_buffer);
            const string_allocator = string_allocator_impl.allocator();

            // Who are we kidding, this will probably be a file.
            var stream_pos: usize = 0;

            var buffered = Seek.BufferedReader{ .unbuffered_reader = self.reader };
            const reader = buffered.reader();

            while (true) {
                var entry: *tar.Entry = undefined;

                if (self.reuse_entry) {
                    entry = &self.entries.items[self.entries.items.len - 1];
                } else {
                    entry = self.entries.addOneAssumeCapacity();
                    entry.* = .{
                        .header = undefined,
                    };
                }

                self.reuse_entry = false;
                entry.stream_offset = stream_pos;

                const num_read = try reader.readAll(&entry.header.any);
                if (num_read != 512) return error.EndOfStream;

                if (std.mem.allEqual(u8, &entry.header.any, 0)) {
                    _ = self.entries.pop();
                    break;
                }

                const len = try entry.header.getSize();
                const aligned_len = std.mem.alignForward(len, 512);

                stream_pos += aligned_len;

                switch (entry.header.unix7.typeflag) {
                    .pax_global => {
                        var limited_reader = LimitedReader.init(reader, len);
                        try self.global_pax.parse(self.allocator, string_allocator, limited_reader.reader());
                        
                        self.reuse_entry = true;

                        try Seek.seekBy(self.reader, &buffered, @intCast(i64, aligned_len - len));
                    },
                    .pax_local => {
                        var limited_reader = LimitedReader.init(reader, len);
                        try entry.pax_ext.parse(self.allocator, string_allocator, limited_reader.reader());

                        self.reuse_entry = true;

                        try Seek.seekBy(self.reader, &buffered, @intCast(i64, aligned_len - len));
                    },
                    .gnu_long_link => {
                        const actual_len = len - 1;
                        const buffer = try string_allocator.alloc(u8, actual_len);

                        const num_read_field = try reader.readAll(buffer);
                        if (num_read_field != actual_len) return error.EndOfStream;

                        entry.gnu_long_link = buffer;
                        self.reuse_entry = true;

                        try Seek.seekBy(self.reader, &buffered, @intCast(i64, aligned_len - actual_len));
                    },
                    .gnu_long_name => {
                        const actual_len = len - 1;
                        const buffer = try string_allocator.alloc(u8, actual_len);

                        const num_read_field = try reader.readAll(buffer);
                        if (num_read_field != actual_len) return error.EndOfStream;

                        entry.gnu_long_name = buffer;
                        self.reuse_entry = true;

                        try Seek.seekBy(self.reader, &buffered, @intCast(i64, aligned_len - actual_len));
                    },
                    else => {
                        try Seek.seekBy(self.reader, &buffered, @intCast(i64, aligned_len));
                    },
                }
            }

            if (self.reuse_entry) return error.MalformedArchive;
        }
    };
}
