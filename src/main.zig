//! zzz format serializer and deserializer. public domain.
//!
//! StreamingParser inspired by Zig's JSON parser.
//!
//! SPARSE SPEC
//! (zzz text is escaped using Zig's multiline string: \\)
//!
//! A zzz file describes a tree. Special characters (and spaces) are used to go up and down
//! the tree. The tree has an implicit null root node.
//!
//! Descending the tree:
//! \\grandparent:parent:child:grandchild
//! Output:
//! null -> "grandparent" -> "parent" -> "child" -> "grandchild"
//!
//! Traversing the children of root (siblings):
//! \\sibling1,sibling2,sibling3
//! Output:
//! null -> "sibling1"
//!      -> "sibling2"
//!      -> "sibling3"
//!
//! Going up to the parent:
//! \\parent:child;anotherparent
//! Output:
//! null -> "parent" -> "child"
//!      -> "anotherparent"
//!
//! White space and newlines are significant. A newline will take you back to the root:
//! \\parent:child
//! \\anotherparent
//! Output:
//! null -> "parent" -> "child"
//!      -> "anotherparent"
//!
//! Exactly two spaces are used to to go down a level in the tree:
//! \\parent:child
//! \\  sibling
//! Output:
//! null -> "parent" -> "child"
//!                  -> "sibling"
//!
//! You can only go one level deeper than the previous line's depth. Anything more is an error:
//! \\parent:child
//! \\    sibling
//! Output: Error!
//!
//! Trailing commas, semicolons, and colons are optional. So the above (correct one) can be written
//! as:
//! \\parent
//! \\  child
//! \\  sibling
//! Output:
//! null -> "parent" -> "child"
//!                  -> "sibling"
//!
//! zzz can contain strings, integers (i32), floats (f32), boolean, and nulls:
//! \\string:42:42.0:true::
//! Output:
//! null -> "string" -> 42 -> 42.0 -> true -> null
//!
//! strings are trimmed, they may still contain spaces:
//! \\parent:     child:      grand child      ;
//! Output:
//! null -> "parent" -> "child" -> "grand child"
//!
//! strings can be quoted with double quotes or Lua strings:
//! \\"parent":[[ child ]]:[==[grand child]=]]==];
//! Output:
//! null -> "parent" -> " child " -> "grand child]=]"
//!
//! Lua strings will skip the first empty newline:
//! \\[[
//! \\some text]]
//! Output:
//! null -> "some text"
//!
//! Strings are not escaped and taken "as-is".
//! \\"\n\t\r"
//! Output:
//! null -> "\n\t\r"
//!
//! Comments begin with # and run up to the end of the line. Their intendation follows the same
//! rules as nodes.
//! \\# A comment
//! \\a node
//! \\  # Another comment
//! \\  a sibling
//! Output:
//! null -> "a node"
//!      -> "a sibling"

const std = @import("std");

/// The only output of the tokenizer.
pub const ZNodeToken = struct {
    const Self = @This();
    /// 0 is top level children.
    depth: usize,
    /// The extent of the slice.
    start: usize,
    end: usize,
};

