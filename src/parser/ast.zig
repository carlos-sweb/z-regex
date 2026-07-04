//! Abstract Syntax Tree for regex patterns
//!
//! This module defines the AST node types that represent
//! the structure of a parsed regex pattern.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// AST node types
pub const NodeType = enum {
    // Literals
    char, // Single character
    char_range, // Character range [a-z]
    char_class, // Character class [abc]
    dot, // Any character

    // Quantifiers (greedy)
    star, // Zero or more (greedy)
    plus, // One or more (greedy)
    question, // Zero or one (greedy)
    repeat, // {n,m}

    // Lazy quantifiers
    lazy_star, // Zero or more (lazy)
    lazy_plus, // One or more (lazy)
    lazy_question, // Zero or one (lazy)
    lazy_repeat, // {n,m}?

    // Possessive quantifiers (atomic, no backtracking)
    possessive_star, // Zero or more (possessive)
    possessive_plus, // One or more (possessive)
    possessive_question, // Zero or one (possessive)

    // Grouping
    group, // (...) capturing group
    non_capturing_group, // (?:...) non-capturing group
    alternation, // a|b

    // Backreferences
    back_ref, // \1, \2, ..., \9

    // Sequences
    sequence, // Concatenation

    // Anchors
    anchor_start, // ^
    anchor_end, // $
    word_boundary, // \b
    not_word_boundary, // \B

    // Assertions
    lookahead, // (?=...)
    negative_lookahead, // (?!...)
    lookbehind, // (?<=...)
    negative_lookbehind, // (?<!...)
};

