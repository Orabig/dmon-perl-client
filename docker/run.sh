#!/bin/sh

DIR="$(cd "$(dirname "$0")" && pwd)"

DMON_API="$(grep DMON_API /etc/dmon.config | awk -F= '{print $2}')"
CENT_WS="$(grep CENT_WS /etc/dmon.config | awk -F= '{print $2}')"

docker rm -f dmon-perl-client
docker run -d \
   --name dmon-perl-client \
   --restart=always \
   --volume $DIR/src:/src \
   --volume /home/orabig/DEV/centreon-plugins:/var/lib/centreon-plugins \
   --volume $DIR/tmp:/var/lib/centreon/centplugins \
   --volume $DIR/config.json:/tmp/config.json \
   --volume /proc/meminfo:/proc/meminfo:ro \
   --volume /proc/stat:/proc/stat:ro \
   --volume /proc/diskstats:/proc/diskstats:ro \
   -e DMON_API=$DMON_API \
   -e CENT_WS=$CENT_WS \
   dmon-perl-client /bin/sh -c 'cd /src; perl run.pl'
