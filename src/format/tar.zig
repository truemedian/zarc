const std = @import("std");

// A note on some design decisions here:
// - We copy all strings into a buffer rather than keeping a reference to a header. This is thanks to posix splitting
//     prefix + name, which requires a copy anyway.
// - There is a lot of copied code here. Ideally this would not be the case, but I don't see a nice way to do this
//     without a lot of extra work and digging into mixins.

const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

pub const ParseIntError = std.fmt.ParseIntError;

pub const TypeFlag = enum(u8) {
    regular_compat = 0,
    regular = '0',
    hard_link = '1',
    soft_link = '2',
    character_device = '3',
    block_device = '4',
    directory = '5',
    fifo = '6',
    reserved = '7',

    // GNU specific
    gnu_directory = 'D',
    gnu_long_link = 'K',
    gnu_long_name = 'L',
    gnu_continuation = 'M',
    gnu_relink = 'N',
    gnu_sparse = 'S',
    gnu_volume_name = 'V',

    // PAX specific
    pax_global = 'g',
    pax_local = 'x',

    // Others
    solaris_acl = 'A',
    solaris_extension = 'X',

    _,
};

pub const Unix7Header = extern struct {
    /// The name of the file. A common convention is to store directories with a trailing `/` in the name.
    name: [100]u8,

    /// The file's mode.
    mode: [8]u8,

    /// The user id of this file's owner.
    user_id: [8]u8,

    /// The group id of this file's owner.
    group_id: [8]u8,

    /// The size of the file.
    size: [12]u8,

    /// The time of last modification relative to the Unix epoch.
    mod_time: [12]u8,

    /// This header's checksum
    checksum: [8]u8,

    /// The type of file.
    typeflag: TypeFlag,

    /// For hardlinks. The name of the file that this file is a hard link to.
    linkname: [100]u8,

    __pad1: [255]u8,

    comptime {
        assert(@sizeOf(@This()) == 512);
    }

    /// Returns the length of the name field.
    pub fn getNameLen(self: Unix7Header) usize {
        const len = std.mem.indexOfScalar(u8, &self.name, 0) orelse self.name.len;

        return len;
    }

    /// Copies the file's name into a buffer.
    pub fn getName(self: Unix7Header, buf: []u8) []u8 {
        const len = std.mem.indexOfScalar(u8, &self.name, 0) orelse self.name.len;
        std.mem.copy(u8, buf, self.name[0..len]);

        return buf[0..len];
    }

    /// Returns a slice of the file's name.
    pub fn getNameSlice(self: *const Unix7Header) []const u8 {
        const len = std.mem.indexOfScalar(u8, &self.name, 0) orelse self.name.len;
        return self.name[0..len];
    }

    /// Returns the file's mode.
    pub fn getMode(self: Unix7Header) ParseIntError!u24 {
        const len = std.mem.indexOfAny(u8, &self.mode, "\x00") orelse self.mode.len;

        return std.fmt.parseUnsigned(u24, self.mode[0..len], 8) catch |err| switch (err) {
            error.Overflow => unreachable,
            else => |e| return e,
        };
    }

    /// Returns the file's user id.
    pub fn getUserId(self: Unix7Header) ParseIntError!u24 {
        const len = std.mem.indexOfAny(u8, &self.user_id, " \x00") orelse self.user_id.len;

        return std.fmt.parseUnsigned(u24, self.user_id[0..len], 8) catch |err| switch (err) {
            error.Overflow => unreachable,
            else => |e| return e,
        };
    }

    /// Returns the file's group id.
    pub fn getGroupId(self: Unix7Header) ParseIntError!u24 {
        const len = std.mem.indexOfAny(u8, &self.group_id, " \x00") orelse self.group_id.len;

        return std.fmt.parseUnsigned(u24, self.group_id[0..len], 8) catch |err| switch (err) {
            error.Overflow => unreachable,
            else => |e| return e,
        };
    }

    /// Returns the file's size.
    pub fn getSize(self: Unix7Header) ParseIntError!u36 {
        const len = std.mem.indexOfAny(u8, &self.size, " \x00") orelse self.size.len;

        return std.fmt.parseUnsigned(u36, self.size[0..len], 8) catch |err| switch (err) {
            error.Overflow => unreachable,
            else => |e| return e,
        };
    }

    /// Returns the file's time of last modification relative to the Unix epoch.
    pub fn getModificationTime(self: Unix7Header) ParseIntError!u36 {
        const len = std.mem.indexOfAny(u8, &self.mod_time, " \x00") orelse self.mod_time.len;

        return std.fmt.parseUnsigned(u36, self.mod_time[0..len], 8) catch |err| switch (err) {
            error.Overflow => unreachable,
            else => |e| return e,
        };
    }

    /// Returns the file's checksum.
    pub fn getChecksum(self: Unix7Header) ParseIntError!u24 {
        const len = std.mem.indexOfAny(u8, &self.checksum, " \x00") orelse self.checksum.len;

        return std.fmt.parseUnsigned(u24, self.checksum[0..len], 8) catch |err| switch (err) {
            error.Overflow => unreachable,
            else => |e| return e,
        };
    }

    /// For hardlinks. Returns the length of the file's link name.
    pub fn getLinkNameLen(self: GnuHeader) usize {
        const len = std.mem.indexOfScalar(u8, &self.linkname, 0) orelse self.linkname.len;
        return len;
    }

    /// For hardlinks. Copies the file's link name into a buffer.
    pub fn getLinkName(self: GnuHeader, buf: []u8) []u8 {
        const len = std.mem.indexOfScalar(u8, &self.linkname, 0) orelse self.linkname.len;

        std.mem.copy(u8, buf, self.linkname[0..len]);

        return buf[0..len];
    }

    /// Returns a slice of the file's link name.
    pub fn getLinkNameSlice(self: *const Unix7Header) []const u8 {
        const len = std.mem.indexOfScalar(u8, &self.linkname, 0) orelse self.linkname.len;
        return self.linkname[0..len];
    }
};

