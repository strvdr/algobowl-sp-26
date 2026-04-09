// verify.zig — Standalone verifier for Enclose Horse solutions.
//
// Usage: zig build-exe verify.zig && ./verify <input_file> <output_file>
//
// Checks:
//   1. Output grid dimensions match input grid dimensions.
//   2. Only grass tiles ('.') were changed to walls ('W'), and only pre-placed
//      walls ('W') were optionally changed back to grass ('.').
//   3. Total walls placed <= budget.
//   4. Horse cannot reach any perimeter tile (BFS with portal traversal).
//   5. Reported score on line 1 matches the actual computed score.

const std = @import("std");

// ─── Types ───────────────────────────────────────────────────────────────────

const CellType = enum {
    water,
    grass,
    wall,
    horse,
    cherry,
    apple,
    bee,
    portal,

    pub fn score(self: CellType) i32 {
        return switch (self) {
            .apple => 11,
            .cherry => 4,
            .bee => -4,
            else => 1,
        };
    }

    pub fn char(self: CellType) u8 {
        return switch (self) {
            .water => '#',
            .grass => '.',
            .wall => 'W',
            .horse => 'H',
            .apple => 'a',
            .bee => 'b',
            .cherry => 'c',
            .portal => 'p',
        };
    }
};

const PortalPair = struct {
    r1: usize,
    c1: usize,
    r2: usize,
    c2: usize,
};

const Pos = struct {
    row: usize,
    col: usize,
};

// ─── Parsing helpers ─────────────────────────────────────────────────────────

fn parseCellType(ch: u8) !CellType {
    return switch (ch) {
        '#' => .water,
        '.' => .grass,
        'W' => .wall,
        'H' => .horse,
        'a' => .apple,
        'b' => .bee,
        'c' => .cherry,
        'p' => .portal,
        else => return error.UnknownCell,
    };
}

const GridParseResult = struct {
    grid: []CellType,
    horseRow: usize,
    horseCol: usize,
    horseFound: bool,
};

/// Parse grid lines from a line iterator into a flat row-major array.
fn parseGrid(
    allocator: std.mem.Allocator,
    lines: *std.mem.TokenIterator(u8, .scalar),
    rows: usize,
    cols: usize,
) !GridParseResult {
    const grid = try allocator.alloc(CellType, rows * cols);
    var horseRow: usize = 0;
    var horseCol: usize = 0;
    var horseFound = false;

    for (0..rows) |r| {
        const raw = lines.next() orelse return error.InvalidInput;
        const line = std.mem.trim(u8, raw, " \r");
        if (line.len != cols) {
            std.debug.print("ERROR: Row {d} has {d} columns, expected {d}\n", .{ r, line.len, cols });
            return error.DimensionMismatch;
        }
        for (line, 0..) |ch, c| {
            const ct = try parseCellType(ch);
            grid[r * cols + c] = ct;
            if (ct == .horse) {
                horseRow = r;
                horseCol = c;
                horseFound = true;
            }
        }
    }

    return .{ .grid = grid, .horseRow = horseRow, .horseCol = horseCol, .horseFound = horseFound };
}

// ─── BFS ─────────────────────────────────────────────────────────────────────

const BFSResult = struct {
    score: i32,
    reachesBoundary: bool,
    reachableCount: usize,
};

