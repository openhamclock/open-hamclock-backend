#!/usr/bin/env bash

DIR=${1:-/opt/maps}

declare -A seen

# Gather what exists
while read -r f; do
  base=$(basename "$f")

  if [[ $base =~ map-([DN])-([0-9]+x[0-9]+)-(Countries|Terrain|Physical)\.bmp(\.z)? ]]; then
    DORN=${BASH_REMATCH[1]}
    RES=${BASH_REMATCH[2]}
    TYPE=${BASH_REMATCH[3]}
    key="$RES:$DORN:$TYPE"
    seen["$key"]=1
  fi
done < <(find "$DIR" -type f)

# Collect all resolutions observed
resolutions=$(printf "%s\n" "${!seen[@]}" | cut -d: -f1 | sort -u)

missing=0

for r in $resolutions; do
  for dn in D N; do
    for t in Countries Terrain Physical; do
      k="$r:$dn:$t"
      if [[ -z "${seen[$k]}" ]]; then
        echo "MISSING: map-$dn-$r-$t"
        missing=1
      fi
    done
  done
done

if [[ $missing -eq 0 ]]; then
  echo "Inventory OK — no missing assets."
fi
