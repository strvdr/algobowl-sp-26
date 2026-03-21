# Enclose Horse — AlgoBOWL Solver

Solvers for the [Enclose Horse](https://enclose.horse) puzzle game. Includes a Python scraper for fetching daily puzzles and a batch runner for benchmarking.

Genetic Algorithm Author: Strydr Silverberg

## The Problem

You're given a grid of grass, water, apples, bees, cherries, and portals — with a horse somewhere in the middle. Your goal: place up to **W** walls to **enclose the horse** (cut it off from the grid boundary) while **maximizing the score** of all tiles it can still reach.

| Tile | Score |
|------|-------|
| Grass / Horse / Portal | +1 |
| Apple | +11 |
| Cherry | +4 |
| Bees | −4 |

Walls can only be placed on empty grass tiles — not on water, apples, bees, cherries, or portals.

## Quick Start

### 1. Build the solver

```bash
zig build-exe main.zig -O ReleaseFast
```

### 2. Run on a single puzzle

```bash
./main input.txt
```

The solver prints debug info (generation progress, best scores) to **stderr** and the final result summary there as well. It reads the companion `.json` file automatically if present to compare against the known optimal.

### 3. Scrape daily puzzles

```bash
# Today's puzzle
python encloseHorseScraper.py

# Specific date
python encloseHorseScraper.py 2026-03-12

# Date range
python encloseHorseScraper.py 2025-12-30 2026-03-20

# Custom output directory
python encloseHorseScraper.py --output-dir ./my_puzzles 2026-03-12
```

This fetches from the `enclose.horse` API and saves two files per puzzle:
- `puzzle_YYYY-MM-DD.txt` — the input in AlgoBOWL assignment format
- `puzzle_YYYY-MM-DD.json` — metadata (budget, optimal score, grid size)

### 4. Batch run all puzzles

```bash
python encloseHorseBatchRunner.py
python encloseHorseBatchRunner.py --solver ./main --puzzle-dir ./puzzles --timeout 300
```

Runs the solver on every `.txt`/`.json` pair in the puzzle directory. Results go to `puzzles/results/` with a summary table at the end showing scores, gaps from optimal, and validity.

## How the Genetic Algorithm Solver Works

### Core idea

The solver uses a **genetic algorithm (GA)** to search the space of possible wall placements. Each "individual" in the population is a set of wall positions (a boolean mask over candidate cells). The GA evolves these over many generations to find enclosures that are both **valid** (horse can't reach the boundary) and **high-scoring** (maximize reachable tile value).

### Pipeline

1. **Parse** the input and identify the horse position, portals, and grid layout.
2. **Remove pre-placed walls** from the input.
3. **BFS from the horse** with no walls to find all reachable cells. Only reachable grass cells are candidates for wall placement.
4. **Run the GA** across multiple threads, each with a different random seed.
5. **Output** the best valid solution found across all threads.

### GA details

- **Population**: 200 individuals, each representing a wall placement of size ≤ budget.
- **Fitness**:
  - **Valid** individuals (horse enclosed) get their BFS score directly — higher is better.
  - **Invalid** individuals get a negative penalty proportional to how many cells are reachable, plus an **adjacency bonus** that rewards walls forming contiguous barriers near water/edges. This guides the search toward valid enclosures even before finding one.
- **Selection**: Tournament selection (pick 2 random individuals, keep the better one).
- **Crossover**: Child inherits walls both parents share first, then fills from walls either parent has, up to budget.
- **Mutation**: With 30% probability, swap 1–3 random walls to new positions.
- **Elitism**: Top 5 valid + top 5 invalid individuals survive unchanged each generation.
- **Expand mutation**: After sorting each generation, the top 10 valid individuals attempt an "expand" — remove a boundary wall and try to re-seal with walls placed on edge cells. This lets the GA grow enclosures outward once it finds a valid one.
- **Pruning**: Valid individuals get their walls pruned — any wall that can be removed without breaking validity or lowering score is removed, freeing budget for the expand step.
- **Parallelism**: Spawns one solver thread per CPU core, each running the full GA independently. Best result wins.

### Key constants (tunable in `main.zig`)

| Constant | Value | Purpose |
|----------|-------|---------|
| `populationSize` | 200 | Individuals per generation |
| `gaGenerations` | 100,000 | Max generations per thread |
| `mutationRate` | 30 | % chance of mutation per child |
| `eliteCount` | 10 | Survivors per generation (5 valid + 5 invalid) |

