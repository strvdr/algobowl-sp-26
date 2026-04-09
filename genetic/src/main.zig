// Author: Strydr Silverberg
//
// Solver for the Enclose Horse puzzle game (AlgoBOWL).
// Uses a multi-threaded genetic algorithm to find optimal wall placements
// that enclose the horse while maximizing the score of reachable tiles.
//
// Scoring:
//   Grass/Horse/Portal tiles: +1 each
//   Apple tiles: +11 (+1 grass, +10 apple)
//   Bee tiles: -4 (+1 grass, -5 bees)
//   Cherry tiles: +4 (+1 grass, +3 cherries)

const std = @import("std");

// =============================================================================
// Data Types
// =============================================================================

const CellType = enum {
    water,
    grass,
    wall,
    horse,
    cherry,
    apple,
    bee,
    portal,

    /// Returns the score contribution when this cell is reachable.
    pub fn score(self: CellType) i32 {
        return switch (self) {
            .apple => 11,
            .cherry => 4,
            .bee => -4,
            else => 1,
        };
    }
};

const Cell = struct {
    type: CellType,
};

const Pos = struct {
    row: usize,
    col: usize,
};

const PortalPair = struct {
    r1: usize,
    c1: usize,
    r2: usize,
    c2: usize,
};

const BFSResult = struct {
    count: usize,
    score: i32,
    reachesBoundary: bool,
    minBoundaryDist: u32, // NEW: Tracks distance to escape
};

/// Pre-allocated scratch buffers for BFS to avoid per-call allocation.
const BFSScratch = struct {
    queue: []Pos,
    /// Stamp-based visited array: cell is "visited" iff visited[i] == currentStamp.
    /// Incrementing currentStamp resets all visited state in O(1) — no memset needed.
    visited: []u32,
    depth: []u32, // NEW: Parallel array for BFS depth
    currentStamp: u32,
    /// Reused buffer for findBoundaryWalls results (indices into candidates).
    boundaryBuf: []usize,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, maxCells: usize) !BFSScratch {
        const visited = try allocator.alloc(u32, maxCells);
        @memset(visited, 0);
        
        const depth = try allocator.alloc(u32, maxCells); // NEW
        @memset(depth, 0);
        
        return .{
            .queue = try allocator.alloc(Pos, maxCells),
            .visited = visited,
            .depth = depth, // NEW
            .currentStamp = 1,
            .boundaryBuf = try allocator.alloc(usize, maxCells),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *BFSScratch) void {
        self.allocator.free(self.queue);
        self.allocator.free(self.visited);
        self.allocator.free(self.depth); // NEW
        self.allocator.free(self.boundaryBuf);
    }

    /// Begin a new BFS — O(1) reset via stamp increment.
    /// On the rare wrap-around to 0, memset visited+depth to avoid stale data.
    pub inline fn nextStamp(self: *BFSScratch) u32 {
        self.currentStamp +%= 1;
        if (self.currentStamp == 0) {
            self.currentStamp = 1;
            @memset(self.visited, 0);
            @memset(self.depth, 0);
        }
        return self.currentStamp;
    }

    /// Safe depth read: returns depth if cell was visited this stamp, else maxInt.
    pub inline fn getDepthOrInf(self: *BFSScratch, idx: usize) u32 {
        return if (self.visited[idx] == self.currentStamp)
            self.depth[idx]
        else
            std.math.maxInt(u32);
    }

    /// Safe write: mark cell as visited and record its depth in one step.
    pub inline fn visit(self: *BFSScratch, idx: usize, d: u32) void {
        self.visited[idx] = self.currentStamp;
        self.depth[idx] = d;
    }
};

const Individual = struct {
    walls: []bool,
    /// Flat grid-indexed wall map kept in sync with walls[].
    /// isWallMap[row*cols+col] = true iff a wall from this individual is placed there.
    /// Maintained by all mutation/crossover helpers so BFS never has to rebuild it.
    isWallMap: []bool,
    score: i32,
    valid: bool,
    /// Cached count of placed walls — avoids O(n) scans in mutate().
    wallCount: u32,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Individual) void {
        self.allocator.free(self.walls);
        self.allocator.free(self.isWallMap);
    }

    /// Place a wall at candidate index i (pos must be provided for isWallMap update).
    pub inline fn placeWall(self: *Individual, i: usize, pos: Pos, cols: usize) void {
        if (!self.walls[i]) {
            self.walls[i] = true;
            self.isWallMap[pos.row * cols + pos.col] = true;
            self.wallCount += 1;
        }
    }

    /// Remove a wall at candidate index i.
    pub inline fn removeWall(self: *Individual, i: usize, pos: Pos, cols: usize) void {
        if (self.walls[i]) {
            self.walls[i] = false;
            self.isWallMap[pos.row * cols + pos.col] = false;
            self.wallCount -= 1;
        }
    }

    /// Rebuild isWallMap from walls[] in O(wallCount) — much cheaper than
    /// memcpy-ing the full gridSize isWallMap when copying individuals.
    pub fn rebuildIsWallMap(self: *Individual, candidates: []const Pos, cols: usize) void {
        @memset(self.isWallMap, false);
        for (self.walls, 0..) |w, i| {
            if (w) self.isWallMap[candidates[i].row * cols + candidates[i].col] = true;
        }
    }

    /// Sort ordering: valid individuals first (descending score), then invalid (descending score).
    pub fn compareDescending(_: void, a: Individual, b: Individual) bool {
        if (a.valid and !b.valid) return true;
        if (!a.valid and b.valid) return false;
        return b.score < a.score;
    }
};

/// Result returned from a solver thread, transferring ownership of the walls slice.
const SolveResult = struct {
    walls: []bool,
    score: i32,
    valid: bool,
};

const Puzzle = struct {
    /// Flat row-major grid: grid[row*cols + col]
    grid: []Cell,
    /// Precomputed per-cell score lookup: scoreMap[row*cols+col] = cell.type.score()
    scoreMap: []i32,
    rows: usize,
    cols: usize,
    budget: u32,
    horseRow: usize,
    horseCol: usize,
    portals: []PortalPair,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Puzzle) void {
        self.allocator.free(self.grid);
        self.allocator.free(self.scoreMap);
        self.allocator.free(self.portals);
    }
};

/// Per-thread context for parallel GA solving.
const ThreadContext = struct {
    puzzle: *const Puzzle,
    candidates: []const Pos,
    seed: u64,
    popSize: usize,
    /// Optional pre-placed wall seed (candidates-indexed).
    /// When non-null, the first
    /// individual(s) in this thread's population are initialized from it rather than
    /// randomly, giving the thread a guaranteed valid head-start.
    seedWalls: ?[]const bool,
    /// Grid-indexed lookup: gridToCand[row*cols+col] = candidate index, or maxInt if not a candidate.
    gridToCand: []const usize,
    result: ?SolveResult,
    allocator: std.mem.Allocator,
    /// Shared migration pool for island-model inter-thread elite exchange.
    migration: *MigrationPool,
    /// This thread's island index (0..numIslands-1).
    islandIdx: usize,

    pub fn run(self: *ThreadContext) void {
        self.result = self.doSolve() catch null;
    }

    fn doSolve(self: *ThreadContext) !SolveResult {
        var prng = std.Random.DefaultPrng.init(self.seed);
        const random = prng.random();
        return solve(self.puzzle, self.candidates, random, self.popSize, self.seedWalls, self.gridToCand, self.migration, self.islandIdx, self.allocator);
    }
};

/// Shared pool for island-model migration between solver threads.
/// Each island has a slot where it periodically publishes its best individual.
/// Other islands can read from any slot to import elites.
/// Protected by a mutex since migrations are infrequent (every N generations).
const MigrationPool = struct {
    /// Per-island wall buffers: slots[i] holds island i's exported best.
    slots: [][]bool,
    scores: []i32,
    valid: []bool,
    wallCounts: []u32,
    /// Whether each slot has been written at least once.
    populated: []bool,
    numIslands: usize,
    numCandidates: usize,
    mutex: std.Thread.Mutex,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, numIslands: usize, numCandidates: usize) !MigrationPool {
        const slots = try allocator.alloc([]bool, numIslands);
        for (slots) |*s| {
            s.* = try allocator.alloc(bool, numCandidates);
            @memset(s.*, false);
        }
        const scores = try allocator.alloc(i32, numIslands);
        @memset(scores, 0);
        const valid = try allocator.alloc(bool, numIslands);
        @memset(valid, false);
        const wallCounts = try allocator.alloc(u32, numIslands);
        @memset(wallCounts, 0);
        const populated = try allocator.alloc(bool, numIslands);
        @memset(populated, false);
        return .{
            .slots = slots,
            .scores = scores,
            .valid = valid,
            .wallCounts = wallCounts,
            .populated = populated,
            .numIslands = numIslands,
            .numCandidates = numCandidates,
            .mutex = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *MigrationPool) void {
        for (self.slots) |s|
            self.allocator.free(s);
        self.allocator.free(self.slots);
        self.allocator.free(self.scores);
        self.allocator.free(self.valid);
        self.allocator.free(self.wallCounts);
        self.allocator.free(self.populated);
    }

    /// Export this island's best individual into its slot.
    pub fn exportBest(self: *MigrationPool, islandIdx: usize, walls: []const bool, score: i32, isValid: bool, wallCount: u32) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        @memcpy(self.slots[islandIdx], walls);
        self.scores[islandIdx] = score;
        self.valid[islandIdx] = isValid;
        self.wallCounts[islandIdx] = wallCount;
        self.populated[islandIdx] = true;
    }

    /// Import a random other island's best into the given buffers.
    /// Returns true if a suitable donor was found, false if no other island has exported yet.
    pub fn importFrom(self: *MigrationPool, myIsland: usize, random: std.Random, outWalls: []bool) ?struct { score: i32, isValid: bool, wallCount: u32 } {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Collect populated islands that aren't ours
        var donorCount: usize = 0;
        var donors: [64]usize = undefined; // max 64 islands
        for (0..self.numIslands) |i|
        {
            if (i != myIsland and self.populated[i]) {
                if (donorCount < 64) {
                    donors[donorCount] = i;
                    donorCount += 1;
                }
            }
        }
        if (donorCount == 0) return null;

        // Prefer valid donors; among those, pick the best score.
        // If no valid donors, pick a random one.
        var bestDonor: usize = donors[0];
        var bestScore: i32 = std.math.minInt(i32);
        var anyValidDonor = false;
        for (0..donorCount) |di|
        {
            const d = donors[di];
            if (self.valid[d]) {
                if (!anyValidDonor or self.scores[d] > bestScore) {
                    bestDonor = d;
                    bestScore = self.scores[d];
                    anyValidDonor = true;
                }
            }
        }
        if (!anyValidDonor) {
            // No valid donor — pick random
            bestDonor = donors[random.intRangeLessThan(usize, 0, donorCount)];
        }

        @memcpy(outWalls, self.slots[bestDonor]);
        return .{
            .score = self.scores[bestDonor],
            .isValid = self.valid[bestDonor],
            .wallCount = self.wallCounts[bestDonor],
        };
    }
};

/// Indices of top-k valid and top-k invalid individuals, found via O(n) scan.
const TopKResult = struct {
    validIndices: [validEliteCount]usize = undefined,
    validCount: usize = 0,
    invalidIndices: [invalidEliteCount]usize = undefined,
    invalidCount: usize = 0,
    bestIdx: usize = 0,
};

// =============================================================================
// Constants
// =============================================================================

const populationSize: usize = 50;
const gaGenerations: usize = 50_000;
const validEliteCount: usize = 5;
const invalidEliteCount: usize = 5;
const eliteCount: usize = validEliteCount + invalidEliteCount;
const mutationRate: u32 = 30;
const stagnationThreshold: usize = 25_000;
const maxRestarts: usize = 75;
const migrationFrequency: usize = 5_000;

// =============================================================================
// Parsing
// =============================================================================

fn parseCell(ch: u8) !Cell {
    return .{ .type = switch (ch) {
        '#' => .water,
        '.' => .grass,
        'H' => .horse,
        'W' => .wall,
        'a' => .apple,
        'b' => .bee,
        'c' => .cherry,
        'p' => .portal,
        else => return error.UnknownCell,
    } };
}

fn parseInput(allocator: std.mem.Allocator, data: []const u8) !Puzzle {
    var lines = std.mem.tokenizeScalar(u8, data, '\n');
    const budgetLine = std.mem.trim(u8, lines.next() orelse return error.InvalidInput, " \r");
    const budget = try std.fmt.parseInt(u32, budgetLine, 10);
    
    const dimensionsLine = std.mem.trim(u8, lines.next() orelse return error.InvalidInput, " \r");
    var dims = std.mem.tokenizeScalar(u8, dimensionsLine, ' ');
    const rows = try std.fmt.parseInt(usize, dims.next() orelse return error.InvalidInput, 10);
    const cols = try std.fmt.parseInt(usize, dims.next() orelse return error.InvalidInput, 10);
    
    // Flat row-major grid allocation
    const grid = try allocator.alloc(Cell, rows * cols);
    const scoreMap = try allocator.alloc(i32, rows * cols);

    var horseRow: usize = 0;
    var horseCol: usize = 0;

    for (0..rows) |rowIndex| {
        const line = std.mem.trim(u8, lines.next() orelse return error.InvalidInput, " \r");
        for (line, 0..) |ch, colIndex| {
            const cell = try parseCell(ch);
            grid[rowIndex * cols + colIndex] = cell;
            scoreMap[rowIndex * cols + colIndex] = cell.type.score();
            if (ch == 'H') {
                horseRow = rowIndex;
                horseCol = colIndex;
            }
        }
    }

    const portalLine = std.mem.trim(u8, lines.next() orelse return error.InvalidInput, " \r");
    const numPortals = try std.fmt.parseInt(usize, portalLine, 10);

    const portals = try allocator.alloc(PortalPair, numPortals);
    for (portals) |*pp|
    {
        const line = std.mem.trim(u8, lines.next() orelse return error.InvalidInput, " \r");
        var tokens = std.mem.tokenizeScalar(u8, line, ' ');
        pp.* = .{
            .r1 = try std.fmt.parseInt(usize, tokens.next() orelse return error.InvalidInput, 10),
            .c1 = try std.fmt.parseInt(usize, tokens.next() orelse return error.InvalidInput, 10),
            .r2 = try std.fmt.parseInt(usize, tokens.next() orelse return error.InvalidInput, 10),
            .c2 = try std.fmt.parseInt(usize, tokens.next() orelse return error.InvalidInput, 10),
        };
    }

    return .{
        .grid = grid,
        .scoreMap = scoreMap,
        .rows = rows,
        .cols = cols,
        .budget = budget,
        .horseRow = horseRow,
        .horseCol = horseCol,
        .portals = portals,
        .allocator = allocator,
    };
}

