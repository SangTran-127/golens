#!/bin/bash
# Usage: layout-loop-check.sh <pid> <start, as YYYY-MM-DD HH:MM:SS>
# Prints how many AppKit layout or update-constraints loop warnings that process logged since start; 0 is the pass.
pid=${1:?usage: layout-loop-check.sh <pid> <start>}
start=${2:?usage: layout-loop-check.sh <pid> <start>}
/usr/bin/log show --style compact --start "$start" --predicate "processID == $pid" 2>/dev/null \
  | grep -cE 'iterations because|needing another Update Constraints|has continued for [0-9]+ iterations'
