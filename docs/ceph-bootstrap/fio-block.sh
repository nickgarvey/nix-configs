# usage: fio-block.sh <block device> -- the same jobs for RBD and Longhorn. Destroys data on the device.
set -eu
DEV=$1
run() { # name, extra fio args
  fio --filename=$DEV --direct=1 --invalidate=0 --ioengine=libaio --time_based --runtime=30 --ramp_time=3 --size=20G \
      --group_reporting --output-format=json --name=$1 "${@:2}" 2>/dev/null |
  jq -r --arg n "$1" '.jobs[0] | [$n,
      (.read.bw/1024), .read.iops, (.read.clat_ns.mean/1e6), ((.read.clat_ns.percentile["99.000000"] // 0)/1e6),
      (.write.bw/1024), .write.iops, (.write.clat_ns.mean/1e6), ((.write.clat_ns.percentile["99.000000"] // 0)/1e6),
      ((.sync.lat_ns.mean // 0)/1e6)] |
    "\(.[0]|.+"                          "|.[0:24]) R \(.[1]|floor) MiB/s \(.[2]|floor) IOPS mean \(.[3]*100|round/100) p99 \(.[4]*100|round/100) ms | W \(.[5]|floor) MiB/s \(.[6]|floor) IOPS mean \(.[7]*100|round/100) p99 \(.[8]*100|round/100) ms | fsync \(.[9]*100|round/100) ms"'
}
# Fill the test region first: reads from a never-written thin volume skip the disks.
fio --filename=$DEV --direct=1 --invalidate=0 --ioengine=libaio --rw=write --bs=1M --iodepth=16 --size=20G --name=fill >/dev/null 2>&1
run sync-randwrite-4k-qd1  --rw=randwrite --bs=4k --iodepth=1 --fsync=1
run randwrite-4k-qd32      --rw=randwrite --bs=4k --iodepth=32
run randread-4k-qd1        --rw=randread  --bs=4k --iodepth=1
run randread-4k-qd32       --rw=randread  --bs=4k --iodepth=32
run seqwrite-1m-qd16       --rw=write     --bs=1M --iodepth=16
run seqread-1m-qd16        --rw=read      --bs=1M --iodepth=16
