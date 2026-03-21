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
    visited: []bool,
    isWall: []bool,
    boundaryBuf: []usize,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, maxCells: usize) !BFSScratch {
        return .{
            .queue = try allocator.alloc(Pos, maxCells),
            .visited = try allocator.alloc(bool, maxCells),
            .isWall = try allocator.alloc(bool, maxCells),
            .boundaryBuf = try allocator.alloc(usize, maxCells),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *BFSScratch) void {
        self.allocator.free(self.queue);
        self.allocator.free(self.visited);
        self.allocator.free(self.isWall);
        self.allocator.free(self.boundaryBuf);
    }
};

const Individual = struct {
    walls: []bool,
    score: i32,
    valid: bool,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Individual) void {
        self.allocator.free(self.walls);
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
    grid: [][]Cell,
    rows: usize,
    cols: usize,
    budget: u32,
    horseRow: usize,
    horseCol: usize,
    portals: []PortalPair,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Puzzle) void {
        for (self.grid) |row| {
            self.allocator.free(row);
        }
        self.allocator.free(self.grid);
        self.allocator.free(self.portals);
    }

    /// Pretty-print the grid to stderr for debugging.
    pub fn display(self: *const Puzzle) void {
        std.debug.print("Grid: {} rows x {} cols\n", .{ self.rows, self.cols });
        std.debug.print("Horse at: ({}, {})\n", .{ self.horseRow, self.horseCol });
        std.debug.print("Budget: {}\n\n", .{self.budget});

        for (self.grid, 0..) |row, rowIndex| {
            std.debug.print("{d:2} | ", .{rowIndex});
            for (row, 0..) |cell, colIndex| {
                switch (cell.type) {
                    .horse => std.debug.print(" H ", .{}),
                    .water => std.debug.print(" ~ ", .{}),
                    .grass => std.debug.print(" . ", .{}),
                    .cherry => std.debug.print(" * ", .{}),
                    .bee => std.debug.print(" ! ", .{}),
                    .apple => std.debug.print(" a ", .{}),
                    .wall => std.debug.print(" W ", .{}),
                    .portal => {
                        var label: ?usize = null;
                        for (self.portals, 0..) |pp, index| {
                            if ((rowIndex == pp.r1 and colIndex == pp.c1) or
                                (rowIndex == pp.r2 and colIndex == pp.c2))
                            {
                                label = index + 1;
                                break;
                            }
                        }
                        if (label) |l| {
                            std.debug.print("P{d} ", .{l});
                        } else {
                            std.debug.print(" p ", .{});
                        }
                    },
                }
            }
            std.debug.print("\n", .{});
        }
        std.debug.print("\n", .{});
    }
};

/// Per-thread context for parallel GA solving.
const ThreadContext = struct {
    puzzle: *const Puzzle,
    candidates: []const Pos,
    seed: u64,
    popSize: usize,
    result: ?SolveResult,
    allocator: std.mem.Allocator,

    pub fn run(self: *ThreadContext) void {
        self.result = self.doSolve() catch null;
    }

    fn doSolve(self: *ThreadContext) !SolveResult {
        var prng = std.Random.DefaultPrng.init(self.seed);
        const random = prng.random();
        const best = try solve(self.puzzle, self.candidates, random, self.popSize, self.allocator);

        return .{
            .walls = best.walls,
            .score = best.score,
            .valid = best.valid,
        };
    }
};

// =============================================================================
// Constants
// =============================================================================

const directions = [_][2]i8{ .{ -1, 0 }, .{ 1, 0 }, .{ 0, -1 }, .{ 0, 1 } };

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

    const grid = try allocator.alloc([]Cell, rows);

    var horseRow: usize = 0;
    var horseCol: usize = 0;

    for (grid, 0..) |*row, rowIndex| {
        const line = std.mem.trim(u8, lines.next() orelse return error.InvalidInput, " \r");
        row.* = try allocator.alloc(Cell, cols);
        for (line, 0..) |ch, colIndex| {
            row.*[colIndex] = try parseCell(ch);
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
        .rows = rows,
        .cols = cols,
        .budget = budget,
        .horseRow = horseRow,
        .horseCol = horseCol,
        .portals = portals,
        .allocator = allocator,
    };
}

