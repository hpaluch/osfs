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
	local db=$1
	local user=$2
	local db_pwd_file=$CFG_SEC_DIR/mysql_${user}_pwd.txt
	[ -r $db_pwd_file ] || openssl rand -hex 10 > $db_pwd_file
	local db_pwd=`cat $db_pwd_file | tr -d '\r\n'`
mysql -u root -p`cat $MYSQL_ROOT_PWD_FILE`  <<EOF
CREATE DATABASE $db;
GRANT ALL PRIVILEGES ON $db.* TO '$user'@'localhost' IDENTIFIED BY '$db_pwd';
GRANT ALL PRIVILEGES ON $db.* TO '$user'@'%' IDENTIFIED BY '$db_pwd';
FLUSH PRIVILEGES;
EOF
}

extract_db_pwd ()
{
	local user=$1
	local db_pwd_file=$CFG_SEC_DIR/mysql_${user}_pwd.txt
	cat $db_pwd_file | tr -d '\r\n'
}

create_svc_pwd ()
{
	local svc=$1
	[ -f $CFG_SEC_DIR/svc_${svc}_pwd.txt ] || {
		openssl rand -hex 10 > $CFG_SEC_DIR/svc_${svc}_pwd.txt
	}
}

extract_svc_pwd ()
{
	local svc=$1
	local pwd_file=$CFG_SEC_DIR/svc_${svc}_pwd.txt
	cat $pwd_file | tr -d '\r\n'
}