fn bfsFromHorse(
    grid: []const CellType,
    rows: usize,
    cols: usize,
    horseRow: usize,
    horseCol: usize,
    portals: []const PortalPair,
    allocator: std.mem.Allocator,
) !BFSResult {
    const n = rows * cols;
    const visited = try allocator.alloc(bool, n);
    defer allocator.free(visited);
    @memset(visited, false);

    const queue = try allocator.alloc(Pos, n);
    defer allocator.free(queue);

    var head: usize = 0;
    var tail: usize = 0;

    const startIdx = horseRow * cols + horseCol;
    visited[startIdx] = true;
    queue[tail] = .{ .row = horseRow, .col = horseCol };
    tail += 1;

    var totalScore: i32 = 0;
    var reachesBoundary = false;
    var reachableCount: usize = 0;

    while (head < tail) {
        const cur = queue[head];
        head += 1;
        reachableCount += 1;

        const ci = cur.row * cols + cur.col;
        totalScore += grid[ci].score();

        if (cur.row == 0 or cur.row == rows - 1 or cur.col == 0 or cur.col == cols - 1) {
            reachesBoundary = true;
        }

        // Cardinal neighbors
        const deltas = [_][2]i32{ .{ -1, 0 }, .{ 1, 0 }, .{ 0, -1 }, .{ 0, 1 } };
        for (deltas) |d| {
            const nr_i = @as(i32, @intCast(cur.row)) + d[0];
            const nc_i = @as(i32, @intCast(cur.col)) + d[1];
            if (nr_i < 0 or nr_i >= @as(i32, @intCast(rows))) continue;
            if (nc_i < 0 or nc_i >= @as(i32, @intCast(cols))) continue;
            const nr: usize = @intCast(nr_i);
            const nc: usize = @intCast(nc_i);
            const ni = nr * cols + nc;
            if (visited[ni]) continue;
            const ct = grid[ni];
            if (ct == .water or ct == .wall) continue;
            visited[ni] = true;
            queue[tail] = .{ .row = nr, .col = nc };
            tail += 1;
        }

        // Portal traversal
        if (grid[ci] == .portal) {
            for (portals) |pp| {
                const partner = portalPartner(pp, cur.row, cur.col) orelse continue;
                const pi = partner.row * cols + partner.col;
                if (!visited[pi]) {
                    visited[pi] = true;
                    queue[tail] = partner;
                    tail += 1;
                }
            }
        }
    }

    return .{ .score = totalScore, .reachesBoundary = reachesBoundary, .reachableCount = reachableCount };
}

fn portalPartner(pp: PortalPair, row: usize, col: usize) ?Pos {
    if (row == pp.r1 and col == pp.c1) return .{ .row = pp.r2, .col = pp.c2 };
    if (row == pp.r2 and col == pp.c2) return .{ .row = pp.r1, .col = pp.c1 };
    return null;
}

