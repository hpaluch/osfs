# It Works! Configure OpenStack with LinuxBridge

Here is most simple setup where OpenStack uses existing bridge (in my
case `br-ex`) for both VMs and infrastructure ("Proxmox like" setup).

- before setup you have to evaluate and apply these files
- `etc/netplan/99-openstack.yaml`
  - replace your `/etc/netplan` with this file, customize it and use `netplan generate && netplan apply`
  - WARNING! `netplan apply` will likely kill you network connection!
- also review and apply:
  - `etc/hosts`
  - `etc/hostname`
  - example how to stop renaming interfaces (keep `eth0`): `etc/default/grub`

When your PC works properly you can run

- review script `setup_openstack_lbr.sh`
- you will likely need to customize command `network create ...` at the end of
  script to fit your network
- finally run `./setup_openstack_lbr.sh` in this directory.
- and follow instructions how to create 1st VM


# Resources

Based guide:
- https://docs.openstack.org/neutron/latest/admin/deploy-lb-provider.html

We have one special interface
- Bridge `br-ex` where is mapped `eth0` with static IP 192.168.0.11 and Gateway 192.168.0.1 - main
   routable network interface

Now I have assigned manual bridge
- https://blueprints.launchpad.net/neutron/+spec/phy-net-bridge-mapping
- https://review.opendev.org/c/openstack/neutron/+/224357

But Nova most of time hardcodes interfaces. We have to check:
- `/usr/lib/python3/dist-packages/nova/network/neutron.py`
- function `def _nw_info_build_network(self, context, port, networks, subnets):`

Workaround - to make Nova to use manual bridge following hard-coded patch is needed:
- also under `patches/manual-bridge.patch`

```diff
--- /usr/lib/python3/dist-packages/nova/network/neutron.py.orig	2023-12-03 15:42:51.478133357 +0000
+++ /usr/lib/python3/dist-packages/nova/network/neutron.py	2023-12-03 15:44:17.850213932 +0000
@@ -3278,9 +3278,11 @@
                                       CONF.neutron.ovs_bridge)
             ovs_interfaceid = port['id']
         elif vif_type == network_model.VIF_TYPE_BRIDGE:
-            bridge = port_details.get(network_model.VIF_DETAILS_BRIDGE_NAME,
-                                      "brq" + port['network_id'])
-            should_create_bridge = True
+            LOG.info("XXXHP: manual bridge")
+            #bridge = port_details.get(network_model.VIF_DETAILS_BRIDGE_NAME,
+            #                          "brq" + port['network_id'])
+            bridge = port_details.get(network_model.VIF_DETAILS_BRIDGE_NAME, "br-ex")
+            #should_create_bridge = True
         elif vif_type == network_model.VIF_TYPE_DVS:
             # The name of the DVS port group will contain the neutron
             # network id
```


Milestone: was able to create VM in state active:

```
openstack server list

+--------------------------------------+------+--------+-------------------------+--------+---------+
| ID                                   | Name | Status | Networks                | Image  | Flavor  |
+--------------------------------------+------+--------+-------------------------+--------+---------+
| 925f1e15-6a2f-49be-9f59-fe54f1012f3f | vm1  | ACTIVE | provider1=192.168.0.186 | cirros | m1.tiny |
+--------------------------------------+------+--------+-------------------------+--------+---------+
```

# (Solved) Problems

Was fighting with firewall. So I switched it off using:
```ini
# /etc/neutron/plugins/ml2/linuxbridge_agent.ini
[securitygroup]
enable_security_group = False
enable_ipset = False
```

NOTE: Applied in script `setup_openstack_lbr.sh) - you don't need it to do it manually.

If you insists on having firewall I recommend following Logging patch to see (with `dmesg`) which
packets were dropped:

```diff
--- /usr/lib/python3/dist-packages/neutron/agent/linux/iptables_firewall.py.orig	2023-12-03 16:57:07.335108916 +0000
+++ /usr/lib/python3/dist-packages/neutron/agent/linux/iptables_firewall.py	2023-12-03 16:58:41.913760392 +0000
@@ -304,6 +304,8 @@
 
     def _add_fallback_chain_v4v6(self):
         self.iptables.ipv4['filter'].add_chain('sg-fallback')
+        self.iptables.ipv4['filter'].add_rule('sg-fallback', '-j LOG',
+                                              comment=ic.UNMATCH_DROP)
         self.iptables.ipv4['filter'].add_rule('sg-fallback', '-j DROP',
                                               comment=ic.UNMATCH_DROP)
         self.iptables.ipv6['filter'].add_chain('sg-fallback')
```

Warning!

There is also ARP filter on ebtables (or nftables) level - it can be disabled with
`--disable-port-security ` parameter when creating network with `openstack network ...` command.

