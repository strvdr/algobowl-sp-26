// Author: Strydr Silverberg
//
// Problem Statement: Implement a solver for Enclose Horse. You are to be given inputs and are to create the best solution
// you can while maximizing your score.
//
// Scoring
// The score of a given horse enclosure is computed as the total score of all tiles the horse can reach.
// 1. Empty grass tiles, the grass tile with the horse, and grass tiles with portals all score +1 point
// 2. A grass tile with an apple scores +11 points (+1 for the grass tile, and +10 for the apple)
// 3. A grass tile with bees scores −4 points (+1 for the grass tile, and −5 for the bees)
// 4. A grass tile with cherries scores +4 points (+1 for the grass tile, and +3 for the cherries)
//
// Valid Enclosure
// A valid enclosure must satisfy the following conditions:
// 1. There is no path the horse can take from it’s present location to the perimeter using grass
// tiles and portals.
// 2. No wall has been placed on a tile containing water, an apple, bees, cherries, or a portal.
//
// Input Format
// The first line of the input contains a single positive integer 𝑊 the wall budget.
// The second line of the input file contains two space-separated, positive integers, 𝑅 and 𝐶, indicating
// the number of rows and columns in the grid respectively.
// The next 𝑅 lines each contain exactly 𝐶 characters. Each character must be one of the following
// symbols:
// • # — Water tile
// • . — Empty grass tile
// • H — Grass tile containing the horse
// • W — Grass tile containing a pre placed wall1
// • a — Grass tile with an apple
// • b — Grass tile with bees
// • c — Grass tile with cherries
// • p — Grass tile with a portal
// 
// The next line contains a positive integer 𝑃 indicating the number of pairs of portals in the grid
// above (there should be exactly 2𝑃 characters in the grid with the symbol P).
// The next 𝑃 lines of input each contain four space-separated, positive integers, indicating the
// locations of the paired portals. The 𝑖th line should contain integers 𝑟𝑖,1, 𝑐𝑖,1, 𝑟𝑖,2, and 𝑐𝑖,2 — the 0-
// indexed row and column of the first portal and second portal respectively.
//
// An example input is shown below.
// 5
// 9 13
// ##########..#
// #...#...#...#
// .WHW..a.#.p.#
// #.W.#...#...#
// #...#####.###
// #...#.......#
// #.p.#.b.#.c.#
// #...#...#...#
// #.#####...###
// 1
// 2 10 6 2

const std = @import("std");

const CellType = enum { 
    water,
    grass,
    wall,
    horse,
    cherry, // c, +3
    apple, // a, +10
    bee, //b, -5
    portal, //p
};

const Pos = struct {
    row: usize,
    col: usize,
};

const Individual = struct {
    walls: []bool,
    score: i32,
    valid: bool,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Individual) void {
        self.allocator.free(self.walls);
    }
};

const BFSResult = struct {
    visited: []bool,
    count: usize,
    score: i32,
    reachesBoundary: bool,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *BFSResult) void {
        self.allocator.free(self.visited);
    }
};

const Cell = struct {
    type: CellType,
};

const PortalPair = struct { 
    r1: usize,
    c1: usize,
    r2: usize,
    c2: usize,
};

const Puzzle = struct {
    grid: [][]Cell, //grid[row][col]
    rows: usize,
    cols: usize,
    budget: u32,
    horseRow: usize,
    horseCol: usize,
    portals: []PortalPair,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Puzzle) void {
        for(self.grid) |row| {
            self.allocator.free(row);
        }

        self.allocator.free(self.grid);
        self.allocator.free(self.portals);
    }

    //pretty print for viewing
    pub fn display(self: *const Puzzle) !void { 
        std.debug.print("Grid: {} rows x {} cols\n", .{self.rows, self.cols});
        std.debug.print("Horse at: ({}, {})\n", .{self.horseRow, self.horseCol});
        std.debug.print("Budget: {}\n\n", .{self.budget});

        for(self.grid, 0..) |row, rowIndex| {
            std.debug.print("{d:2} | ", .{rowIndex});
            for(row, 0..) |cell, colIndex| {
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
                        for(self.portals, 0..) |portalPair, index| {
                            if((rowIndex == portalPair.r1 and colIndex == portalPair.c1) or (rowIndex == portalPair.r2 and colIndex == portalPair.c2)) {
                                label = index + 1;
                                break;
                            }
                        }

                        if(label) |l| {
                            std.debug.print("P{d} ", .{l});
                        } else {
                            std.debug.print( " p ", .{});
                        }
                    }
                }
            }
            std.debug.print("\n", .{});
        }
        std.debug.print("\n", .{});
    }
};

