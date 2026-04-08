#!/bin/bash
# Eddie Silva

[ "$#" -ne 2 ] && echo "Usage: $0 <inputs_dir> <outputs_dir>" && exit 1

# find the directory where this script lives (Verification/)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Force the report to be saved next to the script
REPORT="$SCRIPT_DIR/results.txt"
> "$REPORT"

shopt -s nullglob

for in_file in "$1"/input_*.txt; do
    base=$(basename "$in_file")
    out_file="$2/puzzle_${base%.txt}_result.txt"

    echo "Verifying $base..."
    echo -e "\n$base" >> "$REPORT"

    if [ -f "$out_file" ]; then
        # Explicitly call verify.py using the script's directory path
        python3 "$SCRIPT_DIR/verify.py" "$in_file" "$out_file" >> "$REPORT" 2>&1
    else
        echo "Missing output file: $out_file" >> "$REPORT"
    fi
done

echo "Done. Check $REPORT"