pub const PosixHeader = extern struct {
    pub const Magic = "ustar\x00";
    pub const Version = "00";

    /// The name of the file. A common convention is to store directories with a trailing `/` in the name.
    name: [100]u8,

    /// The file's mode.
    mode: [8]u8,

    /// The user id of this file's owner.
    user_id: [8]u8,

    /// The group id of this file's owner.
    group_id: [8]u8,

    /// The size of the file.
    size: [12]u8,

    /// The time of last modification relative to the Unix epoch.
    mod_time: [12]u8,

    /// This header's checksum.
    checksum: [8]u8,

    /// The type of file.
    typeflag: TypeFlag,

    /// For hardlinks. The name of the file that this file is a hard link to.
    linkname: [100]u8,

    /// Used to identify the kind of archive.
    magic: [6]u8,

    /// Used to identify the kind of archive.
    version: [2]u8,

    /// The user name of this file's owner.
    user_name: [32]u8,

    /// The group name of this file's owner.
    group_name: [32]u8,

    /// The major number for the device.
    device_major: [8]u8,

    /// The minor number for the device.
    device_minor: [8]u8,

    /// A string that is prepended along with a trailing `/` to the file name.
    prefix: [155]u8,

    __padding: [12]u8,

    comptime {
        assert(@sizeOf(@This()) == 512);
    }

    /// Returns the length of the name field.
    pub fn getNameLen(self: PosixHeader) usize {
        const len_name = std.mem.indexOfScalar(u8, &self.name, 0) orelse self.name.len;

        if (self.prefix[0] == 0) {
            // There is no prefix
            return len_name;
        } else {
            const len_prefix = std.mem.indexOfScalar(u8, &self.prefix, 0) orelse self.prefix.len;

            return len_prefix + len_name + 1;
        }
    }

    /// Copies the file's name into a buffer.
    pub fn getName(self: PosixHeader, buf: []u8) []u8 {
        const len_name = std.mem.indexOfScalar(u8, &self.name, 0) orelse self.name.len;
        std.mem.copy(u8, buf, self.name[0..len_name]);

        if (self.prefix[0] == 0) {
            return buf[0..len_name];
        } else {
            buf[len_name] = '/';

            const len_prefix = std.mem.indexOfScalar(u8, &self.prefix, 0) orelse self.prefix.len;
            std.mem.copy(u8, buf[len_name + 1 ..], self.prefix[0..len_prefix]);

            return buf[0 .. len_name + len_prefix + 1];
        }
    }

    /// Returns a slice of the file's name. This only works if the file does not have a prefix.
    pub fn getNameSlice(self: *const PosixHeader) ?[]const u8 {
        if (self.prefix[0] == 0) {
            const len_name = std.mem.indexOfScalar(u8, &self.name, 0) orelse self.name.len;

            return self.name[0..len_name];
        } else {
            return null;
        }
    }

    /// Returns the length of the owner's user name.
    pub fn getUserNameLen(self: PosixHeader) usize {
        const len = std.mem.indexOfScalar(u8, &self.user_name, 0) orelse self.user_name.len;

        return len;
    }

    /// Copies the owner's user name into a buffer.
    pub fn getUserName(self: PosixHeader, buf: []u8) []u8 {
        const len = std.mem.indexOfScalar(u8, &self.user_name, 0) orelse self.user_name.len;

        std.mem.copy(u8, buf, self.user_name[0..len]);

        return buf[0..len];
    }

    /// Returns a slice of the owner's user name.
    pub fn getUserNameSlice(self: *const Unix7Header) []const u8 {
        const len = std.mem.indexOfScalar(u8, &self.user_name, 0) orelse self.user_name.len;
        return self.user_name[0..len];
    }

    /// Returns the length of the owner's group name.
    pub fn getGroupNameLen(self: PosixHeader) usize {
        const len = std.mem.indexOfScalar(u8, &self.group_name, 0) orelse self.group_name.len;

        return len;
    }

    /// Copies the owner's group name into a buffer.
    pub fn getGroupName(self: PosixHeader, buf: []u8) []u8 {
        const len = std.mem.indexOfScalar(u8, &self.group_name, 0) orelse self.group_name.len;

        std.mem.copy(u8, buf, self.group_name[0..len]);

        return buf[0..len];
    }

    /// Returns a slice of the owner's group name.
    pub fn getGroupNameSlice(self: *const Unix7Header) []const u8 {
        const len = std.mem.indexOfScalar(u8, &self.group_name, 0) orelse self.group_name.len;
        return self.group_name[0..len];
    }

    // TODO: we don't support spanned archives, but these could be implemented
    // pub fn getDeviceMajor(self: PosixHeader) ParseIntError!u24
    // pub fn getDeviceMinor(self: PosixHeader) ParseIntError!u24
};