pub fn getCandidateWalls(puzzle: *const Puzzle, visited: []bool, allocator: std.mem.Allocator) ![]Pos {
    var candidates: std.ArrayList(Pos) = .{};
    defer candidates.deinit(allocator);

    for(0..puzzle.rows) |row| {
        for(0..puzzle.cols) |col| {
            if(!visited[idx(puzzle.cols, row, col)]) continue;
            if(row == puzzle.horseRow and col == puzzle.horseCol) continue;
            if(puzzle.grid[row][col].type != .grass) continue;

            try candidates.append(allocator, .{ .row = row, .col = col });
        }
    }

    return try candidates.toOwnedSlice(allocator);
}

//weird index math so I can use 1d array instead of 2d (i want to figure out if this is actually more efficient/better in any meaningful way)
fn idx(cols: usize, row: usize, col: usize) usize {
    return row * cols + col;
}

pub fn solve(puzzle: *const Puzzle, candidates: []const Pos, random: std.Random, allocator: std.mem.Allocator) !Individual {
    const populationSize: usize = 200;
    const generations: usize = 1000;
    const eliteCount: usize = 10;

    //initialize population
    var population = try allocator.alloc(Individual, populationSize); 
    defer {
        for(population) |*individual| {
            individual.deinit();
        } 
        allocator.free(population);
    }

    for(population) |*individual| {
        individual.* = try createRandomIndividual(candidates.len, puzzle.budget, random, allocator);
        try evaluateFitness(individual, candidates, puzzle, allocator);
    }

    std.debug.print("Starting GA: {} candidates, budget {}, population {}\n", .{ candidates.len, puzzle.budget, populationSize });

    std.mem.sort(Individual, population, {}, struct {
        pub fn lessThan(_: void, a: Individual, b: Individual) bool {
            return b.score < a.score;
        }
    }.lessThan);

    std.debug.print("Gen 0: best score = {}\n", .{population[0].score});

    var bestSoFar: i32 = population[0].score;

    for(1..generations + 1) |generation| {
        var next = try allocator.alloc(Individual, populationSize);

        for(0..eliteCount) |i| {
            const walls = try allocator.alloc(bool, candidates.len);
            @memcpy(walls, population[i].walls);
            next[i] = Individual{
                .walls = walls,
                .score = population[i].score,
                .valid = population[i].valid,
                .allocator = allocator,
            };
        }

        for(eliteCount..populationSize) |i| {
            const parent1 = tournamentSelect(population, random);
            const parent2 = tournamentSelect(population, random);
            
            var child = try crossover(parent1, parent2, candidates.len, puzzle.budget, allocator);

            if(random.intRangeLessThan(u32, 0, 100) < 20) { 
                mutate(&child, random);
            }

            try evaluateFitness(&child, candidates, puzzle, allocator);
            next[i] = child;
        }

        //free old population
        for(population) |*individual| {
            individual.deinit();
        }

        allocator.free(population);
        population = next;

        std.mem.sort(Individual, population, {}, struct {
            pub fn lessThan(_: void, a: Individual, b: Individual) bool {
                return b.score < a.score;
            }
        }.lessThan);

        if (population[0].score > bestSoFar) {
            bestSoFar = population[0].score;
            std.debug.print("Gen {}: NEW BEST = {}\n", .{ generation, bestSoFar });
        }
   
        if(generation % 100 == 0) {
            std.debug.print("Gen {}: best score = {}\n", .{generation, population[0].score });
        }
    }

    std.debug.print("\nGA complete. Best score = {}, valid = {}\n", .{ population[0].score, population[0].valid });

    const bestWalls = try allocator.alloc(bool, candidates.len);
    @memcpy(bestWalls, population[0].walls);
    return Individual {
        .walls = bestWalls,
        .score = population[0].score,
        .valid = population[0].valid,
        .allocator = allocator,
    };
}

