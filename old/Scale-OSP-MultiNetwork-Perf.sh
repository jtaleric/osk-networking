#!/bin/bash

#-------------------------------------------------------------------------------
# OSP-Network-Perf.sh
#
#
# -- To do --
# ----  
# ---- Currently now VLAN testing... This assumes there is a br-tun bridge
#
# -- Updates --
# 01/11/14 - uperf-bpench inital drop
# 07/16/14 - Super-netperf integration... Layed things down for FloatingIP
# 04/21/14 - Neutron changed how the flows are built. Previously there was a
#            signle flow for the dhcp-agent, now there is a per-guest flow
#            which is a bit more secure.
# 04/17/14 - Sync the throughput runs... Sync with Lock file 
# 03/18/14 - Fixes
# 02/20/14 - Working on Scale 
# 11/13/13 - Create a new security group, then remove it for the cleanup
# 11/12/13 - Added code to allow multiple launches of this script
# 11/11/13 - First drop
# @author Joe Talerico (jtaleric@redhat.com)
#-------------------------------------------------------------------------------

#-------------------------------------------------------------------------------
# Determine the Run - for multi-run 
#-------------------------------------------------------------------------------
RUN=0
if [ -z $1 ] ; then 
 RUN=1
else 
 echo Run : $1
 RUN=$1
fi

#----------------------- Test name ---------------------------------------------
if [ -z $3 ] ; then
 TESTNAME="no-name"
else
 echo Test name: $3
 TESTNAME=$3
fi

#----------------------- Run Super-Netperf -------------------------------------
if [ -z $4 ] ; then 
 SUPER=false
else
  echo Super-netperf Testing
  SUPER=true
fi

# UPerf-PBench work
UPERF=true

#----------------------- Perf GIT ----------------------------------------------
PERFGITFILE="perf-dept.tar.gz"
PERFGIT="/root/osk-networking/${PERFGITFILE}"

#----------------------- Currently not using Floating IPs ----------------------
VETH1="veth$RUN"
VETH2="veth"`expr $RUN + 1000`

#----------------------- Set the eth within the guest --------------------------
GUEST_VETH="eth0"

#----------------------- Store the results -------------------------------------
if [ -z $2 ] ; then 
 FOLDER=OSP-NetworkScale-Output_$(date +%Y_%m_%d_%H_%M_%S)
else
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
NETPERF_IMG_NAME="pbench-updated"
NETPERF_IMG="/home/netperf-nocloudinit-centos.qcow2"
GUEST_SIZE="m1.small"
#----------------------- Netperf values ----------------------------------------
NETPERF_LENGTH=30

#-------------------------------------------------------------------------------
#
# Disable these to just do a simple ping test.
#
#-------------------------------------------------------------------------------
TCP_STREAM=true
UDP_STREAM=true

#----------------------- Run forever? ------------------------------------------
FOREVER=false

#----------------------- Floating IPs ------------------------------------------
FLOATERS=false

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
CLEAN=false

#----------------------- Show Debug output -------------------------------------
DEBUG=false

#-------------------------------------------------------------------------------
# CLEAN_IMAGE will remove the netperf-networktest image from glance
#-------------------------------------------------------------------------------
CLEAN_IMAGE=false

#----------------------- Hosts to Launch Guests  -------------------------------
ZONE[0]="nova:macb8ca3a6106b4.perf.lab.eng.bos.redhat.com"
ZONE[1]="nova:macb8ca3a60ff54.perf.lab.eng.bos.redhat.com"

#----------------------- Run PStat on Hypervisors ------------------------------
PSTAT=false
pstat_host1=""
pstat_host2=""

#----------------------- Network -----------------------------------------------
TUNNEL_NIC="enp4s0f0"
TUNNEL_SPEED=`ethtool ${TUNNEL_NIC} | grep Speed | sed 's/\sSpeed: \(.*\)Mb\/s/\1/'`
TUNNEL_TYPE=`ovs-vsctl show | grep -E 'Port.*gre|vxlan|stt*'`
NETWORK="240Net-$RUN"
SUBNET="240.0.$RUN.0/24"
MTU=8950
SSHKEY="/root/.ssh/id_rsa.pub"
SINGLE_TUNNEL_TEST=true

