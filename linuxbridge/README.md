Attempt to configure OpenStack
with LinuxBridge.

Based guide:
- https://docs.openstack.org/neutron/latest/admin/deploy-lb-provider.html

We have two special interfaces:
- Bridge `br-ex` where is mapped `eth0` with static IP 192.168.0.11 and Gateway 192.168.0.1 - main
   routable network interface
- `dummy0` interface with static IP 192.168.0.12

The `dummy0` will be used as target for LinuxBridge configuration (we have to provide such interface)



