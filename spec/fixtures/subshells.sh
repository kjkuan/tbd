#!/usr/bin/env bash
source tbd.sh
for i in 1 2 3; do x=$(echo "s$i"); done
echo "$x" | cat
y=$(echo inner)
echo "y=$y"