/// Parses text outputting ZNodeTokens. Does not convert strings to numbers, and all strings are
/// "as is", no escaping is performed.
pub const StreamingParser = struct {
    const Self = @This();
    state: State,
    start_index: usize,
    current_index: usize,
    // The maximum node depth.
    max_depth: usize,
    // The current line's depth.
    line_depth: usize,
    // The current node depth.
    node_depth: usize,
    /// Level of multiline string.
    open_string_level: usize,
    /// Current level of multiline string close.
    close_string_level: usize,
    /// Account for any extra spaces trailing at the end of a word.
    trailing_spaces: usize,

    pub const Error = error {
        TooMuchIndentation,
        InvalidWhitespace,
        OddIndentationValue,
        InvalidQuotation,
        InvalidMultilineOpen,
        InvalidMultilineClose,
        InvalidNewLineInString,
        InvalidCharacterAfterString,
        SemicolonWentPastRoot,
    };

    pub const State = enum {
        /// Whether we're starting on an openline.
        OpenLine,
        ExpectZNode,
        Indent,
        OpenCharacter,
        Quotation,
        SingleLineCharacter,
        MultilineOpen0,
        MultilineOpen1,
        MultilineLevelOpen,
        MultilineLevelClose,
        MultilineClose0,
        MultilineCharacter,
        EndString,
        OpenComment,
        Comment,
    };

    /// Returns a blank parser.
    pub fn init() Self {
        var self: StreamingParser = undefined;
        self.reset();
        return self;
    }

    /// Resets the parser back to the beginning state.
    pub fn reset(self: *Self) void {
        self.state = .OpenLine;
        self.start_index = 0;
        self.current_index = 0;
        self.max_depth = 0;
        self.line_depth = 0;
        self.node_depth = 0;
        self.open_string_level = 0;
        self.close_string_level = 0;
        self.trailing_spaces = 0;
    }

    pub fn hasCompleted(self: *const Self) bool {
        switch (self.state) {
            .ExpectZNode, .OpenLine, .EndString => return true,
            else => return false,
        }
    }

    /// Feeds a character to the parser. May output a ZNode. Check "hasCompleted" to see if there
    /// are any unfinished strings.
    pub fn feed(self: *Self, c: u8) Error!?ZNodeToken {
        defer self.current_index += 1;
        //std.debug.print("FEED<{}> {} {} ({c})\n", .{self.state, self.current_index, c, c});
        switch (self.state) {
            .OpenComment, .Comment => switch (c) {
                '\n' => {
                    self.start_index = self.current_index + 1;
                    // We're ending a line with nodes.
                    if (self.state == .Comment) {
                        self.max_depth = self.line_depth + 1;
                    }
                    self.node_depth = 0;
                    self.line_depth = 0;
                    self.state = .OpenLine;
                },
                else => {
                    // Skip.
                }
            },
            // All basically act the same except for a few minor differences.
            .ExpectZNode, .OpenLine, .EndString, .OpenCharacter => switch (c) {
                '#' => {
                    if (self.state == .OpenLine) {
                        self.state = .OpenComment;
                    } else {
                        defer self.state = .Comment;
                        if (self.state == .OpenCharacter) {
                            return ZNodeToken{
                                .depth = self.line_depth + self.node_depth,
                                .start = self.start_index,
                                .end = self.current_index - self.trailing_spaces,
                            };
                        }
                    }
                },
                // The tricky character (and other whitespace).
                ' ' => {
                    if (self.state == .OpenLine) {
                        if (self.line_depth >= self.max_depth) {
                            return Error.TooMuchIndentation;
                        }
                        self.state = .Indent;
                    } else if (self.state == .OpenCharacter) {
                        self.trailing_spaces += 1;
                    } else {

                        // Skip spaces when expecting a node on a closed line,
                        // including this one.
                        self.start_index = self.current_index + 1;
                    }
                },
                ':' => {
                    defer self.state = .ExpectZNode;
                    const node = ZNodeToken{
                        .depth = self.line_depth + self.node_depth,
                        .start = self.start_index,
                        .end = self.current_index - self.trailing_spaces,
                    };
                    self.start_index = self.current_index + 1;
                    self.node_depth += 1;
                    // Only return when we're not at end of a string.
                    if (self.state != .EndString) {
                        return node;
                    }
                },
                ',' => {
                    defer self.state = .ExpectZNode;
                    const node = ZNodeToken{
                        .depth = self.line_depth + self.node_depth,
                        .start = self.start_index,
                        .end = self.current_index - self.trailing_spaces,
                    };
                    self.start_index = self.current_index + 1;
                    // Only return when we're not at end of a string.
                    if (self.state != .EndString) {
                        return node;
                    }
                },
                ';' => {
                    if (self.node_depth == 0) {
                        return Error.SemicolonWentPastRoot;
                    }
                    defer self.state = .ExpectZNode;
                    const node = ZNodeToken{
                        .depth = self.line_depth + self.node_depth,
                        .start = self.start_index,
                        .end = self.current_index - self.trailing_spaces,
                    };
                    self.start_index = self.current_index + 1;
                    self.node_depth -= 1;
                    // Only return when we're not at end of a string, or in semicolons
                    // special case, when we don't have an empty string.
                    if (self.state != .EndString and node.start < node.end) {
                        return node;
                    }
                },
                '"' => {
                    if (self.state == .EndString) {
                        return Error.InvalidCharacterAfterString;
                    }
                    // We start here to account for the possibility of a string being ""
                    self.start_index = self.current_index + 1;
                    self.state = .Quotation;
                },
                '[' => {
                    if (self.state == .EndString) {
                        return Error.InvalidCharacterAfterString;
                    }
                    self.open_string_level = 0;
                    self.state = .MultilineOpen0;
                },
                '\n' => {
                    defer self.state = .OpenLine;
                    const node = ZNodeToken{
                        .depth = self.line_depth + self.node_depth,
                        .start = self.start_index,
                        .end = self.current_index - self.trailing_spaces,
                    };
                    self.start_index = self.current_index + 1;
                    // Only reset on a non open line.
                    if (self.state != .OpenLine) {
                        self.max_depth = self.line_depth + 1;
                        self.line_depth = 0;
                    }
                    self.node_depth = 0;
                    // Only return something if there is something. Quoted strings are good.
                    if (self.state == .OpenCharacter) {
                        return node;
                    }
                },
                '\t', '\r' => {
                    return Error.InvalidWhitespace;
                },
                else => {
                    // We already have a string.
                    if (self.state == .EndString) {
                        return Error.InvalidCharacterAfterString;
                    }
                    // Don't reset if we're in a string.
                    if (self.state != .OpenCharacter) {
                        self.start_index = self.current_index;
                    }
                    self.trailing_spaces = 0;
                    self.state = .OpenCharacter;
                }
            },
            .Indent => switch (c) {
                ' ' => {
                    self.start_index = self.current_index + 1;
                    self.line_depth += 1;
                    self.state = .OpenLine;
                },
                else => {
                    return Error.OddIndentationValue;
                }
            },
            .Quotation => switch (c) {
                '"' => {
                    self.state = .EndString;
                    const node = ZNodeToken{
                        .depth = self.line_depth + self.node_depth,
                        .start = self.start_index,
                        .end = self.current_index,
                    };
                    // Reset because we're going to expecting nodes.
                    self.start_index = self.current_index + 1;
                    return node;
                },
                else => {
                    self.state = .SingleLineCharacter;
                }
            },
            .SingleLineCharacter => switch (c) {
                '"' => {
                    self.state = .EndString;
                    const node = ZNodeToken{
                        .depth = self.line_depth + self.node_depth,
                        .start = self.start_index,
                        .end = self.current_index,
                    };
                    // Reset because we're going to expecting nodes.
                    self.start_index = self.current_index + 1;
                    return node;
                },
                '\n' => {
                    return Error.InvalidNewLineInString;
                },
                else => {
                    // Consume.
                }
            },
            .MultilineOpen0, .MultilineLevelOpen => switch (c) {
                '=' => {
                    self.open_string_level += 1;
                    self.state = .MultilineLevelOpen;
                },
                '[' => {
                    self.start_index = self.current_index + 1;
                    self.state = .MultilineOpen1;
                },
                else => {
                    return Error.InvalidMultilineOpen;
                }
            },
            .MultilineOpen1 => switch (c) {
                ']' => {
                    self.state = .MultilineClose0;
                },
                '\n' => {
                    // Skip first newline.
                    self.start_index = self.current_index + 1;
                },
                else => {
                    self.state = .MultilineCharacter;
                }
            },
            .MultilineCharacter => switch (c) {
                ']' => {
                    self.close_string_level = 0;
                    self.state = .MultilineClose0;
                },
                else => {
                    // Capture EVERYTHING.
                }
            },
            .MultilineClose0, .MultilineLevelClose => switch (c) {
                '=' => {
                    self.close_string_level += 1;
                    self.state = .MultilineLevelClose;
                },
                ']' => {
                    if (self.close_string_level == self.open_string_level) {
                        self.state = .EndString;
                        return ZNodeToken{
                            .depth = self.line_depth + self.node_depth,
                            .start = self.start_index,
                            .end = self.current_index - self.open_string_level - 1,
                        };
                    }
                    self.state = .MultilineCharacter;
                },
                else => {
                    return Error.InvalidMultilineClose;
                }
            }
        }
        return null;
    }
};