#----------------------- No Code.... yet. --------------------------------------
MULTI_TUNNEL_TEST=false

#----------------------- Need to determine how to tell ( ethtool? STT ) --------
HARDWARE_OFFLOAD=false 

#----------------------- Is Jumbo Frames enabled throughout? -------------------
JUMBO=false

#----------------------- Ignore DHCP MTU ---------------------------------------
DHCP=false

#-------------------------------------------------------------------------------
# Params to set the guest MTU lower to account for tunnel overhead
# or if JUMBO is enabled to increase MTU
#-------------------------------------------------------------------------------
if $DHCP ; then
if $TUNNEL ; then
 MTU=1450
 if $JUMBO ; then
  MTU=8950
 fi
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
NETPERF[32]="5,.7"
NETPERF[64]="8,1"
NETPERF[128]="13,2"
NETPERF[256]="15,5"
NETPERF[512]="15,11"
NETPERF[1024]="15,20"
NETPERF[2048]="15,25"
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
 echo "WARNING :: Unable to find the Netperf image"
 echo "You must import the image before running this script"
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

 ip link delete $VETH1
 ovs-vsctl del-port $VETH2

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

NETWORKID=`nova network-list | grep -e "${NETWORK}\s" | awk '{print $2}'` 
if $DEBUG  ; then
 echo "#----------------------- Debug -------------------------------------------------"
 echo "Network ID :: $NETWORKID"
 echo "#-------------------------------------------------------------------------------"
fi

#
# Glance is erroring out.
#
# BZ 1109890 
#  max database connection issue
#
# IMAGE_ID="f6e00ceb-3c79-41f6-9d09-a163df637328"
# GLANCE=false

if $GLANCE ; then
if [ -z "$(glance image-list | grep -E "${NETPERF_IMG_NAME}")" ]; then
 #----------------------- Import image into Glance ------------------------------
 echo "#------------------------------------------------------------------------------- "
 echo "Importing Netperf image into Glance"
 echo "#-------------------------------------------------------------------------------"
 IMAGE_ID=$(glance image-create --name ${NETPERF_IMG_NAME} --disk-format=qcow2 --container-format=bare < ${NETPERF_IMG} | grep id | awk '{print $4}')
else 
 IMAGE_ID=$(glance image-list | grep -E "${NETPERF_IMG_NAME}" | awk '{print $2}')
fi
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
  command_out=$(nova boot --image ${IMAGE_ID} --nic net-id=${NETWORKID} --flavor ${GUEST_SIZE} --availability-zone ${host_zone} netperf-${host_zone} --key_name network-testkey --security_group default,netperf-networktest | egrep "\sid\s" | awk '{print $4}')
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
echo "Guest Search String :: $search_string"
echo "#-------------------------------------------------------------------------------"
fi
if $TUNNEL ; then
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

#----------------------- If we are not using Floating IPs ----------------------
if [ -z "$(ip link | grep -e "$VETH1\s")" ]; then
 echo "#------------------------------------------------------------------------------- "
 echo "Adding a veth"
 echo "#-------------------------------------------------------------------------------"
 ip link add name $VETH1 type veth peer name $VETH2 
 ip a a 240.0.${RUN}.150/24 dev $VETH1
 ip l s up dev $VETH1
 ip l s up dev $VETH2
fi

