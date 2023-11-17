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
CFG_SEC_DIR=$CFG_BASE/secrets
MYSQL_ROOT_PWD_FILE=$CFG_SEC_DIR/mysql_root_pwd.txt

setup_mysql_db ()
{
	# arguments: DB_NAME USER_NAME
	db=$1
	user=$2
	db_pwd_file=$CFG_SEC_DIR/mysql_${user}_pwd.txt
	[ -r $db_pwd_file ] || openssl rand -hex 10 > $db_pwd_file
	db_pwd=`cat $db_pwd_file | tr -d '\r\n'`
mysql -u root -p`cat $MYSQL_ROOT_PWD_FILE`  <<EOF
CREATE DATABASE $db;
GRANT ALL PRIVILEGES ON $db.* TO '$user'@'localhost' IDENTIFIED BY '$db_pwd';
GRANT ALL PRIVILEGES ON $db.* TO '$user'@'%' IDENTIFIED BY '$db_pwd';
FLUSH PRIVILEGES;
EOF
}

for i in $CFG_BASE $CFG_STAGE_DIR $CFG_SEC_DIR
do
	[ -d "$i" ] || mkdir -vp "$i"
done

set -x

STAGE=$CFG_STAGE_DIR/001basepkg
[ -f $STAGE ] || {
	sudo apt-get install -y software-properties-common eatmydata curl wget jq netcat-openbsd openssl
	touch $STAGE
}

STAGE=$CFG_STAGE_DIR/002enable-os-repo
[ -f $STAGE ] || {
	sudo eatmydata add-apt-repository cloud-archive:$RELEASE
	sudo eatmydata apt-get install -y python3-openstackclient
	touch $STAGE
}

STAGE=$CFG_STAGE_DIR/003install-mysql
[ -f $STAGE ] || {
	sudo eatmydata apt-get install -y mariadb-server python3-pymysql
	touch $STAGE
}

STAGE=$CFG_STAGE_DIR/004config-mysql
[ -f $STAGE ] || {
sudo tee /etc/mysql/mariadb.conf.d/99-openstack.cnf  <<EOF
[mysqld]
bind-address = $HOST_IP

default-storage-engine = innodb
innodb_file_per_table = on
max_connections = 4096
collation-server = utf8_general_ci
character-set-server = utf8
# my additions
innodb_buffer_pool_size = 256m
# see: https://mariadb.com/docs/reference/es/system-variables/innodb_flush_log_at_trx_commit/
innodb_flush_log_at_trx_commit = 0
EOF
	sudo systemctl restart mariadb
	touch $STAGE
}

STAGE=$CFG_STAGE_DIR/005secure-mysql
[ -f $STAGE ] || {
	echo "Anser no to socket and note MySQL root password you set"
	sudo mysql_secure_installation
	echo "Now store MySQL root password to $MYSQL_ROOT_PWD_FILE"
	touch $STAGE
}

# Verify that MySQL root password file exists
[ -r "$MYSQL_ROOT_PWD_FILE" ] || {
	echo "ERROR: You have to store MySQL root password to $MYSQL_ROOT_PWD_FILE" >&2
	exit 1
}

# Verify that we can login to MySQL as root user
mysql -u root -p`cat $MYSQL_ROOT_PWD_FILE` -e 'show databases' || {
	echo "ERROR: Unable to login as root to MySQL" >&2
	exit 1
}

STAGE=$CFG_STAGE_DIR/010install-memcached
[ -f $STAGE ] || {
	sudo eatmydata apt-get install -y memcached
	touch $STAGE
}

STAGE=$CFG_STAGE_DIR/011config-memcached
[ -f $STAGE ] || {
	sudo sed -i.bak -e 's/^-l.*/-l '"$HOST_IP"'/' /etc/memcached.conf
        sudo systemctl restart memcached
	touch $STAGE
}

ss -lt4 | fgrep $HOST_IP\:11211 || {
	echo "ERROR: Memacached does not listen on port 11211" >&2
	exit 1
}

STAGE=$CFG_STAGE_DIR/020keystone-db
[ -f $STAGE ] || {
	setup_mysql_db keystone keystone
	touch $STAGE
}

STAGE=$CFG_STAGE_DIR/021keystone-pkg
[ -f $STAGE ] || {
	sudo eatmydata apt-get install -y keystone
	touch $STAGE
}

exit 0
