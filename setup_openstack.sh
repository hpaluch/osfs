#!/bin/bash
# setup_openstack.sh - attempt to setup single-node OpenStack on Ubuntu 22.04 LTS
# USE ON YOUR OWN RISK!

set -euo pipefail

HOST=`hostname`
HOST_IP=`hostname -i`
RELEASE=antelope

echo "HOST='$HOST' HOST_IP='$HOST_IP' Release='$RELEASE'"

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

	[ -r "$f" ] || {
		echo "ERROR: Unable to read logfile '$f'" >&2
		exit 1
	}
	! grep -vE "$not_regex" $f || {
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
	sudo eatmydata apt-get install -y neutron-server neutron-plugin-ml2 neutron-linuxbridge-agent \
       		python3-neutronclient neutron-macvtap-agent
	touch $STAGE
}

STAGE=$CFG_STAGE_DIR/065nova-pkg
[ -f $STAGE ] || {
	sudo eatmydata apt-get install -y nova-api nova-conductor nova-novncproxy nova-scheduler
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
	sudo crudini --set $f service_user auth_url  "http://$HOST/identity"
	sudo crudini --set $f service_user auth_strategy keystone
	sudo crudini --set $f service_user auth_type password
	sudo crudini --set $f service_user project_domain_name Default
	sudo crudini --set $f service_user project_name service
	sudo crudini --set $f service_user user_domain_name Default
	sudo crudini --set $f service_user username "$svc"
	sudo crudini --set $f service_user password "$np"

	sudo crudini --set $f vnc enabled true
	sudo crudini --set $f vnc server_listen "$HOST_IP"
	sudo crudini --set $f server_proxyclient_address  "$HOST_IP"

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
	# We don't use metadata service (OpenStack is complex enough even without metadata)
	sudo crudini --set $f neutron service_metadata_proxy false
	sudo crudini --set $f neutron metadata_proxy_shared_secret METADATA_SECRET

	#sudo diff $f{.orig,}
	touch $STAGE
}
STAGE=$CFG_STAGE_DIR/067-nova-syncd
[ -f $STAGE ] || {
	sudo -u nova nova-manage api_db sync
	sudo -u nova nova-manage cell_v2 map_cell0
	sudo -u nova nova-manage cell_v2 create_cell --name=cell1 --verbose
	sudo -u nova nova-manage db sync
        sudo -u nova nova-manage cell_v2 list_cells
	for s in nova-api nova-scheduler nova-conductor nova-novncproxy
	do
		sudo systemctl restart $s
	done
	wait_for_tcp_port 8774 60 "Nova API"
	touch $STAGE
}

wait_for_tcp_port 8774 5 "Nova API"

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

	f=/etc/neutron/plugins/ml2/ml2_conf.ini
	sudo crudini --set $f ml2 type_drivers flat
	sudo crudini --set $f ml2 tenant_network_types ''
	# from: https://docs.openstack.org/neutron/latest/admin/config-macvtap.html
	sudo crudini --set $f ml2 mechanism_drivers macvtap
	sudo crudini --set $f ml2_type_flat flat_networks "provider,macvtap"

	f=/etc/neutron/plugins/ml2/macvtap_agent.ini
	sudo crudini --set $f macvtap physical_interface_mappings "macvtap:br-ex"
	sudo crudini --set $f securitygroup firewall_driver noop

	echo "Please restart whole system to ensure that all Configuration changes had been applied."
	echo "And then rerun this script again..."
	touch $STAGE
	exit 0
}

STAGE=$CFG_STAGE_DIR/068b-neutron-db-manage1
[ -f $STAGE ] || {
	sudo -u neutron neutron-db-manage --config-file /etc/neutron/neutron.conf --config-file /etc/neutron/plugins/ml2/ml2_conf.ini upgrade head
	echo "Please restart whole system to ensure that all Configuration changes had been applied."
	echo "And then rerun this script again..."
	touch $STAGE
	exit 0
}
	
wait_for_tcp_port 9696 20 "Neutron API"

STAGE=$CFG_STAGE_DIR/069-create-network
[ -f $STAGE ] || {
	( source $CFG_BASE/keystonerc_admin
	  openstack network create  --share --external \
	  --provider-physical-network provider \
	  --provider-network-type flat provider
	)
	touch $STAGE
	exit 0
}

# Setting Nova Compute
# https://docs.openstack.org/nova/2023.2/install/compute-install-ubuntu.html

STAGE=$CFG_STAGE_DIR/070nova-compute-pkg
[ -f $STAGE ] || {
	sudo eatmydata apt-get install -y nova-compute
	touch $STAGE
}

STAGE=$CFG_STAGE_DIR/071nova-compute-cfg
[ -f $STAGE ] || {
	svc=nova
	f=/etc/nova/nova.conf
	sudo crudini --set $f vnc novncproxy_base_url  "http://$HOST:6080/vnc_auto.html"

	sudo systemctl restart nova-compute
	sleep 10

	( source $CFG_BASE/keystonerc_admin
	# TOOD: verify that our 1 node is there
	openstack compute service list --service nova-compute
	sudo -u nova nova-manage cell_v2 discover_hosts --verbose
	)
	touch $STAGE
}

STAGE=$CFG_STAGE_DIR/072neutron-dbsync
[ -f $STAGE ] || {
	sudo -u neutron neutron-db-manage --config-file /etc/neutron/neutron.conf --config-file /etc/neutron/plugins/ml2/ml2_conf.ini upgrade head
	touch $STAGE
}
	

exit 0
