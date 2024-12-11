#!/bin/bash
# setup_openstack.sh - attempt to setup single-node OpenStack on Ubuntu 24.04 LTS
# USE ON YOUR OWN RISK!
# Utilizing OVS:
# - https://docs.openstack.org/neutron/2024.1/admin/deploy-ovs-provider.html
# - https://docs.openstack.org/neutron/2024.1/install/compute-install-option1-ubuntu.html

set -euo pipefail

# any non-empty string will enable eatmydata that will skip all fsync() calls favoring speed over "safety"
ENABLE_EATMYDATA=''
# NOTE: Enabling eatmydata will cause harmless (I hope) errors on packages install:
#   ERROR: ld.so: object 'libeatmydata.so' from LD_PRELOAD cannot be preloaded (cannot open shared object file): ignored.

# feel free to add your favorite packages to this variable:
EXTRA_PKGS='sysstat strace'
HOST=`hostname -f`
HOST_IP=`hostname -i`
METADATA_SECRET=Secret123

# change working directory to this script location
cd $(dirname $0)
# get full absolute path of this directory (we will later use it to apply Nova Bridge name patch)
WD=`pwd`

APT_CMD="apt-get"
[ -z "$ENABLE_EATMYDATA" ] || APT_CMD="eatmydata apt-get"

echo "HOST='$HOST' HOST_IP='$HOST_IP'"

ENABLE_TRACE="set -x"
#ENABLE_TRACE=true
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