// =============================================================================
// Advanced Mutations
// =============================================================================

fn destructiveMutation(
    individual: *Individual,
    candidates: []const Pos,
    puzzle: *const Puzzle,
    scratch: *BFSScratch,
    random: std.Random,
) void {
    const cols = puzzle.cols;
    // Pick a random center in candidate space
    const centerIdx = random.intRangeLessThan(usize, 0, candidates.len);
    const center = candidates[centerIdx];

    // Radius in grid space
    const radius: i32 = @intCast(random.intRangeLessThan(u32, 8, 25));

    // --- REMOVE walls in region ---
    for (candidates, 0..) |pos, i|
    {
        if (!individual.walls[i]) continue;

        const dr = @as(i32, @intCast(pos.row)) - @as(i32, @intCast(center.row));
        const dc = @as(i32, @intCast(pos.col)) - @as(i32, @intCast(center.col));

        if (dr * dr + dc * dc <= radius * radius) {
            if (random.float(f32) < 0.6) {
                individual.removeWall(i, pos, cols);
            }
        }
    }

    // --- REGROW walls randomly to fill budget (rejection sampling) ---
    while (individual.wallCount < puzzle.budget) {
        const i = random.intRangeLessThan(usize, 0, candidates.len);
        if (!individual.walls[i]) {
            individual.placeWall(i, candidates[i], cols);
        }
    }

    // Re-evaluate after mutation
    evaluateFitness(individual, candidates, puzzle, scratch);
}

fn shiftMutation(
    individual: *Individual,
    candidates: []const Pos,
    puzzle: *const Puzzle,
    gridToCand: []const usize,
    random: std.Random,
) void {
    if (individual.wallCount == 0) return;
    const cols = puzzle.cols;
    const sentinel = std.math.maxInt(usize);

    // Try up to 10 times to find a wall with an empty neighbor
    var attempts: usize = 0;
    while (attempts < 10) : (attempts += 1) {
        const candIdx = random.intRangeLessThan(usize, 0, candidates.len);
        if (!individual.walls[candIdx]) continue;

        const pos = candidates[candIdx];
        var possibleMoves = [_]usize{0} ** 4;
        var moveCount: usize = 0;

        const deltas = [4][2]i32{ .{ -1, 0 }, .{ 1, 0 }, .{ 0, -1 }, .{ 0, 1 } };
        for (deltas) |d| {
            const nr_i = @as(i32, @intCast(pos.row)) + d[0];
            const nc_i = @as(i32, @intCast(pos.col)) + d[1];
            
            if (nr_i < 0 or nr_i >= puzzle.rows or nc_i < 0 or nc_i >= puzzle.cols) continue;

            const ni = @as(usize, @intCast(nr_i)) * cols + @as(usize, @intCast(nc_i));
            const nCandIdx = gridToCand[ni];

            // If neighbor is a valid candidate and not currently walled
            if (nCandIdx != sentinel and !individual.walls[nCandIdx]) {
                possibleMoves[moveCount] = nCandIdx;
                moveCount += 1;
            }
        }

        // Execute the shift
        if (moveCount > 0) {
            const moveTo = possibleMoves[random.intRangeLessThan(usize, 0, moveCount)];
            individual.removeWall(candIdx, pos, cols);
            individual.placeWall(moveTo, candidates[moveTo], cols);
            break;
        }
    }
}

fn chainRemovalMutation(
    individual: *Individual,
    candidates: []const Pos,
    puzzle: *const Puzzle,
    gridToCand: []const usize,
    random: std.Random,
) void {
    if (individual.wallCount == 0) return;
    const cols = puzzle.cols;
    const sentinel = std.math.maxInt(usize);

    // Pick a random starting wall
    var currIdx = random.intRangeLessThan(usize, 0, candidates.len);
    while (!individual.walls[currIdx]) {
        currIdx = random.intRangeLessThan(usize, 0, candidates.len);
    }

    const removeLength = random.intRangeLessThan(usize, 3, 10);
    for (0..removeLength) |_| {
        if (individual.walls[currIdx]) {
            individual.removeWall(currIdx, candidates[currIdx], cols);
        }

        // Find adjacent walls to continue the chain
        const pos = candidates[currIdx];
        var adjWalls = [_]usize{0} ** 4;
        var adjCount: usize = 0;

        const deltas = [4][2]i32{ .{ -1, 0 }, .{ 1, 0 }, .{ 0, -1 }, .{ 0, 1 } };
        for (deltas) |d| {
            const nr_i = @as(i32, @intCast(pos.row)) + d[0];
            const nc_i = @as(i32, @intCast(pos.col)) + d[1];
            if (nr_i < 0 or nr_i >= puzzle.rows or nc_i < 0 or nc_i >= puzzle.cols) continue;

            const ni = @as(usize, @intCast(nr_i)) * cols + @as(usize, @intCast(nc_i));
            const nCandIdx = gridToCand[ni];

            if (nCandIdx != sentinel and individual.walls[nCandIdx]) {
                adjWalls[adjCount] = nCandIdx;
                adjCount += 1;
            }
        }

        if (adjCount == 0) break; // Chain ended early
        currIdx = adjWalls[random.intRangeLessThan(usize, 0, adjCount)];
    }

    // Regrow randomly
    while (individual.wallCount < puzzle.budget) {
        const i = random.intRangeLessThan(usize, 0, candidates.len);
        if (!individual.walls[i]) {
            individual.placeWall(i, candidates[i], cols);
        }
    }
}

/// Leak-sealing mutation for invalid individuals. Runs a BFS to find where the
/// horse reaches the boundary, then walls grass candidates adjacent to those
/// boundary leak points.
fn sealLeakMutation(
    individual: *Individual,
    candidates: []const Pos,
    puzzle: *const Puzzle,
    scratch: *BFSScratch,
    gridToCand: []const usize,
    random: std.Random,
) void {
    if (individual.valid) return;

    const cols = puzzle.cols;
    const rows = puzzle.rows;
    const sentinel = std.math.maxInt(usize);

    // BFS from horse without earlyExit to find all reachable boundary cells
    const result = bfs(puzzle, individual.isWallMap, scratch, false);
    if (!result.reachesBoundary) {
        // Actually valid — just update
        individual.score = result.score;
        individual.valid = true;
        return;
    }

    const stamp = scratch.currentStamp;

    // Collect reachable boundary cells and their reachable inward neighbors
    // that are grass candidates (potential seal positions)
    var sealPositions: [512]usize = undefined; // candidate indices
    var sealCount: usize = 0;

    for (0..rows) |row|
    {
        if (row != 0 and row != rows - 1) continue; // only boundary rows
        for (0..cols) |col|
        {
            const ci = row * cols + col;
            if (scratch.visited[ci] != stamp) continue;
            
            // This boundary cell is reachable — find its reachable neighbors
            // that are grass candidates (potential wall positions)
            const deltas = [4][2]i32{ .{ -1, 0 }, .{ 1, 0 }, .{ 0, -1 }, .{ 0, 1 } };
            for (deltas) |d| {
                const nr_i = @as(i32, @intCast(row)) + d[0];
                const nc_i = @as(i32, @intCast(col)) + d[1];
                if (nr_i < 0 or nr_i >= @as(i32, @intCast(rows))) continue;
                if (nc_i < 0 or nc_i >= @as(i32, @intCast(cols))) continue;
                
                const nr: usize = @intCast(nr_i);
                const nc: usize = @intCast(nc_i);
                const ni = nr * cols + nc;
                
                if (scratch.visited[ni] != stamp) continue;
                const candIdx = gridToCand[ni];
                
                if (candIdx == sentinel) continue;
                if (individual.walls[candIdx]) continue;
                if (nr == puzzle.horseRow and nc == puzzle.horseCol) continue;
                
                if (sealCount < 512) {
                    sealPositions[sealCount] = candIdx;
                    sealCount += 1;
                }
            }
        }
    }
    // Also check boundary columns
    for (0..rows) |row|
    {
        for ([_]usize{ 0, cols - 1 }) |col|
        {
            const ci = row * cols + col;
            if (scratch.visited[ci] != stamp) continue;
            const deltas = [4][2]i32{ .{ -1, 0 }, .{ 1, 0 }, .{ 0, -1 }, .{ 0, 1 } };
            for (deltas) |d| {
                const nr_i = @as(i32, @intCast(row)) + d[0];
                const nc_i = @as(i32, @intCast(col)) + d[1];
                if (nr_i < 0 or nr_i >= @as(i32, @intCast(rows))) continue;
                if (nc_i < 0 or nc_i >= @as(i32, @intCast(cols))) continue;
                
                const nr: usize = @intCast(nr_i);
                const nc: usize = @intCast(nc_i);
                const ni = nr * cols + nc;
                
                if (scratch.visited[ni] != stamp) continue;
                const candIdx = gridToCand[ni];
                
                if (candIdx == sentinel) continue;
                if (individual.walls[candIdx]) continue;
                if (nr == puzzle.horseRow and nc == puzzle.horseCol) continue;
                
                if (sealCount < 512) {
                    sealPositions[sealCount] = candIdx;
                    sealCount += 1;
                }
            }
        }
    }

    if (sealCount == 0) return;

    // Place walls at seal positions, freeing budget from non-boundary walls
    var placed: usize = 0;
    for (0..sealCount) |si| {
        if (individual.walls[sealPositions[si]]) continue;
        
        if (individual.wallCount >= puzzle.budget) {
            // Need to free a wall — remove one that's NOT near the boundary
            var removed = false;
            var attempts: usize = 0;
            while (!removed and attempts < candidates.len) : (attempts += 1) {
                const ri = random.intRangeLessThan(usize, 0, candidates.len);
                if (!individual.walls[ri]) continue;
                
                // Don't remove walls near boundary (those might be helping)
                const rci = candidates[ri].row * cols + candidates[ri].col;
                var nearBoundary = false;
                if (candidates[ri].row <= 1 or candidates[ri].row >= rows - 2) nearBoundary = true;
                if (candidates[ri].col <= 1 or candidates[ri].col >= cols - 2) nearBoundary = true;
                
                if (!nearBoundary and scratch.visited[rci] != stamp) {
                    // Not reachable and not near boundary — safe to remove
                    individual.removeWall(ri, candidates[ri], cols);
                    removed = true;
                }
            }
            if (!removed) break;
        }
        individual.placeWall(sealPositions[si], candidates[sealPositions[si]], cols);
        placed += 1;
    }

    evaluateFitness(individual, candidates, puzzle, scratch);
}

// =============================================================================
// Grid Helpers
// =============================================================================

fn removePrePlacedWalls(puzzle: *Puzzle) void {
    for (0..puzzle.rows) |row|
    {
        for (0..puzzle.cols) |col|
        {
            const i = row * puzzle.cols + col;
            if (puzzle.grid[i].type == .wall) {
                puzzle.grid[i] = .{ .type = .grass };
                puzzle.scoreMap[i] = CellType.grass.score();
            }
        }
    }
}

/// Returns positions where walls may be placed: reachable grass tiles excluding the horse.
fn getCandidateWalls(puzzle: *const Puzzle, visited: []u32, stamp: u32, allocator: std.mem.Allocator) ![]Pos {
    var candidates: std.ArrayList(Pos) = .{};
    defer candidates.deinit(allocator);

    for (0..puzzle.rows) |row| {
        for (0..puzzle.cols) |col|
        {
            const i = row * puzzle.cols + col;
            if (visited[i] != stamp) continue;
            if (row == puzzle.horseRow and col == puzzle.horseCol) continue;
            if (puzzle.grid[i].type != .grass) continue;
            try candidates.append(allocator, .{ .row = row, .col = col });
        }
    }

    return try candidates.toOwnedSlice(allocator);
}

// =============================================================================
// BFS (Breadth-First Search)
// =============================================================================