pub const GnuSparse = extern struct {
    offset: [12]u8,
    size: [12]u8,

    comptime {
        assert(@sizeOf(@This()) == 24);
    }
};

pub const GnuHeader = extern struct {
    pub const Magic = "ustar ";
    pub const Version = " \x00";

    /// The name of the file. A common convention is to store directories with a trailing `/` in the name.
    name: [100]u8,

    /// The file's mode.
    mode: [8]u8,

    /// The user id of this file's owner.
    user_id: [8]u8,

    /// The group id of this file's owner.
    group_id: [8]u8,

    /// The size of the file.
    size: [12]u8,

    /// The time of last modification relative to the Unix epoch.
    mod_time: [12]u8,

    /// This header's checksum.
    checksum: [8]u8,

    /// The type of file.
    typeflag: TypeFlag,

    /// For hardlinks. The name of the file that this file is a hard link to.
    linkname: [100]u8,

    /// Used to identify the kind of archive.
    magic: [6]u8,

    /// Used to identify the kind of archive.
    version: [2]u8,

    /// The user name of this file's owner.
    user_name: [32]u8,

    /// The group name of this file's owner.
    group_name: [32]u8,

    /// The major number for the device.
    device_major: [8]u8,

    /// The minor number for the device.
    device_minor: [8]u8,

    /// The time of last access relative to the Unix epoch.
    access_time: [12]u8,

    /// The time of last change relative to the Unix epoch.
    change_time: [12]u8,

    /// Unknown usage.
    offset: [12]u8,

    /// Unknown usage.
    longnames: [4]u8,

    __pad1: [1]u8,

    /// Unknown usage.
    sparse: [4]GnuSparse,

    /// Signifies if a gnu extended information header directly follows this.
    is_extended: u8,

    /// The real size of the file, in binary.
    realsize: [12]u8,

    __pad2: [17]u8,

    comptime {
        assert(@sizeOf(@This()) == 512);
    }

    /// Returns the file's time of last access relative to the Unix epoch.
    pub fn getAccessTime(self: GnuHeader) ParseIntError!u36 {
        const len = std.mem.indexOfAny(u8, &self.access_time, " \x00") orelse self.access_time.len;

        return std.fmt.parseUnsigned(u36, self.access_time[0..len], 8) catch |err| switch (err) {
            error.Overflow => unreachable,
            else => |e| return e,
        };
    }

    /// Returns the file's time of last change relative to the Unix epoch.
    pub fn getChangeTime(self: GnuHeader) ParseIntError!u36 {
        const len = std.mem.indexOfAny(u8, &self.change_time, " \x00") orelse self.change_time.len;

        return std.fmt.parseUnsigned(u36, self.change_time[0..len], 8) catch |err| switch (err) {
            error.Overflow => unreachable,
            else => |e| return e,
        };
    }

    /// Returns the file's offset.
    pub fn getOffset(self: GnuHeader) ParseIntError!u36 {
        const len = std.mem.indexOfAny(u8, &self.change_time, " \x00") orelse self.change_time.len;

        return std.fmt.parseUnsigned(u36, self.change_time[0..len], 8) catch |err| switch (err) {
            error.Overflow => unreachable,
            else => |e| return e,
        };
    }

    // pub fn getSparse() ???
    // pub fn getIsExtended() bool
    // pub fn getRealSize() u96
};