#-------------------------------------------------------------------------------
# Determine the Segmentation ID if not using 
#-------------------------------------------------------------------------------
PORT=0
for ports in `neutron port-list | grep -e "240.0.$RUN." | awk '{print $2}'` ; do 
 if $DEBUG ; then 
  echo "#----------------------- Debug -------------------------------------------------"
  echo "Ports :: $ports"
  echo "#-------------------------------------------------------------------------------"
 fi
 if [[ ! -z $(neutron port-show $ports | grep "device_owner" | grep "compute:nova") ]] ; then 
  echo "#----------------------- Debug -------------------------------------------------"
  echo "Ports :: $ports"
  echo "#-------------------------------------------------------------------------------"
  PORT=$(neutron port-show $ports | grep "mac_address" | awk '{print $4}'); 
 fi 
done;
if [[ -z "${PORT}" ]] ; then
 echo "ERROR :: Unable to determine DHCP Port for Network"
 if $CLEAN ; then
  cleanup
 fi
 exit 0
fi
try=0
if $DEBUG ; then 
 echo "#----------------------- Debug -------------------------------------------------"
 echo "Port :: $PORT"
 echo "#-------------------------------------------------------------------------------"
fi
while true ; do
 FLOW=`ovs-ofctl dump-flows br-tun | grep "${PORT}"`
 IFS=', ' read -a array <<< "$FLOW"
 VLANID_HEX=`echo ${array[9]} | sed 's/vlan_tci=//g' | sed 's/\/.*//g'`
 if $DEBUG ; then 
  echo "#----------------------- Debug -------------------------------------------------"
  echo "VLAN HEX :: $VLANID_HEX"
  echo "#-------------------------------------------------------------------------------"
 fi
 if [[ $(echo $VLANID_HEX | grep -q "dl_dst") -eq 1 ]] ; then 
  continue
 fi 
 VLAN=`printf "%d" ${VLANID_HEX}`
 if $DEBUG ; then
  echo "#----------------------- Debug -------------------------------------------------"
  echo "VLAN :: $VLAN"
  echo "#-------------------------------------------------------------------------------"
 fi
 if [ $VLAN -ne 0 ] ; then
  break
 else 
  sleep 10 
 fi
 if [[ $try -eq 15 ]] ; then 
  echo "ERROR :: Attempting to find the VLAN to use failed..."
  if $CLEAN ; then
   cleanup
  fi
  exit 0
 fi 
 try=$((try+1))
done

if $DEBUG ; then
 echo "Using VLAN :: $VLAN"
fi
fi

if $TUNNEL ; then 
 if ! [ -z "$(ovs-vsctl show | grep "Port \"$VETH2\"")" ] ; then
  ovs-vsctl del-port $VETH2 
 fi