fn testNextTextOrError(stream: *StreamingParser, idx: *usize, text: []const u8) ![]const u8 {
    while (idx.* < text.len) {
        const node = try stream.feed(text[idx.*]);
        idx.* += 1;
        if (node) |n| {
            //std.debug.print("TOKEN {}\n", .{text[n.start..n.end]});
            return text[n.start..n.end];
        }
    }
    return error.ExhaustedLoop;
}

test "parsing slice output" {
    const testing = std.testing;

    const text =
        \\# woo comment
        \\mp:10
        \\[[sy]]
        \\  # another
        \\  : n : "en"  ,  [[m]]
        \\    "sc"   :  [[10]]   ,    g #inline
        \\  [[]]:[==[
        \\hi]==]
    ;
    var idx: usize = 0;
    var stream = StreamingParser.init();
    testing.expectEqualSlices(u8, "mp", try testNextTextOrError(&stream, &idx, text));
    testing.expectEqualSlices(u8, "10", try testNextTextOrError(&stream, &idx, text));
    testing.expectEqualSlices(u8, "sy", try testNextTextOrError(&stream, &idx, text));
    testing.expectEqualSlices(u8, "", try testNextTextOrError(&stream, &idx, text));
    testing.expectEqualSlices(u8, "n", try testNextTextOrError(&stream, &idx, text));
    testing.expectEqualSlices(u8, "en", try testNextTextOrError(&stream, &idx, text));
    testing.expectEqualSlices(u8, "m", try testNextTextOrError(&stream, &idx, text));
    testing.expectEqualSlices(u8, "sc", try testNextTextOrError(&stream, &idx, text));
    testing.expectEqualSlices(u8, "10", try testNextTextOrError(&stream, &idx, text));
    testing.expectEqualSlices(u8, "g", try testNextTextOrError(&stream, &idx, text));
    testing.expectEqualSlices(u8, "", try testNextTextOrError(&stream, &idx, text));
    testing.expectEqualSlices(u8, "hi", try testNextTextOrError(&stream, &idx, text));
}

fn testNextLevelOrError(stream: *StreamingParser, idx: *usize, text: []const u8) !usize {
    while (idx.* < text.len) {
        const node = try stream.feed(text[idx.*]);
        idx.* += 1;
        if (node) |n| {
            return n.depth;
        }
    }
    return error.ExhaustedLoop;
}

test "parsing depths" {
    const testing = std.testing;

    const text =
        \\# woo comment
        \\mp:10
        \\[[sy]]
        \\  # another
        \\  : n : "en"  ,  [[m]]
        \\    # more
        \\
        \\    # even more
        \\
        \\    "sc"   :  [[10]]   ,    g #inline
        \\  [[]]:[==[
        \\hi]==]
    ;
    var idx: usize = 0;
    var stream = StreamingParser.init();

    testing.expectEqual(try testNextLevelOrError(&stream, &idx, text), 0);
    testing.expectEqual(try testNextLevelOrError(&stream, &idx, text), 1);
    testing.expectEqual(try testNextLevelOrError(&stream, &idx, text), 0);
    testing.expectEqual(try testNextLevelOrError(&stream, &idx, text), 1);
    testing.expectEqual(try testNextLevelOrError(&stream, &idx, text), 2);
    testing.expectEqual(try testNextLevelOrError(&stream, &idx, text), 3);
    testing.expectEqual(try testNextLevelOrError(&stream, &idx, text), 3);
    testing.expectEqual(try testNextLevelOrError(&stream, &idx, text), 2);
    testing.expectEqual(try testNextLevelOrError(&stream, &idx, text), 3);
    testing.expectEqual(try testNextLevelOrError(&stream, &idx, text), 3);
    testing.expectEqual(try testNextLevelOrError(&stream, &idx, text), 1);
    testing.expectEqual(try testNextLevelOrError(&stream, &idx, text), 2);
}

/// A `ZNode`'s value. The `.String` is dynamic memory managed by the node. These should not be
/// created directly but through a `ZNode`.
pub const ZValue = union(enum) {
    const Self = @This();
    Null,
    // Unallocated, references text.
    StringRef: []const u8,
    // Allocated string.
    String: []u8,
    Int: i32,
    Float: f32,
    Bool: bool,
};

