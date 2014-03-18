#!/bin/bash

NUM=30

pstat_host1="pcloud16"
pstat_host2="pcloud15"

FOLDER=OSP-NetworkScale-Output_$(date +%Y_%m_%d_%H_%M_%S)

mkdir $FOLDER

for i in $(seq 1 ${NUM}) ; do 
 echo "Run $i"
 echo "Launching OSP MultiNetwork Perf"
 $(./Scale-OSP-MultiNetwork-Perf.sh $i $FOLDER > $FOLDER/run-out-$i 2>&1 & ); 
# sleep 20
done

sleep 5

while true; do 
 if [[ -z $(ps aux | grep "Scale-OSP" | grep -v "grep")  ]]; then
  break;
 fi
 sleep 6; 
done

echo "Killing PStat"
ssh -o "StrictHostKeyChecking no" -q -t $pstat_host1 "kill -9 `pgrep pstat` ; killall -q -9 turbostat mpstat iostat sosreport"
ssh -o "StrictHostKeyChecking no" -q -t $pstat_host2 "kill -9 `pgrep pstat` ; killall -q -9 turbostat mpstat iostat sosreport"
