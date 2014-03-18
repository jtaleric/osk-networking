#!/bin/bash

#-------------------------------------------------------------------------------
# OSP-Network-Perf.sh
#
#
# -- To do --
# Currently now VLAN testing... This assumes there is a br-tun bridge
#
# -- Updates --
# 02/20/14 - Working on Scale 
# 11/13/13 - Create a new security group, then remove it for the cleanup
# 11/12/13 - Added code to allow multiple launches of this script
# 11/11/13 - First drop
# @author Joe Talerico (jtaleric@redhat.com)
#-------------------------------------------------------------------------------

if [ -n $1 ] ; then 
 echo Run : $1
fi

FOLDER=OSP-NetworkScale-Output_$(date +%Y_%m_%d_%H_%M_%S)
if [ -n $2 ] ; then 
 FOLDER=$2
fi

#-------------------------------------------------------------------------------
# Folder where to store the the results of netperf and the output of 
# the OSP Script.
#-------------------------------------------------------------------------------
mkdir -p $FOLDER

#-------------------------------------------------------------------------------
#
# Must modify to fit the enviorment...
#
# !! Do not overlap networks or use a existing network, must be new !!
# !! This Script will create the networks, and remove them for cleanup !!
#
#-------------------------------------------------------------------------------
KEYSTONE_ADMIN="/root/keystonerc_admin"
#----------------------- Image and flavor size ---------------------------------
NETPERF_IMG_NAME="netperf-test-cloudinit"
NETPERF_IMG="/home/netperf-nocloudinit-centos.qcow2"
GUEST_SIZE="m1.small"
#----------------------- Netperf values ----------------------------------------
NETPERF_LENGTH=60
TCP_STREAM=true
UDP_STREAM=true
PSTAT=false
#-------------------------------------------------------------------------------
# Set this to true if tunnels are used, set to false if VLANs are used.
#
# !! If VLANs are used, the user must setup the flows and veth before running !!
#-------------------------------------------------------------------------------
TUNNEL=true
#----------------------- Array to hold guest ID --------------------------------
declare -A GUESTS
#-------------------------------------------------------------------------------
# Clean will remove Network and Guest information
#-------------------------------------------------------------------------------
CLEAN=true
#-------------------------------------------------------------------------------
# CLEAN_IMAGE will remove the netperf-networktest image from glance
#-------------------------------------------------------------------------------
CLEAN_IMAGE=false
#----------------------- Hosts to Launch Guests  -------------------------------
ZONE[0]="nova:pcloud16.perf.lab.eng.bos.redhat.com"
ZONE[1]="nova:pcloud16.perf.lab.eng.bos.redhat.com"
# Run PStat
pstat_host1="pcloud16.perf.lab.eng.bos.redhat.com"
pstat_host2="pcloud15.perf.lab.eng.bos.redhat.com"
#----------------------- Network -----------------------------------------------
TUNNEL_NIC="p3p1"
TUNNEL_SPEED=`ethtool ${TUNNEL_NIC} | grep Speed | sed 's/\sSpeed: \(.*\)Mb\/s/\1/'`
TUNNEL_TYPE=`ovs-vsctl show | grep -E 'Port.*gre|vxlan|stt*'`
NETWORK="10Net"
SUBNET="10.0.0.0/24"
MTU=1500
SSHKEY="/root/.ssh/id_rsa.pub"
SINGLE_TUNNEL_TEST=true
#----------------------- No Code.... yet. --------------------------------------
MULTI_TUNNEL_TEST=false
#----------------------- Need to determine how to tell ( ethtool? STT ) --------
HARDWARE_OFFLOAD=false 
#----------------------- Is Jumbo Frames enabled throughout? -------------------
JUMBO=false
DEBUG=true

