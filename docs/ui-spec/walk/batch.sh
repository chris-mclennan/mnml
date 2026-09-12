#!/bin/bash
# batch.sh JOBS_FILE — lines: NAME SIZE INPUT [FRESH]; 4 sequential queues, one per slot
cd /private/tmp/walk
rm -f q1 q2 q3 q4
i=0
while read -r name size input fresh; do
  [ -n "$name" ] || continue
  q=$(( i % 4 + 1 )); i=$((i+1))
  echo "$name $size $input ${fresh:-0}" >> q$q
done < "$1"
for q in 1 2 3 4; do
  [ -f q$q ] || continue
  ( while read -r name size input fresh; do
      FRESH=$fresh ./run.sh $q $name $size $input > out/log-$name-$size-$input-$fresh.txt 2>&1
      echo "done q$q $name $size $input $fresh"
    done < q$q ) &
done
wait
echo ALL DONE