/// A `ZNode` in a zzz tree. The root `ZNode` will have a value of `.Null`.
pub const ZNode = struct {
    const Self = @This();
    parent: ?*ZNode,
    /// The `ZNode`s value.
    value: ZValue,
    /// The `ZNode`s children. Should really have to access this directly, but through the use
    /// of convenience functions.
    children: std.ArrayList(ZNode),

    /// Turns the `ZNode`s string value into a dynamic one if it isn't one already. Optionally
    /// recurses children. Essentially enforces ownership of string contents.
    pub fn makeDynamic(self: *Self, recurse: bool) anyerror!void {
        if (self.value == .StringRef) {
            try self.setString(self.value.StringRef);
        }
        if (recurse) {
            for (self.getChildren()) |*child| {
                try child.*.makeDynamic(recurse);
            }
        }
    }

    /// Create a `.Null` `ZNode`.
    pub fn initNull(allocator: *std.mem.Allocator) Self {
        return Self{
            .parent = null,
            .value = .Null,
            .children = std.ArrayList(ZNode).init(allocator),
        };
    }

    /// Create a `.String` `ZNode`. The string is managed by the node.
    pub fn initString(allocator: *std.mem.Allocator, value: []const u8) !Self {
        return Self{
            .parent = null,
            .value = .{.String = try allocator.dupeZ(u8, value)},
            .children = std.ArrayList(ZNode).init(allocator),
        };
    }

    /// Create a `.StringRef` `ZNode`. This is a string not managed by the node.
    pub fn initStringRef(allocator: *std.mem.Allocator, value: []const u8) !Self {
        return Self{
            .parent = null,
            .value = .{.StringRef = value},
            .children = std.ArrayList(ZNode).init(allocator),
        };
    }

    /// Create a `.Int` `ZNode`.
    pub fn initInt(allocator: *std.mem.Allocator, value: i32) Self {
        return Self{
            .parent = null,
            .value = .{.Int = value},
            .children = std.ArrayList(ZNode).init(allocator),
        };
    }

    /// Create a `.Float` `ZNode`.
    pub fn initFloat(allocator: *std.mem.Allocator, value: f32) Self {
        return Self{
            .parent = null,
            .value = .{.Float = value},
            .children = std.ArrayList(ZNode).init(allocator),
        };
    }

    /// Create a `.Bool` `ZNode`.
    pub fn initBool(allocator: *std.mem.Allocator, value: bool) Self {
        return Self{
            .parent = null,
            .value = .{.Bool = value},
            .children = std.ArrayList(ZNode).init(allocator),
        };
    }

    /// Sets the `ZNode`s value to `.Null`. Frees any memory currently allocated.
    pub fn setNull(self: *Self) void {
        if (self.value == .String) {
            self.children.allocator.free(self.value.String);
        }
        self.value = .Null;
    }

    /// Sets the `ZNode`s value to `.String`. Frees any memory currently allocated.
    pub fn setString(self: *Self, value: []const u8) !void {
        if (self.value == .String) {
            self.children.allocator.free(self.value.String);
        }
        self.value = .{.String = try self.children.allocator.dupeZ(u8, value)};
    }

    /// Sets the `ZNode`s value to `.StringRef`. Frees any memory currently allocated.
    pub fn setStringRef(self: *Self, value: []const u8) !void {
        if (self.value == .String) {
            self.children.allocator.free(self.value.String);
        }
        self.value = .{.StringRef = value};
    }

    /// Sets the `ZNode`s value to `.Int`. Frees any memory currently allocated.
    pub fn setInt(self: *Self, value: i32) void {
        if (self.value == .String) {
            self.children.allocator.free(self.value.String);
        }
        self.value = .{.Int = value};
    }

    /// Sets the `ZNode`s value to `.Float`. Frees any memory currently allocated.
    pub fn setFloat(self: *Self, value: f32) void {
        if (self.value == .String) {
            self.children.allocator.free(self.value.String);
        }
        self.value = .{.Float = value};
    }

    /// Sets the `ZNode`s value to `.Bool`. Frees any memory currently allocated.
    pub fn setBool(self: *Self, value: bool) void {
        if (self.value == .String) {
            self.children.allocator.free(self.value.String);
        }
        self.value = .{.Bool = value};
    }

    /// Returns true if this `ZNode`s value is of `.Null`.
    pub fn isNull(self: *const Self) bool {
        if (self.value == .Null) {
            return true;
        }
        return false;
    }

    /// Returns a reference to the string if this `ZNode`s value is one of `.String` or `.StringRef`.
    pub fn getString(self: *const Self) ?[]const u8 {
        if (self.value == .String) {
            return self.value.String;
        }
        if (self.value == .StringRef) {
            return self.value.StringRef;
        }
        return null;
    }

    /// Returns the integer if this `ZNode`s value is of `.Int`.
    pub fn getInt(self: *const Self) ?i32 {
        if (self.value == .Int) {
            return self.value.Int;
        }
        return null;
    }

    /// Returns the float if this `ZNode`s value is of `.Float`.
    pub fn getFloat(self: *const Self) ?f32 {
        if (self.value == .Float) {
            return self.value.Float;
        }
        return null;
    }

    /// Returns the boolean if this `ZNode`s value is of `.Bool`.
    pub fn getBool(self: *const Self) ?bool {
        if (self.value == .Bool) {
            return self.value.Bool;
        }
        return null;
    }

    /// Clears and frees all children under this `ZNode`.
    pub fn clearChildren(self: *Self) void {
        for (self.getChildren()) |*child| {
            child.deinit();
        }
        while (self.children.items.len > 0) {
            _ = self.children.pop();
        }
    }

    /// Frees the memory associated with the `ZNode` and its children.
    pub fn deinit(self: *const Self) void {
        switch (self.value) {
            // Use the ArrayLists's allocator, heh. Why store an extra pointer?
            .String => self.children.allocator.free(self.value.String),
            else => {}
        }
        for (self.children.items) |*child| {
            child.deinit();
        }
        self.children.deinit();
    }

    /// Appends a `.Null` `ZNode` to this `ZNode`s children.
    pub fn appendNull(self: *Self) !*ZNode {
        var node = ZNode.initNull(self.children.allocator);
        node.parent = self;
        try self.children.append(node);
        return &self.children.items[self.children.items.len - 1];
    }

    /// Appends a `.String` `ZNode` to this `ZNode`s children.
    pub fn appendString(self: *Self, string: []const u8) !*ZNode {
        var node = try ZNode.initString(self.children.allocator, string);
        node.parent = self;
        errdefer node.deinit();
        try self.children.append(node);
        return &self.children.items[self.children.items.len - 1];
    }

    /// Appends a `.StringRef` `ZNode` to this `ZNode`s children.
    pub fn appendStringRef(self: *Self, string: []const u8) !*ZNode {
        var node = try ZNode.initStringRef(self.children.allocator, string);
        node.parent = self;
        errdefer node.deinit();
        try self.children.append(node);
        return &self.children.items[self.children.items.len - 1];
    }

    /// Appends a `.Int` `ZNode` to this `ZNode`s children.
    pub fn appendInt(self: *Self, integer: i32) !*ZNode {
        var node = ZNode.initInt(self.children.allocator, integer);
        node.parent = self;
        errdefer node.deinit();
        try self.children.append(node);
        return &self.children.items[self.children.items.len - 1];
    }

    /// Appends a `.Float` `ZNode` to this `ZNode`s children.
    pub fn appendFloat(self: *Self, float: f32) !*ZNode {
        var node = ZNode.initFloat(self.children.allocator, float);
        node.parent = self;
        errdefer node.deinit();
        try self.children.append(node);
        return &self.children.items[self.children.items.len - 1];
    }

    /// Appends a `.Bool` `ZNode` to this `ZNode`s children.
    pub fn appendBool(self: *Self, boolean: bool) !*ZNode {
        var node = ZNode.initBool(self.children.allocator, boolean);
        node.parent = self;
        errdefer node.deinit();
        try self.children.append(node);
        return &self.children.items[self.children.items.len - 1];
    }

    /// Returns true if this `ZNode` has no children.
    pub inline fn isLeaf(self: *const Self) bool {
        return self.children.items.len == 0;
    }

    /// Returns the slice of the children. Becomes invalid after any appends or clears.
    pub inline fn getChildren(self: *const Self) std.ArrayList(ZNode).Slice {
        return self.children.items;
    }

    /// Returns the `nth` child or null.
    pub inline fn getChild(self: *const Self, nth: usize) ?*ZNode {
        if (nth < self.children.items.len) {
            return &self.children.items[nth];
        }
        return null;
    }

    /// Returns the number of children this `ZNode` has.
    pub inline fn getChildCount(self: *const Self) usize {
        return self.children.items.len;
    }

    /// Finds the `nth` child with the value of `.Null`.
    pub fn findNull(self: *const Self, nth: usize) ?*ZNode {
        var i: usize = 0;
        for (self.getChildren()) |*child| {
            if (child.*.value == .Null) {
                if (i == nth) {
                    return child;
                }
                i += 1;
            }
        }
        return null;
    }

    /// Finds the `nth` child with the value of `.String` matching the passed string.
    pub fn findString(self: *const Self, string: []const u8, nth: usize) ?*ZNode {
        var i: usize = 0;
        for (self.getChildren()) |*child| {
            if (child.*.value == .String or child.*.value == .StringRef) {
                const equal = if (child.*.value == .String)
                    std.mem.eql(u8, child.*.value.String, string)
                else
                    std.mem.eql(u8, child.*.value.StringRef, string);
                if (equal) {
                    if (i == nth) {
                        return child;
                    }
                    i += 1;
                }
            }
        }
        return null;
    }

    /// Finds the `nth` child with the value of `.String`.
    pub fn findAnyString(self: *const Self, nth: usize) ?*ZNode {
        var i: usize = 0;
        for (self.getChildren()) |*child| {
            if (child.*.value == .String or child.*.value == .StringRef) {
                if (i == nth) {
                    return child;
                }
                i += 1;
            }
        }
        return null;
    }

    /// Finds the `nth` child with the value of `.Int` matching the passed integer.
    pub fn findInt(self: *const Self, int: i32, nth: usize) ?*ZNode {
        var i: usize = 0;
        for (self.getChildren()) |*child| {
            if (child.*.value == .Int and child.*.value.Int == int) {
                if (i == nth) {
                    return child;
                }
                i += 1;
            }
        }
        return null;
    }

    /// Finds the `nth` child with the value of `.Int`.
    pub fn findAnyInt(self: *const Self, nth: usize) ?*ZNode {
        var i: usize = 0;
        for (self.getChildren()) |*child| {
            if (child.*.value == .Int) {
                if (i == nth) {
                    return child;
                }
                i += 1;
            }
        }
        return null;
    }

    /// Finds the `nth` child with the value of `.Float` matching the passed float using `approxEq`.
    pub fn findFloat(self: *const Self, float: f32, nth: usize) ?*ZNode {
        var i: usize = 0;
        for (self.getChildren()) |*child| {
            if (child.*.value == .Float and std.math.approxEq(f32, child.*.value.Float, float, std.math.f32_epsilon)) {
                if (i == nth) {
                    return child;
                }
                i += 1;
            }
        }
        return null;
    }

    /// Finds the `nth` child with the value of `.Float`.
    pub fn findAnyFloat(self: *const Self, nth: usize) ?*ZNode {
        var i: usize = 0;
        for (self.getChildren()) |*child| {
            if (child.*.value == .Float) {
                if (i == nth) {
                    return child;
                }
                i += 1;
            }
        }
        return null;
    }

    /// Finds the `nth` child with the value of `.Bool` matching the passed bool.
    pub fn findBool(self: *const Self, boolean: bool, nth: usize) ?*ZNode {
        var i: usize = 0;
        for (self.getChildren()) |*child| {
            if (child.*.value == .Bool and child.*.value.Bool == boolean) {
                if (i == nth) {
                    return child;
                }
                i += 1;
            }
        }
        return null;
    }

    /// Finds the `nth` child with the value of `.Bool`.
    pub fn findAnyBool(self: *const Self, nth: usize) ?*ZNode {
        var i: usize = 0;
        for (self.getChildren()) |*child| {
            if (child.*.value == .Bool) {
                if (i == nth) {
                    return child;
                }
                i += 1;
            }
        }
        return null;
    }

    fn show_(self: *const Self, index: usize) void {
        var i: usize = 0;
        while (i < index) : (i += 1) {
            std.debug.print("  ", .{});
        }
        std.debug.print("{}:\n", .{self.value});
        for (self.children.items) |item| {
            item.show_(index + 1);
        }
    }

    /// Debug prints the values using `std.debug.print`.
    pub fn show(self: *const Self) void {
        self.show_(0);
    }

    /// Checks to enable or disable when calling `imprint`.
    pub const ImbueChecks = packed struct {
        /// Return an error when a struct field is missing from the node tree.
        field_exists: bool = false,
        /// Returns an error when a field's node exists, but the value doesn't.
        child_exists: bool = false,
        /// Returns an error when a node's value is of the wrong type.
        correct_type: bool = true,
        /// Returns an error when a node couldn't be converted to an enum.
        enum_converted: bool = true,
        /// Returns an error when passed invalid types (even on the struct).
        invalid_types: bool = true,
    };

    /// Projects this node into a type. The only types allowed are zzz types, structs, fixed arrays,
    /// optionals, and enums. This function performs no allocations and u8 slices refer to strings
    /// by reference. Enums can be mapped from string or int. There are a few optional checks:
    ///
    /// - `.NoCheck` perform no checks, if something can fit it'll fit.
    /// - `.CheckField`
    ///
    /// TODO: Removing anyerror causes infinite loop.
    pub fn imprint(self: *const Self, checks: ImbueChecks, onto_ptr: anytype) anyerror!void {
        std.debug.assert(@typeInfo(@TypeOf(onto_ptr)) == .Pointer);
        const T = @typeInfo(@TypeOf(onto_ptr)).Pointer.child;
        switch (@typeInfo(T)) {
            .Bool => {
                if (self.getChild(0)) |child| {
                    onto_ptr.* = switch (child.value) {
                        .Bool => |b| b,
                        else => if (checks.correct_type) return error.ExpectedBool else return,
                    };
                } else if (checks.child_exists) {
                    return error.ChildDoesNotExist;
                }
            },
            .Float, .ComptimeFloat => {
                if (self.getChild(0)) |child| {
                    onto_ptr.* = switch (child.value) {
                        .Float => |n| @floatCast(f32, n),
                        else => if (checks.correct_type) return error.ExpectedFloat else return,
                    };
                } else if (checks.child_exists) {
                    return error.ChildDoesNotExist;
                }
            },
            .Int, .ComptimeInt => {
                if (self.getChild(0)) |child| {
                    onto_ptr.* = switch (child.value) {
                        .Int => |n| @intCast(i32, n),
                        else => if (checks.correct_type) return error.ExpectedInt else return,
                    };
                } else if (checks.child_exists) {
                    return error.ChildDoesNotExist;
                }
            },
            .Enum => {
                if (self.getChild(0)) |child| {
                    switch (child.value) {
                        .Int => |int| {
                            onto_ptr.* = try std.meta.intToEnum(T, int);
                        },
                        .String, .StringRef => {
                            if (std.meta.stringToEnum(T, child.getString().?)) |e| {
                                onto_ptr.* = e;
                            } else {
                                return if (checks.enum_converted) error.CouldNotConvertStringToEnum;
                            }
                        },
                        else => if (checks.correct_type) return error.ExpectedIntOrString,
                    }
                    return;
                } else if (checks.child_exists) {
                    return error.ChildDoesNotExist;
                }
            },
            .Optional => |opt_info| {
                var t: opt_info.child = undefined;
                var err = false;
                self.imprint(checks, &t) catch |e| {
                    std.debug.print("ERR {}\n", .{e});
                    if (e != error.ChildDoesNotExist) {
                        return e;
                    }
                    err = true;
                };
                if (!err) { onto_ptr.* = t; }
            },
            .Struct => |struct_info| {
                var r: T = T{};
                inline for (struct_info.fields) |field, i| {
                    if (self.findString(field.name, 0)) |child| {
                        try child.imprint(checks, &@field(r, field.name));
                    } else if (checks.field_exists) {
                        return error.FieldDoesNotExist;
                    }
                }
                onto_ptr.* = r;
            },
            // Only handle [N]?T, where T is any other valid type.
            .Array => |array_info| {
                var r = std.mem.zeroes(T);
                var i: usize = 0;
                while (i < r.len) : (i += 1) {
                    if (i >= self.getChildCount()) {
                        break;
                    }
                    try self.getChild(i).?.imprint(checks, &r[i]);
                }
                onto_ptr.* = r;
            },
            // Only handle []const u8 and ZNode pointers.
            .Pointer => |ptr_info| {
                switch (ptr_info.size) {
                    .One => {
                        if (ptr_info.child != ZNode) {
                            if (checks.invalid_types) {
                                return error.ExpectedZNodePointer;
                            }
                        } else {
                            onto_ptr.* = self;
                        }
                    },
                    .Slice => {
                        switch (self.value) {
                            .String, .StringRef => {
                                if (ptr_info.child != u8) {
                                    if (checks.invalid_types) {
                                        return error.NonStringSlice;
                                    }
                                } else {
                                    if (self.getChild(0)) |child| {
                                        onto_ptr.* = child.getString().?;
                                    } else if (checks.child_exists) {
                                        return error.ChildDoesNotExist;
                                    }
                                }
                            },
                            else => if (checks.correct_type) return error.ExpectedStringNode,
                        }
                        return;
                    },
                    else => if (checks.invalid_types) return error.InvalidType,
                }
            },
            else => if (checks.invalid_types) return error.InvalidType,
        }
    }
};