//essentially basic bfs, with a scoring component added.
//fan out from horse to boundary
pub fn bfs(puzzle: *const Puzzle, solutionWalls: ?[]const Pos, allocator: std.mem.Allocator, earlyExit: bool) !BFSResult {
    const maxCells = puzzle.rows * puzzle.cols;
    const queue = try allocator.alloc(Pos, maxCells);
    defer allocator.free(queue);
    var head: usize = 0;
    var tail: usize = 0;

    const directions = [_][2]i8{ .{-1, 0}, .{1, 0}, .{0, -1}, .{0, 1}};

    const visited = try allocator.alloc(bool, maxCells);
    errdefer allocator.free(visited);
    @memset(visited, false);

    var isWall = try allocator.alloc(bool, maxCells);
    defer allocator.free(isWall);
    @memset(isWall, false);

    if(solutionWalls) |walls| {
        for(walls) |w| {
            isWall[idx(puzzle.cols, w.row, w.col)] = true;
        }
    }
    
    visited[idx(puzzle.cols, puzzle.horseRow, puzzle.horseCol)] = true;
    queue[tail] = .{ .row = puzzle.horseRow, .col = puzzle.horseCol };
    tail += 1;

    var reachable: usize = 0;
    var reachesBoundary = false;

    var score: i32 = 0;

    while(head < tail) {
        const current = queue[head];
        head += 1;
        reachable += 1;

        score += switch(puzzle.grid[current.row][current.col].type) {
            .apple => 11,
            .cherry => 4,
            .bee => -4,
            else => 1,
        };

        if(current.row == 0 or current.row == puzzle.rows - 1 or current.col == 0 or current.col == puzzle.cols - 1) { 
            reachesBoundary = true;
            if(earlyExit) break;
        }

        for(directions) |direction| {
            const newRowSigned = @as(i64, @intCast(current.row)) + direction[0];
            const newColSigned = @as(i64, @intCast(current.col)) + direction[1];

            if(newRowSigned < 0 or newRowSigned >= puzzle.rows or newColSigned < 0 or newColSigned >= puzzle.cols) continue;

            const neighborRow = @as(usize, @intCast(newRowSigned));
            const neighborCol = @as(usize, @intCast(newColSigned));
            const neighborIndex = idx(puzzle.cols, neighborRow, neighborCol);

            if(visited[neighborIndex]) continue;

            if(puzzle.grid[neighborRow][neighborCol].type == .water or puzzle.grid[neighborRow][neighborCol].type == .wall or isWall[neighborIndex]) continue;

            visited[neighborIndex] = true;
            queue[tail] = .{ .row = neighborRow, .col = neighborCol };
            tail += 1;
        }

        if(puzzle.grid[current.row][current.col].type == .portal) {
            for(puzzle.portals) |portalPair| {
                var partnerRow: usize = undefined;
                var partnerCol: usize = undefined;
                var found = false;

                if(current.row == portalPair.r1 and current.col == portalPair.c1) {
                    partnerRow = portalPair.r2;
                    partnerCol = portalPair.c2;
                    found = true;
                } else if(current.row == portalPair.r2 and current.col == portalPair.c2) {
                    partnerRow = portalPair.r1;
                    partnerCol = portalPair.c1;
                    found = true;
                }

                if(found) {
                    const partnerIndex = idx(puzzle.cols, partnerRow, partnerCol);
                    if(!visited[partnerIndex] and !isWall[partnerIndex]) {
                        visited[partnerIndex] = true;
                        queue[tail] = . { .row = partnerRow, .col = partnerCol };
                        tail += 1;
                    }
                }
            }
        }
    }

    return BFSResult {
        .visited = visited,
        .count = reachable,
        .score = score,
        .reachesBoundary = reachesBoundary,
        .allocator = allocator,
    };
}