/// AST Node
pub const Node = struct {
    type: NodeType,
    allocator: Allocator,

    /// Character value (for char node)
    char_value: u32 = 0,

    /// Range values (for char_range)
    range_start: u32 = 0,
    range_end: u32 = 0,

    /// Repeat counts (for repeat)
    repeat_min: u32 = 0,
    repeat_max: u32 = 0,

    /// Child nodes (for complex nodes)
    children: std.ArrayListUnmanaged(*Node) = .empty,

    /// Group index (for capture groups and backreferences)
    group_index: u8 = 0,

    /// Whether this is an inverted/negated character class
    inverted: bool = false,

    const Self = @This();

    /// Create a character node
    pub fn createChar(allocator: Allocator, c: u32) !*Node {
        const node = try allocator.create(Node);
        node.* = .{
            .type = .char,
            .allocator = allocator,
            .char_value = c,
        };
        return node;
    }

    /// Create a character range node
    pub fn createCharRange(allocator: Allocator, start: u32, end: u32) !*Node {
        const node = try allocator.create(Node);
        node.* = .{
            .type = .char_range,
            .allocator = allocator,
            .range_start = start,
            .range_end = end,
        };
        return node;
    }

    /// Create a character class node
    pub fn createCharClass(allocator: Allocator) !*Node {
        const node = try allocator.create(Node);
        node.* = .{
            .type = .char_class,
            .allocator = allocator,
        };
        return node;
    }

    /// Create a dot node
    pub fn createDot(allocator: Allocator) !*Node {
        const node = try allocator.create(Node);
        node.* = .{
            .type = .dot,
            .allocator = allocator,
        };
        return node;
    }

    /// Create a quantifier node
    pub fn createQuantifier(allocator: Allocator, qtype: NodeType, child: *Node) !*Node {
        const node = try allocator.create(Node);
        node.* = .{
            .type = qtype,
            .allocator = allocator,
        };
        try node.children.append(allocator, child);
        return node;
    }

    /// Create a repeat node
    pub fn createRepeat(allocator: Allocator, child: *Node, min: u32, max: u32) !*Node {
        const node = try allocator.create(Node);
        node.* = .{
            .type = .repeat,
            .allocator = allocator,
            .repeat_min = min,
            .repeat_max = max,
        };
        try node.children.append(allocator, child);
        return node;
    }

    /// Create a lazy repeat node {n,m}?
    pub fn createLazyRepeat(allocator: Allocator, child: *Node, min: u32, max: u32) !*Node {
        const node = try allocator.create(Node);
        node.* = .{
            .type = .lazy_repeat,
            .allocator = allocator,
            .repeat_min = min,
            .repeat_max = max,
        };
        try node.children.append(allocator, child);
        return node;
    }

    /// Create a sequence node
    pub fn createSequence(allocator: Allocator) !*Node {
        const node = try allocator.create(Node);
        node.* = .{
            .type = .sequence,
            .allocator = allocator,
        };
        return node;
    }

    /// Create an alternation node
    pub fn createAlternation(allocator: Allocator, left: *Node, right: *Node) !*Node {
        const node = try allocator.create(Node);
        node.* = .{
            .type = .alternation,
            .allocator = allocator,
        };
        try node.children.append(allocator, left);
        try node.children.append(allocator, right);
        return node;
    }

    /// Create a group node
    pub fn createGroup(allocator: Allocator, child: *Node, index: u8) !*Node {
        const node = try allocator.create(Node);
        node.* = .{
            .type = .group,
            .allocator = allocator,
            .group_index = index,
        };
        try node.children.append(allocator, child);
        return node;
    }

    /// Create a non-capturing group node
    pub fn createNonCapturingGroup(allocator: Allocator, child: *Node) !*Node {
        const node = try allocator.create(Node);
        node.* = .{
            .type = .non_capturing_group,
            .allocator = allocator,
        };
        try node.children.append(allocator, child);
        return node;
    }

    /// Create a backreference node
    pub fn createBackRef(allocator: Allocator, group: u8) !*Node {
        const node = try allocator.create(Node);
        node.* = .{
            .type = .back_ref,
            .allocator = allocator,
            .group_index = group,
        };
        return node;
    }

    /// Create an anchor node
    pub fn createAnchor(allocator: Allocator, anchor_type: NodeType) !*Node {
        const node = try allocator.create(Node);
        node.* = .{
            .type = anchor_type,
            .allocator = allocator,
        };
        return node;
    }

    /// Create a lookahead node
    pub fn createLookahead(allocator: Allocator, child: *Node, negative: bool) !*Node {
        const node = try allocator.create(Node);
        node.* = .{
            .type = if (negative) .negative_lookahead else .lookahead,
            .allocator = allocator,
        };
        try node.children.append(allocator, child);
        return node;
    }

    /// Create a lookbehind assertion node
    pub fn createLookbehind(allocator: Allocator, child: *Node, negative: bool) !*Node {
        const node = try allocator.create(Node);
        node.* = .{
            .type = if (negative) .negative_lookbehind else .lookbehind,
            .allocator = allocator,
        };
        try node.children.append(allocator, child);
        return node;
    }

    /// Add a child node
    pub fn appendChild(self: *Self, child: *Node) !void {
        try self.children.append(self.allocator, child);
    }

    /// Free the node and all its children
    pub fn deinit(self: *Self) void {
        for (self.children.items) |child| {
            child.deinit();
        }
        self.children.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    /// Pretty print the AST
    pub fn print(self: Self, writer: anytype, indent: usize) !void {
        // Print indentation
        for (0..indent) |_| {
            try writer.writeAll("  ");
        }

        // Print node type
        try writer.print("{s}", .{@tagName(self.type)});

        // Print node-specific data
        switch (self.type) {
            .char => try writer.print(" '{c}'", .{@as(u8, @intCast(self.char_value))}),
            .char_range => try writer.print(" [{c}-{c}]", .{
                @as(u8, @intCast(self.range_start)),
                @as(u8, @intCast(self.range_end)),
            }),
            .repeat => try writer.print(" {{{},{}}}", .{ self.repeat_min, self.repeat_max }),
            .group => try writer.print(" (group {})", .{self.group_index}),
            else => {},
        }

        try writer.writeAll("\n");

        // Print children
        for (self.children.items) |child| {
            try child.print(writer, indent + 1);
        }
    }
};

// =============================================================================
// Tests
// =============================================================================

test "Node: createChar" {
    const node = try Node.createChar(std.testing.allocator, 'a');
    defer node.deinit();

    try std.testing.expectEqual(NodeType.char, node.type);
    try std.testing.expectEqual(@as(u32, 'a'), node.char_value);
}

test "Node: createCharRange" {
    const node = try Node.createCharRange(std.testing.allocator, 'a', 'z');
    defer node.deinit();

    try std.testing.expectEqual(NodeType.char_range, node.type);
    try std.testing.expectEqual(@as(u32, 'a'), node.range_start);
    try std.testing.expectEqual(@as(u32, 'z'), node.range_end);
}

test "Node: createDot" {
    const node = try Node.createDot(std.testing.allocator);
    defer node.deinit();

    try std.testing.expectEqual(NodeType.dot, node.type);
}

test "Node: createQuantifier" {
    const child = try Node.createChar(std.testing.allocator, 'a');
    const node = try Node.createQuantifier(std.testing.allocator, .star, child);
    defer node.deinit();

    try std.testing.expectEqual(NodeType.star, node.type);
    try std.testing.expectEqual(@as(usize, 1), node.children.items.len);
    try std.testing.expectEqual(NodeType.char, node.children.items[0].type);
}

test "Node: createRepeat" {
    const child = try Node.createChar(std.testing.allocator, 'a');
    const node = try Node.createRepeat(std.testing.allocator, child, 2, 5);
    defer node.deinit();

    try std.testing.expectEqual(NodeType.repeat, node.type);
    try std.testing.expectEqual(@as(u32, 2), node.repeat_min);
    try std.testing.expectEqual(@as(u32, 5), node.repeat_max);
    try std.testing.expectEqual(@as(usize, 1), node.children.items.len);
}

test "Node: createSequence" {
    const seq = try Node.createSequence(std.testing.allocator);
    defer seq.deinit();

    const a = try Node.createChar(std.testing.allocator, 'a');
    const b = try Node.createChar(std.testing.allocator, 'b');

    try seq.appendChild(a);
    try seq.appendChild(b);

    try std.testing.expectEqual(NodeType.sequence, seq.type);
    try std.testing.expectEqual(@as(usize, 2), seq.children.items.len);
}

test "Node: createAlternation" {
    const left = try Node.createChar(std.testing.allocator, 'a');
    const right = try Node.createChar(std.testing.allocator, 'b');
    const node = try Node.createAlternation(std.testing.allocator, left, right);
    defer node.deinit();

    try std.testing.expectEqual(NodeType.alternation, node.type);
    try std.testing.expectEqual(@as(usize, 2), node.children.items.len);
}

test "Node: createGroup" {
    const child = try Node.createChar(std.testing.allocator, 'a');
    const node = try Node.createGroup(std.testing.allocator, child, 1);
    defer node.deinit();

    try std.testing.expectEqual(NodeType.group, node.type);
    try std.testing.expectEqual(@as(u8, 1), node.group_index);
    try std.testing.expectEqual(@as(usize, 1), node.children.items.len);
}

test "Node: createAnchor" {
    const node = try Node.createAnchor(std.testing.allocator, .anchor_start);
    defer node.deinit();

    try std.testing.expectEqual(NodeType.anchor_start, node.type);
}

test "Node: print simple" {
    const node = try Node.createChar(std.testing.allocator, 'a');
    defer node.deinit();

    const allocator = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    try node.print(&aw.writer, 0);

    const output = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, output, "char") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "'a'") != null);
}