test "node conforming imprint" {
    const testing = std.testing;

    const ConformingEnum = enum {
        Foo,
    };

    const ConformingSubStruct = struct {
        name: []const u8 = "default",
        params: *const ZNode = undefined,
    };

    const ConformingStruct = struct {
        max_particles: ?i32 = undefined,
        texture: []const u8 = "default",
        systems: [20]?ConformingSubStruct = [_]?ConformingSubStruct{null} ** 20,
        en: ?ConformingEnum = null,
    };

    const text =
        \\max_particles: 100
        \\texture: circle
        \\en: Foo
        \\systems:
        \\  : name:Emitter
        \\    params:
        \\      some,stuff,hehe
        \\  : name:Fire
        \\    params
    ;
    var node = try parse(testing.allocator, &ParseOptions{}, text);
    defer node.deinit();

    var example = ConformingStruct{};
    try node.imprint(ZNode.ImbueChecks{
        .field_exists = true, .child_exists = true,
        .correct_type = true,
    }, &example);
    testing.expectEqual(@as(i32, 100), example.max_particles.?);
    testing.expectEqualSlices(u8, "circle", example.texture);
    testing.expect(null != example.systems[0]);
    testing.expect(null != example.systems[1]);
    testing.expectEqual(@as(?ConformingSubStruct, null), example.systems[2]);
    testing.expectEqual(ConformingEnum.Foo, example.en.?);
    testing.expectEqualSlices(u8, "params", example.systems[0].?.params.getString().?);
}

