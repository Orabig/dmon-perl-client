#!/bin/sh
docker rm -f -v $(docker ps -a | grep dmon-perl-client | awk '{print $1}')
