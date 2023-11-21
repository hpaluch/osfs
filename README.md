# OpenStack from Scratch (OSFS)

Here is early stage of script to setup single-node OpenStack
under Ubuntu 22.04 LTS.

Why not using DevStack? DevStack install everything from source which is not
typical setup (that is suitable for development of OpenStack, but how many
users do that?). And it is currently too sophisticated to be easy to
understand.

Basically I plan to replicate steps shown on my (unfinished!) wiki page:
- https://github.com/hpaluch/hpaluch.github.io/wiki/OpenStack-from-Scratch

# Status

Everything goes well until final Neutron + Nova setup - which has too many
options and partially circular dependencies... However someday I will
hopefully find the right way...

So what works:
* Infrastructure: MysQL (MariaDB), Memcached, RabbitMQ
* Services:
  - Keystone (authentication)
  - Glance (disk image store - required to start new VM which has temporary disk)
  - Placement - scheduler that selects Compute node where to start VM

What is not yet working properly:
* Nova (Compute service - runs VM)
* Neutron (Network service)

# Requirements

* Ubuntu 22.04 LTS (it is only OS where OpenStack is actively developed)
* Set up Bridge Interface with static IP address - please
  see https://github.com/hpaluch/hpaluch.github.io/wiki/OpenStack-from-Scratch
* there is example NetPlan config under `example/etc/netplan/99-openstack.yaml`.
  You need to change IP address/gatway and also define static hostname with
  static IP address and other stuff.


