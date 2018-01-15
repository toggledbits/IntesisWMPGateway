# Intesis WMP Gateway #

## Introduction ##

IntesisWMPGateway is a "plug-in" for for Vera home automation controllers that mimics the behavior of a standard heating/cooling
thermostat and uses the Intesis WMP communications protocol to send commands and receive status from an Intesis WMP gateway
device.

IntesisWMPGateway has not yet been tested on openLuup with AltUI, but is expected to work on both.

IntesisWMPGateway is written and supported by Patrick Rigney, aka rigpapa on the [Vera forums](http://http://forum.micasaverde.com/).

For more information on Intesis WMP Gateways, [visit the Intesis site](https://www.intesishome.com/). For more information on Vera home automation controllers,
[Vera Ltd's site](http://getvera.com/).

## Installation ##

Installation of the plug-in is through the usual mechanisms for Vera controllers: through the Vera plugin catalog, or by downloading
the plugin files from the project's [GitHub repository](https://github.com/toggledbits/IntesisWMPGateway/releases).

### Installation through Vera ###

To install the plug-in from the Vera plug-in catalog:

1. Open the Vera UI on your desktop computer;
1. Click on Apps in the left navigation menu;
1. Click on Install apps;
1. Type "Intesis" into the search box and click "Search app";
1. Choose the "Intesis WMP Gateway" app.

The plug-in will be installed, and the first device created. Each gateway device should have a corresponding Vera device (instance of 
the plug-in). If you have more than one gateway device, find the Intesis WMP Gateway app under the Apps > My apps section of the UI,
click the "Details" button, and then clock the "Create another" button to create an additional Vera device.

Before you can use the device, you must configure the IP address of your gateway in the device data. See Configuration, below.

### Installation from GitHub ###

**Warning: this method is for experienced users only. Incorrectly uploading files to your Vera controller can cause problems, up to 
and including bricking the controller. Proceed at your own risk.**

To install from GitHub, download a release from the project's [GitHub repository](https://github.com/toggledbits/IntesisWMPGateway/releases).
Unzip it, and then upload the release files to your Vera using the uploader found in the UI under Apps > Develop apps > Luup files. You should
turn off the "Restart Luup after upload" checkbox until uploading the last of the files. Turn it on for the last file.

### Configuration ###

If you are coming from a fresh installation of the plug-in, or have just created another device instance, reload Luup and flush your browser cache:

1. Go to Apps > Develop apps > Test Luup code (Lua);
1. Type `luup.reload()` into the text box and click the "GO" button;
1. Do a CTRL-F5 or equivalent (browser-dependent) to refresh the Vera UI with a flush of cached data.

The only configuration required of the plug-in is the IP address of the WMP gateway device. The device must be assigned a static IP address, or
reserved DHCP address, but in any case, the gateway has to have a stable IP address that doesn't change. Once established, put that address into
the plug-in data by clicking on arrow next to the device name in the Vera dashboard, and then clicking the Advanced tab. Enter the IP address in
the "ip" field and hit the tab key or click in another field. The IP address will be stored. Now, repeat the reload and browser refresh steps above.
The plug-in should being communicating with the gateway.

## Operation ##

As it appears in the Vera dashboard, the IntesisWMPGateway plug-in presents a fairly typical thermostat interface in the Vera UI. 
Buttons labeled "Off", "Heat", "Cool", and "Auto" 
are used to change the heating/cooling unit's operating mode. The "slider" control (which doesn't look like a slider in UI7, it has the "+"
and "-" buttons) is used to change the setpoint temperature. To the right of the slider is the current temperature as reported by the
gateway.

If you click the device arrow and click into the "Control" tab, a slightly expanded control UI is presented. The operating mode and setpoint
controls are the same, but the expanded control display includes buttons for fan mode/speed control. Pressing the "Auto" button under the
"Fan" heading will set the fan mode to automatic. Pressing the buttons with up and down arrows changes the fan's fixed speed.

**NOTE:** Since the Intesis WMP devices are gateways for a large number of heating/cooling units by various manufacturers, the capabilities
of each device vary considerably. For many devices, the UI buttons will have no effect; in some cases, the buttons may affect one unit differently
from the way they affect another. This is not a defect of the plug-in, it is a limitation in the use of a generic gateway with a specific device.

## Actions ##

Intesis WMP Gateway implements the following actions under the `urn:toggledbits-com:serviceId:IntesisWMPGateway1` service:

### SetName/GetName ###

The `SetName` action may be used to change the name of the gateway. The name of the gateway itself changes, but this does not change
the name of the Vera device. Use Vera's UI tools for that. When using `SetName`, the new name must be passed in a parameter named
`NewName` (capitalization exactly as shown). The `GetName` action returns the current name of the gateway device in an argument
named `Name`.

### FanSpeedUp/FanSpeedDown ###

The `FanSpeedUp` and `FanSpeedDown` actions adjust the fan speed up or down, respectively, within the limits of the gateway and
the configured heating/cooling unit. These actions take no parameters.

### SetCurrentFanSpeed/GetCurrentFanSpeed ###

The `SetCurrentFanSpeed` action takes a single parameter, `NewCurrentFanSpeed`, which sets the fan speed at the gateway. The new
fan speed is expected to be an integer in the range the gateway and heating/cooling unit can accept. If out of range, the value
may be clamped at the limits. Passing an empty value or 0 will cause the fan speed mode to be set to "Auto" if the gateway supports
it for the configured heating/cooling unit.

The `GetCurrentFanSpeed` action returns a single argument, `CurrentFanSpeed`, with the gateway's last-reported fan speed (an integer
or "Auto").

### GetSignalStrength ###

The `GetSignalStrength` action returns a single argument (`SignalDB`) containing the WiFi signal strength reported by the gateway. 
This is usually a negative integer (&lt; -96 is a bad/unacceptable signal; -86 to -95 is weak; -85 to -81 is good; -80 to -71 is very
good; and anything &gt;= -70 is excellent).

### Other Services ###

In addition to the above actions, the Intesis WMP Gateway plug-in implements the following "standard" actions for thermostats:

* `urn:upnp-org:serviceId:HVAC_UserOperatingMode1`: `SetModeTarget`, `GetModeTarget`, `GetModeStatus`
* `urn:upnp-org:serviceId:HVAC_FanOperatingMode1`: `SetMode`, `GetMode`
* `urn:upnp-org:serviceId:TemperatureSetpoint1`: `SetCurrentSetpoint`, `GetCurrentSetpoint`

The plug-in also provides many of the state variables behind these services. In addition, the plug-in maintains the `CurrentTemperature` 
state variable of the `urn:upnp-org:serviceId:TemperatureSensor1` service (current ambient temperature as reported by the gateway).

## Advanced Configuration ##

There is little advanced configuration in the current version of the plug-in, but all are controlled through the setting of state variables
on the device (under the device panel's Advanced > Variables tab).

### PingInterval ###
`PingInterval` is the time between pings to the gateway device. These pings are used to keep the TCP connection up between the Vera and the
gateway. The value of this variable is in seconds, and the default is 15. It is not recommended to set this value lower than 5 or greater
than 120. If the value is too high (which could be any value greater than the default), disconnects may result, requiring a Luup reload
for recovery.

### RefreshInterval ###
`RefreshInterval` is the time between full queries for data from the gateway. Periodically, the plug-in will make a query for all current
gateway status parameters, to ensure that the Vera plug-in and UI are in sync with the gateway. This value is in seconds, and the default
is 60. It is not recommended to set this value lower than the ping interval (above).

### ForceUnits ###
By default, the plug-in will adjust its UI to display temperatures in the default units configured for the Vera controller. If the Vera's
units are changed, the plug-in will self-reconfigure. If the user has some reason to need the plug-in to present its interfaces in units
over than the Vera's configured unit, setting `ForceUnits` to "C" or "F" will cause the plug-in to display Fahrenheit or Celsius, 
respectively.

Note that this variable is not automatically created with the device. You will need to create it using the "Create Service" tab in the
device's Advanced settings page. The service name is (copy-paste recommended) `urn:toggledbits-com:serviceId:IntesisWMPGateway1`.

## Reporting Bugs/Enhancement Requests ##

Bug reports and enhancement requests are welcome! Please use the ["Issues" section](https://github.com/toggledbits/IntesisWMPGateway/issues) of the Github repository to open a new bug report or make an enhancement request.

## License ##

IntesisWMPGateway is offered under GPL (the GNU Public License) 3.0. See the [LICENSE](https://www.gnu.org/licenses/gpl-3.0.en.html) file for details.

<hr>Copyright 2017 Patrick H. Rigney, All Rights Reserved