#-------------------------------------------------------------------------------
# Params to set the guest MTU lower to account for tunnel overhead
# or if JUMBO is enabled to increase MTU
#-------------------------------------------------------------------------------
if $TUNNEL ; then
 MTU=1450
 if $JUMBO ; then
  MTU=1500
 fi
fi

#-------------------------------------------------------------------------------
# NETPERF["Message Size"]="Expected % of NIC"
#
# Breaking down "Expected % of NIC"
#  NETPERF[16384]="40,60,80"
#                 TCP,UDP,Hardware Offload
# If Netperf reports < the Expected % of NIC the test case will be reported as
# a FAIL. Anything >= will report as PASS
#-------------------------------------------------------------------------------
declare -A NETPERF
NETPERF[8]="1,.1"
NETPERF[16]="2,.3"
#NETPERF[32]="5,.7"
#NETPERF[64]="8,1"
#NETPERF[128]="13,2"
#NETPERF[256]="15,5"
#NETPERF[512]="15,11"
NETPERF[1024]="15,20"
#NETPERF[2048]="15,25"
NETPERF[4096]="15,39"
NETPERF[8192]="15,55"
NETPERF[16384]="15,55"
NETPERF[32768]="15,60"
NETPERF[65500]="15,60"

#-------------------------------------------------------------------------------
# Must have admin rights to run this...
#-------------------------------------------------------------------------------
if [ -f $KEYSTONE_ADMIN ]; then
 source $KEYSTONE_ADMIN 
else 
 echo "ERROR :: Unable to source keystone_admin file"
 exit 1
fi

if ! [ -f $NETPERF_IMG ]; then 
 echo "ERROR :: Unable to find the Netperf image"
 exit 1
fi

#-------------------------------------------------------------------------------
# cleanup()
#  
#
#
#
#-------------------------------------------------------------------------------
cleanup() {
 echo "#-------------------------------------------------------------------------------"
 echo "Cleaning up...."
 echo "#-------------------------------------------------------------------------------"
 if [ -n "$search_string" ] ; then
  echo "Cleaning netperf Guests"
  for key in ${search_string/|/ } 
  do 
   key=${key%"|"}
   echo "Removing $key...."
   nova delete $key
  done
 fi

#-------------------------------------------------------------------------------
# Is Nova done deleting?
#-------------------------------------------------------------------------------
  while true; 
  do
   glist=`nova list | grep -E ${search_string%?} | awk '{print $2}'` 
   if [ -z "$glist" ] ; then
    break
   fi
   sleep 5
  done

#-------------------------------------------------------------------------------
# Remove test Networks
#-------------------------------------------------------------------------------
 nlist=$(neutron subnet-list | grep "${SUBNET}" | awk '{print $2}') 
 if ! [ -z "$nlist" ] ; then 
  echo "Cleaning test networks..."
  neutron subnet-delete $(neutron subnet-list | grep "${SUBNET}" | awk '{print $2}')
  neutron net-delete $NETWORK
 fi

 if $CLEAN_IMAGE ; then
  ilist=$(glance image-list | grep netperf | awk '{print $2}')
  if ! [ -z "$ilist" ] ; then
   echo "Cleaning Glance..."
   yes | glance image-delete $ilist
  fi
 fi 

} #END cleanup

if [ -z "$(neutron net-list | grep "${NETWORK}")" ]; then 
#----------------------- Create Subnet  ----------------------------------------
 echo "#-------------------------------------------------------------------------------"
 echo "Creating Subnets "
 echo "#-------------------------------------------------------------------------------"
 neutron net-create $NETWORK 
 neutron subnet-create $NETWORK $SUBNET 
 neutron net-show $NETWORK 
fi 

if [ -z "$(glance image-list | grep -E "${NETPERF_IMG_NAME}")" ]; then
 #----------------------- Import image into Glance ------------------------------
 echo "#------------------------------------------------------------------------------- "
 echo "Importing Netperf image into Glance"
 echo "#-------------------------------------------------------------------------------"
 IMAGE_ID=$(glance image-create --name ${NETPERF_IMG_NAME} --disk-format=qcow2 --container-format=bare < ${NETPERF_IMG} | grep id | awk '{print $4}')