/// BFS from the horse position using pre-allocated scratch buffers.
/// Computes reachability, score, and whether the boundary is reachable.
/// When `earlyExit` is true, stops as soon as the boundary is reached.
/// `isWallMap` must be a flat grid-indexed bool array (e.g. Individual.isWallMap).
/// Pass `null` for isWallMap when no extra walls are placed.
fn bfs(puzzle: *const Puzzle, isWallMap: ?[]const bool, scratch: *BFSScratch, earlyExit: bool) BFSResult {
    var head: usize = 0;
    var tail: usize = 0;

    // O(1) reset: increment stamp instead of memset-ing the visited array
    const stamp = scratch.nextStamp();
    const startIdx = puzzle.horseRow * puzzle.cols + puzzle.horseCol;
    
    scratch.visit(startIdx, 0);
    
    scratch.queue[tail] = .{ .row = puzzle.horseRow, .col = puzzle.horseCol };
    tail += 1;

    var reachable: usize = 0;
    var reachesBoundary = false;
    var totalScore: i32 = 0;
    var minBoundaryDist: u32 = std.math.maxInt(u32);

    const rows = puzzle.rows;
    const cols = puzzle.cols;

    while (head < tail) {
        const current = scratch.queue[head];
        head += 1;
        reachable += 1;

        const ci = current.row * cols + current.col;
        const currentDepth = scratch.depth[ci]; // safe: we visited this cell
        totalScore += puzzle.scoreMap[ci];

        if (current.row == 0 or current.row == rows - 1 or
            current.col == 0 or current.col == cols - 1)
        {
            reachesBoundary = true;
            if (currentDepth < minBoundaryDist) minBoundaryDist = currentDepth;
            if (earlyExit) break;
        }

        // Unrolled cardinal neighbor expansion
        // Up
        if (current.row > 0) {
            const ni = ci - cols;
            if (scratch.visited[ni] != stamp) {
                const ct = puzzle.grid[ni].type;
                if (ct != .water and ct != .wall and (isWallMap == null or !isWallMap.?[ni])) {
                    scratch.visit(ni, currentDepth + 1);
                    scratch.queue[tail] = .{ .row = current.row - 1, .col = current.col };
                    tail += 1;
                }
            }
        }
        // Down
        if (current.row + 1 < rows) {
            const ni = ci + cols;
            if (scratch.visited[ni] != stamp) {
                const ct = puzzle.grid[ni].type;
                if (ct != .water and ct != .wall and (isWallMap == null or !isWallMap.?[ni])) {
                    scratch.visit(ni, currentDepth + 1);
                    scratch.queue[tail] = .{ .row = current.row + 1, .col = current.col };
                    tail += 1;
                }
            }
        }
        // Left
        if (current.col > 0) {
            const ni = ci - 1;
            if (scratch.visited[ni] != stamp) {
                const ct = puzzle.grid[ni].type;
                if (ct != .water and ct != .wall and (isWallMap == null or !isWallMap.?[ni])) {
                    scratch.visit(ni, currentDepth + 1);
                    scratch.queue[tail] = .{ .row = current.row, .col = current.col - 1 };
                    tail += 1;
                }
            }
        }
        // Right
        if (current.col + 1 < cols) {
            const ni = ci + 1;
            if (scratch.visited[ni] != stamp) {
                const ct = puzzle.grid[ni].type;
                if (ct != .water and ct != .wall and (isWallMap == null or !isWallMap.?[ni])) {
                    scratch.visit(ni, currentDepth + 1);
                    scratch.queue[tail] = .{ .row = current.row, .col = current.col + 1 };
                    tail += 1;
                }
            }
        }

        // Traverse portals
        if (puzzle.grid[ci].type == .portal) {
            for (puzzle.portals) |pp|
            {
                const partner = portalPartner(pp, current.row, current.col) orelse continue;
                const pi = partner.row * cols + partner.col;
                if (scratch.visited[pi] != stamp and (isWallMap == null or !isWallMap.?[pi])) {
                    scratch.visit(pi, currentDepth + 1);
                    scratch.queue[tail] = partner;
                    tail += 1;
                }
            }
        }
    }

    return .{
        .count = reachable,
        .score = totalScore,
        .reachesBoundary = reachesBoundary,
        .minBoundaryDist = minBoundaryDist, // NEW
    };
}

/// Given a portal pair, return the partner position if (row, col) matches one end.
fn portalPartner(pp: PortalPair, row: usize, col: usize) ?Pos {
    if (row == pp.r1 and col == pp.c1) return .{ .row = pp.r2, .col = pp.c2 };
    if (row == pp.r2 and col == pp.c2) return .{ .row = pp.r1, .col = pp.c1 };
    return null;
}

// =============================================================================
// Genetic Algorithm - Operators
// =============================================================================

/// Compute a heuristic bonus for invalid individuals based on how well-connected
/// their placed walls are to existing barriers.
fn computeAdjacencyBonus(candidates: []const Pos, walls: []const bool, puzzle: *const Puzzle, isWallMap: []const bool) i32 {
    var bonus: i32 = 0;
    const rows = puzzle.rows;
    const cols = puzzle.cols;

    for (candidates, 0..) |pos, i|
    {
        if (!walls[i]) continue;

        var neighborCount: i32 = 0;
        const ci = pos.row * cols + pos.col;

        // Up
        if (pos.row == 0) {
            neighborCount += 1;
        } else {
            const ni = ci - cols;
            const ct = puzzle.grid[ni].type;
            if (ct == .water or ct == .wall or isWallMap[ni]) neighborCount += 1;
        }
        // Down
        if (pos.row + 1 >= rows) {
            neighborCount += 1;
        } else {
            const ni = ci + cols;
            const ct = puzzle.grid[ni].type;
            if (ct == .water or ct == .wall or isWallMap[ni]) neighborCount += 1;
        }
        // Left
        if (pos.col == 0) {
            neighborCount += 1;
        } else {
            const ni = ci - 1;
            const ct = puzzle.grid[ni].type;
            if (ct == .water or ct == .wall or isWallMap[ni]) neighborCount += 1;
        }
        // Right
        if (pos.col + 1 >= cols) {
            neighborCount += 1;
        } else {
            const ni = ci + 1;
            const ct = puzzle.grid[ni].type;
            if (ct == .water or ct == .wall or isWallMap[ni]) neighborCount += 1;
        }

        bonus += switch (neighborCount) {
            0 => -3,
            1 => 0,
            2 => 3,
            3 => 2,
            else => -2,
        };
    }
    return bonus;
}

/// Remove redundant walls from a valid individual, freeing budget for expansion.
fn pruneWalls(individual: *Individual, candidates: []const Pos, puzzle: *const Puzzle, scratch: *BFSScratch) void {
    if (!individual.valid) return;
    for (0..candidates.len) |i| {
        if (!individual.walls[i]) continue;

        individual.removeWall(i, candidates[i], puzzle.cols);
        const result = bfs(puzzle, individual.isWallMap, scratch, true);

        if (!result.reachesBoundary and result.score >= individual.score) {
            individual.score = result.score;
            // wall stays removed — budget freed for expansion
        } else {
            individual.placeWall(i, candidates[i], puzzle.cols);
        }
    }
}

/// Evaluate an individual's fitness. Valid enclosures get the BFS score directly.
/// Invalid enclosures are scored by wall quality only — the actual tile score is
/// meaningless for invalid solutions on large grids (it's ~gridSize regardless of
/// wall placement).
fn evaluateFitness(individual: *Individual, candidates: []const Pos, puzzle: *const Puzzle, scratch: *BFSScratch) void {
    // Fast check: is the enclosure valid?
    const fastResult = bfs(puzzle, individual.isWallMap, scratch, true);

    if (!fastResult.reachesBoundary) {
        // Valid — the fast BFS visited everything reachable, score is complete.
        individual.score = fastResult.score;
        individual.valid = true;
        return;
    }

    // Invalid — run full BFS to find ALL reachable boundary cells.
    // We need the complete boundary picture to count gap width and components.
    const fullResult = bfs(puzzle, individual.isWallMap, scratch, false);
    
    const stamp = scratch.currentStamp;
    const rows = puzzle.rows;
    const cols = puzzle.cols;

    var gapWidth: i32 = 0;
    var leakComponents: i32 = 0;
    
    var prevWasLeak = false;
    const firstIsLeak = (scratch.visited[0] == stamp);

    // Top row: (0, 0..cols-1)
    for (0..cols) |c|
    {
        if (scratch.visited[c] == stamp) {
            gapWidth += 1;
            if (!prevWasLeak) leakComponents += 1;
            prevWasLeak = true;
        } else {
            prevWasLeak = false;
        }
    }
    // Right col: (1..rows-1, cols-1)
    for (1..rows) |r|
    {
        const idx = r * cols + cols - 1;
        if (scratch.visited[idx] == stamp) {
            gapWidth += 1;
            if (!prevWasLeak) leakComponents += 1;
            prevWasLeak = true;
        } else {
            prevWasLeak = false;
        }
    }
    // Bottom row: (rows-1, cols-2..0) — skip corner (rows-1, cols-1), already counted
    if (rows > 1) {
        var c_i: usize = if (cols > 1) cols - 2 else 0;
        while (true) {
            const idx = (rows - 1) * cols + c_i;
            if (scratch.visited[idx] == stamp) {
                gapWidth += 1;
                if (!prevWasLeak) leakComponents += 1;
                prevWasLeak = true;
            } else {
                prevWasLeak = false;
            }
            if (c_i == 0) break;
            c_i -= 1;
        }
    }
    // Left col: (rows-2..1, 0) — skip corners (rows-1,0) and (0,0), already counted
    if (rows > 2) {
        var r_i: usize = rows - 2;
        while (r_i >= 1) {
            const idx = r_i * cols;
            if (scratch.visited[idx] == stamp) {
                gapWidth += 1;
                if (!prevWasLeak) leakComponents += 1;
                prevWasLeak = true;
            } else {
                prevWasLeak = false;
            }
            if (r_i == 1) break;
            r_i -= 1;
        }
    }

    // If the perimeter ring wraps around (last cell leaked AND first cell leaked),
    // the first and last components are actually one — merge them.
    if (prevWasLeak and firstIsLeak and leakComponents > 1) {
        leakComponents -= 1;
    }

    const adjBonus = computeAdjacencyBonus(candidates, individual.walls, puzzle, individual.isWallMap);
    const gridPenalty: i32 = @intCast(rows * cols);
    
    // NEW: Reward distance — +10 points for every tile of distance to the perimeter
    const distBonus: i32 = if (fullResult.minBoundaryDist != std.math.maxInt(u32)) 
        @as(i32, @intCast(fullResult.minBoundaryDist)) * 10 
    else 0;

    individual.score = -gridPenalty * 2 - gapWidth * 50 - leakComponents * 20 + adjBonus + distBonus;
    individual.valid = false;
}

fn tournamentSelect(population: []Individual, random: std.Random) *const Individual {
    const a = random.intRangeLessThan(usize, 0, population.len);
    const b = random.intRangeLessThan(usize, 0, population.len);
    return if (population[a].score >= population[b].score) &population[a] else &population[b];
}

/// Perform crossover into a pre-allocated child buffer (no allocation needed).
/// Maintains child.isWallMap and child.wallCount in sync with child.walls.
fn crossoverInto(child: *Individual, parent1: *const Individual, parent2: *const Individual, candidates: []const Pos, cols: usize, budget: u32) void {
    // Clear only the cells that were set in this child's previous generation — O(budget) not O(gridSize)
    for (child.walls, 0..) |w, j|
    {
        if (w) child.isWallMap[candidates[j].row * cols + candidates[j].col] = false;
    }
    @memset(child.walls, false);
    child.wallCount = 0;

    // Keep walls shared by both parents
    for (candidates, 0..) |pos, j|
    {
        if (child.wallCount >= budget) break;
        if (parent1.walls[j] and parent2.walls[j]) {
            child.walls[j] = true;
            child.isWallMap[pos.row * cols + pos.col] = true;
            child.wallCount += 1;
        }
    }

    // Fill remaining from walls only one parent has
    for (candidates, 0..) |pos, j|
    {
        if (child.wallCount >= budget) break;
        if (!child.walls[j] and (parent1.walls[j] or parent2.walls[j])) {
            child.walls[j] = true;
            child.isWallMap[pos.row * cols + pos.col] = true;
            child.wallCount += 1;
        }
    }

    child.score = 0;
    child.valid = false;
}


fn mutate(individual: *Individual, candidates: []const Pos, cols: usize, budget: u32, random: std.Random) void {
    if (individual.wallCount == 0) return;
    const roll = random.intRangeLessThan(u32, 0, 100);

    if (roll < 10) {
        const remove_fraction = 30 + random.intRangeLessThan(u32, 0, 40);
        const to_remove = (individual.wallCount * remove_fraction) / 100;

        var removed: u32 = 0;
        var i: usize = 0;
        while (i < individual.walls.len and removed < to_remove) : (i += 1) {
            if (individual.walls[i] and random.boolean()) {
                individual.removeWall(i, candidates[i], cols);
                removed += 1;
            }
        }

        const target_fill = @min(individual.walls.len / 4, budget);
        while (individual.wallCount < target_fill) {
            const idx = random.intRangeLessThan(usize, 0, individual.walls.len);
            if (!individual.walls[idx]) {
                individual.placeWall(idx, candidates[idx], cols);
            }
        }

        return;
    }

    const swaps: usize = if (roll < 65) 1 else if (roll < 85) 2 else 3;
    var s: usize = 0;
    while (s < swaps) : (s += 1) {
        var target = random.intRangeLessThan(usize, 0, individual.wallCount);
        var i: usize = 0;
        while (i < individual.walls.len) : (i += 1) {
            if (individual.walls[i]) {
                if (target == 0) {
                    individual.removeWall(i, candidates[i], cols);
                    break;
                }
                target -= 1;
            }
        }

        const emptyCount = individual.walls.len - @as(usize, individual.wallCount);
        if (emptyCount == 0) return;

        target = random.intRangeLessThan(usize, 0, emptyCount);

        i = 0;
        while (i < individual.walls.len) : (i += 1) {
            if (!individual.walls[i]) {
                if (target == 0) {
                    individual.placeWall(i, candidates[i], cols);
                    break;
                }
                target -= 1;
            }
        }
    }
}

// =============================================================================
// Genetic Algorithm - Expand Mutation
// =============================================================================

/// Find placed walls that sit on the boundary of the reachable region
/// (adjacent to both reachable and unreachable cells).
fn findBoundaryWalls(individual: *const Individual, candidates: []const Pos, puzzle: *const Puzzle, scratch: *BFSScratch) []usize {
    const result = bfs(puzzle, individual.isWallMap, scratch, false);
    if (result.reachesBoundary) return scratch.boundaryBuf[0..0];

    // The stamp from the bfs call above is still current — use it for visited checks
    const stamp = scratch.currentStamp;
    const cols = puzzle.cols;
    var count: usize = 0;

    for (candidates, 0..) |pos, i|
    {
        if (!individual.walls[i]) continue;

        const ci = pos.row * cols + pos.col;
        var hasReachableNeighbor = false;
        var hasBlockedNeighbor = false;

        // Up
        if (pos.row == 0) { hasBlockedNeighbor = true;
        }
        else if (scratch.visited[ci - cols] == stamp) { hasReachableNeighbor = true;
        }
        else { hasBlockedNeighbor = true;
        }
        // Down
        if (pos.row + 1 >= puzzle.rows) { hasBlockedNeighbor = true;
        }
        else if (scratch.visited[ci + cols] == stamp) { hasReachableNeighbor = true;
        }
        else { hasBlockedNeighbor = true;
        }
        // Left
        if (pos.col == 0) { hasBlockedNeighbor = true;
        }
        else if (scratch.visited[ci - 1] == stamp) { hasReachableNeighbor = true;
        }
        else { hasBlockedNeighbor = true;
        }
        // Right
        if (pos.col + 1 >= puzzle.cols) { hasBlockedNeighbor = true;
        }
        else if (scratch.visited[ci + 1] == stamp) { hasReachableNeighbor = true;
        }
        else { hasBlockedNeighbor = true;
        }

        if (hasReachableNeighbor and hasBlockedNeighbor) {
            scratch.boundaryBuf[count] = i;
            count += 1;
        }
    }

    return scratch.boundaryBuf[0..count];
}