pub const GnuExtendedSparseHeader = extern struct {
    sparse: [21]GnuSparse,
    is_extended: u8,
    __pad1: [7]u8,

    comptime {
        assert(@sizeOf(@This()) == 512);
    }
};

pub const Header = extern union {
    any: [512]u8,
    unix7: Unix7Header,
    posix: PosixHeader,
    gnu: GnuHeader,

    comptime {
        assert(@sizeOf(@This()) == 512);
    }

    pub fn isPosix(self: Header) bool {
        return std.mem.eql(u8, &self.posix.magic, PosixHeader.Magic) and std.mem.eql(u8, &self.posix.version, PosixHeader.Version);
    }

    pub fn isGnu(self: Header) bool {
        return std.mem.eql(u8, &self.gnu.magic, GnuHeader.Magic) and std.mem.eql(u8, &self.gnu.version, GnuHeader.Version);
    }

    /// Returns the length of the name field.
    pub fn getNameLen(self: Header) usize {
        if (self.isPosix()) {
            return self.posix.getNameLen();
        } else {
            // gnu and unix7 represent file names identically.
            return self.unix7.getNameLen();
        }
    }

    /// Copies the file's name into a buffer.
    pub fn getName(self: Header, buf: []u8) []u8 {
        if (self.isPosix()) {
            return self.posix.getName(buf);
        } else {
            // gnu and unix7 represent file names identically.
            return self.unix7.getName(buf);
        }
    }

    /// Returns a slice of the file's name. This will not work for posix headers that have a prefixed name.
    pub fn getNameSlice(self: *const Header) ?[]const u8 {
        if (self.isPosix()) {
            return self.posix.getNameSlice();
        } else {
            // gnu and unix7 represent file names identically.
            return self.unix7.getNameSlice();
        }
    }

    /// Returns the file's mode.
    pub fn getMode(self: Header) ParseIntError!u24 {
        // posix, gnu and unix7 represent file modes identically.
        return self.unix7.getMode();
    }

    /// Returns the file's user id.
    pub fn getUserId(self: Header) ParseIntError!u24 {
        // posix, gnu and unix7 represent user ids identically.
        return self.unix7.getUserId();
    }

    /// Returns the file's group id.
    pub fn getGroupId(self: Header) ParseIntError!u24 {
        // posix, gnu and unix7 represent group ids identically.
        return self.unix7.getGroupId();
    }

    /// Returns the file's size.
    pub fn getSize(self: Header) ParseIntError!u36 {
        // posix, gnu and unix7 represent file sizes identically.
        return self.unix7.getSize();
    }

    /// Returns the file's time of last modification.
    pub fn getModificationTime(self: Header) ParseIntError!u36 {
        // posix, gnu and unix7 represent file mtime identically.
        return self.unix7.getModificationTime();
    }

    /// Returns the file's checksum.
    pub fn getChecksum(self: Header) ParseIntError!u24 {
        // posix, gnu and unix7 represent file checksums identically.
        return self.unix7.getChecksum();
    }

    /// For hardlinks. Returns the length of the file's link name.
    pub fn getLinkNameLen(self: Header) usize {
        // posix, gnu and unix7 represent link names identically.
        return self.unix7.getLinkNameLen();
    }

    /// For hardlinks. Copies the file's link name into a buffer.
    pub fn getLinkName(self: Header, buf: []u8) []u8 {
        // posix, gnu and unix7 represent file link names identically.
        return self.unix7.getLinkName(buf);
    }

    /// Returns a slice of the file's link name.
    pub fn getLinkNameSlice(self: *const Header) []const u8 {
        // posix, gnu and unix7 represent file link names identically.
        return self.unix7.getLinkNameSlice();
    }

    /// Returns the length of the owner's user name.
    pub fn getUserNameLen(self: Header) ?usize {
        if (self.isPosix() or self.isGnu()) {
            // posix and gnu represent user names identically.
            return self.posix.getUserNameLen();
        } else {
            return null;
        }
    }

    /// Copies the owner's user name into a buffer.
    pub fn getUserName(self: Header, buf: []u8) ?[]u8 {
        if (self.isPosix() or self.isGnu()) {
            // posix and gnu represent user names identically.
            return self.posix.getUserName(buf);
        } else {
            return null;
        }
    }

    /// Returns a slice of the owner's user name.
    pub fn getUserNameSlice(self: *const Header) []const u8 {
        if (self.isPosix() or self.isGnu()) {
            // posix and gnu represent user names identically.
            return self.posix.getUserNameSlice();
        } else {
            return null;
        }
    }

    /// Returns the length of the owner's group name.
    pub fn getGroupNameLen(self: Header) ?usize {
        if (self.isPosix() or self.isGnu()) {
            // posix and gnu represent group names identically.
            return self.posix.getGroupNameLen();
        } else {
            return null;
        }
    }

    /// Copies the owner's group name into a buffer.
    pub fn getGroupName(self: Header, buf: []u8) ?[]u8 {
        if (self.isPosix() or self.isGnu()) {
            // posix and gnu represent group names identically.
            return self.posix.getGroupName(buf);
        } else {
            return null;
        }
    }

    /// Returns a slice of the owner's group name.
    pub fn getGroupNameSlice(self: *const Header) []const u8 {
        if (self.isPosix() or self.isGnu()) {
            // posix and gnu represent group names identically.
            return self.posix.getGroupNameSlice();
        } else {
            return null;
        }
    }

    /// Returns the file's time of last access relative to the Unix epoch.
    pub fn getAccessTime(self: Header) ParseIntError!u36 {
        if (self.isGnu()) {
            return self.gnu.getAccessTime();
        } else {
            return null;
        }
    }

    /// Returns the file's time of last change relative to the Unix epoch.
    pub fn getChangeTime(self: Header) ParseIntError!u36 {
        if (self.isGnu()) {
            return self.gnu.getChangeTime();
        } else {
            return null;
        }
    }
};