pub fn createRandomIndividual(numCandidates: usize, budget: u32, random: std.Random, allocator: std.mem.Allocator) !Individual { 
    const walls = try allocator.alloc(bool, numCandidates);
    @memset(walls, false);

    //randomly pick 'budget' unique indices to place walls
    var placed: u32 = 0;
    while(placed < budget) {
        const i = random.intRangeLessThan(usize, 0, numCandidates);
        if(!walls[i]) {
            walls[i] = true;
            placed += 1;
        }
    }

    return Individual {
        .walls = walls,
        .score = 0,
        .valid = false,
        .allocator = allocator,
    };
}

pub fn computeAdjacencyBonus(candidates: []const Pos, walls: []const bool, puzzle: *const Puzzle) i32 {
    const directions = [_][2]i8{ .{-1, 0}, .{1, 0}, .{0, -1}, .{0, 1}};
    var bonus: i32 = 0;

    for(candidates, 0..) |pos, i| {
        if(!walls[i]) continue;

        var neighborCount: i32 = 0;

        for(directions) |direction| {
            const newRowSigned = @as(i64, @intCast(pos.row)) + direction[0];
            const newColSigned = @as(i64, @intCast(pos.col)) + direction[1];

            if(newRowSigned < 0 or newRowSigned >= puzzle.rows or newColSigned < 0 or newColSigned >= puzzle.cols) {
                neighborCount += 1;
                continue;
            }

            const neighborRow = @as(usize, @intCast(newRowSigned));
            const neighborCol = @as(usize, @intCast(newColSigned));
            const neighborType = puzzle.grid[neighborRow][neighborCol].type;

            if(neighborType == .water or neighborType == .wall) { 
                neighborCount += 1;
                continue;
            }

            for(candidates, 0..) |other, j| {
                if(j == i) continue;
                if(walls[j] and other.row == neighborRow and other.col == neighborCol) {
                    neighborCount += 1;
                    break;
                }
            }
        }

        bonus += switch(neighborCount) {
            0 => -3, //isolated, likely wasted (for some puzzles, this might not be ideal)
            1 => 0, //weakly connected
            2 => 2, //forming a line or a corner
            3 => 3, //well connected
            else => -2, //surrounded, penalize
        };
    }

    return bonus;
}

pub fn evaluateFitness(individual: *Individual, candidates: []const Pos, puzzle: *const Puzzle, allocator: std.mem.Allocator) !void {
    var wallList: std.ArrayList(Pos) = .{};
    defer wallList.deinit(allocator);

    for(candidates, 0..) |pos, i| {
        if(individual.walls[i]) {
            try wallList.append(allocator, pos);
        }
    }

    var result = try bfs(puzzle, wallList.items, allocator, true);
    defer result.deinit();

    if(result.reachesBoundary) {
        const adjBonus = computeAdjacencyBonus(candidates, individual.walls, puzzle);
        individual.score = -50 + adjBonus;
        individual.valid = false;
    } else {
        const adjBonus = computeAdjacencyBonus(candidates, individual.walls, puzzle);
        individual.score = result.score + @divTrunc(adjBonus, 2);
        individual.valid = true;
    }

    
}

fn tournamentSelect(population: []Individual, random: std.Random) *const Individual {
    const a = random.intRangeLessThan(usize, 0, population.len);
    const b = random.intRangeLessThan(usize, 0, population.len);

    if(population[a].score >= population[b].score) {
        return &population[a];
    } else {
        return &population[b];
    }
}

fn crossover(parent1: *const Individual, parent2: *const Individual, numCandidates: usize, budget: u32, allocator: std.mem.Allocator) !Individual {
    const walls = try allocator.alloc(bool, numCandidates);
    @memset(walls, false);
    var count: u32 = 0;

    //keep shared walls
    for(0..numCandidates) |i| {
        if(count >= budget) break;
        if(parent1.walls[i] and parent2.walls[i]) {
            walls[i] = true;
            count += 1;
        }
    }

    //randomly pick from walls only one parent has
    for(0..numCandidates) |i| {
        if(count >= budget) break;
        if(!walls[i] and (parent1.walls[i] or parent2.walls[i])) {
            walls[i] = true;
            count += 1;
        }
    }

    return Individual {
        .walls = walls,
        .score = 0,
        .valid = false,
        .allocator = allocator,
    };
}

