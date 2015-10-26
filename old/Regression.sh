#!/bin/bash

# Keystone auth
source ~/keystonerc_admin
FOLDER=OSP-NetworkScale-Regression-Output_$(date +%Y_%m_%d_%H_%M_%S)
mkdir -p $FOLDER

pstat_host1="pcloud18"
pstat_host2="pcloud15"

SINGLE=false
MULTI=true
TEN=false

if $SINGLE ; then
 mkdir -p $FOLDER/single
 echo Running Single netperf test....
 # Run netperf between a single set of guests
 ./Scale-OSP-MultiNetwork-Perf.sh 1 $FOLDER/single single > $FOLDER/single/run-single-out 2>&1  
 sleep 30

echo "Killing PStat"
ssh -o "StrictHostKeyChecking no" -q -t $pstat_host1 "kill -9 `pidof -x pstat.sh` ; killall -9 pstat.sh ; killall -q -9 turbostat mpstat iostat sosreport"
ssh -o "StrictHostKeyChecking no" -q -t $pstat_host2 "kill -9 `pidof -x pstat.sh` ; killall -9 pstat.sh; killall -q -9 turbostat mpstat iostat sosreport"

 mkdir -p $FOLDER/super
 echo Running Single super_netperf test....
 # Run super_netperf between a single set of guests
 ./Scale-OSP-SuperMultiNetwork.sh 1 $FOLDER/super super > $FOLDER/super/run-Super-out 2>&1 
 sleep 30

echo "Killing PStat"
ssh -o "StrictHostKeyChecking no" -q -t $pstat_host1 "kill -9 `pidof -x pstat.sh` ; killall -9 pstat.sh ; killall -q -9 turbostat mpstat iostat sosreport"
ssh -o "StrictHostKeyChecking no" -q -t $pstat_host2 "kill -9 `pidof -x pstat.sh` ; killall -9 pstat.sh; killall -q -9 turbostat mpstat iostat sosreport"

fi

if $MULTI ; then
 
 if $TEN ; then
 echo Running 5 netperf tests....
 mkdir -p $FOLDER/five
 # Run netperf between a set of 5 guests
 for i in $(seq 1 5) ; do
  ./Scale-OSP-MultiNetwork-Perf.sh $i $FOLDER/five 5Guests > $FOLDER/five/run-5-out-$i 2>&1 &
 done 
 sleep 120 
 while [ `nova list | grep net | wc -l` -gt 0 ] ; do
   sleep 5
 done
 sleep 30

echo "Killing PStat"
ssh -o "StrictHostKeyChecking no" -q -t $pstat_host1 "kill -9 `pidof -x pstat.sh` ; killall -9 pstat.sh ; killall -q -9 turbostat mpstat iostat sosreport"
ssh -o "StrictHostKeyChecking no" -q -t $pstat_host2 "kill -9 `pidof -x pstat.sh` ; killall -9 pstat.sh; killall -q -9 turbostat mpstat iostat sosreport"

 echo Running 10 netperf tests....
 mkdir -p $FOLDER/ten
 # Run netperf between a set of 10 guests
 for i in $(seq 1 10) ; do
  ./Scale-OSP-MultiNetwork-Perf.sh $i $FOLDER/ten 10Guests > $FOLDER/ten/run-10-out-$i 2>&1 & 
 done 
 sleep 120 
 while [ `nova list | grep net | wc -l` -gt 0 ] ; do
  sleep 5
 done
 sleep 30

fi

echo "Killing PStat"
ssh -o "StrictHostKeyChecking no" -q -t $pstat_host1 "kill -9 `pidof -x pstat.sh` ; killall -9 pstat.sh ; killall -q -9 turbostat mpstat iostat sosreport"
ssh -o "StrictHostKeyChecking no" -q -t $pstat_host2 "kill -9 `pidof -x pstat.sh` ; killall -9 pstat.sh; killall -q -9 turbostat mpstat iostat sosreport"

 echo Running 20 netperf tests....
 mkdir -p $FOLDER/twenty
 # Run netperf between a set of 20 guests
 for i in $(seq 1 20) ; do
  ./Scale-OSP-MultiNetwork-Perf.sh $i $FOLDER/twenty 20Guests > $FOLDER/twenty/run-20-out-$i 2>&1 & 
 done 

echo "Killing PStat"
ssh -o "StrictHostKeyChecking no" -q -t $pstat_host1 "kill -9 `pidof -x pstat.sh` ; killall -9 pstat.sh ; killall -q -9 turbostat mpstat iostat sosreport"
ssh -o "StrictHostKeyChecking no" -q -t $pstat_host2 "kill -9 `pidof -x pstat.sh` ; killall -9 pstat.sh; killall -q -9 turbostat mpstat iostat sosreport"
fi
