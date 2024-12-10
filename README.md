# OpenStack from Scratch (OSFS)

Here are Working (!) 2 script variants how to setup single-node OpenStack
under Ubuntu LTS.

> Why not using DevStack?
> 
> 1. DevStack install itself from source which is not typical setup (it
>    is suitable for OpenStack developers, but not for mere users)
> 2. In case of failure, the `stack.sh` script is unable to resume - you have to
>    start from scratch. It is precarious because most difficult (and most likely to fail) setup is Neutron
>    (networking layer) that runs practically at the and of setup.
> 3. DevStack setup is too sophisticated (by default it uses OVS + OVN which is most
>    complicated setup available under Linux ever)
> 4. I was unable to setup it properly with plain LinuxBridge and/or
>    plain Macvtap (suspecting that documentation is outdated in that case).

# Status

> WARNING! OpenStack Zed suddenly declared LinuxBridge as "experimental" (actually meaning "unsupported").
> See https://docs.openstack.org/neutron/zed/admin/config-experimental-framework.html So far, it works.

> WARNING! No Horizon (Web UI) yet. It requires self-service network support which is intentionally not
> supported here (due complexity).

There are now 2 variants:

1. DEPRECATED: single interface with LinuxBridge - requires lot of trickery to make it work.
   You can find this version under [linuxbridge/](linuxbridge/) - tested under Ubuntu 22 LTS. Issues:
   it requires firewall and Nova patches and causes assigned IP addresses mismatches

2. RECOMMENDED: 2 network interfaces (Management and Provider) with LinuxBridge - it is only minimal
   configuration officially
   supported by OpenStack - because Provider network rules generally clash with Management network,
   therefore 2 interfaces are required. You can find this recommended version
   under [linuxbridge-2ifaces/](linuxbridge-2ifaces/). This version fully support embedded DHCP server
   and metadata agent (metadata not tested though). Tested under Ubuntu 24.04.1 LTS

> Please ignore `macvtap` version (now under `macvtap-fail/` folder). It seems
> that `macvtap` agent always use VLANs, which is no use in my trivial environment with simple
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