fn mutate(individual: *Individual, random: std.Random) void {
    //find a wall thats placed and remove it
    //find an empty slot and place a wall there
    const len = individual.walls.len;

    var attempts: usize = 0;
    while(attempts < len) : (attempts += 1) { 
        const removeIndex = random.intRangeLessThan(usize, 0, len);
        if(individual.walls[removeIndex]) {
            individual.walls[removeIndex] = false;
            break;
        }
    }

    attempts = 0;
    while(attempts < len) : (attempts += 1) {
        const addIndex = random.intRangeLessThan(usize, 0, len);
        if(!individual.walls[addIndex]) {
            individual.walls[addIndex] = true;
            break;
        }
    }
}

pub fn parseInput(allocator: std.mem.Allocator, data: []const u8) !Puzzle {
    var lines = std.mem.tokenizeScalar(u8, data, '\n');

    const budgetLine = std.mem.trim(u8, lines.next() orelse return error.InvalidInput, " \r");
    const budget = try std.fmt.parseInt(u32, budgetLine, 10);

    const dimensionsLine = std.mem.trim(u8, lines.next() orelse return error.InvalidInput, " \r");
    var dimensions = std.mem.tokenizeScalar(u8, dimensionsLine, ' ');
    const rows = try std.fmt.parseInt(usize, dimensions.next() orelse return error.InvalidInput, 10);
    const cols = try std.fmt.parseInt(usize, dimensions.next() orelse return error.InvalidInput, 10);

    const grid = try allocator.alloc([]Cell, rows);

    var horseRow: usize = 0;
    var horseCol: usize = 0;

    for (grid, 0..) |*row, rowIndex| { 
        const line = std.mem.trim(u8, lines.next() orelse return error.InvalidInput, " \r");
        row.* = try allocator.alloc(Cell, cols);
        for(line, 0..) |ch, colIndex| {
            row.*[colIndex] = try parseCell(ch);
            if(ch == 'H') { 
                horseRow = rowIndex;
                horseCol = colIndex;
            }
        }
    }

    const portalLine = std.mem.trim(u8, lines.next() orelse return error.InvalidInput, " \r");
    const numPortals = try std.fmt.parseInt(usize, portalLine, 10);

    const portals = try allocator.alloc(PortalPair, numPortals);
    for(portals) |*portalPair| {
        const line = std.mem.trim(u8, lines.next() orelse return error.InvalidInput, " \r");
        var tokens = std.mem.tokenizeScalar(u8, line, ' ');
        portalPair.* = PortalPair {
            .r1 = try std.fmt.parseInt(usize, tokens.next() orelse return error.InvalidInput, 10),
            .c1 = try std.fmt.parseInt(usize, tokens.next() orelse return error.InvalidInput, 10),  
            .r2 = try std.fmt.parseInt(usize, tokens.next() orelse return error.InvalidInput, 10),  
            .c2 = try std.fmt.parseInt(usize, tokens.next() orelse return error.InvalidInput, 10),  
        };
    }

    return Puzzle { 
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

pub fn parseCell(ch: u8) !Cell {
    return .{ .type = switch(ch) {
        '#' => .water,
        '.' => .grass,
        'H' => .horse,
        'W' => .wall,
        'a' => .apple,
        'b' => .bee,
        'c' => .cherry,
        'p' => .portal,
        else => return error.UnknownCell,
    }};
}

pub fn removePrePlacedWalls(puzzle: *Puzzle) void {
    for(0..puzzle.rows) |row| {
        for(0..puzzle.cols) |col| {
            if(puzzle.grid[row][col].type == .wall) {
                puzzle.grid[row][col] = .{ .type = .grass};
            }
        }
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var prng = std.Random.DefaultPrng.init(0xFACADE);
    const random = prng.random();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if(args.len < 2) { 
        std.debug.print("Usage: algobowl <input_file>\n", .{});
    }

    const content = try std.fs.cwd().readFileAlloc(allocator, args[1], 1024 * 1024); 
    defer allocator.free(content);

    var puzzle = try parseInput(allocator, content);
    defer puzzle.deinit();

    var initialReach = try bfs(&puzzle, null, allocator, true);
    std.debug.print("With pre-placed solution walls:\n", .{});
    std.debug.print("  Reachable: {}, Score: {}, Reaches boundary: {}\n\n", .{ initialReach.count, initialReach.score, initialReach.reachesBoundary });
    initialReach.deinit();

    try puzzle.display();
    removePrePlacedWalls(&puzzle);

    var fullReach = try bfs(&puzzle, null, allocator, false);
    defer fullReach.deinit();

    std.debug.print("With pre-placed solution walls removed (full budget):\n", .{});
    std.debug.print("  Reachable: {}, Score: {}, Reaches boundary: {}\n\n", .{ fullReach.count, fullReach.score, fullReach.reachesBoundary });

    const candidates = try getCandidateWalls(&puzzle, fullReach.visited, allocator);
    defer allocator.free(candidates);

    var best = try solve(&puzzle, candidates, random, allocator);
    defer best.deinit();

    std.debug.print("BFS Result:\n", .{});
    std.debug.print("  Reachable Cells: {}\n", .{fullReach.count});
    std.debug.print("  Reaches boundary: {}\n\n", .{fullReach.reachesBoundary});
    std.debug.print("  Score from BFS: {}\n\n", .{fullReach.score});
    std.debug.print("  Candidate Wall Positions: {}\n", .{candidates.len});

    std.debug.print("\nFinal result:\n", .{});
    std.debug.print("  Score: {}\n", .{best.score});
    std.debug.print("  Valid: {}\n", .{best.valid});

    std.debug.print("  Walls placed at:\n", .{});
    for (candidates, 0..) |pos, i| {
        if (best.walls[i]) {
            puzzle.grid[pos.row][pos.col] = .{ .type = .wall };
            std.debug.print("    ({}, {})\n", .{ pos.row, pos.col });
        }
    }

    try puzzle.display();
    std.debug.print("All your {s} are belong to us.\n", .{"codebase"});
}

test "parseCell valid characters" {
    const grass = try parseCell('.');
    try std.testing.expectEqual(CellType.grass, grass.type);

    const water = try parseCell('#');
    try std.testing.expectEqual(CellType.water, water.type);

    const horse = try parseCell('H');
    try std.testing.expectEqual(CellType.horse, horse.type);

    const wall = try parseCell('W');
    try std.testing.expectEqual(CellType.wall, wall.type);

    const apple = try parseCell('a');
    try std.testing.expectEqual(CellType.apple, apple.type);

    const bee = try parseCell('b');
    try std.testing.expectEqual(CellType.bee, bee.type);

    const cherry = try parseCell('c');
    try std.testing.expectEqual(CellType.cherry, cherry.type);

    const portal = try parseCell('p');
    try std.testing.expectEqual(CellType.portal, portal.type);
}

test "parseCell invalid character" {
    const result = parseCell('Z');
    try std.testing.expectError(error.UnknownCell, result);
}

test "parseInput example from PDF" {
    const input =
        \\5
        \\9 13
        \\##########..#
        \\#...#...#...#
        \\.WHW..a.#.p.#
        \\#.W.#...#...#
        \\#...#####.###
        \\#...#.......#
        \\#.p.#.b.#.c.#
        \\#...#...#...#
        \\#.#####...###
        \\1
        \\2 10 6 2
    ;

    var puzzle = try parseInput(std.testing.allocator, input);
    defer puzzle.deinit();

    try std.testing.expectEqual(@as(usize, 9), puzzle.rows);
    try std.testing.expectEqual(@as(usize, 13), puzzle.cols);
    try std.testing.expectEqual(@as(u32, 5), puzzle.budget);
    try std.testing.expectEqual(@as(usize, 2), puzzle.horseRow);
    try std.testing.expectEqual(@as(usize, 2), puzzle.horseCol);
    try std.testing.expectEqual(@as(usize, 1), puzzle.portals.len);
    try std.testing.expectEqual(@as(usize, 2), puzzle.portals[0].r1);
    try std.testing.expectEqual(@as(usize, 10), puzzle.portals[0].c1);
    try std.testing.expectEqual(@as(usize, 6), puzzle.portals[0].r2);
    try std.testing.expectEqual(@as(usize, 2), puzzle.portals[0].c2);
}

test "bfs horse enclosed by preplaced walls" {
    const input =
        \\5
        \\9 13
        \\##########..#
        \\#...#...#...#
        \\.WHW..a.#.p.#
        \\#.W.#...#...#
        \\#...#####.###
        \\#...#.......#
        \\#.p.#.b.#.c.#
        \\#...#...#...#
        \\#.#####...###
        \\1
        \\2 10 6 2
    ;

    var puzzle = try parseInput(std.testing.allocator, input);
    defer puzzle.deinit();

    var result = try bfs(&puzzle, null, std.testing.allocator, false);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 4), result.count);
    try std.testing.expect(!result.reachesBoundary);
}

test "bfs no walls horse reaches boundary" {
    // Simple 3x3 grid, horse in center, all grass, no walls
    const input =
        \\0
        \\3 3
        \\...
        \\.H.
        \\...
        \\0
    ;

    var puzzle = try parseInput(std.testing.allocator, input, false);
    defer puzzle.deinit();

    var result = try bfs(&puzzle, null, std.testing.allocator, false);
    defer result.deinit();

    try std.testing.expect(result.reachesBoundary);
}

test "bfs with water enclosing horse" {
    // 5x5 grid, horse in center, place water around it
    const input =
        \\4
        \\5 5
        \\#####
        \\#...#
        \\#.H.#
        \\#...#
        \\#####
        \\0
    ;

    var puzzle = try parseInput(std.testing.allocator, input);
    defer puzzle.deinit();

    // No extra walls needed — water already encloses
    var result = try bfs(&puzzle, null, std.testing.allocator, false);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 9), result.count);
    try std.testing.expect(!result.reachesBoundary);
}