else 
 IMAGE_ID=$(glance image-list | grep -E "${NETPERF_IMG_NAME}" | awk '{print $2}')
fi

if [ -z "$(nova keypair-list | grep "network-testkey")" ]; then 
#----------------------- Security Groups ---------------------------------------
 echo "#------------------------------------------------------------------------------- "
 echo "Adding SSH Key"
 echo "#-------------------------------------------------------------------------------"
 if [ -f $SSHKEY ]; then
  nova keypair-add --pub_key ${SSHKEY} network-testkey
 else 
  echo "ERROR :: SSH public key not found"
  exit 1
 fi
fi

if [ -z "$(nova secgroup-list | egrep -E "netperf-networktest")" ] ; then
 echo "#------------------------------------------------------------------------------- "
 echo "Adding Security Rules"
 echo "#-------------------------------------------------------------------------------"
 nova secgroup-create netperf-networktest "network test sec group"
 nova secgroup-add-rule netperf-networktest tcp 22 22 0.0.0.0/0
 nova secgroup-add-rule netperf-networktest icmp -1 -1 0.0.0.0/0
fi

#----------------------- Launch Instances --------------------------------------
echo "#------------------------------------------------------------------------------- "
echo "Launching netperf instnaces"
echo "#-------------------------------------------------------------------------------"
echo "Launching Instances, $(date)"
search_string=""
for host_zone in "${ZONE[@]}"
do
  echo "Launching instnace on $host_zone"
  command_out=$(nova boot --image ${IMAGE_ID} --flavor ${GUEST_SIZE} --availability-zone ${host_zone} netperf-${host_zone} --key_name network-testkey --security_group default,netperf-networktest | egrep "\sid\s" | awk '{print $4}')
  search_string+="$command_out|"
done

#-------------------------------------------------------------------------------
# Give instances time to get Spawn/Run
# This could vary based on Disk and Network (Glance transfering image)
#-------------------------------------------------------------------------------
echo "#------------------------------------------------------------------------------- "
echo "Waiting for Instances to begin Running"
echo "#-------------------------------------------------------------------------------"
if $DEBUG ; then 
echo "#----------------------- Debug -------------------------------------------------"
echo $search_string
echo "#-------------------------------------------------------------------------------"
fi
while true; do 
 if ! [ -z "$(nova list | egrep -E "${search_string%?}" | egrep -E "ERROR")" ]; then 
  echo "ERROR :: Netperf guest in error state, Compute node issue"
  if $CLEAN ; then
   cleanup
  fi
  exit 1
 fi
#-------------------------------------------------------------------------------
# This is assuming the SINGLE_TUNNEL_TEST
#-------------------------------------------------------------------------------
 if  [ "$(nova list | egrep -E "${search_string%?}" | egrep -E "Running" | wc -l)" -gt 1 ]; then 
  break
 fi
done

if [ -z "$(ip link | grep veth3)" ]; then
 echo "#------------------------------------------------------------------------------- "
 echo "Adding a veth"
 echo "#-------------------------------------------------------------------------------"
 if [ -z "$(ip link | grep -R "veth3\|veth4")" ] ; then 
  ip link add name veth3 type veth peer name veth4
 fi
 ifconfig veth3 10.0.0.150/24
 ifconfig veth3 up
 ifconfig veth4 up
fi
if $TUNNEL ; then 
 if ! [ -z "$(ovs-vsctl show | grep "Port \"veth4\"")" ] ; then
  ovs-vsctl del-port veth4
 fi
