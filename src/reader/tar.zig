const std = @import("std");

const common = @import("../common.zig");
const format = @import("../format.zig");

const tar = format.tar;

const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

pub fn ArchiveReader(comptime Reader: type) type {
    const LimitedReader = common.LimitedReader(Reader);

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

            var result = PreprocessResult{};

            while (true) {
                const num_read = try self.reader.readAll(&entry.header.any);
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

                try self.reader.context.seekBy(@intCast(i64, aligned_len));
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

                const num_read = try self.reader.readAll(&entry.header.any);
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
                        var limited_reader = LimitedReader.init(self.reader, len);
                        try self.global_pax.parse(self.allocator, string_allocator, limited_reader.reader());

                        self.reuse_entry = true;

                        try self.reader.context.seekBy(@intCast(i64, aligned_len - len));
                    },
                    .pax_local, .solaris_extension => {
                        var limited_reader = LimitedReader.init(self.reader, len);
                        try entry.pax_ext.parse(self.allocator, string_allocator, limited_reader.reader());

                        self.reuse_entry = true;

                        try self.reader.context.seekBy(@intCast(i64, aligned_len - len));
                    },
                    .gnu_long_link => {
                        const actual_len = len - 1;
                        const buffer = try string_allocator.alloc(u8, actual_len);

                        const num_read_field = try self.reader.readAll(buffer);
                        if (num_read_field != actual_len) return error.EndOfStream;

                        entry.gnu_long_link = buffer;
                        self.reuse_entry = true;

                        try self.reader.context.seekBy(@intCast(i64, aligned_len - actual_len));
                    },
                    .gnu_long_name => {
                        const actual_len = len - 1;
                        const buffer = try string_allocator.alloc(u8, actual_len);

                        const num_read_field = try self.reader.readAll(buffer);
                        if (num_read_field != actual_len) return error.EndOfStream;

                        entry.gnu_long_name = buffer;
                        self.reuse_entry = true;

                        try self.reader.context.seekBy(@intCast(i64, aligned_len - actual_len));
                    },
                    else => {
                        if (len > 0) try self.reader.context.seekBy(@intCast(i64, aligned_len));
                    },
                }
            }

            if (self.reuse_entry) return error.MalformedArchive;
        }

        pub fn getEntry(self: *Self, index: usize) *const tar.Entry {
            return &self.entries.items[index];
        }

        pub fn extractSingle(self: Self, writer: anytype, index: usize) []const u8 {
            const entry = self.entries.items[index];

            const len = try entry.getSize();

            try self.reader.context.seekTo(entry.stream_offset + 512);

            var buffer: [8096]u8 = undefined;
            var pos: usize = 0;

            while (pos < len) {
                const left = std.math.min(len - pos, buffer.len);
                const num_read = try self.reader.read(buffer[0..left]);
                if (num_read == 0) return error.EndOfStream;

                try writer.writeAll(buffer[0..num_read]);
                pos += num_read;
            }

            return len;
        }

        pub fn extractSingleAlloc(self: Self, allocator: Allocator, index: usize) []const u8 {
            const entry = self.entries.items[index];

            const len = try entry.getSize();
            const buffer = try allocator.alloc(u8, len);

            try self.reader.context.seekTo(entry.stream_offset + 512);
            const num_read = try self.reader.readAll(buffer);
            if (num_read != len) return error.EndOfStream;

            return buffer;
        }

        pub const ExtractDirectoryOptions = struct {
            skip_components: usize = 0,
        };

        pub fn extractToDirectory(self: Self, allocator: Allocator, options: ExtractDirectoryOptions, dir: std.fs.Dir) !void {
            var buffer: [8096]u8 = undefined;

            for (self.entries.items) |entry| {
                const name = try allocator.alloc(u8, entry.getNameLen());
                defer allocator.free(name);

                var actual_name: []const u8 = entry.getName(name);

                if (options.skip_components > 0) {
                    var component_it = std.mem.split(u8, actual_name, "/");

                    var i = options.skip_components;
                    while (i > 0) : (i -= 1) {
                        _ = component_it.next() orelse continue;
                    }

                    actual_name = component_it.rest();
                }

                switch (entry.header.unix7.typeflag) {
                    .directory => {
                        try dir.makePath(actual_name);
                    },
                    else => {
                        if (actual_name[actual_name.len - 1] == '/') {
                            try dir.makePath(actual_name);
                            continue;
                        } else if (std.fs.path.dirnamePosix(actual_name)) |dirname| {
                            try dir.makePath(dirname);
                        }

                        const file = try dir.createFile(actual_name, .{});
                        defer file.close();

                        const len = try entry.getSize();

                        try self.reader.context.seekTo(entry.stream_offset + 512);
                        var pos: usize = 0;

                        const writer = file.writer();
                        try file.setEndPos(len);

                        while (pos < len) {
                            const left = std.math.min(len - pos, buffer.len);
                            const num_read = try self.reader.read(buffer[0..left]);
                            if (num_read == 0) return error.EndOfStream;

                            try writer.writeAll(buffer[0..num_read]);
                            pos += num_read;
                        }
                    },
                }
            }
        }
    };
}
