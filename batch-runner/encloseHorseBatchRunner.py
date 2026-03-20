#!/usr/bin/env python3
"""
Enclose Horse Batch Runner
============================
Runs the compiled Zig solver on all scraped puzzle .txt files, reading
metadata (budget, optimal score) from each puzzle's companion .json file.

Usage:
    python run_all_puzzles.py                              # Defaults: ./main solver, ./puzzles dir
    python run_all_puzzles.py --solver ./zig-out/bin/main  # Custom solver path
    python run_all_puzzles.py --puzzle-dir ./my_puzzles     # Custom puzzle directory
    python run_all_puzzles.py --timeout 60                  # Custom timeout per puzzle

Expected file layout (from enclose_horse_scraper.py):
    puzzles/
        puzzle_2026-03-12.txt    ← assignment-format input
        puzzle_2026-03-12.json   ← metadata: {"budget": 10, "optimal_score": 50, ...}
        ...

For each puzzle, the script runs:
    <solver> <puzzle.txt>

and saves combined stdout+stderr to:
    puzzles/results/puzzle_2026-03-12_result.txt
"""

import argparse
import json
import subprocess
import sys
from pathlib import Path


def findPuzzles(puzzle_dir: Path) -> list[tuple[Path, Path]]:
    """Find all (txt, json) pairs sorted by date."""
    txts = sorted(puzzle_dir.glob("puzzle_*.txt"))
    pairs = []
    for txtPath in txts:
        jsonPath = txtPath.with_suffix(".json")
        if jsonPath.exists():
            pairs.append((txtPath, jsonPath))
        else:
            print(f"WARNING: No metadata file for {txtPath.name}, skipping. "
                  f"(Expected: {jsonPath.name})")
    return pairs


def runSolver(solverPath: Path, puzzlePath: Path, outputPath: Path, timeout: int) -> bool:
    """Run the Zig solver on a single puzzle. Returns True on success."""
    cmd = [str(solverPath), str(puzzlePath)]

    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=timeout,
        )

        with open(outputPath, "w") as f:
            if result.stdout:
                f.write(result.stdout)
            if result.stderr:
                f.write(result.stderr)

        if result.returncode != 0:
            print(f"  EXIT CODE {result.returncode}")
            return False

        return True

    except subprocess.TimeoutExpired:
        with open(outputPath, "w") as f:
            f.write(f"TIMEOUT: solver exceeded {timeout}s limit\n")
        print(f"  TIMEOUT after {timeout}s")
        return False
    except Exception as e:
        print(f"  ERROR: {e}")
        return False


def extractScore(outputPath: Path) -> int | None:
    """Extract the numeric score from Zig solver output."""
    try:
        text = outputPath.read_text()
        for line in text.splitlines():
            # Match "Score: <number>" but not "Score from BFS:"
            stripped = line.strip()
            if stripped.startswith("Score:"):
                parts = stripped.split()
                if len(parts) >= 2:
                    try:
                        return int(parts[1])
                    except ValueError:
                        continue
        return None
    except Exception:
        return None


def extractValid(outputPath: Path) -> bool | None:
    """Extract whether the solution is valid from Zig solver output."""
    try:
        text = outputPath.read_text()
        for line in text.splitlines():
            stripped = line.strip()
            if stripped.startswith("Valid:"):
                return "true" in stripped.lower()
        return None
    except Exception:
        return None


