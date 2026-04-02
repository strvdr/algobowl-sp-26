#!/bin/bash
clear

cd genetic
zig build -Doptimize=ReleaseFast

cd ..
./genetic/zig-out/bin/algobowl.exe "$1"

# cd ../batch-runner
# python encloseHorseBatchRunner.py --solver ../genetic/zig-out/bin/algobowl.exe --puzzle-dir ../input/input.txt --timeout 120
