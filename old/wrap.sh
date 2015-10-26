test="/var/lib/pbench/osp6-sec_group-enabled_iptables-vxlan-guest_1500-uperf-2"

start-tools --dir=${test}
./Scale-OSP-MultiNetwork-Perf.sh 0
stop-tools --dir=${test}
postprocess-tools --dir=${test}
move-results --dir=${test}