test "bfs scoring with special tiles" {
    const input =
        \\0
        \\3 5
        \\#####
        \\#aHc#
        \\#####
        \\0
    ;

    var puzzle = try parseInput(std.testing.allocator, input);
    defer puzzle.deinit();

    var result = try bfs(&puzzle, null, std.testing.allocator, false);
    defer result.deinit();

    // 3 reachable cells: apple(11) + horse(1) + cherry(4) = 16
    try std.testing.expectEqual(@as(usize, 3), result.count);
    try std.testing.expectEqual(@as(i32, 16), result.score);
    try std.testing.expect(!result.reachesBoundary);
}

test "getCandidateWalls excludes special tiles and horse" {
    const input =
        \\0
        \\3 5
        \\#####
        \\#.Hc#
        \\#####
        \\0
    ;

    var puzzle = try parseInput(std.testing.allocator, input);
    defer puzzle.deinit();

    var result = try bfs(&puzzle, null, std.testing.allocator, false);
    defer result.deinit();

    const candidates = try getCandidateWalls(&puzzle, result.visited, std.testing.allocator);
    defer std.testing.allocator.free(candidates);

    // 3 reachable cells: grass(1,1), horse(1,2), cherry(1,3)
    // Only grass(1,1) is a valid candidate
    try std.testing.expectEqual(@as(usize, 1), candidates.len);
    try std.testing.expectEqual(@as(usize, 1), candidates[0].row);
    try std.testing.expectEqual(@as(usize, 1), candidates[0].col);
}

test "solve finds valid enclosure" {
    // Horse in center, one gap on each side to close
    const input =
        \\4
        \\5 5
        \\##.##
        \\#...#
        \\..H.#
        \\#...#
        \\##.##
        \\0
    ;

    var puzzle = try parseInput(std.testing.allocator, input);
    defer puzzle.deinit();

    var fullReach = try bfs(&puzzle, null, std.testing.allocator, false);
    defer fullReach.deinit();

    const candidates = try getCandidateWalls(&puzzle, fullReach.visited, std.testing.allocator);
    defer std.testing.allocator.free(candidates);

    var prng = std.Random.DefaultPrng.init(0xDEADBEEF);
    const random = prng.random();

    var best = try solve(&puzzle, candidates, random, std.testing.allocator);
    defer best.deinit();

    // Should find a valid enclosure
    try std.testing.expect(best.valid);
    try std.testing.expect(best.score > 0);
}