/// Attempt to expand a valid enclosure by removing a boundary wall and
/// re-sealing the leak with walls placed on edge cells.
fn expandMutation(individual: *Individual, candidates: []const Pos, puzzle: *const Puzzle, scratch: *BFSScratch, random: std.Random) bool {
    if (!individual.valid) return false;
    const boundaryWalls = findBoundaryWalls(individual, candidates, puzzle, scratch);
    if (boundaryWalls.len == 0) return false;

    const cols = puzzle.cols;
    const rows = puzzle.rows;
    const stamp = scratch.currentStamp; // from findBoundaryWalls BFS

    // Score each boundary wall by value of unreachable neighbors behind it
    var bestWallIdx: usize = boundaryWalls[0];
    var bestNeighborScore: i32 = std.math.minInt(i32);
    var tiedCount: usize = 0;

    for (boundaryWalls) |candIdx|
    {
        const pos = candidates[candIdx];
        const ci = pos.row * cols + pos.col;
        var neighborScore: i32 = 0;
        if (pos.row > 0) { const ni = ci - cols;
            if (scratch.visited[ni] != stamp) { const ct = puzzle.grid[ni].type; if (ct != .water and ct != .wall) neighborScore += puzzle.scoreMap[ni];
            } }
        if (pos.row + 1 < rows) { const ni = ci + cols;
            if (scratch.visited[ni] != stamp) { const ct = puzzle.grid[ni].type; if (ct != .water and ct != .wall) neighborScore += puzzle.scoreMap[ni];
            } }
        if (pos.col > 0) { const ni = ci - 1;
            if (scratch.visited[ni] != stamp) { const ct = puzzle.grid[ni].type; if (ct != .water and ct != .wall) neighborScore += puzzle.scoreMap[ni];
            } }
        if (pos.col + 1 < cols) { const ni = ci + 1;
            if (scratch.visited[ni] != stamp) { const ct = puzzle.grid[ni].type; if (ct != .water and ct != .wall) neighborScore += puzzle.scoreMap[ni];
            } }

        if (neighborScore > bestNeighborScore) {
            bestNeighborScore = neighborScore;
            bestWallIdx = candIdx;
            tiedCount = 1;
        } else if (neighborScore == bestNeighborScore) {
            tiedCount += 1;
            if (random.intRangeLessThan(usize, 0, tiedCount) == 0) bestWallIdx = candIdx;
        }
    }

    // 50% score-biased, 50% random for diversity
    const wallToRemove = if (random.boolean())
        bestWallIdx
    else
        boundaryWalls[random.intRangeLessThan(usize, 0, boundaryWalls.len)];
    individual.removeWall(wallToRemove, candidates[wallToRemove], cols);

    // Check if still valid after removal (rare but free expansion)
    const leakResult = bfs(puzzle, individual.isWallMap, scratch, false);
    if (!leakResult.reachesBoundary) {
        individual.score = leakResult.score;
        return true;
    }

    // Remaining budget from cached wallCount (no O(n) scan)
    const remainingBudget = puzzle.budget - individual.wallCount;
    // Find candidate seal positions: reachable, unplaced, on the edge of the reachable region
    var sealCandidates: [2048]usize = undefined;
    var sealCount: usize = 0;

    // stamp from the leakResult BFS is still current
    const leakStamp = scratch.currentStamp;
    for (candidates, 0..) |pos, i| {
        if (individual.walls[i]) continue;
        if (pos.row == puzzle.horseRow and pos.col == puzzle.horseCol) continue;

        const cellIdx = pos.row * cols + pos.col;
        if (scratch.visited[cellIdx] != leakStamp) continue;

        var onEdge = false;
        if (pos.row == 0 or pos.row == puzzle.rows - 1 or pos.col == 0 or pos.col == puzzle.cols - 1) {
            onEdge = true;
        } else {
            // Up
            const ct_u = puzzle.grid[cellIdx - cols].type;
            if (ct_u == .water or ct_u == .wall or scratch.visited[cellIdx - cols] != leakStamp) { onEdge = true;
            }
            // Down
            if (!onEdge) {
                const ct_d = puzzle.grid[cellIdx + cols].type;
                if (ct_d == .water or ct_d == .wall or scratch.visited[cellIdx + cols] != leakStamp) { onEdge = true;
                }
            }
            // Left
            if (!onEdge) {
                const ct_l = puzzle.grid[cellIdx - 1].type;
                if (ct_l == .water or ct_l == .wall or scratch.visited[cellIdx - 1] != leakStamp) { onEdge = true;
                }
            }
            // Right
            if (!onEdge) {
                const ct_r = puzzle.grid[cellIdx + 1].type;
                if (ct_r == .water or ct_r == .wall or scratch.visited[cellIdx + 1] != leakStamp) { onEdge = true;
                }
            }
        }

        if (onEdge and sealCount < 2048) {
            sealCandidates[sealCount] = i;
            sealCount += 1;
        }
    }

    // Shuffle seal candidates for variety
    if (sealCount > 1) {
        var j: usize = sealCount - 1;
        while (j > 0) : (j -= 1) {
            const k = random.intRangeLessThan(usize, 0, j + 1);
            const tmp = sealCandidates[j];
            sealCandidates[j] = sealCandidates[k];
            sealCandidates[k] = tmp;
        }
    }

    // Place seal walls up to remaining budget
    var placed: u32 = 0;
    for (0..sealCount) |si| {
        if (placed >= remainingBudget) break;
        individual.placeWall(sealCandidates[si], candidates[sealCandidates[si]], cols);
        placed += 1;
    }

    // Check if we sealed the leak
    const sealResult = bfs(puzzle, individual.isWallMap, scratch, true);
    if (!sealResult.reachesBoundary) {
        individual.score = sealResult.score;
        individual.valid = true;
        return true;
    }

    // Failed — revert all changes
    individual.placeWall(wallToRemove, candidates[wallToRemove], cols);
    for (0..placed) |si|
    {
        individual.removeWall(sealCandidates[si], candidates[sealCandidates[si]], cols);
    }

    const revertResult = bfs(puzzle, individual.isWallMap, scratch, true);
    individual.score = revertResult.score;
    individual.valid = !revertResult.reachesBoundary;

    return false;
}

// =============================================================================
// Genetic Algorithm - Greedy Hill Climb (final polish only)
// =============================================================================

/// Greedy steepest-ascent hill climb: for each BOUNDARY wall, try moving it to
/// unplaced candidate positions near the current enclosure boundary, keeping the
/// swap that yields the best valid score improvement.
fn greedyHillClimb(
    individual: *Individual,
    candidates: []const Pos,
    puzzle: *const Puzzle,
    scratch: *BFSScratch,
    maxPasses: usize,
) usize {
    if (!individual.valid or individual.wallCount == 0) return 0;
    const cols = puzzle.cols;
    const rows = puzzle.rows;
    var totalImproved: usize = 0;

    for (0..maxPasses) |_|
    {
        // Find boundary walls — only these can affect the reachable region when removed.
        const bwalls = findBoundaryWalls(individual, candidates, puzzle, scratch);
        if (bwalls.len == 0) break;
        
        // Also identify "outer edge" candidates for adds: unplaced candidates adjacent to
        // the current reachable region.
        const reachStamp = scratch.currentStamp;
        // Use a stack-allocated buffer for outer edge candidates
        var outerEdgeBuf: [4096]usize = undefined;
        var outerEdgeCount: usize = 0;

        for (candidates, 0..) |pos, i|
        {
            if (individual.walls[i]) continue;
            if (pos.row == puzzle.horseRow and pos.col == puzzle.horseCol) continue;
            const ci = pos.row * cols + pos.col;
            
            // Is this candidate adjacent to a reachable cell?
            var adjReachable = false;
            if (pos.row > 0 and scratch.visited[ci - cols] == reachStamp) adjReachable = true;
            if (!adjReachable and pos.row + 1 < rows and scratch.visited[ci + cols] == reachStamp) adjReachable = true;
            if (!adjReachable and pos.col > 0 and scratch.visited[ci - 1] == reachStamp) adjReachable = true;
            if (!adjReachable and pos.col + 1 < cols and scratch.visited[ci + 1] == reachStamp) adjReachable = true;
            
            // Also include candidates that are themselves reachable (on the frontier)
            if (!adjReachable and scratch.visited[ci] == reachStamp) adjReachable = true;
            
            if (adjReachable and outerEdgeCount < 4096) {
                outerEdgeBuf[outerEdgeCount] = i;
                outerEdgeCount += 1;
            }
        }

        var bestImprovement: i32 = 0;
        var bestRemoveIdx: usize = 0;
        var bestAddIdx: usize = 0;
        var foundImprovement = false;

        for (bwalls) |removeIdx|
        {
            individual.removeWall(removeIdx, candidates[removeIdx], cols);
            // Free removal check
            const withoutResult = bfs(puzzle, individual.isWallMap, scratch, true);
            if (!withoutResult.reachesBoundary) {
                const improvement = withoutResult.score - individual.score;
                if (improvement > bestImprovement) {
                    bestImprovement = improvement;
                    bestRemoveIdx = removeIdx;
                    bestAddIdx = removeIdx; // sentinel: just remove
                    foundImprovement = true;
                }
            }

            // Try outer edge candidates as replacement
            for (0..outerEdgeCount) |oi|
            {
                const addIdx = outerEdgeBuf[oi];
                if (individual.walls[addIdx]) continue; // may have been set by another iteration
                if (addIdx == removeIdx) continue;
                
                individual.placeWall(addIdx, candidates[addIdx], cols);
                const result = bfs(puzzle, individual.isWallMap, scratch, true);
                individual.removeWall(addIdx, candidates[addIdx], cols);
                
                if (!result.reachesBoundary) {
                    const improvement = result.score - individual.score;
                    if (improvement > bestImprovement) {
                        bestImprovement = improvement;
                        bestRemoveIdx = removeIdx;
                        bestAddIdx = addIdx;
                        foundImprovement = true;
                    }
                }
            }

            individual.placeWall(removeIdx, candidates[removeIdx], cols);
        }

        if (!foundImprovement) break;
        
        // Apply the best swap
        individual.removeWall(bestRemoveIdx, candidates[bestRemoveIdx], cols);
        if (bestAddIdx != bestRemoveIdx) {
            individual.placeWall(bestAddIdx, candidates[bestAddIdx], cols);
        }
        individual.score += bestImprovement;
        totalImproved += 1;
    }

    return totalImproved;
}

// =============================================================================
// Post-GA Exhaustive Expansion
// =============================================================================

/// Exhaustive post-processing: repeatedly prune, expand, hill-climb, and fill
/// spare budget to maximize score on the final best solution.
/// This is deterministic and thorough — meant to run once on the winning individual.
/// Guarantees the individual's score never decreases.
fn exhaustivePostProcess(
    individual: *Individual,
    candidates: []const Pos,
    puzzle: *const Puzzle,
    scratch: *BFSScratch,
    random: std.Random,
) void {
    if (!individual.valid) return;

    // Snapshot: track best score seen during post-processing.
    // We checkpoint the walls whenever we beat our best, and restore at the end.
    var bestSeenScore: i32 = individual.score;
    
    // Use a stack buffer for checkpointing walls (candidates.len ≤ grid size ≤ 10000)
    // We store as indices of set walls to save space
    var checkpointBuf: [10000]usize = undefined;
    var checkpointLen: usize = 0;
    
    // Save initial checkpoint
    checkpointLen = 0;
    for (individual.walls, 0..) |w, i| {
        if (w) {
            checkpointBuf[checkpointLen] = i;
            checkpointLen += 1;
        }
    }

    // Phase 1: Iterative prune → single-wall expand cycles
    for (0..200) |_| {
        pruneWalls(individual, candidates, puzzle, scratch);
        if (!deterministicExpand(individual, candidates, puzzle, scratch)) break;
        
        // Checkpoint if improved
        if (individual.valid and individual.score > bestSeenScore) {
            bestSeenScore = individual.score;
            checkpointLen = 0;
            for (individual.walls, 0..) |w, i| {
                if (w) {
                    checkpointBuf[checkpointLen] = i;
                    checkpointLen += 1;
                }
            }
        }
    }

    // Phase 2: Multi-wall expansion — remove pairs/triples of adjacent boundary walls
    for (0..100) |_| {
        pruneWalls(individual, candidates, puzzle, scratch);
        if (!multiWallExpand(individual, candidates, puzzle, scratch)) break;
        
        if (individual.valid and individual.score > bestSeenScore) {
            bestSeenScore = individual.score;
            checkpointLen = 0;
            for (individual.walls, 0..) |w, i| {
                if (w) {
                    checkpointBuf[checkpointLen] = i;
                    checkpointLen += 1;
                }
            }
        }
        
        // After a successful multi-wall expand, try single-wall expands again
        for (0..50) |_| {
            pruneWalls(individual, candidates, puzzle, scratch);
            if (!deterministicExpand(individual, candidates, puzzle, scratch)) break;
            
            if (individual.valid and individual.score > bestSeenScore) {
                bestSeenScore = individual.score;
                checkpointLen = 0;
                for (individual.walls, 0..) |w, i| {
                    if (w) {
                        checkpointBuf[checkpointLen] = i;
                        checkpointLen += 1;
                    }
                }
            }
        }
    }

    // Phase 3: Greedy hill climb to fine-tune wall positions
    pruneWalls(individual, candidates, puzzle, scratch);
    _ = greedyHillClimb(individual, candidates, puzzle, scratch, 50);
    
    if (individual.valid and individual.score > bestSeenScore) {
        bestSeenScore = individual.score;
        checkpointLen = 0;
        for (individual.walls, 0..) |w, i| {
            if (w) {
                checkpointBuf[checkpointLen] = i;
                checkpointLen += 1;
            }
        }
    }

    // Phase 4: Final stochastic expand attempts (uses randomness for diversity)
    for (0..100) |_| {
        pruneWalls(individual, candidates, puzzle, scratch);
        if (!expandMutation(individual, candidates, puzzle, scratch, random)) break;
    }
    pruneWalls(individual, candidates, puzzle, scratch);
    _ = greedyHillClimb(individual, candidates, puzzle, scratch, 50);
    
    if (individual.valid and individual.score > bestSeenScore) {
        bestSeenScore = individual.score;
        checkpointLen = 0;
        for (individual.walls, 0..) |w, i| {
            if (w) {
                checkpointBuf[checkpointLen] = i;
                checkpointLen += 1;
            }
        }
    }

    // Restore best checkpoint if current state is worse
    if (!individual.valid or individual.score < bestSeenScore) {
        // Clear current walls
        for (individual.walls, 0..) |w, i| {
            if (w) individual.isWallMap[candidates[i].row * puzzle.cols + candidates[i].col] = false;
        }
        @memset(individual.walls, false);
        individual.wallCount = 0;
        
        // Restore checkpoint
        for (0..checkpointLen) |ci| {
            const idx = checkpointBuf[ci];
            individual.walls[idx] = true;
            individual.isWallMap[candidates[idx].row * puzzle.cols + candidates[idx].col] = true;
            individual.wallCount += 1;
        }
        individual.score = bestSeenScore;
        individual.valid = true;
    }
}

