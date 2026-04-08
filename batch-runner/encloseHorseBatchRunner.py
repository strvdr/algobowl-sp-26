#!/usr/bin/env python3
"""
Enclose Horse Batch Runner
============================
Runs the compiled Zig solver on all puzzle .txt files in a directory.
JSON metadata files are optional — budget, rows, and cols are parsed
directly from each .txt file if no companion .json exists.

Usage:
    python encloseHorseBatchRunner.py                              # Defaults: ./main solver, ./puzzles dir
    python encloseHorseBatchRunner.py --solver ./zig-out/bin/main  # Custom solver path
    python encloseHorseBatchRunner.py --puzzle-dir ./my_puzzles     # Custom puzzle directory
    python encloseHorseBatchRunner.py --timeout 60                  # Custom timeout per puzzle

Output format from solver:
    stdout: score on line 1, then R lines of the grid
    stderr: "Score: X" and "Valid: true/false" for batch runner parsing
"""

import argparse
import json
import subprocess
import sys
from pathlib import Path


def parseTxtMeta(txtPath: Path) -> dict:
    """Parse budget, rows, cols directly from a puzzle .txt file."""
    try:
        lines = txtPath.read_text().splitlines()
        budget = int(lines[0].strip())
        dims = lines[1].strip().split()
        rows, cols = int(dims[0]), int(dims[1])
        return {"budget": budget, "rows": rows, "cols": cols}
    except Exception:
        return {"budget": "?", "rows": "?", "cols": "?"}


def findPuzzles(puzzle_dir: Path) -> list[tuple[Path, Path | None]]:
    """Find all .txt puzzle files, paired with optional .json metadata."""
    txts = sorted(puzzle_dir.glob("*.txt"))
    pairs = []
    for txtPath in txts:
        jsonPath = txtPath.with_suffix(".json")
        pairs.append((txtPath, jsonPath if jsonPath.exists() else None))
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
    """Extract the numeric score from solver stderr output (Score: X line)."""
    try:
        for line in outputPath.read_text().splitlines():
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
    """Extract validity from solver stderr output (Valid: true/false line)."""
    try:
        for line in outputPath.read_text().splitlines():
            stripped = line.strip()
            if stripped.startswith("Valid:"):
                return "true" in stripped.lower()
        return None
    except Exception:
        return None


def main():
    parser = argparse.ArgumentParser(description="Batch-run Zig enclose horse solver on puzzles")
    parser.add_argument("--puzzle-dir", type=Path, default=Path("puzzles"),
                        help="Directory containing .txt puzzle files (default: ./puzzles)")
    parser.add_argument("--solver", type=Path, default=Path("main"),
                        help="Path to the compiled Zig solver binary (default: ./main)")
    parser.add_argument("--timeout", type=int, default=300,
                        help="Timeout per puzzle in seconds (default: 300)")
    args = parser.parse_args()

    if not args.solver.exists():
        print(f"ERROR: Solver not found at {args.solver}")
        print(f"  Compile it first: zig build -Doptimize=ReleaseFast")
        sys.exit(1)

    if not args.puzzle_dir.exists():
        print(f"ERROR: Puzzle directory not found at {args.puzzle_dir}")
        sys.exit(1)

    pairs = findPuzzles(args.puzzle_dir)
    if not pairs:
        print(f"No .txt puzzle files found in {args.puzzle_dir}")
        sys.exit(1)

    resultsDir = args.puzzle_dir / "results"
    resultsDir.mkdir(exist_ok=True)

    print(f"Found {len(pairs)} puzzle(s) in {args.puzzle_dir}")
    print(f"Solver:  {args.solver}")
    print(f"Timeout: {args.timeout}s per puzzle")
    print(f"Results: {resultsDir}/")
    print("=" * 70)

    summary = []
    totalOptimal = 0
    totalSolved = 0
    totalPuzzles = 0

    for i, (txtPath, jsonPath) in enumerate(pairs, 1):
        # Load metadata: prefer JSON if present, otherwise parse the txt directly
        if jsonPath is not None:
            meta = json.loads(jsonPath.read_text())
        else:
            meta = parseTxtMeta(txtPath)

        puzzleName = meta.get("date", txtPath.stem)
        budget     = meta.get("budget", "?")
        name       = meta.get("name", "")
        optimal    = meta.get("optimal_score")
        rows       = meta.get("rows", "?")
        cols       = meta.get("cols", "?")

        outputPath = resultsDir / f"{txtPath.stem}_result.txt"

        header = f"\n[{i}/{len(pairs)}] {puzzleName}"
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
        summary.append((puzzleName, name, budget, score, valid, optimal, status))

    # Summary table
    print("\n" + "=" * 70)
    print("SUMMARY")
    print("=" * 70)
    print(f"{'Puzzle':<20} {'Budget':>6} {'Score':>7} {'Optimal':>7} {'Gap':>5} {'Status':<15}")
    print("-" * 70)

    totalGap = 0
    totalWithOptimal = 0

    for puzzleName, name, budget, score, valid, optimal, status in summary:
        scoreStr = str(score) if score is not None else "-"
        optStr   = str(optimal) if optimal else "?"

        if score is not None and optimal and valid:
            gap = int(optimal) - score
            gapStr = str(gap)
            totalGap += gap
            totalWithOptimal += 1
        else:
            gapStr = "-"

        validStr = "FAILED" if valid is None else ("VALID" if valid else "INVALID")
        print(f"{puzzleName:<20} {str(budget):>6} {scoreStr:>7} {optStr:>7} {gapStr:>5} {validStr:<15}")

    print("-" * 70)
    print(f"Puzzles: {totalPuzzles}  |  Solved: {totalSolved}  |  Optimal: {totalOptimal}", end="")
    if totalWithOptimal > 0:
        print(f"  |  Avg gap: {totalGap / totalWithOptimal:.1f}")
    else:
        print()

    # Save summary
    summaryPath = resultsDir / "summary.txt"
    with open(summaryPath, "w") as f:
        f.write(f"{'Puzzle':<20} {'Budget':>6} {'Score':>7} {'Optimal':>7} {'Gap':>5} {'Status':<15}\n")
        f.write("-" * 70 + "\n")
        for puzzleName, name, budget, score, valid, optimal, status in summary:
            scoreStr = str(score) if score is not None else "-"
            optStr   = str(optimal) if optimal else "?"
            gapStr   = str(int(optimal) - score) if (score is not None and optimal and valid) else "-"
            validStr = "FAILED" if valid is None else ("VALID" if valid else "INVALID")
            f.write(f"{puzzleName:<20} {str(budget):>6} {scoreStr:>7} {optStr:>7} {gapStr:>5} {validStr:<15}\n")
        f.write("-" * 70 + "\n")
        f.write(f"Puzzles: {totalPuzzles}  |  Solved: {totalSolved}  |  Optimal: {totalOptimal}")
        if totalWithOptimal > 0:
            f.write(f"  |  Avg gap: {totalGap / totalWithOptimal:.1f}")
        f.write("\n")

    print(f"\nSummary saved to {summaryPath}")


if __name__ == "__main__":
    main()
