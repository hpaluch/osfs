# OpenStack from Scratch (OSFS)

Here is early stage of script to setup single-node OpenStack
under Ubuntu 22.04 LTS. My goal is to use simplest Network topology
called `macvtap` where VM directly attaches to select Bridge (in my case `br-ex`).

Why not using DevStack? DevStack install everything from source which is not
typical setup (that is suitable for development of OpenStack, but how many
users do that?). And it is currently too sophisticated to be easy to
understand.

Basically I plan to replicate steps shown on my (unfinished!) wiki page:
- https://github.com/hpaluch/hpaluch.github.io/wiki/OpenStack-from-Scratch

# Status

Finally I was able to query and create Network for future VM.

> But VM creation still fails. Some errors are quite recent:
> https://bugs.launchpad.net/neutron/+bug/2028285
>
> To workaround this bug - when you (re)start `neutron-server` service.
> Your first command should be for example `openstack network list`.
> Only after network command you can issue Nova command (for example
> `openstack server list`). Otherwise it will fail with persistent
> error:
>
> `AttributeError: type object 'Port' has no attribute 'port_forwardings'`
> 
> Once this error occurs you have to restart `neutron-server` service and
> try again commands in "right" order...


It is quite easy to know if OpenStack is configured properly: few minutes
after bootup the CPU load should settle to 20% or so (tested on single core VM).

If there is high CPU usage and load average above 3 or so, it means that some services
are flapping and restarting forever... In such case you have to scan all logs
under `/var/log/SERVICE_NAME/*.log` for cause.

So what works:
* Infrastructure: MysQL (MariaDB), Memcached, RabbitMQ
* Services:
  - Keystone (authentication)
  - Glance (disk image store - required to start new VM which has temporary disk)
  - Placement - scheduler that selects Compute node where to start VM

What needs to be verified (but looks promising):
* Nova (Compute service - runs VM)
* Neutron (Network service)

# Requirements

* Ubuntu 22.04 LTS (it is only OS where OpenStack is actively developed)
* Set up Bridge Interface with static IP address - please
  see https://github.com/hpaluch/hpaluch.github.io/wiki/OpenStack-from-Scratch
* there is example NetPlan config under `example/etc/netplan/99-openstack.yaml`.
  You need to change IP address/gatway and also define static hostname with
  static IP address and other stuff.

# Verification 

When script is finished you can verify various setting using:

```shell
source ~/.config/osfs/keystonerc_admin
openstack # will enter OpenStack shell
```
I strongly recommend to use above OpenStack shell to speed up all queries. Here are 
few recommended:

```
# enter in openstack shell

(openstack) network list
+--------------------------------------+----------+---------+
| ID                                   | Name     | Subnets |
+--------------------------------------+----------+---------+
| 335f2d4e-095c-4987-b544-bf791f8b95a8 | provider |         |
+--------------------------------------+----------+---------+

(openstack) service list
+----------------------------------+-----------+-----------+
| ID                               | Name      | Type      |
+----------------------------------+-----------+-----------+
| 38d76d42954e4587a508be09a01940c3 | neutron   | network   |
| 397ed16034834ed6af89d01de77ad1f2 | nova      | compute   |
| 4713d1ac840b47168eec85994c17ea17 | keystone  | identity  |
| 5a8ab168da114bc39b493d53e2e970a0 | glance    | image     |
| 69243209f8ba432181e13c9e8d0c8806 | placement | placement |
+----------------------------------+-----------+-----------+

(openstack) image list
+--------------------------------------+--------+--------+
| ID                                   | Name   | Status |
+--------------------------------------+--------+--------+
| 24628c8a-36f8-4316-83db-1d3e0f9746b1 | cirros | active |
+--------------------------------------+--------+--------+

(openstack) hypervisor list
+--------------------------------------+---------------------+-----------------+-------------+-------+
| ID                                   | Hypervisor Hostname | Hypervisor Type | Host IP     | State |
+--------------------------------------+---------------------+-----------------+-------------+-------+
| 150d7bda-de19-4ee6-b4e2-3ea69117afbc | osfs1               | QEMU            | 192.168.0.5 | up    |
+--------------------------------------+---------------------+-----------------+-------------+-------+

(openstack) flavor list

+----+-----------+-------+------+-----------+-------+-----------+
| ID | Name      |   RAM | Disk | Ephemeral | VCPUs | Is Public |
+----+-----------+-------+------+-----------+-------+-----------+
| 0  | m1.nano   |    64 |    1 |         0 |     1 | True      |
| 1  | m1.tiny   |   512 |    1 |         0 |     1 | True      |
| 2  | m1.small  |  2048 |   20 |         0 |     1 | True      |
| 3  | m1.medium |  4096 |   40 |         0 |     2 | True      |
| 4  | m1.large  |  8192 |   80 |         0 |     4 | True      |
| 5  | m1.xlarge | 16384 |  160 |         0 |     8 | True      |
| 6  | m1.micro  |   128 |    0 |         0 |     1 | True      |
+----+-----------+-------+------+-----------+-------+-----------+

(openstack) security group list
+--------------------------------------+---------+------------------------+----------------------------------+------+
| ID                                   | Name    | Description            | Project                          | Tags |
+--------------------------------------+---------+------------------------+----------------------------------+------+
| 684e105f-321c-4e3c-9840-1b2a665cfe4a | default | Default security group | c57cd6e8d03c49a7acbac57dbac2c0b0 | []   |
+--------------------------------------+---------+------------------------+----------------------------------+------+
```


