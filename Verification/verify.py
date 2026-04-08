"""
Algobowl output verification script
Author: Eddie Silva

Usage:
	- ./verify.sh <input> <output>
	- py verify.py <input> <output>
"""

import sys
from pathlib import Path
from collections import deque

def parse_input(file_path):
    with file_path.open('r') as f:
        lines = [line.strip() for line in f if line.strip()]

    W_budget = int(lines[0])
    R, C = map(int, lines[1].split())

    grid = []
    for i in range(2, 2 + R):
        grid.append(list(lines[i]))

    P = int(lines[2 + R])
    portals = {}
    portal_lines_start = 3 + R
    for i in range(portal_lines_start, portal_lines_start + P):
        r1, c1, r2, c2 = map(int, lines[i].split())
        portals[(r1, c1)] = (r2, c2)
        portals[(r2, c2)] = (r1, c1)

    return W_budget, R, C, grid, portals

def parse_output(file_path, R):
    with file_path.open('r') as f:
        lines = [line.strip() for line in f if line.strip()]

    reported_score = int(lines[0])
    grid = []
    for i in range(1, 1 + R):
        grid.append(list(lines[i]))

    return reported_score, grid

def verify(input_file, output_file):
    W_budget, R, C, in_grid, portals = parse_input(input_file)
    reported_score, out_grid = parse_output(output_file, R)

    # Dimension Validation
    if len(out_grid) != R or any(len(row) != C for row in out_grid):
        print("Error: Output grid dimensions do not match input.")
        return False

    # Tile Modification and Wall Budget Validation
    walls_used = 0
    start = None

    for r in range(R):
        for c in range(C):
            in_char = in_grid[r][c]
            out_char = out_grid[r][c]

            if out_char == 'W':
                walls_used += 1
            if out_char == 'H':
                start = (r, c)

            if in_char != out_char:
                if not (in_char in ['.', 'W'] and out_char in ['.', 'W']):
                    print(f"Error: Invalid tile modification at ({r}, {c}). Changed '{in_char}' to '{out_char}'.")
                    return False

    if walls_used > W_budget:
        print(f"Error: Wall budget exceeded. Used {walls_used}, Budget {W_budget}.")
        return False

    if not start:
        print("Error: Horse 'H' missing from output grid.")
        return False

    # BFS Traversal for Perimeter Check and Scoring
    score_map = {'.': 1, 'H': 1, 'p': 1, 'a': 11, 'b': -4, 'c': 4}
    q = deque([start])
    visited = {start}
    calculated_score = 0
    escaped = False

    while q:
        r, c = q.popleft()
        calculated_score += score_map.get(out_grid[r][c], 0)

        # Perimeter Escape Condition
        if r == 0 or r == R - 1 or c == 0 or c == C - 1:
            escaped = True

        # Standard 4-Way Neighbors
        for dr, dc in [(-1, 0), (1, 0), (0, -1), (0, 1)]:
            nr, nc = r + dr, c + dc
            if 0 <= nr < R and 0 <= nc < C:
                if out_grid[nr][nc] not in ['#', 'W'] and (nr, nc) not in visited:
                    visited.add((nr, nc))
                    q.append((nr, nc))

        # Portal Jump
        if (r, c) in portals:
            pr, pc = portals[(r, c)]
            if (pr, pc) not in visited:
                visited.add((pr, pc))
                q.append((pr, pc))

    if escaped:
        print("Verdict: INVALID (Horse escaped to perimeter)")
    elif calculated_score != reported_score:
        print(f"Verdict: INVALID (Score mismatch. Reported: {reported_score}, Calculated: {calculated_score})")
    else:
        print(f"Verdict: VALID (Enclosed successfully. Score: {calculated_score}, Walls Used: {walls_used}/{W_budget})")

    return not escaped and calculated_score == reported_score

if __name__ == "__main__":

    input_path, output_path = Path(sys.argv[1]), Path(sys.argv[2])

    verify(input_path, output_path)