pub const GnuExtensions = struct {
    long_link: ?[]const u8 = null,
    long_name: ?[]const u8 = null,
};

pub const PaxExtensions = struct {
    map: std.StringHashMapUnmanaged([]const u8) = .{},

    pub fn deinit(self: *PaxExtensions, allocator: Allocator) void {
        self.map.deinit(allocator);
    }

    pub fn parse(self: *PaxExtensions, map_allocator: Allocator, string_allocator: Allocator, reader: anytype) !void {
        while (true) {
            // log2(10 ^ 19) < 64
            var len_str_buf: [19]u8 = undefined;
            const len_str = try reader.readUntilDelimiter(&len_str_buf, ' ');

            // length of line - length of decimal - 1 (for the space) - 1 (for the newline, will be skipped later)
            const len = (try std.fmt.parseUnsigned(u64, len_str, 10)) - len_str.len - 2;

            const buffer = try string_allocator.alloc(u8, len);
            const size_read = try reader.readAll(buffer);
            if (size_read != len) return error.EndOfStream;

            const split = std.mem.indexOfScalar(u8, buffer, '=') orelse return error.InvalidPaxField;

            const key = buffer[0..split];
            const value = buffer[split + 1 .. len];

            try self.map.put(map_allocator, key, value);

            _ = try reader.readByte(); // skip newline
        }
    }
};