test "node nonconforming imprint" {
    const testing = std.testing;

    const NonConformingStruct = struct {
        max_particles: bool = undefined,
        no_exist: bool = undefined,
    };

    const text =
        \\max_particles: 100
        \\texture: circle
        \\en: Foo
        \\systems:
        \\  : name:Emitter
        \\    params:
        \\      some,stuff,hehe
        \\  : name:Fire
    ;
    var node = try parse(testing.allocator, &ParseOptions{}, text);
    defer node.deinit();

    var example = NonConformingStruct{};
    try node.imprint(ZNode.ImbueChecks{.correct_type = false}, &example);
    testing.expectError(error.FieldDoesNotExist, node.imprint(ZNode.ImbueChecks{.field_exists = true, .correct_type = false}, &example));
}

test "node initialization and setting" {
    const testing = std.testing;
    var root = ZNode.initNull(testing.allocator);
    defer root.deinit();

    testing.expect(root.isNull());
    try root.setString("Hello, world");
    testing.expectEqualSlices(u8, "Hello, world", root.getString() orelse unreachable);
    try root.setStringRef("Hello, world");
    testing.expectEqualSlices(u8, "Hello, world", root.getString() orelse unreachable);
    root.setInt(42);
    testing.expectEqual(@as(i32, 42), root.getInt() orelse unreachable);
    root.setFloat(0.001);
    testing.expect(std.math.approxEq(f32, 0.001, root.getFloat() orelse unreachable, std.math.f32_epsilon));
    root.setBool(true);
    testing.expectEqual(true, root.getBool() orelse unreachable);

}

