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
};

/// Pre-allocated scratch buffers for BFS to avoid per-call allocation.
const BFSScratch = struct {
    queue: []Pos,
    /// Stamp-based visited array: cell is "visited" iff visited[i] == currentStamp.
    /// Incrementing currentStamp resets all visited state in O(1) — no memset needed.
    visited: []u32,
    currentStamp: u32,
    /// Reused buffer for findBoundaryWalls results (indices into candidates).
    boundaryBuf: []usize,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, maxCells: usize) !BFSScratch {
        const visited = try allocator.alloc(u32, maxCells);
        @memset(visited, 0);
        return .{
            .queue = try allocator.alloc(Pos, maxCells),
            .visited = visited,
            .currentStamp = 1,
            .boundaryBuf = try allocator.alloc(usize, maxCells),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *BFSScratch) void {
        self.allocator.free(self.queue);
        self.allocator.free(self.visited);
        self.allocator.free(self.boundaryBuf);
    }

    /// Begin a new BFS — O(1) reset via stamp increment.
    pub inline fn nextStamp(self: *BFSScratch) u32 {
        self.currentStamp +%= 1;
        if (self.currentStamp == 0) self.currentStamp = 1; // skip sentinel 0
        return self.currentStamp;
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
    /// Optional pre-placed wall seed (candidates-indexed). When non-null, the first
    /// individual(s) in this thread's population are initialized from it rather than
    /// randomly, giving the thread a guaranteed valid head-start.
    seedWalls: ?[]const bool,
    result: ?SolveResult,
    allocator: std.mem.Allocator,

    pub fn run(self: *ThreadContext) void {
        self.result = self.doSolve() catch null;
    }

    fn doSolve(self: *ThreadContext) !SolveResult {
        var prng = std.Random.DefaultPrng.init(self.seed);
        const random = prng.random();
        return solve(self.puzzle, self.candidates, random, self.popSize, self.seedWalls, self.allocator);
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
const gaGenerations: usize = 200_000;
const validEliteCount: usize = 5;
const invalidEliteCount: usize = 5;
const eliteCount: usize = validEliteCount + invalidEliteCount;
const mutationRate: u32 = 30;
const stagnationThreshold: usize = 25_000;
const maxRestarts: usize = 75;

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
    for (portals) |*pp| {
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
    for (candidates, 0..) |pos, i| {
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

// =============================================================================
// Grid Helpers
// =============================================================================

fn removePrePlacedWalls(puzzle: *Puzzle) void {
    for (0..puzzle.rows) |row| {
        for (0..puzzle.cols) |col| {
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
        for (0..puzzle.cols) |col| {
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
    scratch.visited[startIdx] = stamp;
    scratch.queue[tail] = .{ .row = puzzle.horseRow, .col = puzzle.horseCol };
    tail += 1;

    var reachable: usize = 0;
    var reachesBoundary = false;
    var totalScore: i32 = 0;

    const rows = puzzle.rows;
    const cols = puzzle.cols;

    while (head < tail) {
        const current = scratch.queue[head];
        head += 1;
        reachable += 1;

        const ci = current.row * cols + current.col;
        totalScore += puzzle.scoreMap[ci];

        if (current.row == 0 or current.row == rows - 1 or
            current.col == 0 or current.col == cols - 1)
        {
            reachesBoundary = true;
            if (earlyExit) break;
        }

        // Unrolled cardinal neighbor expansion
        // Up
        if (current.row > 0) {
            const ni = ci - cols;
            if (scratch.visited[ni] != stamp) {
                const ct = puzzle.grid[ni].type;
                if (ct != .water and ct != .wall and (isWallMap == null or !isWallMap.?[ni])) {
                    scratch.visited[ni] = stamp;
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
                    scratch.visited[ni] = stamp;
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
                    scratch.visited[ni] = stamp;
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
                    scratch.visited[ni] = stamp;
                    scratch.queue[tail] = .{ .row = current.row, .col = current.col + 1 };
                    tail += 1;
                }
            }
        }

        // Traverse portals
        if (puzzle.grid[ci].type == .portal) {
            for (puzzle.portals) |pp| {
                const partner = portalPartner(pp, current.row, current.col) orelse continue;
                const pi = partner.row * cols + partner.col;
                if (scratch.visited[pi] != stamp and (isWallMap == null or !isWallMap.?[pi])) {
                    scratch.visited[pi] = stamp;
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
/// their placed walls are to existing barriers. Encourages the GA to form
/// contiguous barriers even before finding valid enclosures.
fn computeAdjacencyBonus(candidates: []const Pos, walls: []const bool, puzzle: *const Puzzle, isWallMap: []const bool) i32 {
    var bonus: i32 = 0;
    const rows = puzzle.rows;
    const cols = puzzle.cols;

    for (candidates, 0..) |pos, i| {
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
/// Invalid enclosures get a negative penalty proportional to reachable cells,
/// offset by the adjacency bonus heuristic.
fn evaluateFitness(individual: *Individual, candidates: []const Pos, puzzle: *const Puzzle, scratch: *BFSScratch) void {
    const result = bfs(puzzle, individual.isWallMap, scratch, true);

    if (result.reachesBoundary) {
        const reachable: i32 = @intCast(result.count);
        // isWallMap is already up-to-date on individual — pass directly, no rebuild
        const adjBonus = computeAdjacencyBonus(candidates, individual.walls, puzzle, individual.isWallMap);
        individual.score = -reachable * 4 + adjBonus;
        individual.valid = false;
    } else {
        individual.score = result.score;
        individual.valid = true;
    }
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
    for (child.walls, 0..) |w, j| {
        if (w) child.isWallMap[candidates[j].row * cols + candidates[j].col] = false;
    }
    @memset(child.walls, false);
    child.wallCount = 0;

    // Keep walls shared by both parents
    for (candidates, 0..) |pos, j| {
        if (child.wallCount >= budget) break;
        if (parent1.walls[j] and parent2.walls[j]) {
            child.walls[j] = true;
            child.isWallMap[pos.row * cols + pos.col] = true;
            child.wallCount += 1;
        }
    }

    // Fill remaining from walls only one parent has
    for (candidates, 0..) |pos, j| {
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

fn mutate(individual: *Individual, candidates: []const Pos, cols: usize, random: std.Random) void {
    if (individual.wallCount == 0) return;

    const roll = random.intRangeLessThan(u32, 0, 100);
    const swaps: usize = if (roll < 65) 1 else if (roll < 85) 2 else 3;

    for (0..swaps) |_| {
        // Remove the k-th placed wall using cached wallCount (no scan needed for count)
        var target = random.intRangeLessThan(usize, 0, individual.wallCount);
        for (individual.walls, 0..) |w, i| {
            if (w) {
                if (target == 0) {
                    individual.removeWall(i, candidates[i], cols);
                    break;
                }
                target -= 1;
            }
        }

        // Add a wall at a random empty slot — emptyCount = candidates.len - wallCount
        const emptyCount = individual.walls.len - @as(usize, individual.wallCount);
        if (emptyCount == 0) return;
        target = random.intRangeLessThan(usize, 0, emptyCount);
        for (individual.walls, 0..) |w, i| {
            if (!w) {
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
/// (adjacent to both reachable and unreachable cells). These are candidates
/// for removal during expand mutation.
fn findBoundaryWalls(individual: *const Individual, candidates: []const Pos, puzzle: *const Puzzle, scratch: *BFSScratch) []usize {
    const result = bfs(puzzle, individual.isWallMap, scratch, false);
    if (result.reachesBoundary) return scratch.boundaryBuf[0..0];

    // The stamp from the bfs call above is still current — use it for visited checks
    const stamp = scratch.currentStamp;
    const cols = puzzle.cols;
    var count: usize = 0;

    for (candidates, 0..) |pos, i| {
        if (!individual.walls[i]) continue;

        const ci = pos.row * cols + pos.col;
        var hasReachableNeighbor = false;
        var hasBlockedNeighbor = false;

        // Up
        if (pos.row == 0) {
            hasBlockedNeighbor = true;
        } else if (scratch.visited[ci - cols] == stamp) {
            hasReachableNeighbor = true;
        } else {
            hasBlockedNeighbor = true;
        }
        // Down
        if (pos.row + 1 >= puzzle.rows) {
            hasBlockedNeighbor = true;
        } else if (scratch.visited[ci + cols] == stamp) {
            hasReachableNeighbor = true;
        } else {
            hasBlockedNeighbor = true;
        }
        // Left
        if (pos.col == 0) {
            hasBlockedNeighbor = true;
        } else if (scratch.visited[ci - 1] == stamp) {
            hasReachableNeighbor = true;
        } else {
            hasBlockedNeighbor = true;
        }
        // Right
        if (pos.col + 1 >= puzzle.cols) {
            hasBlockedNeighbor = true;
        } else if (scratch.visited[ci + 1] == stamp) {
            hasReachableNeighbor = true;
        } else {
            hasBlockedNeighbor = true;
        }

        if (hasReachableNeighbor and hasBlockedNeighbor) {
            scratch.boundaryBuf[count] = i;
            count += 1;
        }
    }

    return scratch.boundaryBuf[0..count];
}

/// Attempt to expand a valid enclosure by removing a boundary wall and
/// re-sealing the leak with walls placed on edge cells. Returns true if
/// the expansion succeeded and the individual was improved.
fn expandMutation(individual: *Individual, candidates: []const Pos, puzzle: *const Puzzle, scratch: *BFSScratch, random: std.Random) bool {
    if (!individual.valid) return false;

    const boundaryWalls = findBoundaryWalls(individual, candidates, puzzle, scratch);
    if (boundaryWalls.len == 0) return false;

    const cols = puzzle.cols;

    // Remove a random boundary wall
    const pickIdx = random.intRangeLessThan(usize, 0, boundaryWalls.len);
    const wallToRemove = boundaryWalls[pickIdx];
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
    var sealCandidates: [256]usize = undefined;
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
            if (ct_u == .water or ct_u == .wall or scratch.visited[cellIdx - cols] != leakStamp) {
                onEdge = true;
            }
            // Down
            if (!onEdge) {
                const ct_d = puzzle.grid[cellIdx + cols].type;
                if (ct_d == .water or ct_d == .wall or scratch.visited[cellIdx + cols] != leakStamp) {
                    onEdge = true;
                }
            }
            // Left
            if (!onEdge) {
                const ct_l = puzzle.grid[cellIdx - 1].type;
                if (ct_l == .water or ct_l == .wall or scratch.visited[cellIdx - 1] != leakStamp) {
                    onEdge = true;
                }
            }
            // Right
            if (!onEdge) {
                const ct_r = puzzle.grid[cellIdx + 1].type;
                if (ct_r == .water or ct_r == .wall or scratch.visited[cellIdx + 1] != leakStamp) {
                    onEdge = true;
                }
            }
        }

        if (onEdge and sealCount < 256) {
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
    for (0..placed) |si| {
        individual.removeWall(sealCandidates[si], candidates[sealCandidates[si]], cols);
    }

    const revertResult = bfs(puzzle, individual.isWallMap, scratch, true);
    individual.score = revertResult.score;
    individual.valid = !revertResult.reachesBoundary;

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
    for (pop) |*ind| {
        allocator.free(ind.walls);
        allocator.free(ind.isWallMap);
    }
    allocator.free(pop);
}

/// Randomly initialize an individual's wall placement.
/// Clears only previously-set cells in O(wallCount), not O(gridSize).
fn randomizeWalls(individual: *Individual, candidates: []const Pos, cols: usize, budget: u32, random: std.Random) void {
    // Clear only walls that are currently set — O(budget) not O(gridSize)
    for (individual.walls, 0..) |w, i| {
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
/// Maintains two small insertion-sorted arrays (size ≤ 5 each), so this is
/// effectively O(n) with a small constant factor.
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

fn acceptWithAnnealing(
    oldScore: i32,
    newScore: i32,
    temperature: f64,
    random: std.Random,
) bool {
    if (newScore >= oldScore) return true;

    const delta = @as(f64, @floatFromInt(newScore - oldScore));
    const prob = std.math.exp(delta / temperature);

    return random.float(f64) < prob;
}

// =============================================================================
// Genetic Algorithm - Main Loop
// =============================================================================

/// Run the genetic algorithm to find the best wall placement.
/// If `seedWalls` is non-null, the first individual is initialized from it
/// (a known-valid enclosure) and a lightly mutated copy seeds the second,
/// giving those slots a head-start over random initialization.
fn solve(puzzle: *const Puzzle, candidates: []const Pos, random: std.Random, popSize: usize, seedWalls: ?[]const bool, allocator: std.mem.Allocator) !SolveResult {
    var scratch = try BFSScratch.init(allocator, puzzle.rows * puzzle.cols);
    defer scratch.deinit();

    var temperature: f64 = 5.0; // starting temp (tune)
    const coolingRate: f64 = 0.9995;
    const gridSize = puzzle.rows * puzzle.cols;
    const popA = try allocPopulation(allocator, popSize, candidates.len, gridSize);
    defer freePopulation(allocator, popA);
    const popB = try allocPopulation(allocator, popSize, candidates.len, gridSize);
    defer freePopulation(allocator, popB);

    var population = popA;
    var next = popB;

    // Initialize population: seed first slot(s) from pre-placed walls if provided,
    // fill the rest randomly.
    var startIdx: usize = 0;
    if (seedWalls) |sw| {
        // Slot 0: exact pre-placed solution, then fill any remaining budget randomly
        @memcpy(population[0].walls, sw);
        population[0].wallCount = 0;
        for (sw) |w| {
            if (w) population[0].wallCount += 1;
        }
        population[0].rebuildIsWallMap(candidates, puzzle.cols);
        // Pre-placed walls may use fewer than the full budget — fill the rest randomly
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
            for (0..3) |_| mutate(&population[1], candidates, puzzle.cols, random);
            evaluateFitness(&population[1], candidates, puzzle, &scratch);
        }

        startIdx = @min(2, popSize);
    }

    for (population[startIdx..]) |*individual| {
        randomizeWalls(individual, candidates, puzzle.cols, puzzle.budget, random);
        evaluateFitness(individual, candidates, puzzle, &scratch);
    }

    std.mem.sort(Individual, population, {}, Individual.compareDescending);

    var bestSoFar: i32 = population[0].score;
    var gensSinceImprovement: usize = 0;
    var restartCount: usize = 0;

    for (1..gaGenerations + 1) |generation| {
        //copy top-k valid and top-k invalid via O(n) scan from previous gen
        const prevTopK = findTopK(population);
        var eliteIdx: usize = 0;
        temperature *= coolingRate;
        if (temperature < 0.01) temperature = 0.01;

        // Copy top valid elites — walls[] then rebuild isWallMap in O(budget) not O(gridSize)
        for (0..prevTopK.validCount) |vi| {
            const si = prevTopK.validIndices[vi];
            @memcpy(next[eliteIdx].walls, population[si].walls);
            next[eliteIdx].score = population[si].score;
            next[eliteIdx].valid = population[si].valid;
            next[eliteIdx].wallCount = population[si].wallCount;
            next[eliteIdx].rebuildIsWallMap(candidates, puzzle.cols);
            eliteIdx += 1;
        }

        // Copy top invalid elites
        for (0..prevTopK.invalidCount) |ii| {
            const si = prevTopK.invalidIndices[ii];
            @memcpy(next[eliteIdx].walls, population[si].walls);
            next[eliteIdx].score = population[si].score;
            next[eliteIdx].valid = population[si].valid;
            next[eliteIdx].wallCount = population[si].wallCount;
            next[eliteIdx].rebuildIsWallMap(candidates, puzzle.cols);
            eliteIdx += 1;
        }

        // Breed remaining population
        for (eliteCount..popSize) |i| {
            const parent1 = tournamentSelect(population, random);
            const parent2 = tournamentSelect(population, random);

            crossoverInto(&next[i], parent1, parent2, candidates, puzzle.cols, puzzle.budget);

            const roll = random.intRangeLessThan(u32, 0, 100);

            if (roll < 10) {
                // 10%: BIG jump
                destructiveMutation(&next[i], candidates, puzzle, &scratch, random);
            } else if (roll < mutationRate) {
                // normal mutation
                mutate(&next[i], candidates, puzzle.cols, random);
            }

            evaluateFitness(&next[i], candidates, puzzle, &scratch);

            // Compare against parent1 — reject via simulated annealing
            if (!acceptWithAnnealing(parent1.score, next[i].score, temperature, random)) {
                // Reject → copy parent in O(candidates) + O(budget) instead of O(gridSize)
                @memcpy(next[i].walls, parent1.walls);
                next[i].score = parent1.score;
                next[i].valid = parent1.valid;
                next[i].wallCount = parent1.wallCount;
                next[i].rebuildIsWallMap(candidates, puzzle.cols);
            }
        }

        // Swap population buffers
        const tmp = population;
        population = next;
        next = tmp;

        const topK = findTopK(population);

        // Prune+expand: pruneWalls frees budget so expandMutation can seal leaks.
        // Frequency scales with grid size — large grids can't afford it every 100 gens
        // but need it periodically or expandMutation has no budget to work with.
        const pruneFreq: usize = if (gridSize > 5000) 2000 else if (gridSize > 2000) 500 else 100;
        const doPruneExpand = (population[topK.bestIdx].score > bestSoFar) or (generation % pruneFreq == 0);
        if (doPruneExpand) {
            for (0..topK.validCount) |vi| {
                const ei = topK.validIndices[vi];
                pruneWalls(&population[ei], candidates, puzzle, &scratch);
                _ = expandMutation(&population[ei], candidates, puzzle, &scratch, random);
            }
        }

        if (population[topK.bestIdx].score > bestSoFar) {
            bestSoFar = population[topK.bestIdx].score;
            gensSinceImprovement = 0;
        } else {
            gensSinceImprovement += 1;
        }

        const restartCutoff: usize = gaGenerations * 3 / 4;
        // Diversity injection on stagnation
        if (gensSinceImprovement >= stagnationThreshold and restartCount < maxRestarts and generation < restartCutoff) {
            temperature = 5.0;
            restartCount += 1;

            // Reinitialize everyone except elites
            for (eliteCount..popSize) |i| {
                randomizeWalls(&population[i], candidates, puzzle.cols, puzzle.budget, random);
                evaluateFitness(&population[i], candidates, puzzle, &scratch);
            }

            gensSinceImprovement = 0;
        }
    }

    const finalTopK = findTopK(population);
    const finalBest = finalTopK.bestIdx;

    // One final prune pass on the best valid solution to remove redundant walls
    if (population[finalBest].valid) {
        pruneWalls(&population[finalBest], candidates, puzzle, &scratch);
    }

    // Return a copy of the best walls (caller owns the slice).
    const bestWalls = try allocator.alloc(bool, candidates.len);
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
    for (0..puzzle.rows) |row| {
        for (0..puzzle.cols) |col| {
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

    // Build candidates-indexed seedWalls from the pre-captured positions.
    const seedWalls = try allocator.alloc(bool, candidates.len);
    defer allocator.free(seedWalls);
    @memset(seedWalls, false);
    {
        const gridToCand = try allocator.alloc(usize, puzzle.rows * puzzle.cols);
        defer allocator.free(gridToCand);
        @memset(gridToCand, std.math.maxInt(usize));
        for (candidates, 0..) |pos, ci| {
            gridToCand[pos.row * puzzle.cols + pos.col] = ci;
        }
        for (prePlacedWallPositions.items) |pos| {
            const ci = gridToCand[pos.row * puzzle.cols + pos.col];
            if (ci != std.math.maxInt(usize)) {
                seedWalls[ci] = true;
            }
        }
    }

    // Spawn parallel solver threads
    const numThreads: usize = @max(1, std.Thread.getCpuCount() catch 4);

    var contexts = try allocator.alloc(ThreadContext, numThreads);
    defer allocator.free(contexts);

    var threads = try allocator.alloc(std.Thread, numThreads);
    defer allocator.free(threads);

    const baseSeed: u64 = 0xFACADE;
    // Scale population down for large grids: each BFS is O(gridSize) so fewer, faster individuals
    // beats more, slower ones. Target ~50 individuals for 100x100, up to 200 for small grids.
    const gridCells = puzzle.rows * puzzle.cols;
    const scaledPop: usize = if (gridCells > 5000) 30 else if (gridCells > 2000) 50 else if (gridCells > 500) 100 else 200;
    const popSizes = [_]usize{
        scaledPop,               scaledPop,               scaledPop,               scaledPop,
        scaledPop,               scaledPop,               scaledPop,               scaledPop,
        @max(10, scaledPop / 2), @max(10, scaledPop / 2), @max(10, scaledPop / 2), @max(10, scaledPop / 2),
        @max(10, scaledPop / 4), @max(10, scaledPop / 4), @max(10, scaledPop / 4), @max(10, scaledPop / 4),
    };

    for (0..numThreads) |i| {
        // Threads 0 and 1 get the pre-placed wall seed for exploitation.
        // Remaining threads get null for pure exploration from random init.
        const threadSeed: ?[]const bool = if (i < 2) seedWalls else null;
        contexts[i] = .{
            .puzzle = &puzzle,
            .candidates = candidates,
            .seed = baseSeed +% (i *% @as(usize, 0x9E3779B97F4A7C15)),
            .popSize = popSizes[i % popSizes.len],
            .seedWalls = threadSeed,
            .result = null,
            .allocator = allocator,
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

    for (contexts, 0..) |ctx, i| {
        if (ctx.result) |res| {
            const dominated = (anyValid and !res.valid);
            const dominated2 = (anyValid == res.valid and res.score <= bestScore);
            if (!dominated and !dominated2) {
                if (bestIdx) |prev| {
                    if (contexts[prev].result) |prevRes| {
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
    for (candidates, 0..) |pos, i| {
        if (best.walls[i]) {
            puzzle.grid[pos.row * puzzle.cols + pos.col] = .{ .type = .wall };
        }
    }

    // Write the required output format to stdout:
    //   Line 1: score
    //   Next R lines: the grid
    var outBuf = std.ArrayList(u8){};
    defer outBuf.deinit(allocator);
    try outBuf.ensureTotalCapacity(allocator, puzzle.rows * (puzzle.cols + 1) + 16);
    const w = outBuf.writer(allocator);
    try w.print("{}\n", .{best.score});
    for (0..puzzle.rows) |row| {
        for (0..puzzle.cols) |col| {
            const ch: u8 = switch (puzzle.grid[row * puzzle.cols + col].type) {
                .water => '#',
                .grass => '.',
                .wall => 'W',
                .horse => 'H',
                .apple => 'a',
                .bee => 'b',
                .cherry => 'c',
                .portal => 'p',
            };
            try outBuf.append(allocator, ch);
        }
        try outBuf.append(allocator, '\n');
    }
    try std.fs.File.stdout().writeAll(outBuf.items);
}