fi
if $TUNNEL ; then 
 VETH_MAC=`ip link | grep -A 1 veth3 | grep link | awk '{ print $2 }'`
 VLAN=`ovs-ofctl dump-flows br-tun table=21 | egrep -o 'dl_vlan=(.*)\s' | sed -rn 's/dl_vlan=//p'`
 ovs-vsctl add-port br-int veth4 tag=${VLAN}
 ovs-ofctl add-flow br-tun "priority=3,tun_id=0x1,dl_dst=${VETH_MAC},actions=mod_vlan_vid:${VLAN},NORMAL"
fi
echo "#------------------------------------------------------------------------------- "
echo "Waiting for instances to come online"
echo "#-------------------------------------------------------------------------------"
INSTANCES=($(nova list | grep -E "${search_string%?}" | egrep -E "Running|spawning" | egrep -oe '([0-9]{1,3}\.[0-9]{1,3}\.[0-9}{1,3}\.[0-9]+)'))
#-------------------------------------------------------------------------------
# Single Tunnel Test -
#       1. Launch a instance on each side of a GRE/VXLAN/STT Tunnel. 
#       2. Make sure there is connectivity from the Host to the guests via Ping
#       3. Attempt to Login to the Guest via SSH 
#-------------------------------------------------------------------------------
if $SINGLE_TUNNEL_TEST ; then 
 ALIVE=0
 NETSERVER=0
 NETCLIENT=0
 for instance in ${INSTANCES[@]}; do 
  TRY=0
  if [ "$NETSERVER" == "0" ] ; then
   NETSERVER=$instance
  else 
   NETCLIENT=$instance
  fi
  while [ "$TRY" -lt "10" ] ; do
   REPLY=`ping $instance -c 5 | grep received | awk '{print $4}'`
   if [ "$REPLY" != "0" ]; then
    let ALIVE=ALIVE+1
    echo "Instance ${instance} is network reachable, $(date)"
    break
   fi
   sleep 5
   let TRY=TRY+1
  done
 done

#-------------------------------------------------------------------------------
# Check to see if instances became pingable
#-------------------------------------------------------------------------------
 if [ $ALIVE -lt 2 ] ; then 
  echo "ERROR :: Unable to reach one of the guests..."
  if $CLEAN ; then
   cleanup
  fi
  exit 1
 fi

 ssh -o "StrictHostKeyChecking no" -q -t ${NETSERVER} "ifconfig eth0 mtu ${MTU}" 
 ssh -o "StrictHostKeyChecking no" -q -t ${NETCLIENT} "ifconfig eth0 mtu ${MTU}" 
 ssh -o "StrictHostKeyChecking no" -q -t ${NETSERVER} 'netserver ; sleep 2'

 if $JUMBO ; then
  sleep 120
 fi

if $PSTAT ; then
 echo "Checking if PStat is running already, if not, start PStat on the Hosts (currently 2 Hosts)"
 if [[ -z $(ssh -q -t $pstat_host1 "ps aux | grep [p]stat") ]]; then
   echo "Start PStat on $pstat_host1"
   ssh -o "StrictHostKeyChecking no" $pstat_host1 "/opt/perf-dept/pstat/pstat.sh 1 OSP-PSTAT & 2>&1 > /dev/null" & 2>&1 > /dev/null 
 fi 
 if [[ -z $(ssh -q -t $pstat_host2 "ps aux | grep [p]stat") ]]; then
   echo "Start PStat on $pstat_host2"
   ssh -o "StrictHostKeyChecking no" $pstat_host2 "/opt/perf-dept/pstat/pstat.sh 1 OSP-PSTAT & 2>&1 > /dev/null" & 2>&1 > /dev/null 
 fi 
fi