fi
if $TUNNEL ; then 
 VETH_MAC=`ip link | grep -A 1 ${VETH1} | grep link | awk '{ print $2 }'`
 ovs-vsctl add-port br-int ${VETH2} tag=${VLAN}
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

 if $DHCP ; then 
 pass=0
 breakloop=0
 while true 
   do 
     if [[ ${pass} -lt 2 ]] ; then 
       pass=0
     fi
     ssh -o BatchMode=yes -o ConnectTimeout=3 -o StrictHostKeyChecking=no -q -t ${NETSERVER} "ip l s mtu ${MTU} dev ${GUEST_VETH}" 
     if [ $? -eq 0 ] ; then
       pass=$((pass+1))
     fi
     ssh -o BatchMode=yes -o ConnectTimeout=3 -o StrictHostKeyChecking=no -q -t ${NETCLIENT} "ip l s mtu ${MTU} dev ${GUEST_VETH}" 
     if [ $? -eq 0 ] ; then
       pass=$((pass+1))
     fi
     if [ ${pass} -eq 2 ] ; then
       break
     fi
     if [ $? -eq 0 ] ; then
       pass=$((pass+1))
     fi
     if $DEBUG ; then
	echo "pass=$pass , breakloop=$breakloop"
     fi
     if [ $breakloop -eq 10 ] ; then
       echo "Error : unable to set MTU within Guest"
       exit 1
     fi
     breakloop=$((breakloop+1))
 done
 fi 

 
 if $UPERF ; then
  ssh -o BatchMode=yes -o ConnectTimeout=3 -o StrictHostKeyChecking=no -q -t ${NETSERVER} 'setenforce 0'
  ssh -o BatchMode=yes -o ConnectTimeout=3 -o StrictHostKeyChecking=no -q -t ${NETSERVER} 'systemctl stop iptables'
  ssh -o BatchMode=yes -o ConnectTimeout=3 -o StrictHostKeyChecking=no -q -t ${NETSERVER} 'systemctl stop firewalld'
  ssh -o BatchMode=yes -o ConnectTimeout=3 -o StrictHostKeyChecking=no -q -t ${NETSERVER} '/usr/local/bin/uperf -s ' > /dev/null &
 else
  ssh -o BatchMode=yes -o ConnectTimeout=3 -o StrictHostKeyChecking=no -q -t ${NETSERVER} 'netserver ; sleep 4'
 fi
 
 if $DEBUG ; then
  D1=$(ssh -o BatchMode=yes -o ConnectTimeout=3 -o StrictHostKeyChecking=no -q -t ${NETSERVER} 'ls')
  echo "#----------------------- Debug -------------------------------------------------"
  echo "SSH Output :: $D1"
  echo "#-------------------------------------------------------------------------------"
 fi

 if $SUPER ; then
  scp $PERFGIT ${NETCLIENT}:
  out=`ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=no -q -t ${NETCLIENT} "tar -xzf $PERFGITFILE"`
 fi

 if $PSTAT ; then
  echo "Checking if PStat is running already, if not, start PStat on the Hosts (currently 2 Hosts)"
  if [[ -z $(ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=no -q -t $pstat_host1 "ps aux | grep [p]stat") ]]; then
   echo "Start PStat on $pstat_host1"
   ssh -o BatchMode=yes -o ConnectTimeout=3 -o StrictHostKeyChecking=no $pstat_host1 "/opt/perf-dept/pstat/pstat.sh 1 OSP-${pstat_host1}-${TESTNAME}-PSTAT & 2>&1 > /dev/null" & 2>&1 > /dev/null
 fi
  if [[ -z $(ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=no -q -t $pstat_host2 "ps aux | grep [p]stat") ]]; then
   echo "Start PStat on $pstat_host2"
   ssh -o BatchMode=yes -o ConnectTimeout=3 -o StrictHostKeyChecking=no $pstat_host2 "/opt/perf-dept/pstat/pstat.sh 1 OSP-${pstat_host2}-${TESTNAME}-PSTAT & 2>&1 > /dev/null" & 2>&1 > /dev/null
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

#
# We can add a new param,  $UPERF, and instead of sshing to the guest for netperf, it
# Logs in to configure and run uperf. OK
# We just need to have uperf installed in VM images
# Let me take care of that... If i pull the pbench rpm is that enough? grab uperf rpm as well
# Roger. I will add this to my rhel7 guest. uperf-1.0.4-7.el7.centos.x86_64 from perf-dept pbench repo
# Then we can probably just ssh to the guests: 1 to start uperf server (uperf -s) and the other
# to run pbench_uperf --mode=client --server=<other vm> --test-types=stream (may be a couple more args)
#

 if $UPERF ; then
  TCP_STREAM=false
  UDP_STREAM=false
  echo "Running UPerf"
  ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=no -q -t ${NETCLIENT} 'setenforce 0'
  ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=no -q -t ${NETCLIENT} 'systemctl stop iptables'
  ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=no -q -t ${NETCLIENT} 'systemctl stop firewalld'
  ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=no -q -t ${NETCLIENT} "echo '10.16.28.171 perf42.perf.lab.eng.bos.redhat.com' >> /etc/hosts"
  ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=no -q -t ${NETCLIENT} "echo nameserver 10.16.36.29 > /etc/resolv.conf"
  ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=no -q -t ${NETCLIENT} "pbench_uperf --mode=client --server=${NETSERVER} --test-types=stream" | tee -a $FOLDER/uperf-data
  ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=no -q -t ${NETCLIENT} "postprocess-results" | tee -a $FOLDER/postprocess-data
  ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=no -q -t ${NETCLIENT} "move-results" | tee -a $FOLDER/move-data

 elif $TCP_STREAM ; then
  echo "#------------------------------------------------------------------------------- "
  echo "BEGIN TCP_STREAM Test"
  echo "#-------------------------------------------------------------------------------"
  echo "Message Size, Test Status, Tunnel Speed, Throughput, Expected % of Tunnel"
  date_file=$(date +"%d_%m_%y_%H%M%S")
  prev_msg_size=0
  for msg_size in ${!NETPERF[@]}
  do