/// Deterministic expansion: try removing every boundary wall, for each one
/// attempt to re-seal the leak using spare + freed budget. Pick the option
/// that yields the highest valid score. Returns true if an expansion was made.
fn deterministicExpand(
    individual: *Individual,
    candidates: []const Pos,
    puzzle: *const Puzzle,
    scratch: *BFSScratch,
) bool {
    if (!individual.valid) return false;

    const boundaryWalls = findBoundaryWalls(individual, candidates, puzzle, scratch);
    if (boundaryWalls.len == 0) return false;

    const cols = puzzle.cols;
    const rows = puzzle.rows;

    var bestNewScore: i32 = individual.score;
    var bestWallToRemove: ?usize = null;
    // Store the seal configuration for the best expansion
    var bestSealBuf: [2048]usize = undefined;
    var bestSealCount: usize = 0;
    var bestFreeRemoval = false; // true if removing the wall alone keeps validity

    for (boundaryWalls) |candIdx| {
        individual.removeWall(candIdx, candidates[candIdx], cols);

        // Check if removal alone keeps enclosure valid (free expansion)
        const freeResult = bfs(puzzle, individual.isWallMap, scratch, true);
        if (!freeResult.reachesBoundary) {
            if (freeResult.score > bestNewScore) {
                bestNewScore = freeResult.score;
                bestWallToRemove = candIdx;
                bestSealCount = 0;
                bestFreeRemoval = true;
            }
            individual.placeWall(candIdx, candidates[candIdx], cols);
            continue;
        }

        // Need to re-seal. Run full BFS to find leak boundary.
        const leakResult = bfs(puzzle, individual.isWallMap, scratch, false);
        _ = leakResult;
        const leakStamp = scratch.currentStamp;

        // Budget available: what we freed + any spare
        const availBudget = puzzle.budget - individual.wallCount;

        // Find seal candidates: reachable, unplaced, on the edge of reachable region
        var sealCands: [2048]usize = undefined;
        var sealCount: usize = 0;

        for (candidates, 0..) |pos, i| {
            if (individual.walls[i]) continue;
            if (pos.row == puzzle.horseRow and pos.col == puzzle.horseCol) continue;

            const cellIdx = pos.row * cols + pos.col;
            if (scratch.visited[cellIdx] != leakStamp) continue;

            var onEdge = false;
            if (pos.row == 0 or pos.row == rows - 1 or pos.col == 0 or pos.col == cols - 1) {
                onEdge = true;
            } else {
                const ct_u = puzzle.grid[cellIdx - cols].type;
                if (ct_u == .water or ct_u == .wall or scratch.visited[cellIdx - cols] != leakStamp) onEdge = true;
                if (!onEdge) {
                    const ct_d = puzzle.grid[cellIdx + cols].type;
                    if (ct_d == .water or ct_d == .wall or scratch.visited[cellIdx + cols] != leakStamp) onEdge = true;
                }
                if (!onEdge) {
                    const ct_l = puzzle.grid[cellIdx - 1].type;
                    if (ct_l == .water or ct_l == .wall or scratch.visited[cellIdx - 1] != leakStamp) onEdge = true;
                }
                if (!onEdge) {
                    const ct_r = puzzle.grid[cellIdx + 1].type;
                    if (ct_r == .water or ct_r == .wall or scratch.visited[cellIdx + 1] != leakStamp) onEdge = true;
                }
            }

            // Also check if adjacent to individual's placed walls (for tighter seal)
            if (!onEdge) {
                if (pos.row > 0 and individual.isWallMap[cellIdx - cols]) onEdge = true;
                if (!onEdge and pos.row + 1 < rows and individual.isWallMap[cellIdx + cols]) onEdge = true;
                if (!onEdge and pos.col > 0 and individual.isWallMap[cellIdx - 1]) onEdge = true;
                if (!onEdge and pos.col + 1 < cols and individual.isWallMap[cellIdx + 1]) onEdge = true;
            }

            if (onEdge and sealCount < 2048) {
                sealCands[sealCount] = i;
                sealCount += 1;
            }
        }

        if (sealCount > 0 and sealCount <= availBudget) {
            // Try placing all seal candidates (greedy: place all edge walls)
            var placed: usize = 0;
            for (0..sealCount) |si| {
                if (placed >= availBudget) break;
                individual.placeWall(sealCands[si], candidates[sealCands[si]], cols);
                placed += 1;
            }

            const sealResult = bfs(puzzle, individual.isWallMap, scratch, true);
            if (!sealResult.reachesBoundary and sealResult.score > bestNewScore) {
                bestNewScore = sealResult.score;
                bestWallToRemove = candIdx;
                bestSealCount = placed;
                @memcpy(bestSealBuf[0..placed], sealCands[0..placed]);
                bestFreeRemoval = false;
            }

            // Revert seal walls
            for (0..placed) |si| {
                individual.removeWall(sealCands[si], candidates[sealCands[si]], cols);
            }
        }

        // Restore the removed boundary wall
        individual.placeWall(candIdx, candidates[candIdx], cols);
    }

    // Apply the best expansion found
    if (bestWallToRemove) |removeIdx| {
        individual.removeWall(removeIdx, candidates[removeIdx], cols);
        if (!bestFreeRemoval) {
            for (0..bestSealCount) |si| {
                individual.placeWall(bestSealBuf[si], candidates[bestSealBuf[si]], cols);
            }
        }
        individual.score = bestNewScore;
        individual.valid = true;
        return true;
    }

    return false;
}

/// Multi-wall expansion: remove groups of 2-3 adjacent boundary walls at once,
/// then try to re-seal further out. This discovers expansions that single-wall
/// removal cannot — when the gap from removing one wall is too narrow to be
/// worth re-sealing, but removing 2-3 adjacent walls opens a viable path.
fn multiWallExpand(
    individual: *Individual,
    candidates: []const Pos,
    puzzle: *const Puzzle,
    scratch: *BFSScratch,
) bool {
    if (!individual.valid) return false;

    const boundaryWalls = findBoundaryWalls(individual, candidates, puzzle, scratch);
    if (boundaryWalls.len < 2) return false;

    const cols = puzzle.cols;
    const rows = puzzle.rows;

    // Build adjacency among boundary walls: two boundary walls are "adjacent"
    // if their grid positions are cardinal neighbors.
    // For each boundary wall, find its adjacent boundary wall indices.
    // We store this as a flat array of neighbor lists.
    var adjBuf: [4096][4]usize = undefined; // max 4 neighbors per wall
    var adjCount: [4096]u8 = undefined;
    const bwLen = @min(boundaryWalls.len, 4096);

    for (0..bwLen) |wi| {
        adjCount[wi] = 0;
        const posA = candidates[boundaryWalls[wi]];
        for (0..bwLen) |wj| {
            if (wi == wj) continue;
            const posB = candidates[boundaryWalls[wj]];
            const dr = if (posA.row >= posB.row) posA.row - posB.row else posB.row - posA.row;
            const dc = if (posA.col >= posB.col) posA.col - posB.col else posB.col - posA.col;
            if ((dr == 1 and dc == 0) or (dr == 0 and dc == 1)) {
                if (adjCount[wi] < 4) {
                    adjBuf[wi][adjCount[wi]] = wj;
                    adjCount[wi] += 1;
                }
            }
        }
    }

    var bestNewScore: i32 = individual.score;
    var bestRemoveBuf: [3]usize = undefined;
    var bestRemoveCount: usize = 0;
    var bestSealBuf: [2048]usize = undefined;
    var bestSealCount: usize = 0;
    var foundImprovement = false;

    // Try all pairs of adjacent boundary walls
    for (0..bwLen) |wi| {
        for (0..adjCount[wi]) |ni| {
            const wj = adjBuf[wi][ni];
            if (wj <= wi) continue; // avoid duplicates

            const candI = boundaryWalls[wi];
            const candJ = boundaryWalls[wj];

            // Remove both walls
            individual.removeWall(candI, candidates[candI], cols);
            individual.removeWall(candJ, candidates[candJ], cols);

            // Check free expansion (both removed, still valid)
            const freeResult = bfs(puzzle, individual.isWallMap, scratch, true);
            if (!freeResult.reachesBoundary and freeResult.score > bestNewScore) {
                bestNewScore = freeResult.score;
                bestRemoveBuf[0] = candI;
                bestRemoveBuf[1] = candJ;
                bestRemoveCount = 2;
                bestSealCount = 0;
                foundImprovement = true;
            }

            // Try re-sealing if leaked
            if (freeResult.reachesBoundary) {
                const availBudget = puzzle.budget - individual.wallCount;
                if (availBudget > 0) {
                    // Full BFS to find seal candidates
                    _ = bfs(puzzle, individual.isWallMap, scratch, false);
                    const leakStamp = scratch.currentStamp;

                    var sealCands: [2048]usize = undefined;
                    var sealCandCount: usize = 0;

                    for (candidates, 0..) |pos, ci| {
                        if (individual.walls[ci]) continue;
                        if (pos.row == puzzle.horseRow and pos.col == puzzle.horseCol) continue;
                        const cellIdx = pos.row * cols + pos.col;
                        if (scratch.visited[cellIdx] != leakStamp) continue;

                        var onEdge = false;
                        if (pos.row == 0 or pos.row == rows - 1 or pos.col == 0 or pos.col == cols - 1) {
                            onEdge = true;
                        } else {
                            if (puzzle.grid[cellIdx - cols].type == .water or puzzle.grid[cellIdx - cols].type == .wall or scratch.visited[cellIdx - cols] != leakStamp) onEdge = true;
                            if (!onEdge) {
                                if (puzzle.grid[cellIdx + cols].type == .water or puzzle.grid[cellIdx + cols].type == .wall or scratch.visited[cellIdx + cols] != leakStamp) onEdge = true;
                            }
                            if (!onEdge) {
                                if (puzzle.grid[cellIdx - 1].type == .water or puzzle.grid[cellIdx - 1].type == .wall or scratch.visited[cellIdx - 1] != leakStamp) onEdge = true;
                            }
                            if (!onEdge) {
                                if (puzzle.grid[cellIdx + 1].type == .water or puzzle.grid[cellIdx + 1].type == .wall or scratch.visited[cellIdx + 1] != leakStamp) onEdge = true;
                            }
                        }

                        if (onEdge and sealCandCount < 2048) {
                            sealCands[sealCandCount] = ci;
                            sealCandCount += 1;
                        }
                    }

                    if (sealCandCount > 0 and sealCandCount <= availBudget) {
                        var placed: usize = 0;
                        for (0..sealCandCount) |si| {
                            if (placed >= availBudget) break;
                            individual.placeWall(sealCands[si], candidates[sealCands[si]], cols);
                            placed += 1;
                        }

                        const sealResult = bfs(puzzle, individual.isWallMap, scratch, true);
                        if (!sealResult.reachesBoundary and sealResult.score > bestNewScore) {
                            bestNewScore = sealResult.score;
                            bestRemoveBuf[0] = candI;
                            bestRemoveBuf[1] = candJ;
                            bestRemoveCount = 2;
                            bestSealCount = placed;
                            @memcpy(bestSealBuf[0..placed], sealCands[0..placed]);
                            foundImprovement = true;
                        }

                        // Revert seals
                        for (0..placed) |si| {
                            individual.removeWall(sealCands[si], candidates[sealCands[si]], cols);
                        }
                    }
                }
            }

            // Also try triples: for each neighbor of wj that isn't wi
            for (0..adjCount[wj]) |nk| {
                const wk = adjBuf[wj][nk];
                if (wk == wi) continue;
                const candK = boundaryWalls[wk];
                if (individual.walls[candK] == false) continue; // already removed above shouldn't happen

                individual.removeWall(candK, candidates[candK], cols);

                const triResult = bfs(puzzle, individual.isWallMap, scratch, true);
                if (!triResult.reachesBoundary and triResult.score > bestNewScore) {
                    bestNewScore = triResult.score;
                    bestRemoveBuf[0] = candI;
                    bestRemoveBuf[1] = candJ;
                    bestRemoveBuf[2] = candK;
                    bestRemoveCount = 3;
                    bestSealCount = 0;
                    foundImprovement = true;
                }

                // Try re-sealing the triple gap
                if (triResult.reachesBoundary) {
                    const availBudget3 = puzzle.budget - individual.wallCount;
                    if (availBudget3 > 0) {
                        _ = bfs(puzzle, individual.isWallMap, scratch, false);
                        const ls3 = scratch.currentStamp;

                        var sc3: [2048]usize = undefined;
                        var sc3Count: usize = 0;

                        for (candidates, 0..) |pos, ci| {
                            if (individual.walls[ci]) continue;
                            if (pos.row == puzzle.horseRow and pos.col == puzzle.horseCol) continue;
                            const cellIdx = pos.row * cols + pos.col;
                            if (scratch.visited[cellIdx] != ls3) continue;

                            var onEdge = false;
                            if (pos.row == 0 or pos.row == rows - 1 or pos.col == 0 or pos.col == cols - 1) {
                                onEdge = true;
                            } else {
                                if (puzzle.grid[cellIdx - cols].type == .water or puzzle.grid[cellIdx - cols].type == .wall or scratch.visited[cellIdx - cols] != ls3) onEdge = true;
                                if (!onEdge and (puzzle.grid[cellIdx + cols].type == .water or puzzle.grid[cellIdx + cols].type == .wall or scratch.visited[cellIdx + cols] != ls3)) onEdge = true;
                                if (!onEdge and (puzzle.grid[cellIdx - 1].type == .water or puzzle.grid[cellIdx - 1].type == .wall or scratch.visited[cellIdx - 1] != ls3)) onEdge = true;
                                if (!onEdge and (puzzle.grid[cellIdx + 1].type == .water or puzzle.grid[cellIdx + 1].type == .wall or scratch.visited[cellIdx + 1] != ls3)) onEdge = true;
                            }

                            if (onEdge and sc3Count < 2048) {
                                sc3[sc3Count] = ci;
                                sc3Count += 1;
                            }
                        }

                        if (sc3Count > 0 and sc3Count <= availBudget3) {
                            var placed3: usize = 0;
                            for (0..sc3Count) |si| {
                                if (placed3 >= availBudget3) break;
                                individual.placeWall(sc3[si], candidates[sc3[si]], cols);
                                placed3 += 1;
                            }

                            const sr3 = bfs(puzzle, individual.isWallMap, scratch, true);
                            if (!sr3.reachesBoundary and sr3.score > bestNewScore) {
                                bestNewScore = sr3.score;
                                bestRemoveBuf[0] = candI;
                                bestRemoveBuf[1] = candJ;
                                bestRemoveBuf[2] = candK;
                                bestRemoveCount = 3;
                                bestSealCount = placed3;
                                @memcpy(bestSealBuf[0..placed3], sc3[0..placed3]);
                                foundImprovement = true;
                            }

                            for (0..placed3) |si| {
                                individual.removeWall(sc3[si], candidates[sc3[si]], cols);
                            }
                        }
                    }
                }

                individual.placeWall(candK, candidates[candK], cols);
            }

            // Restore both walls
            individual.placeWall(candI, candidates[candI], cols);
            individual.placeWall(candJ, candidates[candJ], cols);
        }
    }

    if (foundImprovement) {
        // Apply best expansion
        for (0..bestRemoveCount) |ri| {
            individual.removeWall(bestRemoveBuf[ri], candidates[bestRemoveBuf[ri]], cols);
        }
        for (0..bestSealCount) |si| {
            individual.placeWall(bestSealBuf[si], candidates[bestSealBuf[si]], cols);
        }
        individual.score = bestNewScore;
        individual.valid = true;
        return true;
    }

    return false;
}