/// Try to read the optimal score from a companion .json file alongside the input.
fn readOptimalScore(allocator: std.mem.Allocator, inputPath: []const u8) ?i32 {
    if (!std.mem.endsWith(u8, inputPath, ".txt")) return null;

    const basePath = inputPath[0 .. inputPath.len - 4];
    const jsonPath = std.fmt.allocPrint(allocator, "{s}.json", .{basePath}) catch return null;
    defer allocator.free(jsonPath);

    const content = std.fs.cwd().readFileAlloc(allocator, jsonPath, 1024 * 1024) catch return null;
    defer allocator.free(content);

    const key = "\"optimal_score\":";
    const keyPos = std.mem.indexOf(u8, content, key) orelse return null;
    const afterKey = content[keyPos + key.len ..];

    var i: usize = 0;
    while (i < afterKey.len and (afterKey[i] == ' ' or afterKey[i] == '"')) : (i += 1) {}

    var end: usize = i;
    while (end < afterKey.len and (afterKey[end] >= '0' and afterKey[end] <= '9')) : (end += 1) {}

    if (end == i) return null;
    return std.fmt.parseInt(i32, afterKey[i..end], 10) catch null;
}

// =============================================================================
// Grid Helpers
// =============================================================================

/// Flatten 2D (row, col) into a 1D index.
fn idx(cols: usize, row: usize, col: usize) usize {
    return row * cols + col;
}

fn removePrePlacedWalls(puzzle: *Puzzle) void {
    for (0..puzzle.rows) |row| {
        for (0..puzzle.cols) |col| {
            if (puzzle.grid[row][col].type == .wall) {
                puzzle.grid[row][col] = .{ .type = .grass };
            }
        }
    }
}