#-------------------------------------------------------------------------------
# TCP_STREAM Test -
#  Run Netperf TCP_STREAM test from one Host to the other over the Tunnel.
#
#  Breaking down "Expected % of NIC"
#   NETPERF[16384]="40,60,80"
#                 TCP,UDP,Hardware Offload
#-------------------------------------------------------------------------------
 if $TCP_STREAM ; then
  echo "#------------------------------------------------------------------------------- "
  echo "BEGIN TCP_STREAM Test"
  echo "#-------------------------------------------------------------------------------"
  echo "Message Size, Test Status, Tunnel Speed, Throughput, Expected % of Tunnel"
  date_file=$(date +"%d_%m_%y_%H%M%S")
  for msg_size in ${!NETPERF[@]}
  do
   out=`ssh -o "StrictHostKeyChecking no" -q -t ${NETCLIENT} "netperf -4 -H ${NETSERVER} -l ${NETPERF_LENGTH} -T1,1 -l 30 -- -m ${msg_size}" | tee -a $FOLDER/$1-$date_file-TCP_STREAM`
   if $DEBUG ; then 
     echo $out
   fi
   throughput=`echo "${out}"| grep "$msg_size"| awk '{print $5}'| sed -e 's/ /,/g'`
   percent=`perl -e "print ${throughput}/${TUNNEL_SPEED}*100"`
#-------------------------------------------------------------------------------
# 1 = TCP, 2 = UDP, 3 = Hardware offload
#-------------------------------------------------------------------------------
   expected_percent=`echo "${NETPERF[$msg_size]}" | cut -d , -f 1`
   perl -e "if(${percent} >= ${expected_percent}) { exit 1 }"
   if [ $? -eq 0 ]; then
    echo "$msg_size, FAILED, ${TUNNEL_SPEED}, $throughput, ${expected_percent}"
   else 
    echo "$msg_size, PASSED, ${TUNNEL_SPEED}, $throughput, ${expected_percent}"
   fi
  done
  echo "#------------------------------------------------------------------------------- "
  echo "END TCP_STREAM Test"
  echo "#-------------------------------------------------------------------------------"
 fi
 if $UDP_STREAM ; then
  echo "#------------------------------------------------------------------------------- "
  echo "BEGIN UDP_STREAM Test"
  echo "#-------------------------------------------------------------------------------"
  echo "Message Size, Test Status, Tunnel Speed, Throughput, Expected % of Tunnel"
  date_file=$(date +"%d_%m_%y_%H%M%S")
  for msg_size in ${!NETPERF[@]}
  do
   out=`ssh -o "StrictHostKeyChecking no" -q -t ${NETCLIENT} "netperf -4 -H ${NETSERVER} -l ${NETPERF_LENGTH} -t UDP_STREAM -T1,1 -l 30 -- -m ${msg_size}" | tee -a $FOLDER/$1-$date_file-UDP_STREAM`
   throughput=`echo "${out}"| grep "$msg_size"| awk '{print $6}'| sed -e 's/ /,/g'`
   percent=`perl -e "print ${throughput}/${TUNNEL_SPEED}*100"`
#-------------------------------------------------------------------------------
# 1 = TCP, 2 = UDP, 3 = Hardware offload
#-------------------------------------------------------------------------------
   expected_percent=`echo "${NETPERF[$msg_size]}" | cut -d , -f 1`
   perl -e "if(${percent} >= ${expected_percent}) { exit 1 }"
   if [ $? -eq 0 ]; then
    echo "$msg_size, FAILED, ${TUNNEL_SPEED}, $throughput, ${expected_percent}"
   else 
    echo "$msg_size, PASSED, ${TUNNEL_SPEED}, $throughput, ${expected_percent}"
   fi
  done
  echo "#------------------------------------------------------------------------------- "
  echo "END UDP_STREAM Test"
  echo "#-------------------------------------------------------------------------------"
  fi


#-------------------------------------------------------------------------------
# UDP_STREAM Test -
#  Run Netperf UDP_STREAM test from one Host to the other over the Tunnel.
#-------------------------------------------------------------------------------
fi # End SINGLE_TUNNEL_TEST

#----------------------- Cleanup -----------------------------------------------
if $CLEAN ; then
 cleanup
fi