#----------------------- Add logic to determine Lock file ----------------------
   wait_state=`ps aux | grep ssh | grep "\-m ${prev_msg_size}" | grep -v grep | wc -l`

#-------------------------------------------------------------------------------
# Sync the SSH Runs - if the above command finds previous ssh clients, wait for
# them to finish
#-------------------------------------------------------------------------------
   if [[ ${wait_state} -gt 0 ]] ; then
     continue
   fi

   out=`ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=no -q -t ${NETCLIENT} "netperf -4 -H ${NETSERVER} -I 99,10 -T1,1 -- -m ${msg_size}" | tee -a $FOLDER/$RUN-$date_file-TCP_STREAM`
   if $DEBUG ; then 
     echo "DEBUG :: $out"
   fi
   throughput=`echo "${out}"| grep "$msg_size"| awk '{print $5}'| sed -e 's/ /,/g'`
   percent=`perl -e "print ${throughput}/${TUNNEL_SPEED}*100" 2> /dev/null`
#-------------------------------------------------------------------------------
# 1 = TCP, 2 = UDP, 3 = Hardware offload
#-------------------------------------------------------------------------------
   expected_percent=`echo "${NETPERF[$msg_size]}" | cut -d , -f 1`
   perl -e "if(${percent} >= ${expected_percent}) { exit 1 }" > /dev/null 2>&1
   if [ $? -eq 0 ]; then
    echo "${msg_size} , FAILED, ${TUNNEL_SPEED} , ${throughput} , ${expected_percent}"
   else 
    echo "${msg_size} , PASSED, ${TUNNEL_SPEED} , ${throughput} , ${expected_percent}"
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
   out=`ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=no -q -t ${NETCLIENT} "netperf -4 -H ${NETSERVER} -I 99,10 -T1,1 -t UDP_STREAM -- -m ${msg_size}" | tee -a $FOLDER/$RUN-$date_file-UDP_STREAM`
   if $DEBUG ; then 
     echo "DEBUG :: ${out}"
   fi
   throughput=`echo "${out}"| grep "$msg_size" -A1 | tail -1 | awk '{print $4}'| sed -e 's/ /,/g'`
   percent=`perl -e "print ${throughput}/${TUNNEL_SPEED}*100" 2> /dev/null`
#-------------------------------------------------------------------------------
# 1 = TCP, 2 = UDP, 3 = Hardware offload
#-------------------------------------------------------------------------------
   expected_percent=`echo "${NETPERF[$msg_size]}" | cut -d , -f 1`
   perl -e "if(${percent} >= ${expected_percent}) { exit 1 }" /dev/null 2>&1
   if [ $? -eq 0 ]; then
    echo "${msg_size} , FAILED, ${TUNNEL_SPEED} , ${throughput} , ${expected_percent}"
   else
    echo "${msg_size} , PASSED, ${TUNNEL_SPEED} , ${throughput} , ${expected_percent}"
   fi
  done
  echo "#------------------------------------------------------------------------------- "
  echo "END UDP_STREAM Test"
  echo "#-------------------------------------------------------------------------------"
  fi

fi # End SINGLE_TUNNEL_TEST

#----------------------- Cleanup -----------------------------------------------
if $CLEAN ; then
 cleanup
fi
