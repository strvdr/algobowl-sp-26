#!/bin/bash
# run_verify.sh — Batch-verify all input/output pairs.
#
# Usage: ./run_verify.sh <verify_binary> <input_dir> <output_dir>
#
# Input files:  input_group1200.txt
# Output files: output_from_XXXX_to_1200.txt
#
# The script matches them by the target group number (1200 in both examples).

set -euo pipefail

if [ $# -lt 3 ]; then
    echo "Usage: $0 <verify_binary> <input_dir> <output_dir>"
    echo ""
    echo "  verify_binary  Path to the compiled verify executable"
    echo "  input_dir      Directory containing input_group*.txt files"
    echo "  output_dir     Directory containing output_from_*_to_*.txt files"
    exit 1
fi

VERIFY="$1"
INPUT_DIR="$2"
OUTPUT_DIR="$3"

if [ ! -x "$VERIFY" ]; then
    echo "ERROR: '$VERIFY' is not executable or does not exist."
    exit 1
fi

TOTAL=0
VALID=0
INVALID=0
MISSING=0
ERRORS=0

# Build a lookup: target_group_number -> output_file
declare -A OUTPUT_MAP

for outfile in "$OUTPUT_DIR"/output_from_*_to_*.txt; do
    [ -f "$outfile" ] || continue
    basename=$(basename "$outfile")
    # Extract the target group number (the number after "to_")
    target=$(echo "$basename" | sed -n 's/.*_to_\([0-9]\+\)\.txt/\1/p')
    if [ -n "$target" ]; then
        OUTPUT_MAP["$target"]="$outfile"
    fi
done

# Process each input file
for infile in "$INPUT_DIR"/input_group*.txt; do
    [ -f "$infile" ] || continue
    basename=$(basename "$infile")
    # Extract the group number
    group=$(echo "$basename" | sed -n 's/input_group\([0-9]\+\)\.txt/\1/p')
    if [ -z "$group" ]; then
        continue
    fi

    TOTAL=$((TOTAL + 1))

    outfile="${OUTPUT_MAP[$group]:-}"
    if [ -z "$outfile" ]; then
        echo "[$group] MISSING — no output file found for input_group${group}.txt"
        MISSING=$((MISSING + 1))
        continue
    fi

    # Run the verifier and capture output
    out_basename=$(basename "$outfile")
    result=$("$VERIFY" "$infile" "$outfile" 2>&1) || true

    # Check the RESULT line
    if echo "$result" | grep -q "RESULT: VALID"; then
        # Extract the computed score
        score=$(echo "$result" | grep "Computed score:" | awk '{print $NF}')
        walls=$(echo "$result" | grep "Walls placed:" | awk '{print $NF}')
        budget=$(echo "$result" | grep "Wall budget:" | awk '{print $NF}')
        echo "[$group] VALID   score=$score  walls=$walls/$budget  ($out_basename)"
        VALID=$((VALID + 1))
    elif echo "$result" | grep -q "RESULT: INVALID"; then
        echo "[$group] INVALID ($out_basename)"
        # Print the error lines indented
        echo "$result" | grep "^ERROR:" | sed 's/^/         /'
        INVALID=$((INVALID + 1))
    else
        echo "[$group] ERROR   verifier failed ($out_basename)"
        echo "$result" | head -5 | sed 's/^/         /'
        ERRORS=$((ERRORS + 1))
    fi
done

# Summary
echo ""
echo "==============================="
echo "  Batch Verification Summary"
echo "==============================="
echo "  Total inputs:  $TOTAL"
echo "  Valid:         $VALID"
echo "  Invalid:       $INVALID"
echo "  Missing output:$MISSING"
echo "  Verifier error:$ERRORS"
echo "==============================="

if [ $INVALID -gt 0 ] || [ $ERRORS -gt 0 ]; then
    exit 1
fi
