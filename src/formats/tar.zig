//! This is a very incomplete implementation. You have been warned.

const std = @import("std");
const utils = @import("../utils.zig");

pub const TypeFlag = enum(u8) {
    aregular = 0,
    regular = '0',
    link = '1',
    symlink = '2',
    char = '3',
    block = '4',
    directory = '5',
    fifo = '6',
    continuous = '7',
    ext_header = 'x',
    ext_global_header = 'g',
    gnu_longname = 'L',
    gnu_longlink = 'K',
    gnu_sparse = 'S',
    _,
};

fn truncate(str: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, str, 0)) |i| {
        return str[0..i];
    } else return str;
}

pub const Header = struct {
    const empty = [_]u8{0} ** 512;

    pub const OldHeader = extern struct {
        name: [100]u8,
        mode: [8]u8,
        uid: [8]u8,
        gid: [8]u8,
        size: [12]u8,
        mtime: [12]u8,
        checksum: [8]u8,
        typeflag: TypeFlag,
        linkname: [100]u8,

        __padding: [255]u8,
    };

    pub const UstarHeader = extern struct {
        name: [100]u8,
        mode: [8]u8,
        uid: [8]u8,
        gid: [8]u8,
        size: [12]u8,
        mtime: [12]u8,
        checksum: [8]u8,
        typeflag: TypeFlag,
        linkname: [100]u8,

        magic: [6]u8,
        version: [2]u8,
        uname: [32]u8,
        gname: [32]u8,
        dev_major: [8]u8,
        dev_minor: [8]u8,
        prefix: [155]u8,

        __padding: [12]u8,
    };

    pub const GnuHeader = extern struct {
        pub const SparseHeader = extern struct {
            offset: [12]u8,
            numbytes: [12]u8,
        };

        name: [100]u8,
        mode: [8]u8,
        uid: [8]u8,
        gid: [8]u8,
        size: [12]u8,
        mtime: [12]u8,
        checksum: [8]u8,
        typeflag: TypeFlag,
        linkname: [100]u8,

        magic: [6]u8,
        version: [2]u8,
        uname: [32]u8,
        gname: [32]u8,
        dev_major: [8]u8,
        dev_minor: [8]u8,
        atime: [12]u8,
        ctime: [12]u8,
        offset: [12]u8,
        long_names: [4]u8,
        __unused: u8,
        sparse: [4]SparseHeader,
        is_extended: u8,
        real_size: [12]u8,

        __padding: [17]u8,
    };

    pub const GnuExtSparseHeader = extern struct {
        sparse: [21]GnuHeader.SparseHeader,
        is_extended: u8,

        __padding: [7]u8,
    };

    comptime {
        std.debug.assert(@sizeOf(OldHeader) == 512 and @bitSizeOf(OldHeader) == 512 * 8);
        std.debug.assert(@sizeOf(UstarHeader) == 512 and @bitSizeOf(UstarHeader) == 512 * 8);
        std.debug.assert(@sizeOf(GnuHeader) == 512 and @bitSizeOf(GnuHeader) == 512 * 8);
        std.debug.assert(@sizeOf(GnuHeader.SparseHeader) == 24 and @bitSizeOf(GnuHeader.SparseHeader) == 24 * 8);
        std.debug.assert(@sizeOf(GnuExtSparseHeader) == 512 and @bitSizeOf(GnuExtSparseHeader) == 512 * 8);
    }

    buffer: [512]u8,
    offset: usize = 0,

    longname: ?[]const u8 = null,
    longlink: ?[]const u8 = null,

    pub fn asOld(self: Header) *const OldHeader {
        return @ptrCast(*const OldHeader, &self.buffer);
    }

    pub fn asUstar(self: Header) *const UstarHeader {
        return @ptrCast(*const UstarHeader, &self.buffer);
    }

    pub fn asGnu(self: Header) *const GnuHeader {
        return @ptrCast(*const GnuHeader, &self.buffer);
    }

    pub fn isUstar(self: Header) bool {
        const header = self.asUstar();

        return std.mem.eql(u8, &header.magic, "ustar\x00") and std.mem.eql(u8, &header.version, "00");
    }

    pub fn isGnu(self: Header) bool {
        const header = self.asGnu();

        return std.mem.eql(u8, &header.magic, "ustar ") and std.mem.eql(u8, &header.version, " \x00");
    }

    pub fn filename(self: Header) []const u8 {
        if (self.longname) |name| return name;

        const header = self.asOld();
        return truncate(&header.name);
    }

    pub fn kind(self: Header) TypeFlag {
        const header = self.asOld();

        return header.typeflag;
    }

    pub fn mode(self: Header) !std.os.mode_t {
        const header = self.asOld();

        const str = truncate(&header.mode);
        const num = if (str.len == 0) 0 else try std.fmt.parseUnsigned(u24, str, 8);
        return @truncate(std.os.mode_t, num);
    }

    pub fn entrySize(self: Header) !u64 {
        const header = self.asOld();

        const str = truncate(&header.size);
        return if (str.len == 0) 0 else try std.fmt.parseUnsigned(u64, str, 8);
    }

    pub fn alignedEntrySize(self: Header) !u64 {
        return std.mem.alignForwardGeneric(u64, try self.entrySize(), 512);
    }

    pub fn realSize(self: Header) !u64 {
        if (self.kind() == .gnu_sparse) {
            const header = self.asGnu();

            const str = truncate(&header.real_size);
            return if (str.len == 0) 0 else try std.fmt.parseUnsigned(u64, str, 8);
        } else return try self.entrySize();
    }

    pub fn preprocess(parser: anytype, reader: anytype, strings: *usize, entries: *usize) !usize {
        var header = Header{
            .buffer = undefined,
        };

        const read = try reader.readAll(&header.buffer);
        if (read != 512) return error.InvalidHeader;

        if (std.mem.eql(u8, &header.buffer, &Header.empty)) return 512;

        switch (header.kind()) {
            .gnu_longname, .gnu_longlink => {
                strings.* += try header.realSize();
            },
            else => {
                entries.* += 1;
            },
        }

        const total_data_len = try header.alignedEntrySize();
        try parser.bufferedSeekBy(reader.context, @intCast(i64, total_data_len));

        return total_data_len + 512;
    }

    pub fn parse(self: *Header, parser: anytype, reader: anytype, offset: usize) !usize {
        const read = try reader.readAll(&self.buffer);
        if (read != 512) return error.InvalidHeader;

        if (std.mem.eql(u8, &self.buffer, &Header.empty)) return 512;

        self.offset = offset;

        const total_data_len = try self.alignedEntrySize();
        switch (self.kind()) {
            .gnu_longname => {
                const size = try self.entrySize();

                parser.last_longname = truncate(try parser.readFilename(reader, size));
                parser.reuse_last_entry = true;

                try parser.bufferedSeekBy(reader.context, @intCast(i64, total_data_len - size));
            },
            .gnu_longlink => {
                const size = try self.entrySize();

                parser.last_longlink = truncate(try parser.readFilename(reader, size));
                parser.reuse_last_entry = true;

                try parser.bufferedSeekBy(reader.context, @intCast(i64, total_data_len - size));
            },
            else => {
                if (parser.last_longname) |name| {
                    self.longname = name;

                    parser.last_longname = null;
                } else {
                    self.longname = null;
                }

                if (parser.last_longlink) |name| {
                    self.longlink = name;

                    parser.last_longlink = null;
                } else {
                    self.longlink = null;
                }

                try parser.bufferedSeekBy(reader.context, @intCast(i64, total_data_len));
            },
        }

        return total_data_len + 512;
    }
};