// =============================================================================
// Genetic Algorithm - Population Management
// =============================================================================

/// Allocate a population of individuals with pre-allocated wall buffers.
fn allocPopulation(allocator: std.mem.Allocator, size: usize, numCandidates: usize, gridSize: usize) ![]Individual {
    const pop = try allocator.alloc(Individual, size);
    for (pop) |*ind| {
        const walls = try allocator.alloc(bool, numCandidates);
        const isWallMap = try allocator.alloc(bool, gridSize);
        @memset(walls, false);
        @memset(isWallMap, false);
        ind.* = .{
            .walls = walls,
            .isWallMap = isWallMap,
            .score = 0,
            .valid = false,
            .wallCount = 0,
            .allocator = allocator,
        };
    }
    return pop;
}

fn freePopulation(allocator: std.mem.Allocator, pop: []Individual) void {
    for (pop) |*ind|
    {
        allocator.free(ind.walls);
        allocator.free(ind.isWallMap);
    }
    allocator.free(pop);
}

/// Constructively initialize walls by doing a BFS from the horse.
fn constructiveInit(
    individual: *Individual,
    candidates: []const Pos,
    puzzle: *const Puzzle,
    scratch: *BFSScratch,
    gridToCand: []const usize,
    maxExpand: usize,
    random: std.Random,
) void {
    const cols = puzzle.cols;
    const rows = puzzle.rows;
    const sentinel = std.math.maxInt(usize);

    // Try with given maxExpand, retry with halved value if frontier exceeds budget
    var tryMax = maxExpand;
    for (0..20) |_| {
        // Clear the individual
        for (individual.walls, 0..) |w, i|
        {
            if (w) individual.isWallMap[candidates[i].row * cols + candidates[i].col] = false;
        }
        @memset(individual.walls, false);
        individual.wallCount = 0;
        
        // BFS from horse
        var head: usize = 0;
        var tail: usize = 0;
        const stamp = scratch.nextStamp();

        const startIdx = puzzle.horseRow * cols + puzzle.horseCol;
        scratch.visited[startIdx] = stamp;
        scratch.queue[tail] = .{ .row = puzzle.horseRow, .col = puzzle.horseCol };
        tail += 1;

        var expanded: usize = 0;
        var overBudget = false;

        while (head < tail) {
            const current = scratch.queue[head];
            head += 1;
            expanded += 1;

            const ci = current.row * cols + current.col;
            
            // Don't expand from boundary cells
            if (current.row == 0 or current.row == rows - 1 or
                current.col == 0 or current.col == cols - 1) continue;
                
            // Stop expanding new cells once we've explored enough
            if (expanded > tryMax) continue;
            
            // Cardinal neighbors
            const deltas = [4][2]i32{ .{ -1, 0 }, .{ 1, 0 }, .{ 0, -1 }, .{ 0, 1 } };
            for (deltas) |d| {
                const nr_i = @as(i32, @intCast(current.row)) + d[0];
                const nc_i = @as(i32, @intCast(current.col)) + d[1];
                if (nr_i < 0 or nr_i >= @as(i32, @intCast(rows))) continue;
                if (nc_i < 0 or nc_i >= @as(i32, @intCast(cols))) continue;
                
                const nr: usize = @intCast(nr_i);
                const nc: usize = @intCast(nc_i);
                const ni = nr * cols + nc;

                if (scratch.visited[ni] == stamp) continue;

                const ct = puzzle.grid[ni].type;
                if (ct == .water or ct == .wall) continue;

                // If it's a grass candidate, decide: wall it or include it?
                const candIdx = gridToCand[ni];
                if (candIdx != sentinel and ct == .grass) {
                    scratch.visited[ni] = stamp;
                    
                    var behindScore: i32 = 0;
                    const dts = [4][2]i32{ .{ -1, 0 }, .{ 1, 0 }, .{ 0, -1 }, .{ 0, 1 } };
                    for (dts) |dd| {
                        const br_i = @as(i32, @intCast(nr)) + dd[0];
                        const bc_i = @as(i32, @intCast(nc)) + dd[1];
                        if (br_i < 0 or br_i >= @as(i32, @intCast(rows))) continue;
                        if (bc_i < 0 or bc_i >= @as(i32, @intCast(cols))) continue;
                        const bi: usize = @as(usize, @intCast(br_i)) * cols + @as(usize, @intCast(bc_i));
                        if (scratch.visited[bi] == stamp) continue;
                        behindScore += puzzle.scoreMap[bi];
                    }

                    if (behindScore > 5 and individual.wallCount + 2 < puzzle.budget and random.intRangeLessThan(u32, 0, 100) < 30) {
                        scratch.queue[tail] = .{ .row = nr, .col = nc };
                        tail += 1;
                    } else if (individual.wallCount < puzzle.budget) {
                        individual.placeWall(candIdx, candidates[candIdx], cols);
                    } else {
                        overBudget = true;
                    }
                    continue;
                }

                // Otherwise expand into it (portal, apple, bee, cherry)
                scratch.visited[ni] = stamp;
                scratch.queue[tail] = .{ .row = nr, .col = nc };
                tail += 1;
            }

            // Portal traversal — can't wall portals, must expand or skip
            if (puzzle.grid[ci].type == .portal) {
                for (puzzle.portals) |pp|
                {
                    const partner = portalPartner(pp, current.row, current.col) orelse continue;
                    const pi = partner.row * cols + partner.col;
                    if (scratch.visited[pi] == stamp) continue;
                    
                    // 50% chance to traverse — creates diversity
                    if (random.float(f32) < 0.5) {
                        scratch.visited[pi] = stamp;
                        scratch.queue[tail] = partner;
                        tail += 1;
                    }
                }
            }
        }

        // If over budget, retry with smaller expansion
        if (overBudget) {
            tryMax = if (tryMax > 2) tryMax / 2 else 1;
            continue;
        }

        // Fill remaining budget: prefer walls adjacent to existing walls (thicken barrier)
        if (individual.wallCount < puzzle.budget) {
            const stamp2 = scratch.currentStamp; // reuse the BFS stamp for "inside" check
            for (candidates, 0..) |pos, i|
            {
                if (individual.wallCount >= puzzle.budget) break;
                if (individual.walls[i]) continue;
                if (pos.row == puzzle.horseRow and pos.col == puzzle.horseCol) continue;
                
                const pci = pos.row * cols + pos.col;
                if (scratch.visited[pci] == stamp2) continue; // inside the enclosure

                var adjWall = false;
                if (pos.row > 0 and individual.isWallMap[pci - cols]) adjWall = true;
                if (!adjWall and pos.row + 1 < rows and individual.isWallMap[pci + cols]) adjWall = true;
                if (!adjWall and pos.col > 0 and individual.isWallMap[pci - 1]) adjWall = true;
                if (!adjWall and pos.col + 1 < cols and individual.isWallMap[pci + 1]) adjWall = true;
                
                if (adjWall) individual.placeWall(i, pos, cols);
            }
        }

        // Fill any still-remaining budget randomly
        if (individual.wallCount < puzzle.budget) {
            var attempts: usize = 0;
            while (individual.wallCount < puzzle.budget and attempts < candidates.len * 2) : (attempts += 1) {
                const ri = random.intRangeLessThan(usize, 0, candidates.len);
                if (!individual.walls[ri]) {
                    individual.placeWall(ri, candidates[ri], cols);
                }
            }
        }

        return; // done
    }

    // All retries failed — fall back to random
    randomizeWalls(individual, candidates, cols, puzzle.budget, random);
}

/// Score-aware constructive initialization. Grows the enclosure outward from
/// the horse using a best-first expansion that prioritizes high-value tiles and
/// always traverses portals (since the horse will always use them).
///
/// Key improvements over constructiveInit:
///  - Portals are always traversed (they're mandatory reachability)
///  - Expansion is score-biased: high-value tiles are included first
///  - Bee-heavy regions are walled earlier to exclude them
///  - Wall placement accounts for "sealing cost": only wall a cell if the
///    budget can afford to close the gap it creates
fn scoreAwareInit(
    individual: *Individual,
    candidates: []const Pos,
    puzzle: *const Puzzle,
    scratch: *BFSScratch,
    targetSize: usize,
    random: std.Random,
) void {
    const cols = puzzle.cols;
    const rows = puzzle.rows;

    // Clear the individual
    for (individual.walls, 0..) |w, i| {
        if (w) individual.isWallMap[candidates[i].row * cols + candidates[i].col] = false;
    }
    @memset(individual.walls, false);
    individual.wallCount = 0;

    // Phase 1: BFS from horse, always following portals, to discover what
    // the horse can reach with NO walls. Tag each reachable cell with its
    // score contribution and distance from horse.
    const stamp = scratch.nextStamp();
    const startIdx = puzzle.horseRow * cols + puzzle.horseCol;
    scratch.visit(startIdx, 0);
    scratch.queue[0] = .{ .row = puzzle.horseRow, .col = puzzle.horseCol };
    var bfsHead: usize = 0;
    var bfsTail: usize = 1;

    while (bfsHead < bfsTail) {
        const current = scratch.queue[bfsHead];
        bfsHead += 1;
        const ci = current.row * cols + current.col;
        const curDepth = scratch.depth[ci]; // safe: we visited this cell

        // Cardinal neighbors
        const deltas = [4][2]i32{ .{ -1, 0 }, .{ 1, 0 }, .{ 0, -1 }, .{ 0, 1 } };
        for (deltas) |d| {
            const nr_i = @as(i32, @intCast(current.row)) + d[0];
            const nc_i = @as(i32, @intCast(current.col)) + d[1];
            if (nr_i < 0 or nr_i >= @as(i32, @intCast(rows))) continue;
            if (nc_i < 0 or nc_i >= @as(i32, @intCast(cols))) continue;
            const nr: usize = @intCast(nr_i);
            const nc: usize = @intCast(nc_i);
            const ni = nr * cols + nc;
            if (scratch.visited[ni] == stamp) continue;
            const ct = puzzle.grid[ni].type;
            if (ct == .water) continue;
            scratch.visit(ni, curDepth + 1);
            scratch.queue[bfsTail] = .{ .row = nr, .col = nc };
            bfsTail += 1;
        }

        // Always traverse portals
        if (puzzle.grid[ci].type == .portal) {
            for (puzzle.portals) |pp| {
                const partner = portalPartner(pp, current.row, current.col) orelse continue;
                const pi = partner.row * cols + partner.col;
                if (scratch.visited[pi] == stamp) continue;
                scratch.visit(pi, curDepth + 1);
                scratch.queue[bfsTail] = partner;
                bfsTail += 1;
            }
        }
    }

    // Phase 2: Score each reachable non-water cell by a "value density" metric
    // that considers the cell's own score and its neighborhood quality.
    // Then decide which cells to INCLUDE (expand into) vs WALL (block).
    //
    // Strategy: sort reachable grass candidates by distance from horse.
    // Walk outward from horse. For each ring of distance d:
    //   - Include cells with high score (apples, cherries) in the enclosure
    //   - Wall cells that border low-value / bee-heavy regions
    //   - Stop when we've used enough of the budget or reached targetSize

    // Collect reachable grass candidates with their distances
    var sortBuf: [10000]u32 = undefined; // packed: distance in high 16, candidate index in low 16
    var sortLen: usize = 0;

    for (candidates, 0..) |pos, i| {
        const ci = pos.row * cols + pos.col;
        if (scratch.visited[ci] != stamp) continue;
        if (pos.row == puzzle.horseRow and pos.col == puzzle.horseCol) continue;
        if (puzzle.grid[ci].type != .grass) continue;
        if (sortLen >= 10000) break;

        const dist: u32 = scratch.getDepthOrInf(ci);
        // Pack: distance in upper 16 bits, index in lower 16 bits
        sortBuf[sortLen] = (dist << 16) | @as(u32, @intCast(i & 0xFFFF));
        sortLen += 1;
    }

    // Sort by distance (ascending) — insertion sort is fine for ≤10000 elements
    for (1..sortLen) |si| {
        const key = sortBuf[si];
        var j: usize = si;
        while (j > 0 and sortBuf[j - 1] > key) {
            sortBuf[j] = sortBuf[j - 1];
            j -= 1;
        }
        sortBuf[j] = key;
    }

    // Walk through candidates by distance, building the wall boundary
    var included: usize = 0;
    for (0..sortLen) |si| {
        if (individual.wallCount >= puzzle.budget) break;
        if (included >= targetSize) break;

        const candIdx: usize = sortBuf[si] & 0xFFFF;
        if (candIdx >= candidates.len) continue;
        if (individual.walls[candIdx]) continue;

        const pos = candidates[candIdx];
        const ci = pos.row * cols + pos.col;

        // Compute neighborhood score: what's behind this cell?
        var neighborScore: i32 = 0;
        var neighborBees: i32 = 0;
        const dts = [4][2]i32{ .{ -1, 0 }, .{ 1, 0 }, .{ 0, -1 }, .{ 0, 1 } };
        for (dts) |d| {
            const br_i = @as(i32, @intCast(pos.row)) + d[0];
            const bc_i = @as(i32, @intCast(pos.col)) + d[1];
            if (br_i < 0 or br_i >= @as(i32, @intCast(rows))) continue;
            if (bc_i < 0 or bc_i >= @as(i32, @intCast(cols))) continue;
            const bi: usize = @as(usize, @intCast(br_i)) * cols + @as(usize, @intCast(bc_i));
            neighborScore += puzzle.scoreMap[bi];
            if (puzzle.grid[bi].type == .bee) neighborBees += 1;
        }

        // Decision: wall this cell or let the enclosure flow through it?
        // Wall if: neighborhood is bee-heavy, or we're far from horse and
        // the area beyond isn't valuable
        const dist = scratch.getDepthOrInf(ci);
        const farFromHorse = dist > @as(u32, @intCast(targetSize / 3));

        if (neighborBees >= 2) {
            // Bee-heavy neighborhood — wall it to exclude bees
            individual.placeWall(candIdx, candidates[candIdx], cols);
        } else if (farFromHorse and neighborScore <= 0) {
            // Far and low value — wall it
            individual.placeWall(candIdx, candidates[candIdx], cols);
        } else {
            // Include it in the enclosure
            included += 1;
        }
    }

    // Phase 3: Wall any remaining reachable candidates that are at the frontier
    // (beyond our included region) to seal the enclosure
    for (0..sortLen) |si| {
        if (individual.wallCount >= puzzle.budget) break;
        const candIdx: usize = sortBuf[si] & 0xFFFF;
        if (candIdx >= candidates.len) continue;
        if (individual.walls[candIdx]) continue;

        // If this cell is beyond our included region, wall it
        const dist = sortBuf[si] >> 16;
        if (dist > @as(u32, @intCast(targetSize / 2))) {
            individual.placeWall(candIdx, candidates[candIdx], cols);
        }
    }

    // Phase 4: Fill remaining budget with walls adjacent to existing walls
    // (thicken the barrier to help the GA seal gaps)
    if (individual.wallCount < puzzle.budget) {
        for (candidates, 0..) |pos, i| {
            if (individual.wallCount >= puzzle.budget) break;
            if (individual.walls[i]) continue;
            if (pos.row == puzzle.horseRow and pos.col == puzzle.horseCol) continue;

            const pci = pos.row * cols + pos.col;
            // Skip cells inside the enclosure (close to horse and not walled)
            if (scratch.getDepthOrInf(pci) < @as(u32, @intCast(targetSize / 4))) continue;

            var adjExistingWall = false;
            if (pos.row > 0 and individual.isWallMap[pci - cols]) adjExistingWall = true;
            if (!adjExistingWall and pos.row + 1 < rows and individual.isWallMap[pci + cols]) adjExistingWall = true;
            if (!adjExistingWall and pos.col > 0 and individual.isWallMap[pci - 1]) adjExistingWall = true;
            if (!adjExistingWall and pos.col + 1 < cols and individual.isWallMap[pci + 1]) adjExistingWall = true;

            if (adjExistingWall) {
                individual.placeWall(i, pos, cols);
            }
        }
    }

    // Phase 5: Fill any remaining budget randomly
    if (individual.wallCount < puzzle.budget) {
        var attempts: usize = 0;
        while (individual.wallCount < puzzle.budget and attempts < candidates.len * 2) : (attempts += 1) {
            const ri = random.intRangeLessThan(usize, 0, candidates.len);
            if (!individual.walls[ri]) {
                individual.placeWall(ri, candidates[ri], cols);
            }
        }
    }
}

