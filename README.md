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
Buttons labeled "Off", "Heat", "Cool", "Auto", "Dry" and "Fan" 
are used to change the heating/cooling unit's operating mode. The "spinner" control (up/down arrows) is used to change the setpoint temperature. 
To the right of the spinner is the current temperature as reported by the gateway.

If you click the arrow in the device panel you land on the "Control" tab, and an expanded control UI is presented. The operating mode and setpoint
controls are the similar, but there additional controls for fan speed and vane position.

**NOTE:** Since the Intesis WMP devices are gateways for a large number of heating/cooling units by various manufacturers, the capabilities
of each device vary considerably. For many devices, some UI buttons will have no effect; in some cases, the buttons may affect one unit differently
from the way they affect another. This is not a defect of the plug-in, but rather the response to Intesis' interpretation of how to best control
the heating/cooling unit given its capabilities.

## Actions ##

Intesis WMP Gateway implements the following actions under the `urn:toggledbits-com:serviceId:IntesisWMPGateway1` service:

### SetName/GetName ###

The `SetName` action may be used to change the name of the gateway. The name of the gateway itself changes, but this does not change
the name of the Vera device. Use Vera's UI tools for that. When using `SetName`, the new name must be passed in a parameter named
`NewName` (capitalization exactly as shown). The `GetName` action returns the current name of the gateway device in an argument
named `Name`.

<pre>
    luup.call_action( "urn:toggledbits-com:serviceId:IntesisWMPGateway1", "SetName", { NewName="Bedroom" }, <i>deviceNumber</i> )
</pre>

### FanSpeedUp/FanSpeedDown ###

The `FanSpeedUp` and `FanSpeedDown` actions adjust the fan speed up or down, respectively, within the limits of the gateway and
the configured heating/cooling unit. These actions take no parameters.

<pre>
    luup.call_action( "urn:toggledbits-com:serviceId:IntesisWMPGateway1", "FanSpeedUp", { }, <i>deviceNumber</i> )
</pre>

### SetCurrentFanSpeed/GetCurrentFanSpeed ###

The `SetCurrentFanSpeed` action takes a single parameter, `NewCurrentFanSpeed`, which sets the fan speed at the gateway. The new
fan speed is expected to be an integer in the range the gateway and heating/cooling unit can accept (e.g. 1 to 5). If out of range, the value
may be clamped at the limits. Passing an empty value or 0 will cause the fan speed mode to be set to "Auto" if the gateway supports
it for the configured heating/cooling unit.

The `GetCurrentFanSpeed` action returns a single argument, `CurrentFanSpeed`, with the gateway's last-reported fan speed (an integer
or "Auto").

<pre>
    luup.call_action( "urn:toggledbits-com:serviceId:IntesisWMPGateway1", "SetCurrentFanSpeed", { NewCurrentFanSpeed=2 }, <i>deviceNumber</i> )
    luup.call_action( "urn:toggledbits-com:serviceId:IntesisWMPGateway1", "SetCurrentFanSpeed", { NewCurrentFanSpeed="Auto" }, <i>deviceNumber</i> )
</pre>

### VaneUp, VaneDown, VaneLeft, VaneRight###

The `Vane___` actions signal the gateway to change the vane position. These actions take no parameters. Position is changed relative to
current position, within the limits of the air handling unit.

<pre>
    luup.call_action( "urn:toggledbits-com:serviceId:IntesisWMPGateway1", "VaneUp", { }, <i>deviceNumber</i> )
    luup.call_action( "urn:toggledbits-com:serviceId:IntesisWMPGateway1", "VaneDown", { }, <i>deviceNumber</i> )
    luup.call_action( "urn:toggledbits-com:serviceId:IntesisWMPGateway1", "VaneLeft", { }, <i>deviceNumber</i> )
    luup.call_action( "urn:toggledbits-com:serviceId:IntesisWMPGateway1", "VaneRight", { }, <i>deviceNumber</i> )
</pre>

### SetLeftRightVanePosition, GetLeftRightVanePosition, SetUpDownVanePosition, GetUpDownVanePosition ###

