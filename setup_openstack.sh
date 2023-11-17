#!/bin/bash
# setup_openstack.sh - attempt to setup single-node OpenStack on Ubuntu 22.04 LTS
# USE ON YOUR OWN RISK!

set -euo pipefail

HOST=`hostname`
HOST_IP=`hostname -i`
RELEASE=antelope

echo "HOST='$HOST' HOST_IP='$HOST_IP' Release='$RELEASE'"

CFG_BASE=$HOME/.config/osfs
CFG_STAGE_DIR=$CFG_BASE/stages

for i in $CFG_BASE $CFG_STAGE_DIR
do
	[ -d "$i" ] || mkdir -vp "$i"
done

set -x

STAGE=$CFG_STAGE_DIR/001basepkg
[ -f $STAGE ] || {
	sudo apt-get install -y software-properties-common eatmydata curl wget jq
	touch $STAGE
}

exit 0
