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

extract_db_pwd ()
{
	user=$1
	db_pwd_file=$CFG_SEC_DIR/mysql_${user}_pwd.txt
	cat $db_pwd_file | tr -d '\r\n'
}

for i in $CFG_BASE $CFG_STAGE_DIR $CFG_SEC_DIR
do
	[ -d "$i" ] || mkdir -vp "$i"
done

set -x

STAGE=$CFG_STAGE_DIR/001basepkg
[ -f $STAGE ] || {
	sudo apt-get install -y software-properties-common eatmydata curl wget jq netcat-openbsd openssl crudini
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

STAGE=$CFG_STAGE_DIR/022keystone-cfg
[ -f $STAGE ] || {
	f=/etc/keystone/keystone.conf
	sudo crudini --set $f cache backend dogpile.cache.memcached
	sudo crudini --set $f cache enabled true
	sudo crudini --set $f cache memcache_servers $HOST:11211
	p=`extract_db_pwd keystone`
	sudo crudini --set $f database connection "mysql+pymysql://keystone:$p@$HOST/keystone"
	sudo crudini --set $f credential provider fernet
	sudo crudini --set $f credential caching true
	#sudo diff /etc/keystone/keystone.conf{.orig,}
	touch $STAGE
}

STAGE=$CFG_STAGE_DIR/023keystone-init
[ -f $STAGE ] || {
	sudo -u keystone keystone-manage db_sync
	touch $STAGE
}

STAGE=$CFG_STAGE_DIR/024keystone-init-fernet
[ -f $STAGE ] || {
	sudo keystone-manage fernet_setup --keystone-user keystone --keystone-group keystone
	touch $STAGE
}

STAGE=$CFG_STAGE_DIR/025keystone-init-cred
[ -f $STAGE ] || {
	sudo keystone-manage credential_setup --keystone-user keystone --keystone-group keystone
	touch $STAGE
}

STAGE=$CFG_STAGE_DIR/026keystone-svc-pwd
[ -f $STAGE ] || {
	svc=keystone
	openssl rand -hex 10 > $CFG_SEC_DIR/svc_${svc}_pwd.txt
	touch $STAGE
}

STAGE=$CFG_STAGE_DIR/027keystone-boostrap
[ -f $STAGE ] || {
	svc=keystone
	p=`cat $CFG_SEC_DIR/svc_${svc}_pwd.txt`
	sudo keystone-manage bootstrap --bootstrap-password "$p" \
	  --bootstrap-admin-url http://$HOST:5000/v3/ \
	  --bootstrap-internal-url http://$HOST:5000/v3/ \
	  --bootstrap-public-url http://$HOST:5000/v3/ \
	  --bootstrap-region-id RegionOne
	sudo systemctl restart apache2
	sleep 3
	touch $STAGE
}

# Do not use -4 - apache listens on IPv6 and IPv4 but LISTEN is shown for IPv6 only...
ss -ltn | fgrep ':5000' || {
	echo "ERROR: keystone not listening on port 5000" >&2
	exit 1
}

STAGE=$CFG_STAGE_DIR/028keystone-adminrc
[ -f $STAGE ] || {
	p=`cat $CFG_SEC_DIR/svc_keystone_pwd.txt`
cat > $CFG_BASE/keystonerc_admin <<EOF
export OS_USERNAME=admin
export OS_PASSWORD=$p
export OS_PROJECT_NAME=admin
export OS_USER_DOMAIN_NAME=Default
export OS_PROJECT_DOMAIN_NAME=Default
# replace with you static IP address
export OS_AUTH_URL=http://$HOST:5000/v3
export OS_IDENTITY_API_VERSION=3
export PS1='\u@\h:\w(keystonerc_admin)\$ '
EOF
	touch $STAGE
}

# verify that keystone is responding
# but use new shell () to declutter environment
(
	source $CFG_BASE/keystonerc_admin
	openstack service list || {
		echo "ERROR: Keystone not responding" >&2
		exit 1
	}
)
	
STAGE=$CFG_STAGE_DIR/029keystone-service-proj
[ -f $STAGE ] || {
	# always use new shell to keep environment clean...
	( source $CFG_BASE/keystonerc_admin
	openstack project create --domain default --description "Service Project" service )
	touch $STAGE
}


exit 0