pub const Entry = struct {
    stream_offset: usize = 0,
    header: Header,

    gnu_long_name: ?[]const u8 = null,
    gnu_long_link: ?[]const u8 = null,

    pax_ext: PaxExtensions = .{},

    pub fn getNameLen(self: Entry) usize {
        if (self.pax_ext.map.get("path")) |path| {
            return path.len;
        }

        if (self.gnu_long_name) |long_name| {
            return long_name.len;
        }

        return self.header.getNameLen();
    }

    pub fn getName(self: Entry, buf: []u8) []u8 {
        if (self.pax_ext.map.get("path")) |path| {
            std.mem.copy(u8, buf, path);

            return buf[0..path.len];
        }

        if (self.gnu_long_name) |long_name| {
            std.mem.copy(u8, buf, long_name);

            return buf[0..long_name.len];
        }

        return self.header.getName(buf);
    }

    pub fn getNameSlice(self: *const Entry) ?[]const u8 {
        if (self.pax_ext.map.get("path")) |path| {
            return path;
        }

        if (self.gnu_long_name) |long_name| {
            return long_name;
        }

        return self.header.getNameSlice();
    }

    pub fn getUserNameLen(self: Entry) usize {
        if (self.pax_ext.map.get("uname")) |uname| {
            return uname.len;
        }

        return self.header.getUserNameLen();
    }

    pub fn getUserName(self: Entry, buf: []u8) []u8 {
        if (self.pax_ext.map.get("uname")) |uname| {
            std.mem.copy(u8, buf, uname);

            return buf[0..uname.len];
        }

        return self.header.getUserName(buf);
    }

    pub fn getUserNameSlice(self: *const Entry) []const u8 {
        if (self.pax_ext.map.get("uname")) |uname| {
            return uname;
        }

        return self.header.getUserNameSlice();
    }

    pub fn getUserId(self: Entry) ParseIntError!u64 {
        if (self.pax_ext.map.get("uid")) |uid| {
            return try std.fmt.parseUnsigned(u64, uid, 10);
        }

        return try self.header.getUserId();
    }

    pub fn getGroupNameLen(self: Entry) usize {
        if (self.pax_ext.map.get("gname")) |gname| {
            return gname.len;
        }

        return self.header.getGroupNameLen();
    }

    pub fn getGroupName(self: Entry, buf: []u8) []u8 {
        if (self.pax_ext.map.get("gname")) |gname| {
            std.mem.copy(u8, buf, gname);

            return buf[0..gname.len];
        }

        return self.header.getGroupName(buf);
    }
    
    pub fn getGroupNameSlice(self: *const Entry) []const u8 {
        if (self.pax_ext.map.get("gname")) |gname| {
            return gname;
        }

        return self.header.getGroupNameSlice();
    }


    pub fn getGroupId(self: Entry) ParseIntError!u64 {
        if (self.pax_ext.map.get("gid")) |gid| {
            return try std.fmt.parseUnsigned(u64, gid, 10);
        }

        return try self.header.getUserId();
    }

    pub fn getSize(self: Entry) ParseIntError!u64 {
        if (self.pax_ext.map.get("size")) |size| {
            return try std.fmt.parseUnsigned(u64, size, 10);
        }

        return try self.header.getSize();
    }
    // TODO: Pax extensions for these times allow for fractional values, we truncate these. Should we provide a way to get the float?
    pub fn getAccessTime(self: Entry) ParseIntError!u64 {
        if (self.pax_ext.map.get("atime")) |atime| {
            const end_integral = std.mem.indexOfScalar(u8, atime, '.') orelse atime.len;

            return try std.fmt.parseUnsigned(u64, atime[0..end_integral], 10);
        }

        return try self.header.getAccessTime();
    }

    pub fn getChangeTime(self: Entry) ParseIntError!u64 {
        if (self.pax_ext.map.get("ctime")) |ctime| {
            const end_integral = std.mem.indexOfScalar(u8, ctime, '.') orelse ctime.len;

            return try std.fmt.parseUnsigned(u64, ctime[0..end_integral], 10);
        }

        return try self.header.getChangeTime();
    }

    pub fn getModificationTime(self: Entry) ParseIntError!u64 {
        if (self.pax_ext.map.get("mtime")) |mtime| {
            const end_integral = std.mem.indexOfScalar(u8, mtime, '.') orelse mtime.len;

            return try std.fmt.parseUnsigned(u64, mtime[0..end_integral], 10);
        }

        return try self.header.getModificationTime();
    }

    pub fn getLinkNameLen(self: Entry) usize {
        if (self.pax_ext.map.get("linkpath")) |linkpath| {
            return linkpath.len;
        }

        if (self.gnu_long_link) |long_link| {
            return long_link.len;
        }

        return self.header.getLinkNameLen();
    }

    pub fn getLinkName(self: Entry, buf: []u8) []u8 {
        if (self.pax_ext.map.get("linkpath")) |linkpath| {
            std.mem.copy(u8, buf, linkpath);

            return buf[0..linkpath.len];
        }

        if (self.gnu_long_link) |long_link| {
            std.mem.copy(u8, buf, long_link);

            return buf[0..long_link.len];
        }

        return self.header.getLinkName(buf);
    }

    pub fn getLinkNameSlice(self: *const Entry) []const u8 {
        if (self.pax_ext.map.get("linkpath")) |linkpath| {
            return linkpath;
        }

        if (self.gnu_long_link) |long_link| {
            return long_link;
        }

        return self.header.getLinkNameSlice();
    }

    // TODO: implement all the other pax things
};

comptime {
    std.testing.refAllDecls(@This());
}
