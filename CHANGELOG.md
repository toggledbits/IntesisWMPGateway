# Change Log

## Version 3.0 (development-20323)

* Support for multi-unit control from a single gateway. This changes the structure of devices where previously the child devices represented individual gateways and a single thermostat. The new model is that the master device represents the gateway device and each child is a thermostat connected to a unit. This is all in support of IntesisBox's latest products.
* Support SockProxy plugin for improved communication response. All users are recommended to install the SockProxy plugin when using this plugin for best performance. This plugin is available for Vera and openLuup.