pub fn Parser(comptime Reader: type) type {
    return struct {
        const Self = @This();
        const ctx = utils.context(Self, Reader);

        usingnamespace ctx;

        allocator: *std.mem.Allocator,

        reader: Reader,

        directory: std.ArrayListUnmanaged(Header) = .{},
        filename_buffer: std.ArrayListUnmanaged(u8) = .{},

        reuse_last_entry: bool = false,
        last_longname: ?[]const u8 = null,
        last_longlink: ?[]const u8 = null,

        pub fn init(allocator: *std.mem.Allocator, reader: Reader) Self {
            return .{
                .allocator = allocator,
                .reader = reader,
            };
        }

        pub fn deinit(self: *Self) void {
            self.directory.deinit(self.allocator);
            self.filename_buffer.deinit(self.allocator);
        }

        pub fn load(self: *Self) !void {
            var buffered = ctx.buffered(self);
            const reader = buffered.reader();

            var num_entries: usize = 0;
            var num_strings: usize = 0;

            const filesize = try self.getEndPos();
            var pos: usize = 0;

            while (pos < filesize) {
                pos += try Header.preprocess(self, reader, &num_strings, &num_entries);
            }

            try self.directory.ensureTotalCapacity(self.allocator, num_entries);
            try self.filename_buffer.ensureTotalCapacity(self.allocator, num_strings);

            try self.bufferedSeekTo(reader.context, 0);
            var index: usize = 0;
            pos = 0;

            while (index < num_entries) : (index += 1) {
                var entry = blk: {
                    if (self.reuse_last_entry) {
                        self.reuse_last_entry = false;
                        index -= 1;

                        break :blk &self.directory.items[self.directory.items.len - 1];
                    } else {
                        break :blk self.directory.addOneAssumeCapacity();
                    }
                };

                pos += try entry.parse(self, reader, pos);
            }
        }

        fn readFilename(self: *Self, reader: anytype, len: usize) ![]const u8 {
            const prev_len = self.filename_buffer.items.len;
            self.filename_buffer.items.len += len;

            var buf = self.filename_buffer.items[prev_len..][0..len];
            _ = try reader.readAll(buf);

            return buf;
        }

        pub fn getFileIndex(self: Self, filename: []const u8) !usize {
            for (self.directory.items) |*hdr, i| {
                if (std.mem.eql(u8, hdr.filename(), filename)) {
                    return i;
                }
            }

            return error.FileNotFound;
        }

        pub fn readFileAlloc(self: *Self, allocator: std.mem.Allocator, index: usize) ![]const u8 {
            const header = self.entries.items[index];

            const entry_size = try header.entrySize();

            try self.seekTo(header.offset + 512);

            var buffer = try allocator.alloc(u8, entry_size);
            errdefer allocator.free(buffer);

            var buffered_read = ctx.buffered(self);
            var limited_reader = ctx.limited(buffered_read.reader(), entry_size);
            const reader = limited_reader.reader();

            var write_stream = std.io.fixedBufferStream(buffer);
            const writer = write_stream.writer();

            var fifo = std.fifo.LinearFifo(u8, .{ .Static = 8192 }).init();

            switch (header.kind()) {
                .aregular, .regular => {
                    try fifo.pump(reader, writer);
                },
                .directory => return error.IsDir,
                else => return error.NotAFile,
            }
        }

        pub const ExtractOptions = struct {
            skip_components: u16 = 0,
        };

        pub fn extract(self: *Self, dir: std.fs.Dir, options: ExtractOptions) !usize {
            var buffered = ctx.buffered(self);
            const file_reader = buffered.reader();

            var written: usize = 0;

            for (self.directory.items) |hdr| {
                const new_filename = utils.stripPathComponents(hdr.filename(), options.skip_components) orelse continue;

                switch (hdr.kind()) {
                    .aregular, .regular => {
                        if (std.fs.path.dirnamePosix(new_filename)) |name| try dir.makePath(name);

                        const fd = try dir.createFile(new_filename, .{ .mode = try hdr.mode() });
                        defer fd.close();

                        try self.bufferedSeekTo(file_reader.context, hdr.offset + 512);

                        var limited_reader = ctx.limited(file_reader, try hdr.entrySize());
                        const reader = limited_reader.reader();

                        var fifo = std.fifo.LinearFifo(u8, .{ .Static = 8192 }).init();

                        written += try hdr.entrySize();

                        try fifo.pump(reader, fd.writer());
                    },
                    .directory => try dir.makePath(new_filename),
                    else => {},
                }
            }

            return written;
        }
    };
}