/// Randomly initialize an individual's wall placement.
/// Clears only previously-set cells in O(wallCount), not O(gridSize).
fn randomizeWalls(individual: *Individual, candidates: []const Pos, cols: usize, budget: u32, random: std.Random) void {
    // Clear only walls that are currently set — O(budget) not O(gridSize)
    for (individual.walls, 0..) |w, i|
    {
        if (w) {
            individual.isWallMap[candidates[i].row * cols + candidates[i].col] = false;
        }
    }
    @memset(individual.walls, false);
    individual.wallCount = 0;
    
    while (individual.wallCount < budget) {
        const i = random.intRangeLessThan(usize, 0, individual.walls.len);
        if (!individual.walls[i]) {
            individual.placeWall(i, candidates[i], cols);
        }
    }
}

/// O(n) scan to find the top-k valid and top-k invalid individuals.
fn findTopK(population: []const Individual) TopKResult {
    var result = TopKResult{};
    var bestScore: i32 = std.math.minInt(i32);
    var bestValid = false;

    for (population, 0..) |ind, i| {
        // Track overall best (valid preferred, then highest score)
        const dominated = (bestValid and !ind.valid);
        const dominated2 = (bestValid == ind.valid and ind.score <= bestScore);
        
        if (!dominated and !dominated2) {
            bestScore = ind.score;
            bestValid = ind.valid;
            result.bestIdx = i;
        }

        if (ind.valid) {
            insertTopK(&result.validIndices, &result.validCount, validEliteCount, i, ind.score, population);
        } else {
            insertTopK(&result.invalidIndices, &result.invalidCount, invalidEliteCount, i, ind.score, population);
        }
    }

    return result;
}

/// Insert index i into a small sorted (descending by score) array if it qualifies.
fn insertTopK(
    indices: []usize,
    count: *usize,
    comptime capacity: usize,
    i: usize,
    score: i32,
    population: []const Individual,
) void {
    // Find insertion position (keep descending order)
    var pos: usize = 0;
    while (pos < count.*) : (pos += 1) {
        if (score > population[indices[pos]].score) break;
    }

    if (pos >= capacity) return; // Doesn't qualify

    // Shift elements right to make room
    const shiftEnd = @min(count.*, capacity - 1);
    var j: usize = shiftEnd;
    while (j > pos) : (j -= 1) {
        indices[j] = indices[j - 1];
    }
    indices[pos] = i;

    if (count.* < capacity) count.* += 1;
}

/// SA acceptance that respects validity: never accept invalid over valid parent.
fn acceptWithAnnealing(
    oldScore: i32,
    oldValid: bool,
    newScore: i32,
    newValid: bool,
    temperature: f64,
    random: std.Random,
) bool {
    // Never regress from valid to invalid
    if (oldValid and !newValid) return false;
    // Always accept invalid→valid transition
    if (!oldValid and newValid) return true;

    if (newScore >= oldScore) return true;
    
    const delta = @as(f64, @floatFromInt(newScore - oldScore));
    const prob = std.math.exp(delta / temperature);

    return random.float(f64) < prob;
}

// =============================================================================
// Genetic Algorithm - Main Loop
// =============================================================================

/// Run the genetic algorithm to find the best wall placement.
fn solve(puzzle: *const Puzzle, candidates: []const Pos, random: std.Random, popSize: usize, seedWalls: ?[]const bool, gridToCand: []const usize, migration: *MigrationPool, islandIdx: usize, allocator: std.mem.Allocator) !SolveResult {
    var scratch = try BFSScratch.init(allocator, puzzle.rows * puzzle.cols);
    defer scratch.deinit();

    const gridSize = puzzle.rows * puzzle.cols;
    const popA = try allocPopulation(allocator, popSize, candidates.len, gridSize);
    defer freePopulation(allocator, popA);
    const popB = try allocPopulation(allocator, popSize, candidates.len, gridSize);
    defer freePopulation(allocator, popB);

    var population = popA;
    var next = popB;
    
    var startIdx: usize = 0;
    if (seedWalls) |sw| {
        // Slot 0: exact pre-placed solution, then fill any remaining budget randomly
        @memcpy(population[0].walls, sw);
        population[0].wallCount = 0;
        for (sw) |w| { if (w) population[0].wallCount += 1; }
        
        population[0].rebuildIsWallMap(candidates, puzzle.cols);
        
        while (population[0].wallCount < puzzle.budget) {
            const ri = random.intRangeLessThan(usize, 0, candidates.len);
            if (!population[0].walls[ri]) {
                population[0].placeWall(ri, candidates[ri], puzzle.cols);
            }
        }
        evaluateFitness(&population[0], candidates, puzzle, &scratch);
        
        // Slot 1: lightly mutated copy for diversity
        if (popSize > 1) {
            @memcpy(population[1].walls, population[0].walls);
            population[1].wallCount = population[0].wallCount;
            population[1].rebuildIsWallMap(candidates, puzzle.cols);
            for (0..3) |_| mutate(&population[1], candidates, puzzle.cols, puzzle.budget, random);
            evaluateFitness(&population[1], candidates, puzzle, &scratch);
        }

        startIdx = @min(2, popSize);
    }

    const randomSlots = @max(2, popSize / 5);
    const constructiveSlots = if (popSize > startIdx + randomSlots)
        popSize - startIdx - randomSlots
    else
        0;
        
    for (population[startIdx..], startIdx..) |*individual, idx| {
        if (constructiveSlots == 0 or idx >= startIdx + constructiveSlots) {
            randomizeWalls(individual, candidates, puzzle.cols, puzzle.budget, random);
        } else {
            const slot = idx - startIdx;
            const minCells: usize = 2;
            const maxAllowed: usize = @max(puzzle.budget * 3, gridSize / 4);
            
            // Alternate between old constructiveInit and new scoreAwareInit
            if (slot % 2 == 0) {
                // Score-aware: vary target size across slots
                const targetSize = if (constructiveSlots <= 2)
                    maxAllowed / 2
                else
                    minCells + ((slot / 2) * (maxAllowed - minCells)) / ((constructiveSlots / 2));
                scoreAwareInit(individual, candidates, puzzle, &scratch, targetSize, random);
            } else {
                // Original constructive: vary maxExpand across slots
                const maxCells = if (constructiveSlots <= 1)
                    maxAllowed / 2
                else
                    minCells + (slot * (maxAllowed - minCells)) / (constructiveSlots - 1);
                constructiveInit(individual, candidates, puzzle, &scratch, gridToCand, maxCells, random);
            }
        }
        evaluateFitness(individual, candidates, puzzle, &scratch);
        
        if (individual.valid) {
            pruneWalls(individual, candidates, puzzle, &scratch);
            for (0..10) |_| {
                if (!expandMutation(individual, candidates, puzzle, &scratch, random)) break;
                pruneWalls(individual, candidates, puzzle, &scratch);
            }
        }
    }

    std.mem.sort(Individual, population, {}, Individual.compareDescending);
    var bestSoFar: i32 = population[0].score;
    var gensSinceImprovement: usize = 0;
    var restartCount: usize = 0;
    
    const bestEverWalls = try allocator.alloc(bool, candidates.len);
    defer allocator.free(bestEverWalls);
    @memcpy(bestEverWalls, population[0].walls);
    var bestEverScore: i32 = if (population[0].valid) population[0].score else std.math.minInt(i32);
    var bestEverValid: bool = population[0].valid;
    
    for (1..gaGenerations + 1) |generation| {
        //copy top-k valid and top-k invalid via O(n) scan from previous gen
        const prevTopK = findTopK(population);
        var eliteIdx: usize = 0;

        // Copy top valid elites
        for (0..prevTopK.validCount) |vi|
        {
            const si = prevTopK.validIndices[vi];
            @memcpy(next[eliteIdx].walls, population[si].walls);
            next[eliteIdx].score = population[si].score;
            next[eliteIdx].valid = population[si].valid;
            next[eliteIdx].wallCount = population[si].wallCount;
            next[eliteIdx].rebuildIsWallMap(candidates, puzzle.cols);
            eliteIdx += 1;
        }

        // Copy top invalid elites
        for (0..prevTopK.invalidCount) |ii|
        {
            const si = prevTopK.invalidIndices[ii];
            @memcpy(next[eliteIdx].walls, population[si].walls);
            next[eliteIdx].score = population[si].score;
            next[eliteIdx].valid = population[si].valid;
            next[eliteIdx].wallCount = population[si].wallCount;
            next[eliteIdx].rebuildIsWallMap(candidates, puzzle.cols);
            eliteIdx += 1;
        }

        // Breed remaining population
        for (eliteCount..popSize) |i|
        {
            const parent1 = tournamentSelect(population, random);
            const parent2 = tournamentSelect(population, random);

            crossoverInto(&next[i], parent1, parent2, candidates, puzzle.cols, puzzle.budget);

            const roll = random.intRangeLessThan(u32, 0, 100);
            if (roll < 5) {
                // 5%: BIG jump (Circular Radius)
                destructiveMutation(&next[i], candidates, puzzle, &scratch, random);
            } else if (roll < 10) {
                // 5%: Chain destruction
                chainRemovalMutation(&next[i], candidates, puzzle, gridToCand, random);
            } else if (roll < 15) {
                // 5%: Wall shifting (Nudging)
                shiftMutation(&next[i], candidates, puzzle, gridToCand, random);
            } else if (roll < mutationRate) {
                // Normal mutation
                mutate(&next[i], candidates, puzzle.cols, puzzle.budget, random);
            }

            evaluateFitness(&next[i], candidates, puzzle, &scratch);
            
            if (!next[i].valid and random.intRangeLessThan(u32, 0, 100) < 60) {
                sealLeakMutation(&next[i], candidates, puzzle, &scratch, gridToCand, random);
            }
        }

        // Swap population buffers
        const tmp = population;
        population = next;
        next = tmp;

        const topK = findTopK(population);

        const pruneFreq: usize = if (gridSize > 5000) 300
                                 else if (gridSize > 2000) 200
                                 else 100;
                                 
        const doPruneExpand = (population[topK.bestIdx].score > bestSoFar) or (generation % pruneFreq == 0);
        
        if (doPruneExpand) {
            // Improve valid elites: prune + multi-expand
            for (0..topK.validCount) |vi|
            {
                const ei = topK.validIndices[vi];
                pruneWalls(&population[ei], candidates, puzzle, &scratch);
                // Multi-expand
                for (0..5) |_|
                {
                    if (!expandMutation(&population[ei], candidates, puzzle, &scratch, random)) break;
                    pruneWalls(&population[ei], candidates, puzzle, &scratch);
                }
            }
            // Try to seal leaks on top invalid elites
            for (0..topK.invalidCount) |ii|
            {
                const ei = topK.invalidIndices[ii];
                sealLeakMutation(&population[ei], candidates, puzzle, &scratch, gridToCand, random);
            }
        }

        const ilsFreq: usize = if (gridSize > 5000) 5000 else 2000;
        if (generation % ilsFreq == 0 and topK.validCount > 0) {
            const bestValidIdx = topK.validIndices[0];
            pruneWalls(&population[bestValidIdx], candidates, puzzle, &scratch);
            _ = greedyHillClimb(&population[bestValidIdx], candidates, puzzle, &scratch, 1);
        }

        if (population[topK.bestIdx].score > bestSoFar) {
            bestSoFar = population[topK.bestIdx].score;
            gensSinceImprovement = 0;
        } else {
            gensSinceImprovement += 1;
        }

        // Update best-ever
        if (population[topK.bestIdx].valid and population[topK.bestIdx].score > bestEverScore) {
            bestEverScore = population[topK.bestIdx].score;
            bestEverValid = true;
            @memcpy(bestEverWalls, population[topK.bestIdx].walls);
        }

        // =====================================================================
        // Island-model migration
        // =====================================================================
        if (generation % migrationFrequency == 0) {
            if (bestEverValid) {
                migration.exportBest(islandIdx, bestEverWalls, bestEverScore, true, blk: {
                    var wc: u32 = 0;
                    for (bestEverWalls) |bw| { if (bw) wc += 1; }
                    break :blk wc;
                });
            }

            const importSlot = popSize - 1;
            if (migration.importFrom(islandIdx, random, population[importSlot].walls)) |imported|
            {
                population[importSlot].score = imported.score;
                population[importSlot].valid = imported.isValid;
                population[importSlot].wallCount = imported.wallCount;
                population[importSlot].rebuildIsWallMap(candidates, puzzle.cols);
                
                evaluateFitness(&population[importSlot], candidates, puzzle, &scratch);
                
                if (population[importSlot].valid and population[importSlot].score > bestEverScore) {
                    bestEverScore = population[importSlot].score;
                    bestEverValid = true;
                    @memcpy(bestEverWalls, population[importSlot].walls);
                    bestSoFar = bestEverScore;
                    gensSinceImprovement = 0;
                }
            }
        }

        const restartCutoff: usize = gaGenerations * 3 / 4;
        
        // Diversity injection on stagnation
        if (gensSinceImprovement >= stagnationThreshold and restartCount < maxRestarts and generation < restartCutoff) {
            restartCount += 1;
            
            if (bestEverValid) {
                @memcpy(population[0].walls, bestEverWalls);
                population[0].wallCount = 0;
                for (bestEverWalls) |bw| { if (bw) population[0].wallCount += 1; }
                
                population[0].rebuildIsWallMap(candidates, puzzle.cols);
                evaluateFitness(&population[0], candidates, puzzle, &scratch);
            }

            const reinitStart = if (bestEverValid) @max(1, eliteCount) else eliteCount;
            for (reinitStart..popSize) |i| {
                if (i % 4 == 0) {
                    randomizeWalls(&population[i], candidates, puzzle.cols, puzzle.budget, random);
                } else if (i % 4 == 1) {
                    const targetSize = random.intRangeLessThan(usize, 2, @max(puzzle.budget * 3, gridSize / 4));
                    scoreAwareInit(&population[i], candidates, puzzle, &scratch, targetSize, random);
                } else {
                    const maxCells = random.intRangeLessThan(usize, 2, @max(puzzle.budget * 3, gridSize / 4));
                    constructiveInit(&population[i], candidates, puzzle, &scratch, gridToCand, maxCells, random);
                }
                evaluateFitness(&population[i], candidates, puzzle, &scratch);
                
                if (population[i].valid) {
                    pruneWalls(&population[i], candidates, puzzle, &scratch);
                    for (0..10) |_| {
                        if (!expandMutation(&population[i], candidates, puzzle, &scratch, random)) break;
                        pruneWalls(&population[i], candidates, puzzle, &scratch);
                    }
                }
            }

            gensSinceImprovement = 0;
        }
    }

    const finalTopK = findTopK(population);
    const finalBest = finalTopK.bestIdx;
    
    // Final post-processing on the best from current population
    if (population[finalBest].valid) {
        exhaustivePostProcess(&population[finalBest], candidates, puzzle, &scratch, random);
    }

    if (population[finalBest].valid and population[finalBest].score > bestEverScore) {
        bestEverScore = population[finalBest].score;
        bestEverValid = true;
        @memcpy(bestEverWalls, population[finalBest].walls);
    }

    // Also run exhaustive post-processing on the best-ever solution
    if (bestEverValid) {
        @memcpy(population[0].walls, bestEverWalls);
        population[0].wallCount = 0;
        for (bestEverWalls) |bw| { if (bw) population[0].wallCount += 1; }
        
        population[0].rebuildIsWallMap(candidates, puzzle.cols);
        population[0].valid = true;
        population[0].score = bestEverScore;

        exhaustivePostProcess(&population[0], candidates, puzzle, &scratch, random);
        
        if (population[0].score > bestEverScore) {
            bestEverScore = population[0].score;
            @memcpy(bestEverWalls, population[0].walls);
        }
    }

    const bestWalls = try allocator.alloc(bool, candidates.len);
    if (bestEverValid and (!population[finalBest].valid or bestEverScore > population[finalBest].score)) {
        @memcpy(bestWalls, bestEverWalls);
        return .{ .walls = bestWalls, .score = bestEverScore, .valid = true };
    }

    @memcpy(bestWalls, population[finalBest].walls);
    return .{
        .walls = bestWalls,
        .score = population[finalBest].score,
        .valid = population[finalBest].valid,
    };
}

