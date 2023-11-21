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

# empty: problem: need at least one flavor
```

TODO:
- define Flavor
- try to start VM


