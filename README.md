# OpenStack from Scratch (OSFS)

Here is Working (!) script to setup single-node OpenStack
under Ubuntu 22.04 LTS. It uses simples network topology
with `linuxbridge` Neutron agent - with setup that resembles Proxmox
(Bridge `br-ex` hosts both real `eth0` interface to Internet and virtual
VMs interfaces - note that VMs depends on external (your) DHCP server).

Why not using DevStack?

1. DevStack install itself from source which is not typical setup (it
   is suitable for OpenStack developers, but not for mere users)
2. In case of failure, the `stack.sh` script is unable to resume - you have to
   start from scratch. It is precarious because most difficult (and most likely to fail) setup is Neutron
   (networking layer) that runs practically at the and of setup.
3. DevStack setup is too sophisticated (by default it uses OVS + OVN which is most
   complicated setup available under Linux ever)
4. I was unable to setup it properly with plain LinuxBridge and/or
   plain Macvtap (suspecting that documentation is outdated in that case).

# Status

I have finally (!) success with `linuxbridge` version under [linuxbridge/](linuxbridge/) folder.
Please read [linuxbridge/README.md](linuxbridge/README.md).

> Please ignore `macvtap` version (now under `macvtap-fail/` folder). It seems
> that `macvtap` agent always use VLANs, which is no use in my trivial environment with simple
> home router.

# Requirements

* Ubuntu 22.04 LTS (it is only OS where OpenStack is actively developed)
* Setup bridge and dummy interface - see files under `linuxbridge/etc`,
  especially  `linuxbridge/etc/netplan/99-openstack.yaml`, but also ensure
  that you have proper (reachable) Hostname and FQDN.

When done go to [linuxbridge/](linuxbridge/) folder and again read its `README.md` and
when ready run its `./setup_openstack_lbr.sh`.

If script finishes successfully it will tell you how to spin and connect to your first VM.

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

