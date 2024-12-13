# It Works! Configure OpenStack with ML2/OVN - 2 interfaces

Here is minimal supported configuration of OpenStack using ML2/OVN and 2
network interfaces. It supports both Provider network and Self-service network
(using `geneve` overlays)

> [!NOTE]
> This network setup (ML2/OVN) is presented as official future for OpenStack -
> LinuxBridge is already deprecated and similar fate will likely happen to L3
> Agents for OVS (without OVN) - once most customers migrate to OVN...  See
> https://fairbanks.nl/migrating-to-ovn/ for example.  But not everything is
> rose, there are also some issues, for example:
> https://f0o.dev/posts/2024/05/openstack--ovn--full-bgp-tables-heaven/

> [!WARNING]
> Although this setup works for me I make no guarantee that is correct! OVN
> is poorly documented - typical answer is to "use Ansible" or "use DevStack" or
> "use TripleO" (that was already killed in 2023)...

Quick recap:
- L3 (Layer3) is level at IP protocol (for example DHCP) and there is also mix of L2 and L3 protocols
  (ARP that allows mapping MAC <-> IP address)
- L2 (Layer3) is ethernet level protocol - it knows only MAC addresses and ethernet related functions,
  for example, broadcasts, VLANs ...

How is OVN L3 setup different from OVS L2 + Agents?
- OVN is L3 layer switch - ARP resolution and DHCP is handled directly at OVN level. So when guest
  sends DHCP broadcast, OVN responds (emulating DHCP server). 
- so there is no longer DHCP Agent and there is no longer "L3 Agent"
- OVS  is still there as L2 switch so it does handle only ethernet stuff 
- these packages were dropped in OVN setup: neutron-metadata-agent neutron-dhcp-agent neutron-l3-agent
- and these are new packages in OVN setup: ovn-host openvswitch-switch neutron-ovn-metadata-agent ovn-central
- notice that metadata are still there but in different package.
- please see nice table on: https://docs.openstack.org/neutron/latest/ovn/faq/index.html
  for detailed comparison

Tested environment:
- Tested OS: `Ubuntu 24.04.1 LTS (Noble Numbat)`
- OpenStack version: output of `dpkg -l neutron-common` is: `2:24.0.0-0ubuntu1`. It should
  be https://releases.openstack.org/caracal/index.html. However official page
  does not contains Ubuntu 24 LTS yet: https://ubuntu.com/openstack/docs/supported-versions

You need to have 2 interfaces:
* `eth0` management interface - in my case 192.168.122.85/24 with access to Internet
* `eth1` "public" (also provider) network - 192.168.124.0/24 with access to Internet, however
   it should be just UP but no IP address assigned (OpenStack OVS backend will do that).
   There should be NO running DHCP server on this network (OpenStack will run its own version of DHCP).

- before setup you have to evaluate and apply these files
- `etc/netplan/99-openstack.yaml`
  - replace your `/etc/netplan` with this file, customize it and use `netplan generate && netplan apply`
  - WARNING! `netplan apply` will likely kill you network connection!
- also review and apply:
  - `etc/hosts`
  - `etc/hostname`
  - example how to stop renaming interfaces (keep `eth0`): `etc/default/grub`

When your PC works properly you can run

- review script `setup_openstack_ovn_full.sh`
- you will likely need to customize command `network create ...` at the end of
  script to fit your network
- finally run `./setup_openstack_ovn_full.sh` in this directory.
- and follow instructions how to create 1st VM

Once your VM starts you should be able to access it remotely (use `openstack
server list` to find its IP address) using from other host just: `ssh
cirros@REMOTE_IP`

Example when `vm1` is running:
```shell
$ openstack server list 

+-------------------------+------+--------+--------------------------+--------+---------+
| ID                      | Name | Status | Networks                 | Image  | Flavor  |
+-------------------------+------+--------+--------------------------+--------+---------+
| 0059c618-d841-436d-     | vm1  | ACTIVE | selfservice1=10.10.10.94 | cirros | m1.tiny |
| ad08-98843bfa6b6b       |      |        | , 192.168.124.69         |        |         |
+-------------------------+------+--------+--------------------------+--------+---------+
```
Note that:
* first IP address (10.10.10.94) is on private network (accessible by 
  this tenant only). This network is automatically tunneled on "overlay"
  if there are more computing nodes (Nova)
* 2nd IP address 192.168.124.69 is public (from floating pool) - you 
  can ping or ssh to this address from other PCs on your network.

# Resources

Based on guides:
- https://docs.openstack.org/neutron/2024.1/admin/ovn/refarch/refarch.html
- https://docs.openstack.org/neutron/2024.1/install/ovn/manual_install.html
- and on https://opendev.org/openstack/devstack scripts