TODO:

Problem starting VM:
```
openstack server create --flavor m1.tiny --image cirros --nic net-id=provider vm1
# ok
# but:
openstack server list
+--------------------------------------+------+--------+----------+--------+---------+
| ID                                   | Name | Status | Networks | Image  | Flavor  |
+--------------------------------------+------+--------+----------+--------+---------+
| 2daf6b4f-8fec-4bde-8e96-f3fb4a62603c | vm1  | ERROR  |          | cirros | m1.tiny |
+--------------------------------------+------+--------+----------+--------+---------+
openstack server show -f yaml vm1
```
TODO...

```
port create --network provider port1
port set port1 --vnic-type macvtap
server create --flavor m1.tiny --image cirros --nic port-id=port1 vm3
```

For the first time got different error than Neutron:
- from `/var/log/nova/nova-conductor.log`

```
023-11-28 17:02:11.853 1109 ERROR nova.scheduler.utils [req-4c672f5e-faa3-4783-b84a-1c2d45c0b6d1 658ba1b46eb04903a0dc86a4b77842e1 e4
52b873d3ac4ef48d5edf7f9de8db1b - default default] [instance: d54cd7b2-b2fa-4df0-b7e2-7b3f83c94333] Error from last host: osfs1 (node 
osfs1): ['Traceback (most recent call last):\n', '  File "/usr/lib/python3/dist-packages/nova/compute/manager.py", line 2487, in _bui
ld_and_run_instance\n    with self.rt.instance_claim(context, instance, node, allocs,\n', '  File "/usr/lib/python3/dist-packages/osl
o_concurrency/lockutils.py", line 391, in inner\n    return f(*args, **kwargs)\n', '  File "/usr/lib/python3/dist-packages/nova/compu
te/resource_tracker.py", line 171, in instance_claim\n    claim = claims.Claim(context, instance, nodename, self, cn,\n', '  File "/u
sr/lib/python3/dist-packages/nova/compute/claims.py", line 74, in __init__\n    self._claim_test(compute_node, limits)\n', '  File "/
usr/lib/python3/dist-packages/nova/compute/claims.py", line 117, in _claim_test\n    raise exception.ComputeResourcesUnavailable(reas
on=\n', 'nova.exception.ComputeResourcesUnavailable: Insufficient compute resources: Claim pci failed.\n', '\nDuring handling of the 
above exception, another exception occurred:\n\n', 'Traceback (most recent call last):\n', '  File "/usr/lib/python3/dist-packages/no
va/compute/manager.py", line 2336, in _do_build_and_run_instance\n    self._build_and_run_instance(context, instance, image,\n', '  F
ile "/usr/lib/python3/dist-packages/nova/compute/manager.py", line 2538, in _build_and_run_instance\n    raise exception.RescheduledE
xception(\n', 'nova.exception.RescheduledException: Build of instance d54cd7b2-b2fa-4df0-b7e2-7b3f83c94333 was re-scheduled: Insuffic
ient compute resources: Claim pci failed.\n']
```


Example how to get function, filename and line in log file:

```diff
diff -u /etc/neutron/neutron.conf{.orig,}
--- /etc/neutron/neutron.conf.orig	2023-11-28 16:45:22.876726934 +0000
+++ /etc/neutron/neutron.conf	2023-11-28 16:47:34.727207600 +0000
@@ -444,6 +444,7 @@
 # Format string to use for log messages when context is undefined. Used by
 # oslo_log.formatters.ContextFormatter (string value)
 #logging_default_format_string = %(asctime)s.%(msecs)03d %(process)d %(levelname)s %(name)s [-] %(instance)s%(message)s
+logging_default_format_string = %(asctime)s %(levelname)s %(funcName)s %(pathname)s:%(lineno)d %(name)s [-] %(instance)s%(message)s
 
 # Additional data to append to log message when logging level for the message
 # is DEBUG. Used by oslo_log.formatters.ContextFormatter (string value)
```

And then:

```shell
systemctl stop neutron-server
rm /var/log/neutron/neutron-server.log
systemctl start neutron-server
```