/// Returns positions where walls may be placed: reachable grass tiles excluding the horse.
fn getCandidateWalls(puzzle: *const Puzzle, visited: []bool, allocator: std.mem.Allocator) ![]Pos {
    var candidates: std.ArrayList(Pos) = .{};
    defer candidates.deinit(allocator);

    for (0..puzzle.rows) |row| {
        for (0..puzzle.cols) |col| {
            if (!visited[idx(puzzle.cols, row, col)]) continue;
            if (row == puzzle.horseRow and col == puzzle.horseCol) continue;
            if (puzzle.grid[row][col].type != .grass) continue;

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
fn bfs(puzzle: *const Puzzle, candidates: ?[]const Pos, walls: ?[]const bool, scratch: *BFSScratch, earlyExit: bool) !BFSResult {
    var head: usize = 0;
    var tail: usize = 0;

    @memset(scratch.visited, false);
    @memset(scratch.isWall, false);

    if (candidates) |cands| {
        if (walls) |w| {
            for (cands, 0..) |pos, i| {
                if (w[i]) {
                    scratch.isWall[idx(puzzle.cols, pos.row, pos.col)] = true;
                }
            }
        }
    }

    scratch.visited[idx(puzzle.cols, puzzle.horseRow, puzzle.horseCol)] = true;
    scratch.queue[tail] = .{ .row = puzzle.horseRow, .col = puzzle.horseCol };
    tail += 1;

    var reachable: usize = 0;
    var reachesBoundary = false;
    var totalScore: i32 = 0;

    while (head < tail) {
        const current = scratch.queue[head];
        head += 1;
        reachable += 1;

        totalScore += puzzle.grid[current.row][current.col].type.score();

        if (current.row == 0 or current.row == puzzle.rows - 1 or
            current.col == 0 or current.col == puzzle.cols - 1)
        {
            reachesBoundary = true;
            if (earlyExit) break;
        }

        // Explore cardinal neighbors
        for (directions) |dir| {
            const newRow = @as(i64, @intCast(current.row)) + dir[0];
            const newCol = @as(i64, @intCast(current.col)) + dir[1];

            if (newRow < 0 or newRow >= puzzle.rows or newCol < 0 or newCol >= puzzle.cols) continue;

            const nr: usize = @intCast(newRow);
            const nc: usize = @intCast(newCol);
            const ni = idx(puzzle.cols, nr, nc);

            if (scratch.visited[ni]) continue;

            const cellType = puzzle.grid[nr][nc].type;
            if (cellType == .water or cellType == .wall or scratch.isWall[ni]) continue;

            scratch.visited[ni] = true;
            scratch.queue[tail] = .{ .row = nr, .col = nc };
            tail += 1;
        }

        // Traverse portals
        if (puzzle.grid[current.row][current.col].type == .portal) {
            for (puzzle.portals) |pp| {
                const partner = portalPartner(pp, current.row, current.col) orelse continue;
                const pi = idx(puzzle.cols, partner.row, partner.col);
                if (!scratch.visited[pi] and !scratch.isWall[pi]) {
                    scratch.visited[pi] = true;
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

    for (candidates, 0..) |pos, i| {
        if (!walls[i]) continue;

        var neighborCount: i32 = 0;

        for (directions) |dir| {
            const nr = @as(i64, @intCast(pos.row)) + dir[0];
            const nc = @as(i64, @intCast(pos.col)) + dir[1];

            if (nr < 0 or nr >= puzzle.rows or nc < 0 or nc >= puzzle.cols) {
                neighborCount += 1;
                continue;
            }

            const nrow: usize = @intCast(nr);
            const ncol: usize = @intCast(nc);
            const cellType = puzzle.grid[nrow][ncol].type;

            if (cellType == .water or cellType == .wall) {
                neighborCount += 1;
                continue;
            }

            if (isWallMap[idx(puzzle.cols, nrow, ncol)]) {
                neighborCount += 1;
            }
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
fn pruneWalls(individual: *Individual, candidates: []const Pos, puzzle: *const Puzzle, scratch: *BFSScratch) !void {
    if (!individual.valid) return;

    for (0..candidates.len) |i| {
        if (!individual.walls[i]) continue;

        individual.walls[i] = false;
        const result = try bfs(puzzle, candidates, individual.walls, scratch, true);

        if (!result.reachesBoundary and result.score >= individual.score) {
            individual.score = result.score;
        } else {
            individual.walls[i] = true;
        }
    }
}

/// Evaluate an individual's fitness. Valid enclosures get the BFS score directly.
/// Invalid enclosures get a negative penalty proportional to reachable cells,
/// offset by the adjacency bonus heuristic.
/// For valid individuals, also prunes walls that don't affect validity or score.
fn evaluateFitness(individual: *Individual, candidates: []const Pos, puzzle: *const Puzzle, scratch: *BFSScratch) !void {
    const result = try bfs(puzzle, candidates, individual.walls, scratch, true);

    if (result.reachesBoundary) {
        const reachable: i32 = @intCast(result.count);
        // Build isWall map for O(1) neighbor lookups
        @memset(scratch.isWall, false);
        for (candidates, 0..) |pos, ci| {
            if (individual.walls[ci]) {
                scratch.isWall[idx(puzzle.cols, pos.row, pos.col)] = true;
            }
        }
        const adjBonus = computeAdjacencyBonus(candidates, individual.walls, puzzle, scratch.isWall);
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
fn crossoverInto(child: *Individual, parent1: *const Individual, parent2: *const Individual, budget: u32) void {
    @memset(child.walls, false);
    var count: u32 = 0;

    // Keep walls shared by both parents
    for (0..child.walls.len) |j| {
        if (count >= budget) break;
        if (parent1.walls[j] and parent2.walls[j]) {
            child.walls[j] = true;
            count += 1;
        }
    }

    // Fill remaining from walls only one parent has
    for (0..child.walls.len) |j| {
        if (count >= budget) break;
        if (!child.walls[j] and (parent1.walls[j] or parent2.walls[j])) {
            child.walls[j] = true;
            count += 1;
        }
    }

    child.score = 0;
    child.valid = false;
}

fn mutate(individual: *Individual, random: std.Random) void {
    const roll = random.intRangeLessThan(u32, 0, 100);
    const swaps: usize = if (roll < 65) 1 else if (roll < 85) 2 else 3;

    for (0..swaps) |_| {
        var wallCount: usize = 0;
        for (individual.walls) |w| {
            if (w) wallCount += 1;
        }
        if (wallCount == 0) return;

        // Remove a random placed wall
        var target = random.intRangeLessThan(usize, 0, wallCount);
        for (individual.walls, 0..) |w, i| {
            if (w) {
                if (target == 0) {
                    individual.walls[i] = false;
                    break;
                }
                target -= 1;
            }
        }

        // Add a wall at a random empty slot
        var emptyCount: usize = 0;
        for (individual.walls) |w| {
            if (!w) emptyCount += 1;
        }

        target = random.intRangeLessThan(usize, 0, emptyCount);
        for (individual.walls, 0..) |w, i| {
            if (!w) {
                if (target == 0) {
                    individual.walls[i] = true;
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
fn findBoundaryWalls(candidates: []const Pos, walls: []const bool, puzzle: *const Puzzle, scratch: *BFSScratch) ![]usize {
    const result = try bfs(puzzle, candidates, walls, scratch, false);
    if (result.reachesBoundary) return scratch.boundaryBuf[0..0];

    var count: usize = 0;

    for (candidates, 0..) |pos, i| {
        if (!walls[i]) continue;

        var hasReachableNeighbor = false;
        var hasBlockedNeighbor = false;

        for (directions) |dir| {
            const nr = @as(i64, @intCast(pos.row)) + dir[0];
            const nc = @as(i64, @intCast(pos.col)) + dir[1];

            if (nr < 0 or nr >= puzzle.rows or nc < 0 or nc >= puzzle.cols) {
                hasBlockedNeighbor = true;
                continue;
            }

            const nrow: usize = @intCast(nr);
            const ncol: usize = @intCast(nc);
            const ni = idx(puzzle.cols, nrow, ncol);

            if (scratch.visited[ni]) {
                hasReachableNeighbor = true;
            } else {
                hasBlockedNeighbor = true;
            }
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
fn expandMutation(individual: *Individual, candidates: []const Pos, puzzle: *const Puzzle, scratch: *BFSScratch, random: std.Random) !bool {
    if (!individual.valid) return false;

    const boundaryWalls = try findBoundaryWalls(candidates, individual.walls, puzzle, scratch);
    if (boundaryWalls.len == 0) return false;

    // Remove a random boundary wall
    const pickIdx = random.intRangeLessThan(usize, 0, boundaryWalls.len);
    const wallToRemove = boundaryWalls[pickIdx];
    individual.walls[wallToRemove] = false;

    // Check if still valid after removal (rare but free expansion)
    const leakResult = try bfs(puzzle, candidates, individual.walls, scratch, false);
    if (!leakResult.reachesBoundary) {
        individual.score = leakResult.score;
        return true;
    }

    // Count current walls to determine remaining budget
    var currentWallCount: u32 = 0;
    for (individual.walls) |w| {
        if (w) currentWallCount += 1;
    }
    const remainingBudget = puzzle.budget - currentWallCount;

    // Find candidate seal positions: reachable, unplaced, on the edge of the reachable region
    var sealCandidates: [256]usize = undefined;
    var sealCount: usize = 0;

    for (candidates, 0..) |pos, i| {
        if (individual.walls[i]) continue;
        if (pos.row == puzzle.horseRow and pos.col == puzzle.horseCol) continue;

        const cellIdx = idx(puzzle.cols, pos.row, pos.col);
        if (!scratch.visited[cellIdx]) continue;

        var onEdge = false;
        if (pos.row == 0 or pos.row == puzzle.rows - 1 or pos.col == 0 or pos.col == puzzle.cols - 1) {
            onEdge = true;
        } else {
            for (directions) |dir| {
                const nr = @as(i64, @intCast(pos.row)) + dir[0];
                const nc = @as(i64, @intCast(pos.col)) + dir[1];
                if (nr < 0 or nr >= puzzle.rows or nc < 0 or nc >= puzzle.cols) {
                    onEdge = true;
                    break;
                }
                const nrow: usize = @intCast(nr);
                const ncol: usize = @intCast(nc);
                const cellType = puzzle.grid[nrow][ncol].type;
                if (cellType == .water or cellType == .wall) {
                    onEdge = true;
                    break;
                }
                if (!scratch.visited[idx(puzzle.cols, nrow, ncol)]) {
                    onEdge = true;
                    break;
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
        individual.walls[sealCandidates[si]] = true;
        placed += 1;
    }

    // Check if we sealed the leak
    const sealResult = try bfs(puzzle, candidates, individual.walls, scratch, true);
    if (!sealResult.reachesBoundary) {
        individual.score = sealResult.score;
        individual.valid = true;
        return true;
    }

    // Failed — revert all changes
    individual.walls[wallToRemove] = true;
    for (0..sealCount) |si| {
        if (si >= placed) break;
        individual.walls[sealCandidates[si]] = false;
    }

    const revertResult = try bfs(puzzle, candidates, individual.walls, scratch, true);
    individual.score = revertResult.score;
    individual.valid = !revertResult.reachesBoundary;

    return false;
}

// =============================================================================
// Genetic Algorithm - Population Management
// =============================================================================

/// Allocate a population of individuals with pre-allocated wall buffers.
fn allocPopulation(allocator: std.mem.Allocator, size: usize, numCandidates: usize) ![]Individual {
    const pop = try allocator.alloc(Individual, size);
    for (pop) |*ind| {
        ind.* = .{
            .walls = try allocator.alloc(bool, numCandidates),
            .score = 0,
            .valid = false,
            .allocator = allocator,
        };
    }
    return pop;
}

fn freePopulation(allocator: std.mem.Allocator, pop: []Individual) void {
    for (pop) |*ind| {
        allocator.free(ind.walls);
    }
    allocator.free(pop);
}

/// Randomly initialize an individual's wall placement.
fn randomizeWalls(individual: *Individual, budget: u32, random: std.Random) void {
    @memset(individual.walls, false);
    var placed: u32 = 0;
    while (placed < budget) {
        const i = random.intRangeLessThan(usize, 0, individual.walls.len);
        if (!individual.walls[i]) {
            individual.walls[i] = true;
            placed += 1;
        }
    }
}

// =============================================================================
// Genetic Algorithm - Main Loop
// =============================================================================

/// Run the genetic algorithm to find the best wall placement.
fn solve(puzzle: *const Puzzle, candidates: []const Pos, random: std.Random, popSize: usize, allocator: std.mem.Allocator) !Individual {
    var scratch = try BFSScratch.init(allocator, puzzle.rows * puzzle.cols);
    defer scratch.deinit();

    // Pre-allocate two population buffers and swap between them (no per-generation allocation)
    // more information found @ https://www.youtube.com/watch?v=aJCgtiN5K14
    const popA = try allocPopulation(allocator, popSize, candidates.len);
    defer freePopulation(allocator, popA);
    const popB = try allocPopulation(allocator, popSize, candidates.len);
    defer freePopulation(allocator, popB);

    var population = popA;
    var next = popB;

    // Initialize population with random wall placements
    for (population) |*individual| {
        randomizeWalls(individual, puzzle.budget, random);
        try evaluateFitness(individual, candidates, puzzle, &scratch);
    }

    std.debug.print("Starting GA: {} candidates, budget {}, population {}\n", .{ candidates.len, puzzle.budget, popSize });

    std.mem.sort(Individual, population, {}, Individual.compareDescending);
    std.debug.print("Gen 0: best score = {}\n", .{population[0].score});

    var bestSoFar: i32 = population[0].score;
    var genTimer = try std.time.Timer.start();
    var gensSinceImprovement: usize = 0;
    var restartCount: usize = 0;

    for (1..gaGenerations + 1) |generation| {
        // Elitism: copy top valid and top invalid individuals
        var eliteIdx: usize = 0;
        var validCopied: usize = 0;
        var invalidCopied: usize = 0;

        for (population) |*ind| {
            if (eliteIdx >= eliteCount) break;
            const keep = (ind.valid and validCopied < validEliteCount) or
                (!ind.valid and invalidCopied < invalidEliteCount);
            if (keep) {
                @memcpy(next[eliteIdx].walls, ind.walls);
                next[eliteIdx].score = ind.score;
                next[eliteIdx].valid = ind.valid;
                if (ind.valid) validCopied += 1 else invalidCopied += 1;
                eliteIdx += 1;
            }
        }

        // Fill remaining elite slots from top of sorted population
        var fillFrom: usize = 0;
        while (eliteIdx < eliteCount and fillFrom < popSize) {
            @memcpy(next[eliteIdx].walls, population[fillFrom].walls);
            next[eliteIdx].score = population[fillFrom].score;
            next[eliteIdx].valid = population[fillFrom].valid;
            eliteIdx += 1;
            fillFrom += 1;
        }

        // Breed remaining population
        for (eliteCount..popSize) |i| {
            const parent1 = tournamentSelect(population, random);
            const parent2 = tournamentSelect(population, random);

            crossoverInto(&next[i], parent1, parent2, puzzle.budget);

            if (random.intRangeLessThan(u32, 0, 100) < mutationRate) {
                mutate(&next[i], random);
            }

            try evaluateFitness(&next[i], candidates, puzzle, &scratch);
        }

        // Swap population buffers
        const tmp = population;
        population = next;
        next = tmp;

        std.mem.sort(Individual, population, {}, Individual.compareDescending);


        // Prune then expand the top valid individuals
        for (0..@min(populationSize, 10)) |ei| {
            if (population[ei].valid) {
                try pruneWalls(&population[ei], candidates, puzzle, &scratch);
                _ = try expandMutation(&population[ei], candidates, puzzle, &scratch, random);
            }
        }

        if (population[0].score > bestSoFar) {
            bestSoFar = population[0].score;
            gensSinceImprovement = 0;
            std.debug.print("Gen {}: NEW BEST = {}\n", .{ generation, bestSoFar });
        } else {
            gensSinceImprovement += 1;
        }

        const restartCutoff: usize = gaGenerations * 3/4;
        // Diversity injection on stagnation
        if (gensSinceImprovement >= stagnationThreshold and restartCount < maxRestarts and generation < restartCutoff) {
            restartCount += 1;
            std.debug.print("Gen {}: RESTART #{} (stagnant for {} gens)\n", .{ generation, restartCount, gensSinceImprovement });

            // Reinitialize everyone except elites
            for (eliteCount..popSize) |i| {
                randomizeWalls(&population[i], puzzle.budget, random);
                try evaluateFitness(&population[i], candidates, puzzle, &scratch);
            }

            gensSinceImprovement = 0;
        }

        if (generation % 1000 == 0) {
            const elapsed = genTimer.read();
            const gensPerSec = @as(f64, @floatFromInt(generation)) / (@as(f64, @floatFromInt(elapsed)) / 1_000_000_000.0);
            std.debug.print("Gen {}: best = {} ({d:.0} gens/sec)\n", .{ generation, population[0].score, gensPerSec });
        }
    }

    std.debug.print("\nGA complete. Best score = {}, valid = {}\n", .{ population[0].score, population[0].valid });

    // Return a copy of the best individual (caller owns the walls slice)
    const bestWalls = try allocator.alloc(bool, candidates.len);
    @memcpy(bestWalls, population[0].walls);

    return .{
        .walls = bestWalls,
        .score = population[0].score,
        .valid = population[0].valid,
        .allocator = allocator,
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
        std.debug.print("Usage: algobowl <input_file>\n", .{});
        return;
    }

    const content = try std.fs.cwd().readFileAlloc(allocator, args[1], 1024 * 1024);
    defer allocator.free(content);

    var puzzle = try parseInput(allocator, content);
    defer puzzle.deinit();

    var scratch = try BFSScratch.init(allocator, puzzle.rows * puzzle.cols);
    defer scratch.deinit();

    // Show initial state with pre-placed walls
    const initialReach = try bfs(&puzzle, null, null, &scratch, true);
    std.debug.print("With pre-placed solution walls:\n", .{});
    std.debug.print("  Reachable: {}, Score: {}, Reaches boundary: {}\n\n", .{
        initialReach.count, initialReach.score, initialReach.reachesBoundary,
    });

    puzzle.display();
    removePrePlacedWalls(&puzzle);

    // Compute full reachability with no walls
    const fullReach = try bfs(&puzzle, null, null, &scratch, false);
    const reachableMap = try allocator.alloc(bool, puzzle.rows * puzzle.cols);
    defer allocator.free(reachableMap);
    @memcpy(reachableMap, scratch.visited);

    std.debug.print("With pre-placed walls removed (full budget):\n", .{});
    std.debug.print("  Reachable: {}, Score: {}, Reaches boundary: {}\n\n", .{
        fullReach.count, fullReach.score, fullReach.reachesBoundary,
    });

    const candidates = try getCandidateWalls(&puzzle, reachableMap, allocator);
    defer allocator.free(candidates);

    // Spawn parallel solver threads
    const numThreads: usize = @max(1, std.Thread.getCpuCount() catch 4);
    std.debug.print("Running {} parallel solvers\n", .{numThreads});

    var contexts = try allocator.alloc(ThreadContext, numThreads);
    defer allocator.free(contexts);

    var threads = try allocator.alloc(std.Thread, numThreads);
    defer allocator.free(threads);

    const baseSeed: u64 = 0xFACADE;
    const popSizes = [_]usize{200, 200, 200, 200, 200, 200, 200, 200, 100, 100, 100, 100, 50, 50, 50, 50};

    for (0..numThreads) |i| {
        contexts[i] = .{
            .puzzle = &puzzle,
            .candidates = candidates,
            .seed = baseSeed +% i * 0x9E3779B97F4A7C15,
            .popSize = popSizes[i % popSizes.len],
            .result = null,
            .allocator = allocator,
        };
    }

    var solveTimer = try std.time.Timer.start();

    for (0..numThreads) |i| {
        threads[i] = try std.Thread.spawn(.{}, ThreadContext.run, .{&contexts[i]});
    }

    for (0..numThreads) |i| {
        threads[i].join();
    }

    const solveElapsed = solveTimer.read();
    std.debug.print("\n=== TIMING ===\n", .{});
    std.debug.print("  solve() total: {d:.3}s ({} threads)\n", .{
        @as(f64, @floatFromInt(solveElapsed)) / 1_000_000_000.0, numThreads,
    });

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
        std.debug.print("ERROR: No thread produced a result\n", .{});
        return;
    }

    var best = Individual{
        .walls = contexts[bestIdx.?].result.?.walls,
        .score = contexts[bestIdx.?].result.?.score,
        .valid = contexts[bestIdx.?].result.?.valid,
        .allocator = allocator,
    };
    defer best.deinit();

    std.debug.print("Best result from thread {}\n", .{bestIdx.?});

    std.debug.print("\nBFS Result:\n", .{});
    std.debug.print("  Reachable Cells: {}\n", .{fullReach.count});
    std.debug.print("  Reaches boundary: {}\n\n", .{fullReach.reachesBoundary});
    std.debug.print("  Score from BFS: {}\n\n", .{fullReach.score});
    std.debug.print("  Candidate Wall Positions: {}\n", .{candidates.len});

    // Compare against known optimal if available
    const optimalScore = readOptimalScore(allocator, args[1]);
    if (optimalScore) |optimal| {
        std.debug.print("\nOptimal score: {}\n", .{optimal});
        if (best.valid) {
            const diff = optimal - best.score;
            if (diff == 0) {
                std.debug.print("  OPTIMAL SOLUTION FOUND!\n", .{});
            } else {
                std.debug.print("  Gap from optimal: {} points\n", .{diff});
            }
        } else {
            std.debug.print("  No valid solution found to compare.\n", .{});
        }
    }

    std.debug.print("\nFinal result:\n", .{});
    std.debug.print("  Score: {}\n", .{best.score});
    std.debug.print("  Valid: {}\n", .{best.valid});

    // Apply walls to grid and display
    std.debug.print("  Walls placed at:\n", .{});
    for (candidates, 0..) |pos, i| {
        if (best.walls[i]) {
            puzzle.grid[pos.row][pos.col] = .{ .type = .wall };
            std.debug.print("    ({}, {})\n", .{ pos.row, pos.col });
        }
    }

    puzzle.display();
}
