#!/bin/bash
clear

if [ -z "$1" ]; then
    echo "Usage: $0 <file_path_or_directory_path>"
    exit 1
fi

TARGET="$1"

cd genetic || exit 1
zig build -Doptimize=ReleaseFast
cd .. || exit 1

EXECUTABLE="./genetic/zig-out/bin/algobowl.exe"

if [ ! -x "$EXECUTABLE" ]; then
    echo "Error: Executable not found at $EXECUTABLE"
    exit 1
fi

if [ -f "$TARGET" ]; then
    "$EXECUTABLE" "$TARGET"
elif [ -d "$TARGET" ]; then
    for file in "$TARGET"/*; do
        if [ -f "$file" ]; then
            echo "Running algobowl.exe on: $file"
            "$EXECUTABLE" "$file"
        fi
    done
else
    echo "Error: '$TARGET' is not a valid file or directory."
    exit 1
fi
