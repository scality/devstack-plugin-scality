# devstack-scality-plugin
This plugin configures DevStack to use Scality drivers for Manila, Cinder, Glance and Swift.

## How to use
Add the following line in your `local.conf` file:
```
[[local|localrc]]
enable_plugin scality https://github.com/scality/devstack-scality-plugin
...
```
If you plan to enable Glance or Swift, you also need to export or to add in your `local.conf` file
this variable: `SCALITY_SPROXYD_ENDPOINTS`. For instance:
```
[[local|localrc]]
SCALITY_SPROXYD_ENDPOINTS=http://A.B.C.D:81/proxy/chord_path
...
```
