Attempt to configure OpenStack
with LinuxBridge.

Based guide:
- https://docs.openstack.org/neutron/latest/admin/deploy-lb-provider.html

We have two special interfaces:
- Bridge `br-ex` where is mapped `eth0` with static IP 192.168.0.11 and Gateway 192.168.0.1 - main
   routable network interface
- `dummy0` interface with static IP 192.168.0.12

The `dummy0` will be used as target for LinuxBridge configuration (we have to provide such interface)

TODO: It should be possible to assign tap dirclty to manual bridge:
- https://blueprints.launchpad.net/neutron/+spec/phy-net-bridge-mapping
- https://review.opendev.org/c/openstack/neutron/+/224357

But Nova most of time hardcodes interfaces. We have to check:
- `/usr/lib/python3/dist-packages/nova/network/neutron.py`
- function `def _nw_info_build_network(self, context, port, networks, subnets):`

Workaround - to make Nova to use manual bridge following hard-coded patch is needed:

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

But need to somehow glue linxubridge to main bridge....

Here is list of bridges and interfaces:
```
$ brctl show

bridge name		bridge id		STP enabled	interfaces
br-ex			8000.02e3a04e339c	no		eth0
brq1999b5b6-e5		8000.7a3d6eece004	no		dummy0
```

Where
- `br-ex` my bridge bound to real network interface `eth0` (routed to Internet)
- `brq1999b5b6-e5` dynamically generated bridge by OpenStack bound to `dummy0`
- what I need to somehow connect `dummy0` also to `br-ex`