// ─── Main ────────────────────────────────────────────────────────────────────

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 3) {
        std.debug.print("Usage: verify <input_file> <output_file>\n", .{});
        return error.MissingArgument;
    }

    const inputData = try std.fs.cwd().readFileAlloc(allocator, args[1], 1024 * 1024);
    defer allocator.free(inputData);

    const outputData = try std.fs.cwd().readFileAlloc(allocator, args[2], 1024 * 1024);
    defer allocator.free(outputData);

    // ── Parse input ──────────────────────────────────────────────────────

    var inLines = std.mem.tokenizeScalar(u8, inputData, '\n');

    const budgetStr = std.mem.trim(u8, inLines.next() orelse return error.InvalidInput, " \r");
    const budget = try std.fmt.parseInt(u32, budgetStr, 10);

    const dimLine = std.mem.trim(u8, inLines.next() orelse return error.InvalidInput, " \r");
    var dims = std.mem.tokenizeScalar(u8, dimLine, ' ');
    const rows = try std.fmt.parseInt(usize, dims.next() orelse return error.InvalidInput, 10);
    const cols = try std.fmt.parseInt(usize, dims.next() orelse return error.InvalidInput, 10);

    const inParsed = try parseGrid(allocator, &inLines, rows, cols);
    const inputGrid = inParsed.grid;
    defer allocator.free(inputGrid);

    // Parse portals
    const portalCountStr = std.mem.trim(u8, inLines.next() orelse return error.InvalidInput, " \r");
    const numPortals = try std.fmt.parseInt(usize, portalCountStr, 10);

    const portals = try allocator.alloc(PortalPair, numPortals);
    defer allocator.free(portals);
    for (portals) |*pp| {
        const line = std.mem.trim(u8, inLines.next() orelse return error.InvalidInput, " \r");
        var tokens = std.mem.tokenizeScalar(u8, line, ' ');
        pp.* = .{
            .r1 = try std.fmt.parseInt(usize, tokens.next() orelse return error.InvalidInput, 10),
            .c1 = try std.fmt.parseInt(usize, tokens.next() orelse return error.InvalidInput, 10),
            .r2 = try std.fmt.parseInt(usize, tokens.next() orelse return error.InvalidInput, 10),
            .c2 = try std.fmt.parseInt(usize, tokens.next() orelse return error.InvalidInput, 10),
        };
    }

    // Count pre-placed walls in input
    var prePlacedWalls: u32 = 0;
    for (inputGrid) |ct| {
        if (ct == .wall) prePlacedWalls += 1;
    }

    // ── Parse output ─────────────────────────────────────────────────────

    var outLines = std.mem.tokenizeScalar(u8, outputData, '\n');

    const scoreStr = std.mem.trim(u8, outLines.next() orelse return error.InvalidInput, " \r");
    const claimedScore = try std.fmt.parseInt(i32, scoreStr, 10);

    const outParsed = try parseGrid(allocator, &outLines, rows, cols);
    const outputGrid = outParsed.grid;
    defer allocator.free(outputGrid);

    // ── Verification ─────────────────────────────────────────────────────

    var outBuf = std.ArrayList(u8){};
    defer outBuf.deinit(allocator);
    try outBuf.ensureTotalCapacity(allocator, 4096);
    const w = outBuf.writer(allocator);

    var errors: u32 = 0;

    // Check 1: Tile changes are legal
    var wallsPlaced: u32 = 0;
    for (0..rows) |r| {
        for (0..cols) |c| {
            const i = r * cols + c;
            const inCell = inputGrid[i];
            const outCell = outputGrid[i];

            if (outCell == .wall) wallsPlaced += 1;

            if (inCell == outCell) continue;

            // Allowed change: pre-placed wall -> grass (removing a pre-placed wall)
            if (inCell == .wall and outCell == .grass) continue;

            // Allowed change: grass -> wall (placing a new wall)
            if (inCell == .grass and outCell == .wall) continue;

            // Anything else is illegal
            try w.print("ERROR: Illegal tile change at ({d},{d}): '{c}' -> '{c}'\n", .{
                r, c, inCell.char(), outCell.char(),
            });
            errors += 1;
        }
    }

    // Check 2: Wall budget
    if (wallsPlaced > budget) {
        try w.print("ERROR: Walls placed ({d}) exceeds budget ({d})\n", .{ wallsPlaced, budget });
        errors += 1;
    }

    // Check 3: Horse exists in output
    if (!outParsed.horseFound) {
        try w.print("ERROR: No horse found in output grid\n", .{});
        errors += 1;
    }

    // Check 4: Horse position matches input
    if (inParsed.horseRow != outParsed.horseRow or inParsed.horseCol != outParsed.horseCol) {
        try w.print("ERROR: Horse position changed from ({d},{d}) to ({d},{d})\n", .{
            inParsed.horseRow, inParsed.horseCol, outParsed.horseRow, outParsed.horseCol,
        });
        errors += 1;
    }

    // Check 5: BFS — horse cannot reach boundary
    const bfsResult = try bfsFromHorse(outputGrid, rows, cols, outParsed.horseRow, outParsed.horseCol, portals, allocator);

    if (bfsResult.reachesBoundary) {
        try w.print("ERROR: Horse can reach the perimeter — enclosure is NOT valid\n", .{});
        errors += 1;
    }

    // Check 6: Claimed score matches actual score
    if (claimedScore != bfsResult.score) {
        try w.print("ERROR: Claimed score ({d}) does not match computed score ({d})\n", .{ claimedScore, bfsResult.score });
        errors += 1;
    }

    // ── Summary ──────────────────────────────────────────────────────────

    try w.print("\n=== Verification Summary ===\n", .{});
    try w.print("Grid:            {d} x {d}\n", .{ rows, cols });
    try w.print("Wall budget:     {d}\n", .{budget});
    try w.print("Walls placed:    {d}\n", .{wallsPlaced});
    try w.print("Pre-placed (in): {d}\n", .{prePlacedWalls});
    try w.print("Claimed score:   {d}\n", .{claimedScore});
    try w.print("Computed score:  {d}\n", .{bfsResult.score});
    try w.print("Reachable tiles: {d}\n", .{bfsResult.reachableCount});
    try w.print("Reaches border:  {}\n", .{bfsResult.reachesBoundary});
    try w.print("Errors:          {d}\n", .{errors});

    if (errors == 0) {
        try w.print("\nRESULT: VALID\n", .{});
    } else {
        try w.print("\nRESULT: INVALID\n", .{});
    }

    // Flush everything to stdout
    try std.fs.File.stdout().writeAll(outBuf.items);
}