def main():
    parser = argparse.ArgumentParser(description="Batch-run Zig enclose horse solver on scraped puzzles")
    parser.add_argument("--puzzle-dir", type=Path, default=Path("puzzles"),
                        help="Directory containing .txt + .json puzzle files (default: ./puzzles)")
    parser.add_argument("--solver", type=Path, default=Path("main"),
                        help="Path to the compiled Zig solver binary (default: ./main)")
    parser.add_argument("--timeout", type=int, default=300,
                        help="Timeout per puzzle in seconds (default: 300)")
    args = parser.parse_args()

    if not args.solver.exists():
        print(f"ERROR: Solver not found at {args.solver}")
        print(f"  Compile it first: zig build-exe main.zig -O ReleaseFast")
        sys.exit(1)

    if not args.puzzle_dir.exists():
        print(f"ERROR: Puzzle directory not found at {args.puzzle_dir}")
        print(f"  Run the scraper first:")
        print(f"    python enclose_horse_scraper.py 2025-12-30 2026-03-20")
        sys.exit(1)

    pairs = findPuzzles(args.puzzle_dir)
    if not pairs:
        print(f"No puzzle .txt + .json pairs found in {args.puzzle_dir}")
        sys.exit(1)

    resultsDir = args.puzzle_dir / "results"
    resultsDir.mkdir(exist_ok=True)

    print(f"Found {len(pairs)} puzzle(s) in {args.puzzle_dir}")
    print(f"Solver: {args.solver}")
    print(f"Timeout: {args.timeout}s per puzzle")
    print(f"Results: {resultsDir}/")
    print("=" * 70)

    summary = []
    totalOptimal = 0
    totalSolved = 0
    totalPuzzles = 0

    for i, (txtPath, jsonPath) in enumerate(pairs, 1):
        meta = json.loads(jsonPath.read_text())
        puzzleDate = meta.get("date", txtPath.stem)
        budget = meta.get("budget", "?")
        name = meta.get("name", "")
        optimal = meta.get("optimal_score")
        rows = meta.get("rows", "?")
        cols = meta.get("cols", "?")

        outputPath = resultsDir / f"puzzle_{puzzleDate}_result.txt"

        header = f"\n[{i}/{len(pairs)}] {puzzleDate}"
        if name:
            header += f" — {name}"
        header += f" ({rows}x{cols}, budget={budget})"
        if optimal:
            header += f" [optimal={optimal}]"
        print(header)

        success = runSolver(args.solver, txtPath, outputPath, args.timeout)

        score = None
        valid = None
        status = "FAILED"

        if success:
            score = extractScore(outputPath)
            valid = extractValid(outputPath)

            if valid is None or not valid:
                status = f"INVALID (score={score})" if score is not None else "INVALID"
            elif score is not None:
                totalSolved += 1
                if optimal and score >= int(optimal):
                    status = f"OPTIMAL! score={score}"
                    totalOptimal += 1
                elif optimal:
                    gap = int(optimal) - score
                    pct = score / int(optimal) * 100
                    status = f"score={score} (gap={gap}, {pct:.0f}%)"
                else:
                    status = f"score={score}"
            else:
                status = "Score not found in output"

        totalPuzzles += 1
        print(f"  → {status}")
        summary.append((puzzleDate, name, budget, score, valid, optimal, status))

    # Print summary table
    print("\n" + "=" * 70)
    print("SUMMARY")
    print("=" * 70)
    print(f"{'Date':<12} {'Budget':>6} {'Score':>7} {'Optimal':>7} {'Gap':>5} {'Status':<15}")
    print("-" * 70)

    totalGap = 0
    totalWithOptimal = 0

    for puzzleDate, name, budget, score, valid, optimal, status in summary:
        scoreStr = str(score) if score is not None else "-"
        optStr = str(optimal) if optimal else "?"

        if score is not None and optimal and valid:
            gap = int(optimal) - score
            gapStr = str(gap)
            totalGap += gap
            totalWithOptimal += 1
        else:
            gapStr = "-"

        if valid is None:
            validStr = "FAILED"
        elif valid:
            validStr = "VALID"
        else:
            validStr = "INVALID"

        print(f"{puzzleDate:<12} {str(budget):>6} {scoreStr:>7} {optStr:>7} {gapStr:>5} {validStr:<15}")

    print("-" * 70)
    print(f"Puzzles: {totalPuzzles}  |  Solved: {totalSolved}  |  Optimal: {totalOptimal}", end="")
    if totalWithOptimal > 0:
        avgGap = totalGap / totalWithOptimal
        print(f"  |  Avg gap: {avgGap:.1f}")
    else:
        print()

    # Save summary to file
    summaryPath = resultsDir / "summary.txt"
    with open(summaryPath, "w") as f:
        f.write(f"{'Date':<12} {'Budget':>6} {'Score':>7} {'Optimal':>7} {'Gap':>5} {'Status':<15}\n")
        f.write("-" * 70 + "\n")
        for puzzleDate, name, budget, score, valid, optimal, status in summary:
            scoreStr = str(score) if score is not None else "-"
            optStr = str(optimal) if optimal else "?"
            if score is not None and optimal and valid:
                gapStr = str(int(optimal) - score)
            else:
                gapStr = "-"
            if valid is None:
                validStr = "FAILED"
            elif valid:
                validStr = "VALID"
            else:
                validStr = "INVALID"
            f.write(f"{puzzleDate:<12} {str(budget):>6} {scoreStr:>7} {optStr:>7} {gapStr:>5} {validStr:<15}\n")

        f.write("-" * 70 + "\n")
        f.write(f"Puzzles: {totalPuzzles}  |  Solved: {totalSolved}  |  Optimal: {totalOptimal}")
        if totalWithOptimal > 0:
            f.write(f"  |  Avg gap: {totalGap / totalWithOptimal:.1f}")
        f.write("\n")

    print(f"\nSummary saved to {summaryPath}")


if __name__ == "__main__":
    main()