wait_for_tcp_port ()
{
	set +x
	local port="$1"
	local timeout=60
	local service=''
	[ $# -lt 2 ] || timeout="$2"
	[ $# -lt 3 ] || service=" service $3"
	echo -n "Waiting for TCP port $port$service to be available, timeout=$timeout: "
	local t=0
	while [ $t -lt $timeout ]
	do
		ss -ltn | grep -qE ":$port\\s" && { $ENABLE_TRACE; return; }
		echo -n .
		sleep 1
		(( t = t + 1 ))
	done
	echo "ERROR: Reached timeout $timeout while waiting for TCP port $port" >&2
	exit 1
}

verify_manage_log ()
{
	set +x
	local f="$1"
	local not_regex=" INFO "
	[ $# -lt 2 ] || not_regex="$2"

	sudo test -r "$f" || {
		echo "ERROR: Unable to read logfile '$f'" >&2
		exit 1
	}
	! sudo grep -vE "$not_regex" $f || {
		echo "ERROR: Unexpected output (other than '$not_regex' level) in '$f'" >&2
		exit 1
	}
	$ENABLE_TRACE
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

[ -z "$ENABLE_EATMYDATA" ] || {
	STAGE=$CFG_STAGE_DIR/001a-eatmydata
	[ -f $STAGE ] || {
		sudo apt-get install -y eatmydata
		touch $STAGE
	}
}

STAGE=$CFG_STAGE_DIR/001basepkg
[ -f $STAGE ] || {
	sudo $APT_CMD install -y software-properties-common curl wget jq netcat-openbsd openssl crudini $EXTRA_PKGS
	touch $STAGE
}

STAGE=$CFG_STAGE_DIR/002enable-os-repo
[ -f $STAGE ] || {
	# we no longer enable OpenStack repo, but rather use Ubuntu's Default (Yoga release?)
	sudo $APT_CMD install -y python3-openstackclient
	touch $STAGE
}

STAGE=$CFG_STAGE_DIR/003install-mysql
[ -f $STAGE ] || {
	sudo $APT_CMD install -y mariadb-server python3-pymysql
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
	[ -r $MYSQL_ROOT_PWD_FILE ] || {
		openssl rand -hex 10 > $MYSQL_ROOT_PWD_FILE
		echo "MySQL root password saved into $MYSQL_ROOT_PWD_FILE"
	}
	p=`cat $MYSQL_ROOT_PWD_FILE`
	# Questions are:
	# 1. Enter current password for root  (\n)
	# 2. Switch to unix_socket authentication  (n\n)
	# 3. Change the root password (\n) # = Yes
	# 4. Enter Mysql root password 2 times
	# 5. Remove anonymous users? (\n) # = Yes
	# 6. Disallow root login remotely? (\n) # = Yes
	# 7. Remove test database and access to it? (\n) # = Yes
	# 8. Reload privilege tables now? (\n) # = Yes
	echo -e '\nn\n\n'"$p"'\n'"$p"'\n\n\n\n\n' | sudo mysql_secure_installation
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
	sudo $APT_CMD install -y memcached
	touch $STAGE
}

STAGE=$CFG_STAGE_DIR/011config-memcached
[ -f $STAGE ] || {
	sudo sed -i.bak -e 's/^-l.*/-l '"$HOST_IP"'/' /etc/memcached.conf
        sudo systemctl restart memcached
	wait_for_tcp_port 11211 60 Memcached
	touch $STAGE
}

wait_for_tcp_port 11211 5 Memcached


STAGE=$CFG_STAGE_DIR/020keystone-db
[ -f $STAGE ] || {
	setup_mysql_db keystone keystone
	touch $STAGE
}

STAGE=$CFG_STAGE_DIR/021keystone-pkg
[ -f $STAGE ] || {
	sudo $APT_CMD install -y keystone
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

keystone_manage_log=/var/log/keystone/keystone-manage.log
STAGE=$CFG_STAGE_DIR/023keystone-init
[ -f $STAGE ] || {
	sudo -u keystone keystone-manage db_sync
	verify_manage_log $keystone_manage_log
	touch $STAGE
}

STAGE=$CFG_STAGE_DIR/024keystone-init-fernet
[ -f $STAGE ] || {
	sudo keystone-manage fernet_setup --keystone-user keystone --keystone-group keystone
	verify_manage_log $keystone_manage_log
	touch $STAGE
}

STAGE=$CFG_STAGE_DIR/025keystone-init-cred
[ -f $STAGE ] || {
	sudo keystone-manage credential_setup --keystone-user keystone --keystone-group keystone
	verify_manage_log $keystone_manage_log
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
	wait_for_tcp_port 5000 30
	touch $STAGE
}

wait_for_tcp_port 5000 5 Keystone

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
	#true ||
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
	sudo $APT_CMD install -y glance
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
	# glance has no manage log???
	touch $STAGE
}

STAGE=$CFG_STAGE_DIR/035glance-mkdir
[ -f $STAGE ] || {
	sudo mkdir -p /var/lib/glance/images/
	sudo chown glance:glance /var/lib/glance/images/
	sudo systemctl restart glance-api
	sudo systemctl restart apache2
	sleep 2
	wait_for_tcp_port 9292 60 "Glance API"
	touch $STAGE
}

wait_for_tcp_port 9292 5 "Glance API"

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
	sudo $APT_CMD install -y placement-api python3-osc-placement
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
	# no manage.log for placement
	sudo systemctl restart apache2
	sleep 3
	wait_for_tcp_port 8778 60 "Placement"
	# verify that Placement works
	( source $CFG_BASE/keystonerc_admin
	  openstack resource class list )
	touch $STAGE
}

wait_for_tcp_port 8778 3 "Placement"

# Setup RabbitMQ
STAGE=$CFG_STAGE_DIR/050rabbit-pkg
[ -f $STAGE ] || {
	# NOTE: eatmydata somehow clashes with erlang setup
	sudo $APT_CMD install -y rabbitmq-server
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
	wait_for_tcp_port 5672 30 RabbitMQ
	touch $STAGE
}

wait_for_tcp_port 5672 5 RabbitMQ

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
	register_service_in_keystone neutron 9696 "OpenStack Networking" network
	touch $STAGE
}

STAGE=$CFG_STAGE_DIR/062nova-db
[ -f $STAGE ] || {
	setup_mysql_db nova nova
	setup_mysql_db nova_api nova
	setup_mysql_db nova_cell0 nova
	touch $STAGE
}

STAGE=$CFG_STAGE_DIR/063nova-svc
[ -f $STAGE ] || {
	register_service_in_keystone nova  8774/v2.1 "OpenStack Compute" compute
	touch $STAGE
}

STAGE=$CFG_STAGE_DIR/064neutron-pkg
[ -f $STAGE ] || {
	sudo $APT_CMD install -y neutron-server neutron-plugin-ml2 \
       		python3-neutronclient neutron-openvswitch-agent \
		neutron-metadata-agent neutron-dhcp-agent
	# Disable and stop all services until they are properly configured to avoid eating CPU, etc...
	sudo systemctl disable --now neutron-openvswitch-agent.service \
		neutron-ovs-cleanup.service neutron-server.service \
		neutron-dhcp-agent.service neutron-metadata-agent.service
	# remove clutter of errors because services are not configured yet
	sudo find /var/log/neutron/ -name '*.log' -a -delete
	touch $STAGE
}

STAGE=$CFG_STAGE_DIR/065nova-pkg
[ -f $STAGE ] || {
	sudo $APT_CMD install -y nova-api nova-conductor nova-novncproxy nova-scheduler
	# Disable and stop all services until they are properly configured to avoid eating CPU, etc...
	# Except qemu-kvm.service
	sudo systemctl disable --now nova-conductor.service nova-api.service \
		nova-scheduler.service nova-novncproxy.service
	# remove clutter of errors because services are not configured yet
	sudo find /var/log/nova/ -name '*.log' -a -delete
	touch $STAGE
}

STAGE=$CFG_STAGE_DIR/066-nova-cfg
[ -f $STAGE ] || {
	svc=nova
	f=/etc/nova/nova.conf
	p=`extract_db_pwd $svc`
        rp=$(extract_svc_pwd rabbit)
        np=$(extract_svc_pwd nova)

	# configuration based on: https://docs.openstack.org/nova/latest/install/controller-install-ubuntu.html
	sudo crudini --set $f api_database connection "mysql+pymysql://$svc:$p@$HOST/nova_api"
	sudo crudini --set $f database connection "mysql+pymysql://$svc:$p@$HOST/nova"
	sudo crudini --set $f DEFAULT transport_url "rabbit://openstack:$rp@$HOST:5672/"
	sudo crudini --set $f DEFAULT my_ip "$HOST_IP"
	# configure VM using virtual CD ROM drive instead of Metadata server
	sudo crudini --set $f DEFAULT force_config_drive True

	sudo crudini --set $f api auth_strategy keystone

	sudo crudini --set $f keystone_authtoken auth_url "http://$HOST:5000/"
	sudo crudini --set $f keystone_authtoken memcached_servers  "$HOST:11211"
	sudo crudini --set $f keystone_authtoken auth_type password
	sudo crudini --set $f keystone_authtoken project_domain_name Default
	sudo crudini --set $f keystone_authtoken user_domain_name  Default
	sudo crudini --set $f keystone_authtoken project_name service
	sudo crudini --set $f keystone_authtoken username "$svc"
	sudo crudini --set $f keystone_authtoken password `extract_svc_pwd $svc`

	sudo crudini --set $f service_user send_service_user_token true
	# auth URL must match keystone_manage --bootstrap-public-url value
	#sudo crudini --set $f service_user auth_url  "http://$HOST:5000/v3"
	sudo crudini --set $f service_user auth_url  "http://$HOST:5000"
	sudo crudini --set $f service_user auth_strategy keystone
	sudo crudini --set $f service_user auth_type password
	sudo crudini --set $f service_user project_domain_name Default
	sudo crudini --set $f service_user project_name service
	sudo crudini --set $f service_user user_domain_name Default
	sudo crudini --set $f service_user username "$svc"
	sudo crudini --set $f service_user password "$np"

	sudo crudini --set $f vnc enabled true
	#sudo crudini --set $f vnc server_listen "$HOST_IP"
	#sudo crudini --set $f spice server_proxyclient_address  "$HOST_IP"

	sudo crudini --set $f glance api_servers  "http://$HOST:9292"
	sudo crudini --set $f oslo_concurrency lock_path  /var/lib/nova/tmp

	sudo crudini --set $f placement region_name RegionOne
	sudo crudini --set $f placement project_domain_name Default
	sudo crudini --set $f placement project_name service
	sudo crudini --set $f placement auth_type password
	sudo crudini --set $f placement user_domain_name Default
	sudo crudini --set $f placement auth_url "http://$HOST:5000/v3"
	sudo crudini --set $f placement username placement
	sudo crudini --set $f placement password $(extract_svc_pwd placement)

	# from: https://docs.openstack.org/neutron/latest/install/controller-install-ubuntu.html#configure-the-compute-service-to-use-the-networking-service
	sudo crudini --set $f neutron auth_url  "http://$HOST:5000"
	sudo crudini --set $f neutron auth_type password
	sudo crudini --set $f neutron project_domain_name Default
	sudo crudini --set $f neutron user_domain_name Default
	sudo crudini --set $f neutron region_name RegionOne
	sudo crudini --set $f neutron project_name service
	sudo crudini --set $f neutron username neutron
	sudo crudini --set $f neutron password $(extract_svc_pwd neutron)
	sudo crudini --set $f neutron service_metadata_proxy true
	sudo crudini --set $f neutron metadata_proxy_shared_secret $METADATA_SECRET

	#sudo diff $f{.orig,}
	touch $STAGE
}

# configuration from https://docs.openstack.org/neutron/latest/install/controller-install-option1-ubuntu.html
STAGE=$CFG_STAGE_DIR/068-neutron-cfg
[ -f $STAGE ] || {
	svc=neutron
	f=/etc/neutron/neutron.conf
	p=`extract_db_pwd $svc`
        rp=$(extract_svc_pwd rabbit)

	sudo crudini --set $f database connection "mysql+pymysql://$svc:$p@$HOST/neutron"
	sudo crudini --set $f DEFAULT core_plugin ml2
	# service_plugins should be empty
	sudo crudini --set $f DEFAULT service_plugins ''
	sudo crudini --set $f DEFAULT transport_url "rabbit://openstack:$rp@$HOST:5672/"
	sudo crudini --set $f DEFAULT auth_strategy keystone
	sudo crudini --set $f DEFAULT notify_nova_on_port_status_changes true
	sudo crudini --set $f DEFAULT notify_nova_on_port_data_changes true
	sudo crudini --set $f DEFAULT dhcp_agents_per_network 1

	sudo crudini --set $f keystone_authtoken www_authenticate_uri "http://$HOST:5000"
	sudo crudini --set $f keystone_authtoken auth_url "http://$HOST:5000"
	sudo crudini --set $f keystone_authtoken memcached_servers  "$HOST:11211"
	sudo crudini --set $f keystone_authtoken auth_type password
	sudo crudini --set $f keystone_authtoken project_domain_name Default
	sudo crudini --set $f keystone_authtoken user_domain_name  Default
	sudo crudini --set $f keystone_authtoken project_name service
	sudo crudini --set $f keystone_authtoken username "$svc"
	sudo crudini --set $f keystone_authtoken password `extract_svc_pwd $svc`

	sudo crudini --set $f nova auth_url "http://$HOST:5000"
	sudo crudini --set $f nova auth_type password
	sudo crudini --set $f nova project_domain_name Default
	sudo crudini --set $f nova user_domain_name Default
	sudo crudini --set $f nova region_name RegionOne
	sudo crudini --set $f nova project_name service
	sudo crudini --set $f nova username nova
	sudo crudini --set $f nova password `extract_svc_pwd nova`

	sudo crudini --set $f oslo_concurrency lock_path /var/lib/neutron/tmp

	# https://docs.openstack.org/neutron/latest/admin/deploy-lb-provider.html
	f=/etc/neutron/plugins/ml2/ml2_conf.ini
	sudo crudini --set $f ml2 type_drivers flat,vlan
	sudo crudini --set $f ml2 tenant_network_types ''
	sudo crudini --set $f ml2 mechanism_drivers openvswitch
	sudo crudini --set $f ml2 extension_drivers port_security
	sudo crudini --set $f ml2_type_flat flat_networks provider

	# Agent part (Compute)
	f=/etc/neutron/plugins/ml2/openvswitch_agent.ini
	# see https://docs.openstack.org/neutron/2024.1/admin/deploy-ovs-provider.html
	# see https://docs.openstack.org/neutron/2024.1/install/compute-install-option1-ubuntu.html
	sudo crudini --set $f ovs bridge_mappings 'provider:br-provider'
	sudo crudini --set $f ovs securitygroup firewall_driver openvswitch

	# we don't plan to use DHCP but just following docs
	f=/etc/neutron/dhcp_agent.ini
	sudo crudini --set $f DEFAULT interface_driver openvswitch
	sudo crudini --set $f DEFAULT enable_isolated_metadata True
	sudo crudini --set $f DEFAULT force_metadata True

	# Neutron Metadata Agent
	f=/etc/neutron/metadata_agent.ini
	sudo crudini --set $f DEFAULT nova_metadata_host "$HOST_IP"
	sudo crudini --set $f DEFAULT metadata_proxy_shared_secret $METADATA_SECRET
	touch $STAGE
}

STAGE=$CFG_STAGE_DIR/068-neutron-ovs-br
[ -f $STAGE ] || {
	sudo ovs-vsctl add-br br-provider
	sudo ovs-vsctl add-port br-provider eth1
	touch $STAGE
}

STAGE=$CFG_STAGE_DIR/067-nova-syncd
[ -f $STAGE ] || {
	sudo -u nova nova-manage api_db sync
	sudo -u nova nova-manage cell_v2 map_cell0
	sudo -u nova nova-manage cell_v2 create_cell --name=cell1 --verbose
	sudo -u nova nova-manage db sync
        sudo -u nova nova-manage cell_v2 list_cells
	verify_manage_log /var/log/nova/nova-manage.log
	touch $STAGE
}

STAGE=$CFG_STAGE_DIR/068b-neutron-db-manage1
[ -f $STAGE ] || {
	sudo -u neutron neutron-db-manage --config-file /etc/neutron/neutron.conf --config-file /etc/neutron/plugins/ml2/ml2_conf.ini upgrade head
	# TODO: Verify log on stdout
	touch $STAGE
}

# Enable + start Nova and Neutron in proper order (ehm)...
STAGE=$CFG_STAGE_DIR/069-nova-proxy
[ -f $STAGE ] || {
	sudo systemctl enable --now nova-novncproxy.service
	wait_for_tcp_port 6080 60 "Nova NoVNC proxy"
	touch $STAGE
}
wait_for_tcp_port 6080 5 "Nova NoVNC proxy"

STAGE=$CFG_STAGE_DIR/069-nova-api
[ -f $STAGE ] || {
	sudo systemctl enable --now nova-api.service
	wait_for_tcp_port 8774 60 "Nova API"
	touch $STAGE
}
wait_for_tcp_port 8774 5 "Nova API"

STAGE=$CFG_STAGE_DIR/069-nova-scheduler
[ -f $STAGE ] || {
	sudo systemctl enable --now nova-scheduler.service
	# FIXME: Know no way how to find if scheduler is running (no LISTEN port?)
	touch $STAGE
}

STAGE=$CFG_STAGE_DIR/069-nova-conductor
[ -f $STAGE ] || {
	sudo systemctl enable --now nova-conductor.service
	# FIXME: Know no way how to find if conductor is running (no LISTEN port?)
	touch $STAGE
}

# Now start Neutron services in order
STAGE=$CFG_STAGE_DIR/070-neutron-server
[ -f $STAGE ] || {
	sudo systemctl enable --now neutron-server.service
	wait_for_tcp_port 9696 60 "Neutron API"
	touch $STAGE
}
wait_for_tcp_port 9696 5 "Neutron API"

STAGE=$CFG_STAGE_DIR/070-neutron-ovs
[ -f $STAGE ] || {
	sudo systemctl enable --now neutron-openvswitch-agent.service neutron-ovs-cleanup.service
	# FIXME: Know no way how to detect if service is running properly
	touch $STAGE
}

STAGE=$CFG_STAGE_DIR/070b-neutron-agents-enable
[ -f $STAGE ] || {
	# re-enable
	sudo systemctl enable --now \
		neutron-dhcp-agent.service neutron-metadata-agent.service
	touch $STAGE
}

# create provider network without VLAN - see: https://docs.openstack.org/neutron/latest/admin/deploy-lb-provider.html#create-initial-networks
STAGE=$CFG_STAGE_DIR/080-create-network
[ -f $STAGE ] || {
	( source $CFG_BASE/keystonerc_admin
	  openstack network create --share --provider-physical-network provider \
		  --disable-port-security \
		  --provider-network-type flat provider1
	)
	touch $STAGE
}

STAGE=$CFG_STAGE_DIR/081-create-subnet
[ -f $STAGE ] || {
	( source $CFG_BASE/keystonerc_admin
	# from: https://docs.openstack.org/install-guide/launch-instance-networks-provider.html
	openstack subnet create --network provider1 \
	  --allocation-pool start=192.168.124.10,end=192.168.124.200 \
	  --dns-nameserver 192.168.124.1 --gateway 192.168.124.1 \
	  --subnet-range 192.168.124.0/24 provider1-v4
	)
	touch $STAGE
}

# Setting Nova Compute
# https://docs.openstack.org/nova/2023.2/install/compute-install-ubuntu.html

STAGE=$CFG_STAGE_DIR/090nova-compute-pkg
[ -f $STAGE ] || {
	sudo $APT_CMD install -y nova-compute
	sudo systemctl disable --now nova-compute.service
	# remove log - we did not configured Nova yet
	sudo rm -f /var/log/nova/nova-compute.log
	touch $STAGE
}

STAGE=$CFG_STAGE_DIR/090bnova-disable-default-net
[ -f $STAGE ] || {
	# https://docs.openstack.org/neutron/2024.2/admin/misc-libvirt.html
	sudo virsh net-destroy default # means "stop"
	sudo virsh net-autostart --network default --disable
	touch $STAGE
}

STAGE=$CFG_STAGE_DIR/091nova-compute-cfg
[ -f $STAGE ] || {
	svc=nova
	f=/etc/nova/nova.conf
	sudo crudini --set $f vnc novncproxy_base_url  "http://$HOST:6080/vnc_auto.html"

	sudo systemctl enable --now nova-compute.service
	sleep 10

	( source $CFG_BASE/keystonerc_admin
	# TOOD: verify that our 1 node is there
	openstack compute service list --service nova-compute
	sudo -u nova nova-manage cell_v2 discover_hosts --verbose
	)
	touch $STAGE
}

STAGE=$CFG_STAGE_DIR/092neutron-dbsync
[ -f $STAGE ] || {
	sudo -u neutron neutron-db-manage --config-file /etc/neutron/neutron.conf --config-file /etc/neutron/plugins/ml2/ml2_conf.ini upgrade head
	touch $STAGE
}

# to launch VM we have to configure 'default' security group (although our 'macvtap' network
# has NOP firewall it is still good to define basic rules)
# from https://opendev.org/openstack/devstack/src/branch/master/samples/local.sh

STAGE=$CFG_STAGE_DIR/100security-rules
[ -f $STAGE ] || {
	( source $CFG_BASE/keystonerc_admin
	openstack security group rule create --protocol icmp default
	openstack security group rule create --protocol tcp --dst-port 22 default
	)
	touch $STAGE
}

# need at lest 1 flavor to launch VM
STAGE=$CFG_STAGE_DIR/101flavors
[ -f $STAGE ] || {
	( source $CFG_BASE/keystonerc_admin
	# from: https://docs.openstack.org/install-guide/launch-instance.html
	openstack flavor create --id 0 --vcpus 1 --ram 64 --disk 1 m1.nano
	# from: https://opendev.org/openstack/devstack/src/branch/master/lib/nova
	openstack flavor create --id 1 --ram 512 --disk 1 --vcpus 1 m1.tiny
	openstack flavor create --id 2 --ram 2048 --disk 20 --vcpus 1 m1.small
	openstack flavor create --id 3 --ram 4096 --disk 40 --vcpus 2 m1.medium
	openstack flavor create --id 4 --ram 8192 --disk 80 --vcpus 4 m1.large
	openstack flavor create --id 5 --ram 16384 --disk 160 --vcpus 8 m1.xlarge
	# from https://opendev.org/openstack/devstack/src/branch/master/samples/local.sh
	openstack flavor create --id 6 --ram 128 --disk 0 --vcpus 1 m1.micro
	openstack flavor list
	)
	touch $STAGE
}

set +x
echo "Ensure that on list below the 'State' column has value 'Up'"
( source $CFG_BASE/keystonerc_admin
	openstack hypervisor list
)

cat <<EOF
OK: SETUP FINISHED!

Now you can create your fist VM using commands like:

# do not taint main bash environment:
bash
source $CFG_BASE/keystonerc_admin
openstack server create --flavor m1.tiny --image cirros --nic net-id=provider1 vm1
# then poll until server is ACTIVE
openstack server list
# to see boot messages use:
console log show vm1
# to connect to console use:
console url show vm1
# exit OpenStack environment when done:
exit
EOF

exit 0
