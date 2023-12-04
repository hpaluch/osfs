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

Please ignore `macvtap` version (now under `macvtap-fail/` folder). It seems
that `macvtap` agent always use VLANs, which is not my setup.


I have nice success with `linuxbridge` version under [linuxbridge/](linuxbridge/) folder.
For the first time it works, however you need to apply
at least this patch: [linuxbridge/patches/manual-bridge.patch](linuxbridge/patches/manual-bridge.patch)
to force Nova compute to use existing bridge.

# Requirements

* Ubuntu 22.04 LTS (it is only OS where OpenStack is actively developed)
* Setup brdige and dummy interface - see files under `linuxbridge/etc/`

# Verification 

When script is finished you can verify various setting using:

```shell
source ~/.config/osfs/keystonerc_admin
openstack # will enter OpenStack shell
```
I strongly recommend to use above OpenStack shell to speed up all queries. Here are 
few recommended:

```
Outdated - need to refresh
```


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

