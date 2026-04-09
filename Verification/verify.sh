#!/bin/bash
# Eddie Silva

clear

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <input_file|input_dir> <output_file|output_dir>"
    exit 1
fi

IN_FILE="$1"
OUT_DIR="$2"

if [ ! -e "$IN_FILE" ]; then
    echo "Error: Input '$IN_FILE' not found."
    exit 1
fi

if [ ! -e "$OUT_DIR" ]; then
    echo "Error: Output '$OUT_DIR' not found."
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPORT="$SCRIPT_DIR/results.txt"

# Initialize report
: > "$REPORT"

shopt -s nullglob

verify_pair() {
    local input_file="$1"
    local output_file="$2"
    local base_in
    local base_out

    base_in=$(basename "$input_file")
    base_out=$(basename "$output_file")

    echo -e "\n$base_in -> $base_out"
    echo -e "\n$base_out:" >> "$REPORT"

    python3 "$SCRIPT_DIR/verify.py" "$input_file" "$output_file" >> "$REPORT" 2>&1
}

find_matching_output() {
    local input_file="$1"
    local output_dir="$2"
    local input_base
    local input_stem
    local group_num
    local candidate

    input_base=$(basename "$input_file")
    input_stem="${input_base%.txt}"

    if [ -f "$output_dir/$input_base" ]; then
        echo "$output_dir/$input_base"
        return 0
    fi

    # Extract group number from input file (e.g., 1161 from input_group1161)
    group_num="${input_stem##*group}"

    # Remove trailing slash from output_dir if present for glob matching
    output_dir="${output_dir%/}"

    # Look for output file with pattern output_from_*_to_<group_num>
    for candidate in $output_dir/output_from_*_to_${group_num}.txt; do
        [ -e "$candidate" ] || continue
        echo "$candidate"
        return 0
    done

    # Fallback to old naming convention
    for candidate in "$output_dir"/*.txt; do
        [ -e "$candidate" ] || continue
        case "$(basename "$candidate")" in
            *"$input_stem"*)
                echo "$candidate"
                return 0
                ;;
        esac
    done

    return 1
}

if [ -f "$IN_FILE" ] && [ -f "$OUT_DIR" ]; then
    verify_pair "$IN_FILE" "$OUT_DIR"
elif [ -f "$IN_FILE" ] && [ -d "$OUT_DIR" ]; then
    out_file=$(find_matching_output "$IN_FILE" "$OUT_DIR") || true
    if [ -z "$out_file" ]; then
        echo "Missing output for $(basename "$IN_FILE")"
        echo -e "\n$(basename "$IN_FILE")" >> "$REPORT"
        echo "Error: No matching output found in '$OUT_DIR'." >> "$REPORT"
    else
        verify_pair "$IN_FILE" "$out_file"
    fi
elif [ -d "$IN_FILE" ] && [ -f "$OUT_DIR" ]; then
    for in_file in "$IN_FILE"/*.txt; do
        verify_pair "$in_file" "$OUT_DIR"
    done
elif [ -d "$IN_FILE" ] && [ -d "$OUT_DIR" ]; then
    for in_file in "$IN_FILE"/*.txt; do
        base_in=$(basename "$in_file")
        out_file=$(find_matching_output "$in_file" "$OUT_DIR") || true

        if [ -z "$out_file" ]; then
            echo "Missing output for $base_in"
            echo -e "\n$base_in" >> "$REPORT"
            echo "Error: No matching output found in '$OUT_DIR'." >> "$REPORT"
            continue
        fi

        verify_pair "$in_file" "$out_file"
    done
else
    echo "Error: Use either files or directories for both arguments."
    exit 1
fi

echo "Done. Check $REPORT"