register_service_in_keystone ()
{
	local svc=$1
	local port=$2
	local descr="$3"
	local svc2=$4
	( source $CFG_BASE/keystonerc_admin
	echo "SVC: $svc PORT: $port DESCR: $descr SVC2: $svc2"
	# test that openstack client really works
	openstack service list
	# create password for $svc
	[ -f $CFG_SEC_DIR/svc_${svc}_pwd.txt ] || {
	       	openssl rand -hex 10 > $CFG_SEC_DIR/svc_${svc}_pwd.txt
	}
	p=`cat $CFG_SEC_DIR/svc_${svc}_pwd.txt`
	openstack user create --domain default --password $p $svc
	openstack role add --project service --user $svc admin
	openstack service create --name $svc --description "$descr" $svc2
	for ep in public internal admin
	do
		openstack endpoint create --region RegionOne $svc2 $ep http://$HOST:$port
	done
	)
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
	echo "Answer no to socket and note MySQL root password you set"
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

# Now setup Glance (image service)
STAGE=$CFG_STAGE_DIR/030glance-db
[ -f $STAGE ] || {
	setup_mysql_db glance glance
	touch $STAGE
}

STAGE=$CFG_STAGE_DIR/031glance-svc
[ -f $STAGE ] || {
	register_service_in_keystone glance 9292 "OpenStack Image" image
	touch $STAGE
}

STAGE=$CFG_STAGE_DIR/032glance-pkg
[ -f $STAGE ] || {
	sudo eatmydata apt-get install -y glance
	touch $STAGE
}


STAGE=$CFG_STAGE_DIR/033glance-cfg
[ -f $STAGE ] || {
	svc=glance
	f=/etc/glance/glance-api.conf
	p=`extract_db_pwd glance`
	sudo crudini --set $f database connection "mysql+pymysql://glance:$p@$HOST/glance"
	sudo crudini --set $f glance_store stores "file,http"
	sudo crudini --set $f glance_store default_store file
	sudo crudini --set $f glance_store filesystem_store_datadir /var/lib/glance/images
	sudo crudini --set $f keystone_authtoken www_authenticate_uri "http://$HOST:5000"
	sudo crudini --set $f keystone_authtoken auth_url "http://$HOST:5000"
	sudo crudini --set $f keystone_authtoken memcached_servers  "$HOST:11211"
	sudo crudini --set $f keystone_authtoken auth_type password
	sudo crudini --set $f keystone_authtoken project_domain_name Default
	sudo crudini --set $f keystone_authtoken user_domain_name  Default
	sudo crudini --set $f keystone_authtoken project_name service
	sudo crudini --set $f keystone_authtoken username "$svc"
	sudo crudini --set $f keystone_authtoken password `extract_svc_pwd $svc`
	sudo crudini --set $f paste_deploy flavor keystone
	#sudo diff $f{.orig,}
	touch $STAGE
}

STAGE=$CFG_STAGE_DIR/034glance-dbsync
[ -f $STAGE ] || {
	sudo -u glance glance-manage db_sync
	touch $STAGE
}

STAGE=$CFG_STAGE_DIR/035glance-mkdir
[ -f $STAGE ] || {
	sudo mkdir -p /var/lib/glance/images/
	sudo chown glance:glance /var/lib/glance/images/
	sudo systemctl restart glance-api
	sudo systemctl restart apache2
	sleep 5
	touch $STAGE
}

STAGE=$CFG_STAGE_DIR/036glance-image
[ -f $STAGE ] || {
	f=cirros-0.5.1-x86_64-disk.img
	url=http://download.cirros-cloud.net/0.5.1/$f
	path=$HOME/$f
	curl -fL -o $path $url
	( source $CFG_BASE/keystonerc_admin
	openstack image list
	openstack image create --public --container-format bare --disk-format qcow2 --file $path cirros
	openstack image list
	)
	touch $STAGE
}

# Now setup Nova Placement
STAGE=$CFG_STAGE_DIR/040placement-db
[ -f $STAGE ] || {
	setup_mysql_db placement placement
	touch $STAGE
}

STAGE=$CFG_STAGE_DIR/041placement-svc
[ -f $STAGE ] || {
	register_service_in_keystone placement 8778 "Placement API" placement
	touch $STAGE
}

STAGE=$CFG_STAGE_DIR/042placement-pkg
[ -f $STAGE ] || {
	sudo eatmydata apt-get install -y placement-api python3-osc-placement
	touch $STAGE
}

STAGE=$CFG_STAGE_DIR/043placement-cfg
[ -f $STAGE ] || {
	svc=placement
	f=/etc/placement/placement.conf
	p=`extract_db_pwd $svc`

	sudo crudini --set $f api auth_strategy keystone

	sudo crudini --set $f keystone_authtoken auth_url "http://$HOST:5000/v3"
	sudo crudini --set $f keystone_authtoken memcached_servers  "$HOST:11211"
	sudo crudini --set $f keystone_authtoken auth_type password
	sudo crudini --set $f keystone_authtoken project_domain_name Default
	sudo crudini --set $f keystone_authtoken user_domain_name  Default
	sudo crudini --set $f keystone_authtoken project_name service
	sudo crudini --set $f keystone_authtoken username "$svc"
	sudo crudini --set $f keystone_authtoken password `extract_svc_pwd $svc`

	sudo crudini --set $f placement_database connection "mysql+pymysql://$svc:$p@$HOST/$svc"

	#sudo diff $f{.orig,}
	touch $STAGE
}

STAGE=$CFG_STAGE_DIR/044placement-dbsync
[ -f $STAGE ] || {
	sudo -u placement placement-manage db sync
	sudo systemctl restart apache2
	sleep 10
	# verify that Placement works
	( source $CFG_BASE/keystonerc_admin
	  openstack resource class list )
	touch $STAGE
}

# Setup RabbitMQ
STAGE=$CFG_STAGE_DIR/050rabbit-pkg
[ -f $STAGE ] || {
	# NOTE: eatmydata somehow clashes with erlang setup
	sudo apt-get install -y rabbitmq-server
	touch $STAGE
}

STAGE=$CFG_STAGE_DIR/051rabbit-pwd
[ -f $STAGE ] || {
	create_svc_pwd rabbit
	touch $STAGE
}

STAGE=$CFG_STAGE_DIR/052rabbit-listen
[ -f $STAGE ] || {
	echo "NODE_IP_ADDRESS=$HOST_IP" | sudo tee -a /etc/rabbitmq/rabbitmq-env.conf
	touch $STAGE
}

STAGE=$CFG_STAGE_DIR/053rabbit-restart
[ -f $STAGE ] || {
	sudo systemctl restart rabbitmq-server.service
	sleep 3
	ss -ltn | fgrep ':5672'
	touch $STAGE
}

STAGE=$CFG_STAGE_DIR/054rabbit-account
[ -f $STAGE ] || {
	sudo rabbitmqctl add_user openstack $(extract_svc_pwd rabbit)
	sudo rabbitmqctl set_permissions openstack ".*" ".*" ".*"
	touch $STAGE
}

# Partial Setup for Neutron and Nova (there is circular dependency so we have
# to setup them in smal increments)...
STAGE=$CFG_STAGE_DIR/060neutron-db
[ -f $STAGE ] || {
	setup_mysql_db neutron neutron
	touch $STAGE
}

STAGE=$CFG_STAGE_DIR/061neutron-svc
[ -f $STAGE ] || {
	register_service_in_keystone neutron 9696 "OpenStack Networking" neutron
	touch $STAGE
}

STAGE=$CFG_STAGE_DIR/062nova-db
[ -f $STAGE ] || {
	setup_mysql_db nova nova
	touch $STAGE
}

STAGE=$CFG_STAGE_DIR/063nova-svc
[ -f $STAGE ] || {
	register_service_in_keystone nova  8774/v2.1 "OpenStack Compute" nova
	touch $STAGE
}

STAGE=$CFG_STAGE_DIR/064neutron-pkg
[ -f $STAGE ] || {
	sudo eatmydata apt-get install -y neutron-server neutron-plugin-ml2 neutron-linuxbridge-agent \
       		python3-neutronclient neutron-macvtap-agent
	touch $STAGE
}

STAGE=$CFG_STAGE_DIR/065nova-pkg
[ -f $STAGE ] || {
	sudo eatmydata apt-get install -y nova-api nova-conductor nova-novncproxy nova-scheduler
	touch $STAGE
}



exit 0
