#!/bin/bash
# Eddie Silva

[ "$#" -ne 2 ] && echo "Usage: $0 <single_input_file> <outputs_dir>" && exit 1

IN_FILE="$1"
OUT_DIR="$2"

[ ! -f "$IN_FILE" ] && echo "Error: Input '$IN_FILE' not found." && exit 1
[ ! -d "$OUT_DIR" ] && echo "Error: Directory '$OUT_DIR' not found." && exit 1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPORT="$SCRIPT_DIR/results.txt"

# Initialize report
> "$REPORT"

shopt -s nullglob

# Loop through every text file in the outputs directory
for out_file in "$OUT_DIR"/*.txt; do
    base_out=$(basename "$out_file")

    echo "Verifying $base_out..."
    echo -e "\n--- $base_out ---" >> "$REPORT"

    # Run Python with the single input file and the current output file
    python3 "$SCRIPT_DIR/verify.py" "$IN_FILE" "$out_file" >> "$REPORT" 2>&1
done

echo "Done. Check $REPORT"