test "node appending and searching" {
    const testing = std.testing;

    var root = ZNode.initNull(testing.allocator);
    defer root.deinit();

    var nullChild = try root.appendNull();
    var stringChild = try root.appendString("Hello");
    var fooChild = try root.appendString("foo");
    var integerChild = try root.appendInt(42);
    var floatChild = try root.appendFloat(3.14);
    var boolChild = try root.appendBool(true);

    testing.expectEqual(@as(usize, 6), root.getChildCount());
    testing.expect(root.findNull(0) != null);

    testing.expect(root.findString("Hello", 0) != null);
    testing.expect(root.findString("foo", 0) != null);
    testing.expect(root.findString("Hello", 1) == null);
    testing.expect(root.findString("foo", 1) == null);
    testing.expect(root.findAnyString(0) != null);
    testing.expect(root.findAnyString(1) != null);
    testing.expect(root.findAnyString(2) == null);

    testing.expect(root.findInt(42, 0) != null);
    testing.expect(root.findInt(41, 0) == null);
    testing.expect(root.findInt(42, 1) == null);
    testing.expect(root.findAnyInt(0) != null);
    testing.expect(root.findAnyInt(1) == null);

    testing.expect(root.findFloat(3.14, 0) != null);
    testing.expect(root.findFloat(3.13, 0) == null);
    testing.expect(root.findFloat(3.14, 1) == null);
    testing.expect(root.findAnyFloat(0) != null);
    testing.expect(root.findAnyFloat(1) == null);

    testing.expect(root.findAnyBool(0) != null);
    testing.expect(root.findBool(true, 0) != null);
    testing.expect(root.findAnyBool(1) == null);
    testing.expect(root.findBool(true, 1) == null);

    root.clearChildren();
    testing.expect(root.isLeaf());
}

/// Max number of `Transformer`.
pub const MAX_TRANSFORMERS = 8;
/// Transformer function. Level is tree depth past root, so top depth nodes have a depth of 0.
pub const Transformer = fn(new_node: *ZNode, depth: usize) anyerror!void;

/// Parsing options, including custom `Transformer` to control how or if to translate strings.
pub const ParseOptions = struct {
    /// Enabled owned strings in output `ZNode`. By defaults nodes reference the source text.
    owned_strings: bool = false,
    /// Use the default `Transformer` (tries translating to float->int->bool).
    use_default_transformer: bool = true,
    /// Custom `Transformer`. `Transformers` are called in order on each new `ZNode`.
    transformers: [MAX_TRANSFORMERS]?Transformer = [_]?Transformer{null} ** MAX_TRANSFORMERS,
};

fn defaultTransformer(new_node: *ZNode, depth: usize) !void {
    // Try to cast to numbers, then true/false checks, then string.
    const slice = new_node.getString() orelse unreachable;
    const integer = std.fmt.parseInt(i32, slice, 10) catch |_| {
        const float = std.fmt.parseFloat(f32, slice) catch |_| {
            if (std.mem.eql(u8, "true", slice)) {
                new_node.setBool(true);
            } else if (std.mem.eql(u8, "false", slice)) {
                new_node.setBool(false);
            } else {
                // Do nothing.
            }
            return;
        };
        new_node.setFloat(float);
        return;
    };
    new_node.setInt(integer);
}