// =============================================================================
// Entry Point
// =============================================================================

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    
    if (args.len < 2) {
        return error.MissingArgument;
    }

    const content = try std.fs.cwd().readFileAlloc(allocator, args[1], 1024 * 1024);
    defer allocator.free(content);
    
    var puzzle = try parseInput(allocator, content);
    defer puzzle.deinit();

    var scratch = try BFSScratch.init(allocator, puzzle.rows * puzzle.cols);
    defer scratch.deinit();
    
    // Capture pre-placed wall grid positions BEFORE removing them.
    var prePlacedWallPositions = std.ArrayList(Pos){};
    defer prePlacedWallPositions.deinit(allocator);
    for (0..puzzle.rows) |row|
    {
        for (0..puzzle.cols) |col|
        {
            if (puzzle.grid[row * puzzle.cols + col].type == .wall) {
                try prePlacedWallPositions.append(allocator, .{ .row = row, .col = col });
            }
        }
    }

    removePrePlacedWalls(&puzzle);
    
    // Compute full reachability with no walls
    const fullReach = bfs(&puzzle, null, &scratch, false);
    const fullReachStamp = scratch.currentStamp;
    _ = fullReach;

    const candidates = try getCandidateWalls(&puzzle, scratch.visited, fullReachStamp, allocator);
    defer allocator.free(candidates);
    
    // Build gridToCand mapping
    const gridToCand = try allocator.alloc(usize, puzzle.rows * puzzle.cols);
    defer allocator.free(gridToCand);
    @memset(gridToCand, std.math.maxInt(usize));
    for (candidates, 0..) |pos, ci|
    {
        gridToCand[pos.row * puzzle.cols + pos.col] = ci;
    }

    const seedWalls = try allocator.alloc(bool, candidates.len);
    defer allocator.free(seedWalls);
    @memset(seedWalls, false);
    for (prePlacedWallPositions.items) |pos|
    {
        const ci = gridToCand[pos.row * puzzle.cols + pos.col];
        if (ci != std.math.maxInt(usize)) {
            seedWalls[ci] = true;
        }
    }

    const numThreads: usize = @max(1, std.Thread.getCpuCount() catch 4);
    
    // Create shared migration pool for island-model elite exchange
    var migrationPool = try MigrationPool.init(allocator, numThreads, candidates.len);
    defer migrationPool.deinit();

    var contexts = try allocator.alloc(ThreadContext, numThreads);
    defer allocator.free(contexts);

    var threads = try allocator.alloc(std.Thread, numThreads);
    defer allocator.free(threads);
    
    const baseSeed: u64 = 0x67B199ED;
    const gridCells = puzzle.rows * puzzle.cols;
    const scaledPop: usize = if (gridCells > 5000) 30
                             else if (gridCells > 2000) 50
                             else if (gridCells > 500) 100
                             else 200;
                             
    const popSizes = [_]usize{
        scaledPop, scaledPop, scaledPop, scaledPop,
        scaledPop, scaledPop, scaledPop, scaledPop,
        @max(10, scaledPop / 2), @max(10, scaledPop / 2),
        @max(10, scaledPop / 2), @max(10, scaledPop / 2),
        @max(10, scaledPop / 4), @max(10, scaledPop / 4),
        @max(10, scaledPop / 4), @max(10, scaledPop / 4),
    };
    
    for (0..numThreads) |i| {
        const threadSeed: ?[]const bool = if (i < 2) seedWalls else null;
        contexts[i] = .{
            .puzzle = &puzzle,
            .candidates = candidates,
            .seed = baseSeed +% (i *% @as(usize, 0x9E3779B97F4A7C15)),
            .popSize = popSizes[i % popSizes.len],
            .seedWalls = threadSeed,
            .gridToCand = gridToCand,
            .result = null,
            .allocator = allocator,
            .migration = &migrationPool,
            .islandIdx = i,
        };
    }

    for (0..numThreads) |i| {
        threads[i] = try std.Thread.spawn(.{}, ThreadContext.run, .{&contexts[i]});
    }

    for (0..numThreads) |i| {
        threads[i].join();
    }

    // Pick the best result across all threads
    var bestScore: i32 = std.math.minInt(i32);
    var bestIdx: ?usize = null;
    var anyValid = false;

    for (contexts, 0..) |ctx, i|
    {
        if (ctx.result) |res|
        {
            const dominated = (anyValid and !res.valid);
            const dominated2 = (anyValid == res.valid and res.score <= bestScore);
            
            if (!dominated and !dominated2) {
                if (bestIdx) |prev|
                {
                    if (contexts[prev].result) |prevRes|
                    {
                        allocator.free(prevRes.walls);
                    }
                }
                bestScore = res.score;
                bestIdx = i;
                anyValid = anyValid or res.valid;
            } else {
                allocator.free(res.walls);
            }
        }
    }

    if (bestIdx == null) {
        return error.NoResult;
    }

    const best = contexts[bestIdx.?].result.?;
    defer allocator.free(best.walls);
    
    // Apply walls to flat grid
    for (candidates, 0..) |pos, i|
    {
        if (best.walls[i]) {
            puzzle.grid[pos.row * puzzle.cols + pos.col] = .{ .type = .wall };
        }
    }

    const verifyResult = bfs(&puzzle, null, &scratch, false);
    const isValid = !verifyResult.reachesBoundary;

    // Validation 
    {
        var wallsPlaced: u32 = 0;
        for (0..puzzle.rows) |row| {
            for (0..puzzle.cols) |col|
            {
                if (puzzle.grid[row * puzzle.cols + col].type == .wall) {
                    wallsPlaced += 1;
                }
            }
        }
        if (wallsPlaced > puzzle.budget) {
            std.debug.print("VALIDATION FAILED: placed {d} walls but budget is {d}\n", .{ wallsPlaced, puzzle.budget });
            return error.BudgetExceeded;
        }

        if (!isValid) {
            std.debug.print("VALIDATION FAILED: horse can reach the boundary (invalid enclosure)\n", .{});
            return error.InvalidEnclosure;
        }

        const vStamp = scratch.currentStamp;
        var recomputedScore: i32 = 0;
        var recomputedCount: usize = 0;
        for (0..puzzle.rows) |row| {
            for (0..puzzle.cols) |col|
            {
                if (scratch.visited[row * puzzle.cols + col] == vStamp) {
                    recomputedScore += puzzle.scoreMap[row * puzzle.cols + col];
                    recomputedCount += 1;
                }
            }
        }
        if (recomputedScore != verifyResult.score) {
            std.debug.print("VALIDATION FAILED: BFS score {d} != recomputed score {d}\n", .{ verifyResult.score, recomputedScore });
            return error.ScoreMismatch;
        }

        std.debug.print("Validation OK: {d} walls (budget {d}), score {d}, {d} reachable tiles\n", .{ wallsPlaced, puzzle.budget, verifyResult.score, recomputedCount });
    }

    var outBuf = std.ArrayList(u8){};
    defer outBuf.deinit(allocator);
    try outBuf.ensureTotalCapacity(allocator, puzzle.rows * (puzzle.cols + 1) + 16);
    const w = outBuf.writer(allocator);
    try w.print("{}\n", .{verifyResult.score});
    
    for (0..puzzle.rows) |row| {
        for (0..puzzle.cols) |col|
        {
            const ch: u8 = switch (puzzle.grid[row * puzzle.cols + col].type) {
                .water  => '#',
                .grass  => '.',
                .wall   => 'W',
                .horse  => 'H',
                .apple  => 'a',
                .bee    => 'b',
                .cherry => 'c',
                .portal => 'p',
            };
            try outBuf.append(allocator, ch);
        }
        try outBuf.append(allocator, '\n');
    }
    try std.fs.File.stdout().writeAll(outBuf.items);
    
    std.debug.print("Score: {}\n", .{verifyResult.score});
    std.debug.print("Valid: {}\n", .{isValid});
}

fn acceptCandidate(
    old_score: i32,
    new_score: i32,
    temperature: f64,
    random: std.Random,
) bool {
    if (new_score > old_score) return true;
    const delta = @as(f64, @floatFromInt(new_score - old_score));
    const prob = std.math.exp(delta / temperature);

    return random.float(f64) < prob;
}