test "Node: print tree" {
    const seq = try Node.createSequence(std.testing.allocator);
    defer seq.deinit();

    const a = try Node.createChar(std.testing.allocator, 'a');
    const b = try Node.createChar(std.testing.allocator, 'b');

    try seq.appendChild(a);
    try seq.appendChild(b);

    const allocator = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    try seq.print(&aw.writer, 0);

    const output = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, output, "sequence") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "char") != null);
}

test "Node: complex tree" {
    // Build AST for: (a|b)+
    const a = try Node.createChar(std.testing.allocator, 'a');
    const b = try Node.createChar(std.testing.allocator, 'b');
    const alt = try Node.createAlternation(std.testing.allocator, a, b);
    const group = try Node.createGroup(std.testing.allocator, alt, 1);
    const plus = try Node.createQuantifier(std.testing.allocator, .plus, group);
    defer plus.deinit();

    try std.testing.expectEqual(NodeType.plus, plus.type);
    try std.testing.expectEqual(@as(usize, 1), plus.children.items.len);

    const group_node = plus.children.items[0];
    try std.testing.expectEqual(NodeType.group, group_node.type);
    try std.testing.expectEqual(@as(usize, 1), group_node.children.items.len);

    const alt_node = group_node.children.items[0];
    try std.testing.expectEqual(NodeType.alternation, alt_node.type);
    try std.testing.expectEqual(@as(usize, 2), alt_node.children.items.len);
}
