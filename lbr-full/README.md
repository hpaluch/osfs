# It Works! Configure OpenStack with LinuxBridge - 2 interfaces

Here is minimal supported configuration of OpenStack using LinuxBridge plugin and 2
network interfaces. It supports both Provider network and Self-service network
(using `geneve` overlays). It includes Web UI Horizon.

- Tested OS: `Ubuntu 24.04.1 LTS (Noble Numbat)`
- OpenStack version: output of `dpkg -l neutron-common` is: `2:24.0.0-0ubuntu1`. It should
  be https://releases.openstack.org/caracal/index.html. However official page
  does not contains Ubuntu 24 LTS yet: https://ubuntu.com/openstack/docs/supported-versions


You need to have 2 interfaces:
* `eth0` management interface - in my case 192.168.122.85/24 with access to Internet
* `eth1` "public" (also provider) network - 192.168.124.0/24 with access to Internet, however
   it should be just UP but no IP address assigned (OpenStack LinuxBridge backend will do that).
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

- review script `setup_openstack_lbr_full.sh`
- you will likely need to customize command `network create ...` at the end of
  script to fit your network
- finally run `./setup_openstack_lbr_full.sh` in this directory.
- and follow instructions how to create 1st VM

Once your VM starts you should be able to access it remotely (use `openstack server list` to find its
IP address) using from other host just: `ssh cirros@REMOTE_IP`

Example when `vm1` is running:
```shell
$ openstack server list 
+-----------------------+------+--------+------------------------+--------+---------+
| ID                    | Name | Status | Networks               | Image  | Flavor  |
+-----------------------+------+--------+------------------------+--------+---------+
| db7aa9d0-29a7-44a6-   | vm1  | ACTIVE | selfservice1=10.10.10. | cirros | m1.tiny |
| 90eb-f929ef4feb1e     |      |        | 72, 192.168.124.101    |        |         |
+-----------------------+------+--------+------------------------+--------+---------+
```
Note that:
* first IP address (10.10.10.72) is on private network (accessible by 
  this tenant only). This network is automatically tunneled on "overlay"
  if there are more computing nodes (Nova)
* 2nd IP address 192.168.124.101 is public (from floating pool) - you 
  can ping or ssh to this address from other PCs on your network.

# Resources

Based on guides:
- Provider Network guide: https://docs.openstack.org/neutron/2024.1/admin/deploy-lb-provider.html
- Self-Service Network guide: https://docs.openstack.org/neutron/2024.1/admin/deploy-lb-selfservice.html
