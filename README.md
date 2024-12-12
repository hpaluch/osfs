# OpenStack from Scratch (OSFS)

> Project summary: setup OpenStack with single (easy to understand) bash script.

Here are several variants how to setup single-node OpenStack
under Ubuntu LTS 24.04 (but 1st variant tested under 22.04 only).

# Status

> WARNING! OpenStack Zed suddenly declared LinuxBridge as "experimental"
> (actually meaning "unsupported").  See
> https://docs.openstack.org/neutron/zed/admin/config-experimental-framework.html
> and https://opendev.org/openstack/kolla-ansible/commit/8ef21123aea6371f23a7e86f6461a91c17bd84fd
> So far, it works.
>
> What is irony that in the past RackSpace run away from OVS back to
> LinuxBridge because OVS was to unstable for regular use:
> https://www.youtube.com/watch?v=_OdPP_4PYD4

> WARNING! No Horizon (Web UI) yet. 
> I plan to add such variant later...

Setup variants with "provider" (public) network only:

1. DEPRECATED: single interface with LinuxBridge - requires lot of trickery to
   make it work.  You can find this version under [linuxbridge/](linuxbridge/) -
   tested under Ubuntu 22 LTS. Issues: it requires firewall and Nova patches and
   causes assigned IP addresses mismatches

2. DEPRECATED yet usable: 2 network interfaces (Management and Provider) with LinuxBridge
   under [linuxbridge-2ifaces/](linuxbridge-2ifaces/). This version includes embedded DHCP server
   and metadata agent (metadata not tested though). Tested under Ubuntu 24.04.1 LTS.

   Problem: LinuxBridge is flagged "experimental" (meaning: not supported) since OpenStack Zed. However
   it still works in Ubuntu 24.04.1 LTS

3. RECOMMENDED: 2 network interfaces (Management and Provider) with Open vSwitch (OVS)
   under [ovs-2ifaces/](ovs-2ifaces/). This version includes embedded DHCP server
   and metadata agent (metadata not tested though). Tested under Ubuntu 24.04.1 LTS.
   Since OpenStack Zed, OVS bridge is only supported bridge in OpenStack deployments (where
   LinuxBridge is "deprecated" and "macvtap" abandoned)

Setup variants with both "provider" (public) and "self-service" (private tenant) networks (typical
OpenStack setup):

4. RECOMMENDED: 2 network interfaces (Management, Provider) with Open
   vSwitch (OVS) under [ovs-full/](ovs-full/) with self-service network. This
   version includes embedded DHCP server and metadata agent (metadata not tested
   though). Tested under Ubuntu 24.04.1 LTS.  This is most common setup where each
   tenant has its "self-service" network and uses floating IP address to make VMs
   reachable from outside.

OVN Notes: I have no OVS+OVN variant (currently pushed by DevStack) because
- official docs mention TripleO that was killed (and crippled repositories) in Feb 2023:
  https://lists.openstack.org/pipermail/openstack-discuss/2023-February/032083.html
- official docs admit that OVN documentation is incomplete on
  https://docs.openstack.org/neutron/latest/install/ovn/manual_install.html

> Please ignore `macvtap` version (now under `macvtap-fail/` folder). It seems
> that `macvtap` agent always use VLANs, which is no way in my trivial environment with simple
> home router.

# Debugging tips

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

# Why not using DevStack?

1. DevStack install itself from source which is not typical setup (it
   is suitable for OpenStack developers, but not for mere users)
2. In case of failure, the `stack.sh` script is unable to resume - you have to
   start from scratch. It is precarious because most difficult (and most likely to fail) setup is Neutron
   (networking layer) that runs practically at the and of setup.
3. DevStack setup is too sophisticated (by default it uses OVS + OVN which is most
   complicated setup available under Linux ever)
4. I was unable to setup it properly with plain LinuxBridge and/or
   plain Macvtap (suspecting that documentation is outdated in that case).
