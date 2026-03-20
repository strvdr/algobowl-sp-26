#!/usr/bin/env python3
"""
Enclose Horse Daily Puzzle Scraper
===================================
Fetches the daily puzzle from enclose.horse and exports it in the
assignment input format.

Usage:
    python enclose_horse_scraper.py                     # Today's puzzle
    python enclose_horse_scraper.py 2026-03-12          # Specific date
    python enclose_horse_scraper.py 2026-03-01 2026-03-12  # Date range

Output format (matches AlgoBOWL spec):
    Line 1: W (wall budget)
    Line 2: R C (rows, columns)
    Next R lines: grid characters
        # = water, . = grass, H = horse, W = wall
        a = apple, b = bee, c = cherry, p = portal
    Next line: P (number of portal pairs)
    Next P lines: r1 c1 r2 c2 (0-indexed portal pair positions)

API: https://enclose.horse/api/daily/{YYYY-MM-DD}
"""

import json
import sys
import requests
from datetime import date, datetime, timedelta
from pathlib import Path

API_URL = "https://enclose.horse/api/daily/{date}"

# API tile symbols -> assignment format symbols
TILE_MAP = {
    ".": ".",   # grass
    "~": "#",   # water
    "H": "H",   # horse
    "C": "c",   # cherry
    "G": "a",   # golden apple -> apple
    "S": "b",   # skull/bee swarm -> bee
    "W": "W",   # wall
    "#": "#",   # wall -> water (treat as impassable)
}


def fetchPuzzle(puzzleDate: str) -> dict:
    """Fetch puzzle data from the enclose.horse API."""
    url = API_URL.format(date=puzzleDate)
    resp = requests.get(url, timeout=15)
    resp.raise_for_status()
    return resp.json()


def convertToInputFormat(data: dict) -> str:
    """
    Convert API response to the AlgoBOWL assignment input format.
    """
    map_str = data.get("map", "")
    budget = data.get("budget", 0)

    lines = [line for line in map_str.splitlines() if line.strip()]
    rows = len(lines)
    cols = len(lines[0]) if lines else 0

    # First pass: collect portal characters and their positions
    portalChars = {}  # char -> list of (row, col)
    for r, line in enumerate(lines):
        for c, ch in enumerate(line):
            if ch in "0123456789abcdefghijklmnopqrstuvwxyz" and ch not in TILE_MAP:
                portalChars.setdefault(ch, []).append((r, c))

    # Build portal pairs list
    portalPairs = []
    for ch in sorted(portalChars.keys()):
        positions = portalChars[ch]
        if len(positions) == 2:
            r1, c1 = positions[0]
            r2, c2 = positions[1]
            portalPairs.append((r1, c1, r2, c2))
        else:
            print(f"  Warning: portal '{ch}' has {len(positions)} positions (expected 2)")

    # Second pass: build the grid lines
    gridLines = []
    for r, line in enumerate(lines):
        row = []
        for c, ch in enumerate(line):
            if ch in portalChars:
                row.append("p")
            elif ch in TILE_MAP:
                row.append(TILE_MAP[ch])
            else:
                print(f"  Warning: unknown tile '{ch}' at row {r}, col {c} — treating as grass")
                row.append(".")
        gridLines.append("".join(row))

    # Assemble output
    output = []
    output.append(str(budget))
    output.append(f"{rows} {cols}")
    output.extend(gridLines)
    output.append(str(len(portalPairs)))
    for r1, c1, r2, c2 in portalPairs:
        output.append(f"{r1} {c1} {r2} {c2}")

    return "\n".join(output)


def processDate(puzzleDate: str, outputDir: Path) -> Path | None:
    """Fetch a single puzzle and save it. Returns the output path or None on failure."""
    print(f"Fetching puzzle for {puzzleDate}...")
    try:
        data = fetchPuzzle(puzzleDate)
    except requests.HTTPError as e:
        print(f"  ERROR: HTTP {e.response.status_code} — no puzzle found for {puzzleDate}")
        return None
    except requests.RequestException as e:
        print(f"  ERROR: {e}")
        return None

    map_str = data.get("map", "")
    if not map_str:
        print(f"  ERROR: No map data in API response for {puzzleDate}")
        return None

    # Print puzzle metadata
    name = data.get("name", "")
    author = data.get("author", "")
    budget = data.get("budget", "?")
    optimal = data.get("optimalScore", "")
    if name:
        print(f"  Puzzle: {name}" + (f" by {author}" if author else ""))
    print(f"  Budget: {budget} walls")
    if optimal:
        print(f"  Optimal: {optimal}")

    inputText = convertToInputFormat(data)

    # Count grid size from the output
    outputLines = inputText.splitlines()
    dimensions = outputLines[1].split()
    rows, cols = dimensions[0], dimensions[1]
    print(f"  Grid: {rows}x{cols}")

    # Save input file
    filename = f"puzzle_{puzzleDate}.txt"
    filepath = outputDir / filename
    with open(filepath, "w") as f:
        f.write(inputText + "\n")
    print(f"  Saved: {filepath}")

    # Save metadata JSON
    meta = {
        "date": puzzleDate,
        "name": name,
        "author": author,
        "budget": budget,
        "optimal_score": optimal,
        "rows": int(rows),
        "cols": int(cols),
    }
    metadataPath = outputDir / f"puzzle_{puzzleDate}.json"
    with open(metadataPath, "w") as f:
        json.dump(meta, f, indent=2)

    return filepath


def parseDate(s: str) -> date:
    """Parse a YYYY-MM-DD string to a date object."""
    return datetime.strptime(s, "%Y-%m-%d").date()


def main():
    args = sys.argv[1:]
    outputDir = Path("puzzles")
    if "--output-dir" in args:
        idx = args.index("--output-dir")
        outputDir = Path(args[idx + 1])
        args = args[:idx] + args[idx + 2:]

    outputDir.mkdir(parents=True, exist_ok=True)

    if len(args) == 0:
        today = date.today().isoformat()
        processDate(today, outputDir)

    elif len(args) == 1:
        processDate(args[0], outputDir)

    elif len(args) == 2:
        start = parseDate(args[0])
        end = parseDate(args[1])
        if start > end:
            start, end = end, start

        current = start
        count = 0
        while current <= end:
            result = processDate(current.isoformat(), outputDir)
            if result:
                count += 1
            current += timedelta(days=1)
            print()

        print(f"Done — saved {count} puzzle(s).")

    else:
        print("Usage:")
        print("  python enclose_horse_scraper.py                          # Today's puzzle")
        print("  python enclose_horse_scraper.py 2026-03-12               # Specific date")
        print("  python enclose_horse_scraper.py 2025-12-30 2026-03-15    # Date range")
        print("  python enclose_horse_scraper.py --output-dir ./my_puzzles 2026-03-12")


if __name__ == "__main__":
    main()