The `Set___VanePosition` actions set the vane position of the air handling unit to the specified setting, if possible. These actions
take a single parameter, `NewPosition`, which must be an integer greater than zero (limits are determined by the air handler and vary 
from device to device), or "Auto". The value zero is also interpreted as "Auto".

<pre>
    luup.call_action( "urn:toggledbits-com:serviceId:IntesisWMPGateway1", "SetLeftRightVanePosition", { NewPosition=3 }, <i>deviceNumber</i> )
    luup.call_action( "urn:toggledbits-com:serviceId:IntesisWMPGateway1", "SetUpDownVanePosition", { NewPosition="Auto" }, <i>deviceNumber</i> )
</pre>

### GetSignalStrength ###

The `GetSignalStrength` action returns a single argument (`SignalDB`) containing the WiFi signal strength reported by the gateway. 
This is usually a negative integer (&lt; -96 is a bad/unacceptable signal; -86 to -95 is weak; -85 to -81 is good; -80 to -71 is very
good; and anything &gt;= -70 is excellent).

### Other Services ###

In addition to the above actions, the Intesis WMP Gateway plug-in implements the following "standard" actions for thermostats:

* `urn:upnp-org:serviceId:HVAC_UserOperatingMode1`: `SetModeTarget` (Off, AutoChangeOver, HeatOn, CoolOn), `GetModeTarget`, `GetModeStatus`
* `urn:upnp-org:serviceId:HVAC_FanOperatingMode1`: `SetMode` (Auto, ContinuousOn), `GetMode`
* `urn:upnp-org:serviceId:TemperatureSetpoint1`: `SetCurrentSetpoint`, `GetCurrentSetpoint`

The plug-in also provides many of the state variables behind these services. In addition, the plug-in maintains the `CurrentTemperature` 
state variable of the `urn:upnp-org:serviceId:TemperatureSensor1` service (current ambient temperature as reported by the gateway).

**IMPORTANT:** The model for handling fan mode differs significantly between Intesis and Vera. In Vera/UPnP, setting the fan mode to `ContinuousOn`
turns the fan on, but does not change the operating mode of the air handling unit. For example, with the fan mode set to ContinuousOn,
if the AHU is cooling, it continues to cool until setpoint is achieved, at which time cooling shuts down but the fan continues to operate.
In Intesis, to get continuous operation of the fan, one sets the (operating) mode to "Fan", which will stop the AHU from heating or cooling.
Because of this, the plugin does not react to the `SetMode` action in service `urn:upnp-org:serviceId:HVAC_FanOperatingMode1` 
(it is quietly ignored).
In addition, the `FanStatus` state can only be deduced in the "Off" or "FanOnly" operating modes, in which case the status will
be "Off" or "On" respectively; in all other cases it will be "Unknown".

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

## ImperiHome Integration ##

ImperiHome does not, by default, detect many plugin devices, including ImperiHome WMP Gateway. However, it is possible to configure this plugin
for use with ImperiHome, as the plugin implements the [ImperiHome ISS API](http://dev.evertygo.com/api/iss).

To connect Intesis WMP Gateway to ImperiHome:

1. In ImperiHome, go into **My Objects**
1. Click **Add a new object**
1. Choose **ImperiHome Standard System**
1. In the **Local base API** field, enter 
   `http://your-vera-local-ip:3480/data_request?id=lr_IntesisWMPGateway&command=ISS&path=`
1. Click **Next** to connect.

ImperiHome should then populate your groups with your Intesis WMP Gateway plugin devices.

## Reporting Bugs/Enhancement Requests ##

Bug reports and enhancement requests are welcome! Please use the ["Issues" section](https://github.com/toggledbits/IntesisWMPGateway/issues) of the Github repository to open a new bug report or make an enhancement request.

## License ##

IntesisWMPGateway is offered under GPL (the GNU Public License) 3.0. See the [LICENSE](https://www.gnu.org/licenses/gpl-3.0.en.html) file for details.

<hr>Copyright 2017 Patrick H. Rigney, All Rights Reserved