fn parseText(stream: *StreamingParser, idx: *usize, text: []const u8) !?ZNodeToken {
    while (idx.* <= text.len) {
        // Insert an extra newline at the end of the stream.
        const node = if (idx.* == text.len) try stream.feed('\n') else try stream.feed(text[idx.*]);
        idx.* += 1;
        if (node) |n| {
            return n;
        }
    }
    return null;
}

/// Parses a text block and returns the root `ZNode`. All `ZNode`s will just reference the text and
/// will not make any string allocations.
pub fn parse(allocator: *std.mem.Allocator, options: *const ParseOptions, text: []const u8) !ZNode {
    const MAX_DEPTH = 256;
    var stack: [MAX_DEPTH]*ZNode = undefined;
    var node = ZNode.initNull(allocator);
    stack[0] = &node;
    var stack_depth: usize = 0;
    errdefer stack[0].deinit();

    var stream = StreamingParser.init();
    var idx: usize = 0;
    while (try parseText(&stream, &idx, text)) |token| {
        const slice = text[token.start..token.end];
        if (token.depth <= stack_depth) {
            stack_depth = token.depth;
        } else if (token.depth == stack_depth + 1) {
            // Descend.
            const len = stack[stack_depth].children.items.len;
            stack[stack_depth + 1] = &stack[stack_depth].children.items[len - 1];
            stack_depth += 1;
        } else {
            // Levels shouldn't increase by more than one.
            unreachable;
        }
        if (slice.len == 0) {
            _ = try stack[stack_depth].appendNull();
            continue;
        }
        var new_node = try stack[stack_depth].appendStringRef(slice);
        if (options.use_default_transformer) {
            try defaultTransformer(new_node, stack_depth);
        }
        var trans_idx: usize = 0;
        while (options.transformers[trans_idx]) |tf| : (trans_idx += 1)  {
            try tf(new_node, stack_depth);
        }
    }

    if (!stream.hasCompleted()) {
        return error.UnfinishedString;
    }

    if (options.owned_strings) {
        try node.makeDynamic(true);
    }

    return node;
}

/// Outputs a value to the `out_stream`. This output is a parsable.
pub fn stringifyValue(value: ZValue, out_stream: anytype) @TypeOf(out_stream).Error!void {
    switch (value) {
        .Null => {
            // Skip.
        },
        .String, .StringRef => {
            const find = std.mem.indexOfScalar;
            const chars = "\"\n\t\r,:;";
            const chars_count = @sizeOf(@TypeOf(chars));
            var need_escape = false;
            var found = [_]bool{false} ** chars_count;
            for ("\"\n\t\r,:;") |ch, i| {
                const f = if (value == .String) find(u8, value.String, ch) else find(u8, value.StringRef, ch);
                if (f != null) {
                    found[i] = true;
                    need_escape = true;
                }
            }
            if (need_escape) {
                // 0=" 1=\n
                if (found[0] or found[1]) {
                    // Escape with Lua.
                    try out_stream.writeAll("[[");
                    const ret = if (value == .String) try out_stream.writeAll(value.String) else out_stream.writeAll(value.StringRef);
                    try out_stream.writeAll("]]");
                    return ret;
                } else {
                    // Escape with basic quotes.
                    try out_stream.writeAll("\"");
                    const ret = if (value == .String) try out_stream.writeAll(value.String) else out_stream.writeAll(value.StringRef);
                    try out_stream.writeAll("\"");
                    return ret;
                }
            }
            return if (value == .String) try out_stream.writeAll(value.String) else out_stream.writeAll(value.StringRef);
        },
        .Int => {
            return std.fmt.formatIntValue(value.Int, "", std.fmt.FormatOptions{}, out_stream);
        },
        .Float => {
            return std.fmt.formatFloatScientific(value.Float, std.fmt.FormatOptions{}, out_stream);
        },
        .Bool => {
            return out_stream.writeAll(if (value.Bool) "true" else "false");
        }
    }
}

/// Outputs a `ZNode` and its children on a single line. This can be parsed back.
pub fn stringifyNode(node: ZNode, out_stream: anytype) @TypeOf(out_stream).Error!void {
    try stringifyValue(node.value, out_stream);
    if (node.children.items.len == 0) {
        return;
    }
    try out_stream.writeAll(":");
    for (node.children.items) |child, i| {
        try stringifyNode(child, out_stream);
        if (i != node.children.items.len - 1 and child.children.items.len == 0) {
            try out_stream.writeAll(",");
        }
    }
    try out_stream.writeAll(";");
}

/// Stringifies the root `ZNode`s children. Each on their own line.
pub fn stringify(node: ZNode, out_stream: anytype) @TypeOf(out_stream).Error!void {
    for (node.children.items) |child, i| {
        try stringifyNode(child, out_stream);
        try out_stream.writeAll("\n");
    }
}

test "parsing into nodes" {
    const testing = std.testing;
    const text1 =
        \\elements: fire,water,air,earth
        \\subelements:
        \\  fire: lightning
        \\  water: blood; ice
        \\  air: spirit
        \\  earth: [[metal]]
    ;
    const text2 =
        \\elements:fire,water,air,earth;
        \\subelements:fire:lightning;water:blood;ice,air:spirit,;earth:metal;;
    ;
    const text =
        \\name:wizard;
        \\stats
        \\  : health:10
        \\    mana:30
    ;
    const node = try parse(testing.allocator, &ParseOptions{.use_default_transformer = false}, text);
    //node.show();
    //var out = std.io.getStdOut().writer();
    //try stringify(node, out);

    defer node.deinit();
}
