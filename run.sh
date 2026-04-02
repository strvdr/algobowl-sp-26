clear

cd genetic
zig build -Doptimize=ReleaseFast

cd ../batch-runner
python encloseHorseBatchRunner.py --solver ../genetic/zig-out/bin/algobowl.exe --puzzle-dir ../puzzles --timeout 120
