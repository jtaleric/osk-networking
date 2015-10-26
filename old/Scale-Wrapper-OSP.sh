#!/bin/bash

NUM=25

pstat_host1="pcloud16"
pstat_host2="pcloud15"

FOLDER=OSP-NetworkScale-Output_$(date +%Y_%m_%d_%H_%M_%S)

mkdir $FOLDER

for i in $(seq 1 ${NUM}) ; do 
 echo " Launching OSP Network Perf "
 $(./Scale-OSP-Network-Perf.sh run-out-$i $FOLDER > $FOLDER/run-out-$i 2>&1 & ); 
done

while true; do 
 if [[ -z `ps aux | grep "Scale-OSP" | grep -qv grep` ]]; then
  break;
 fi
 sleep 6; 
done

echo "Killing PStat"
ssh -o "StrictHostKeyChecking no" -q -t $pstat_host1 "kill -9 `pidof -x pstat.sh` ; killall -q -9 turbostat mpstat iostat sosreport"
ssh -o "StrictHostKeyChecking no" -q -t $pstat_host2 "kill -9 `pidof -x pstat.sh` ; killall -q -9 turbostat mpstat iostat sosreport"
