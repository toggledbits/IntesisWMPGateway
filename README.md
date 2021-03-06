# Intesis WMP Gateway #

Revised 2019-09-28

## Introduction ##

IntesisWMPGateway is a "plug-in" for for Vera home automation controllers that mimics the behavior of a standard heating/cooling
thermostat and uses the Intesis WMP communications protocol to send commands and receive status from an Intesis WMP gateway
device.

The IntesisWMPGateway plug-in works with the following Intesis devices: IS-IR-WMP-1, ME-AC-WMP-1, DK-AC-WMP-1,
MH-AC-WMP-1, MH-RC-WMP-1, TD-RC-WMP-1, PA-AC-WMP-1, PA-RC2-WMP-1, LG-RC-WMP-1, FJ-RC-WMP-1. The plug-in uses the local
WMP interface for communication (uses TCP port 3310). Note that devices that use Intesis cloud service for control
do not work, even though they may have "WMP" in the product model. A separate plug-in is planned for these devices.

IntesisWMPGateway works with ALTUI, but does not work with openLuup at this time.

IntesisWMPGateway is written and supported by Patrick Rigney, aka rigpapa on the [Vera forums](http://community.getvera.com/).
If you find the project useful, please consider supporting my work a small donation at [my web site](https://www.toggledbits.com/donate/).

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

To install from GitHub, [download a released version](https://github.com/toggledbits/IntesisWMPGateway/releases) from the project's GitHub repository.
Alternately, the latest stable development version (somewhat tested and expected to be nearly bug-free) can be downloaded from
[the project's "stable" branch](https://github.com/toggledbits/IntesisWMPGateway/tree/stable)
(click the green "Clone or download" button here and choose "Download ZIP").

Unzip the downloaded archive, and then upload the release files to your Vera using the uploader found in the web UI under
*Apps > Develop apps > Luup files*. You can multi-select and drag the files as a group to the "Upload" control (recommended). If you
decide to upload the files one at a time, turn off the "Restart Luup after upload" checkbox until uploading the last file.
Turn it back on for that last file.

### Configuration ###

If you are coming from a fresh installation of the plug-in, or have just created another device instance (discovery),
reload Luup and flush your browser cache:

1. Go to *Apps > Develop apps > Test Luup code (Lua)*;
1. Type `luup.reload()` into the text box and click the "GO" button;
1. [Hard-refresh your browser](https://www.getfilecloud.com/blog/2015/03/tech-tip-how-to-do-hard-refresh-in-browsers/). **Do not skip this step.**

## Operation ##

When first installed, the IntesisWMPGateway plugin will initiate network discovery and attempt to locate your compatible IntesisBox
devices. There will be several Luup reloads during this process as devices are found, and as is frequently the case in Vera, a full
refresh/cache flush of your browser will be necessary to consistently display all of the discovered devices.

The "Intesis WMP Gateway" device represents the interface and controller for all of the IntesisBox devices. There is normally only
one such device, and it is the parent for all other devices created by the plugin. Clicking on the arrow in
the Vera dashboard to access the gateway's control panel will give you three options for launching network discovery. The first
("Run Discovery") will run network broadcast discovery, which is the first method you should try if the plugin did not find all of your devices.
The second option is "Discover MAC", where a MAC address is entered (see the label on the IntesisBox device for this value) and the plugin searches for
that device specifically. The third is "Discover IP", which may be used if the IP address of the device is known.

> NOTE: It is recommended that your IntesisBox devices be assigned a stable IP address on your network, either by using static addressing, or by a DHCP reservation. If you don't know what this means or have any idea what how to do it, no worries. It's not mission-critical. Just now that from time-to-time, the plugin may have to search for your devices if/when their assigned network address changes, and this can result in a delay. If the delay persists, re-running discovery usually quickly resolves the issue.

Each discovered IntesisBox
device presents as a heating/cooling thermostat in the Vera UI. These devices are child devices of the parent gateway device, although
this association is not readily apparent from the UI, and in most cases is not relevant for the typical Vera user (Lua scripters will care, though).
Buttons labeled "Off", "Heat", "Cool", "Auto", "Dry" and "Fan"
are used to change the heating/cooling unit's operating mode. The "spinner" control (up/down arrows) is used to change the setpoint temperature.
To the right of the spinner is the current temperature as reported by the gateway. If you click the arrow in the device panel you land on the "Control" tab, and an expanded control UI is presented. The operating mode and setpoint controls are the similar, but there additional controls for fan speed and vane position.

You can safely rename the device in the Vera UI if you wish, and assign it to any room.

> NOTE: Since the IntesisBox devices are interfaces for a large number of heating/cooling units by various manufacturers, the capabilities of each device vary considerably. For many devices, some UI buttons will have no effect, or have side-effects to other functions; in some cases, the buttons may affect one unit differently from the way they affect another. This is not a defect of the plug-in, but rather the response to Intesis' interpretation of how to best control the heating/cooling unit given its capabilities.

## Actions ##

The plugin creates two device types and services:

1. Type `urn:schemas-toggledbits-com:device:IntesisWMPGateway:1`, service `urn:toggledbits-com:serviceId:IntesisWMPGateway1`, which contains state and actions associated with the plugin itself;
1. Type `urn:schemas-toggledbits-com:device:IntesisWMPDevice:1`, service `urn:toggledbits-com:serviceId:IntesisWMPDevice1`, which contains state and actions associated with each IntesisBox gateway discovered;

### IntesisGateway1 Service Actions and Variables ###

The `IntesisGateway1` service, which must be referenced using its full name `urn:toggledbits-com:serviceId:IntesisWMPGateway1`,
contains the state and actions associated with the gateway device itself. It is associated with the
`urn:schemas-toggledbits-com:device:IntesisWMPGateway:1` device type.

The following actions are implemented under this service:

#### Action: RunDiscovery ####
This action launches broadcast discovery, and adds any newly-discovered compatible IntesisBox devices to the configuration.
Discovery lasts for 30 seconds, and runs asynchronously (all other tasks and jobs continue during discovery).

#### Action: DiscoverMAC ####
This action starts discovery for a given MAC address, passed in the `MACAddress` parameter. This is useful because the MAC addresses are printed on a label on the back of the
device, and if the device is connected to the same LAN as the Vera, is likely discoverable by this address. If the device is found
and compatible, it will be added to the configuration.

#### Action: DiscoverIP ####
This action starts discovery for a given IP address. If communication with the device can be established at the given address
(provided in the `IPAddreess` parameter), and the device is compatible, it will be added to the configuration.

#### Action: SetDebug ####
This action enables debugging to the Vera log, which increases the verbosity of the plugins information output. It takes a single
parameter, `debug`, which must be either 0 or 1 in numeric or string form. 

When Luup reloads and the plugin restarts, debugging will return to the *off* state. To get persistent debug across reloads,
see the *DebugMode* state variable, below.

#### Variable: PingInterval ####

`PingInterval` is the time between pings to the gateway device. These pings are used to keep the TCP connection up between the Vera and the
gateway. The value of this variable is in seconds, and the default is 32. It is not recommended to set this value lower than 5 or greater
than 120. If the value is too high (which could be any value greater than the default), disconnects may result, resulting in longer refresh
times when data changes or commands are executed.

#### Variable: RefreshInterval ####

`RefreshInterval` is the time between full queries for data from the gateway. Periodically, the plug-in will make a query for all current
gateway status parameters, to ensure that the Vera plug-in and UI are in sync with the gateway. This value is in seconds, and the default
is 64. This value should always be greater than the ping interval (above).

#### Variable: DebugMode ####

When non-zero, this variable enables debug output to the Luup log file at plugin startup. A restart is required for changes to take effect.
The default value is 0 (zero).

### IntesisDevice1 Service Actions and Variables ###

The IntesisDevice1 service, which must be referenced using its full name `urn:toggledbits-com:serviceId:IntesisWMPDevice1`,
contains the state and actions associated with IntesisBox devices. It is associated with the
`urn:schemas-toggledbits-com:device:IntesisWMPDevice:1` device type.

These devices also implement actions and variables
of `HVAC_OperatingState1`, `HVAC_FanState1`, `TemperatureSetpoint1`, and `TemperatureSensor1`. See "Other Services" below for details.

The following actions are implemented under by the `IntesisDevice1` service specifically:

#### Action: SetName/GetName ####

The `SetName` action may be used to change the name of the IntesisBox device. The name of the device itself changes, but this does not change
the name of the Vera device. Use Vera's UI tools for that. When using `SetName`, the new name must be passed in a parameter named
`NewName` (capitalization exactly as shown). The `GetName` action returns the current name of the gateway device in an argument
named `Name`.

<pre>
    luup.call_action( "urn:toggledbits-com:serviceId:IntesisWMPGateway1", "SetName", { NewName="Bedroom" }, <i>deviceNumber</i> )
</pre>

#### Action: FanSpeedUp/FanSpeedDown ####

The `FanSpeedUp` and `FanSpeedDown` actions adjust the fan speed up or down, respectively, within the limits of the gateway and
the configured heating/cooling unit. These actions take no parameters.

<pre>
    luup.call_action( "urn:toggledbits-com:serviceId:IntesisWMPGateway1", "FanSpeedUp", { }, <i>deviceNumber</i> )
</pre>

#### Action: SetCurrentFanSpeed/GetCurrentFanSpeed ####

The `SetCurrentFanSpeed` action takes a single parameter, `NewCurrentFanSpeed`, which sets the fan speed at the gateway. The new
fan speed is expected to be an integer in the range the gateway and heating/cooling unit can accept (e.g. 1 to 5). If out of range, the value
may be clamped at the limits. Passing an empty value or 0 will cause the fan speed mode to be set to "AUTO" if the gateway supports
it for the configured heating/cooling unit. The speeds supported by the configured unit can be seen by examining the `LimitsFANSP` state
variable.

The `GetCurrentFanSpeed` action returns a single argument, `CurrentFanSpeed`, with the gateway's last-reported fan speed (an integer
or text).

<pre>
    luup.call_action( "urn:toggledbits-com:serviceId:IntesisWMPGateway1", "SetCurrentFanSpeed", { NewCurrentFanSpeed=2 }, <i>deviceNumber</i> )
    luup.call_action( "urn:toggledbits-com:serviceId:IntesisWMPGateway1", "SetCurrentFanSpeed", { NewCurrentFanSpeed="Auto" }, <i>deviceNumber</i> )
</pre>

#### Action: VaneUp, VaneDown, VaneLeft, VaneRight ####

The `Vane___` actions signal the gateway to change the vane position. These actions take no parameters. Position is changed relative to
current position, within the limits of the air handling unit.

<pre>
    luup.call_action( "urn:toggledbits-com:serviceId:IntesisWMPGateway1", "VaneUp", { }, <i>deviceNumber</i> )
    luup.call_action( "urn:toggledbits-com:serviceId:IntesisWMPGateway1", "VaneDown", { }, <i>deviceNumber</i> )
    luup.call_action( "urn:toggledbits-com:serviceId:IntesisWMPGateway1", "VaneLeft", { }, <i>deviceNumber</i> )
    luup.call_action( "urn:toggledbits-com:serviceId:IntesisWMPGateway1", "VaneRight", { }, <i>deviceNumber</i> )
</pre>

If any of these actions are invoked when the current vane mode is AUTO, SWING, PULSE, etc., the vanes will go to fixed positioning.
Invoking `VaneUp` or `VaneLeft` when the vanes are in the respective extreme position will cause the vanes to transition to "SWING"
mode if that mode is available on the device.

#### Action: SetLeftRightVanePosition, GetLeftRightVanePosition, SetUpDownVanePosition, GetUpDownVanePosition ####

The `Set___VanePosition` actions set the vane position of the air handling unit to the specified setting, if possible. These actions
take a single parameter, `NewPosition`, which must be an integer greater than zero (limits are determined by the air handler and vary
from device to device). If zero (0) or no position is given, the plugin will attempt to set "AUTO" position. Any valid position supported
by the device can be given; for example, some devices support SWING and PULSE modes. The range of values accepted by the configured air
handler can be seen by examining the `LimitsVANEUD` and `LimitsVANELR` state variables.

<pre>
    luup.call_action( "urn:toggledbits-com:serviceId:IntesisWMPGateway1", "SetLeftRightVanePosition", { NewPosition=3 }, <i>deviceNumber</i> )
    luup.call_action( "urn:toggledbits-com:serviceId:IntesisWMPGateway1", "SetUpDownVanePosition", { NewPosition="AUTO" }, <i>deviceNumber</i> )
</pre>

#### Action: GetSignalStrength ####

The `GetSignalStrength` action returns a single argument (`SignalDB`) containing the WiFi signal strength reported by the gateway.
This is usually a negative integer (&lt; -96 is a bad/unacceptable signal; -86 to -95 is weak; -85 to -81 is good; -80 to -71 is very
good; and anything &gt;= -70 is excellent).

#### Variable: LimitsMODE, LimitsSETPTEMP, LimitsFANSP, etc ####

The variables beginning with `Limits` (e.g. `LimitsMODE`) contain the values, as a comma-separated list, that are acceptable to the
configured air handler as reported by the gateway. The `LimitsSETPTEMP` is a two-element list containing the minimum and maximum acceptable
setpoint temperatures in tenths of degrees Celsius. All other `Limits` variables are simple lists of the acceptable values, not ranges.

> NOTE: The limit values reported by the IntesisBox gateway are not always accurate for the air handler, and in some cases even conflict within the gateway. For example, it has been noted that at least one unit configuration will report "AUTO" as an acceptable value for "FANSP" (fan speed), yet attempts to set "AUTO" on the fan speed never work and always result in a numeric fan speed value. On other unit configurations it works fine.

#### Variable: ForceUnits ####

By default, the plug-in will adjust its UI to display temperatures in the default units configured for the Vera controller. If the Vera's
units are changed, the plug-in will self-reconfigure. If the user has some reason to need the plug-in to present its interfaces in units
over than the Vera's configured unit, setting `ForceUnits` to "C" or "F" will cause the plug-in to display Fahrenheit or Celsius,
respectively.

Note that this variable is not automatically created with the device. You will need to create it using the "Create Service" tab in the
device's Advanced settings tab (not the gateway device--the IntesisBox thermostat-looking device). The service name is (copy-paste recommended) `urn:toggledbits-com:serviceId:IntesisWMPDevice1`.

Each IntesisDevice1 instance may have its own copy of this variable, thus making it possible that the displayed units of each thermostat
may be different, as need may require.

#### Variable: IntesisERRSTATUS and IntesisERRCODE ####

The plugin will store the values of any `ERRSTATUS` and `ERRCODE` reports from the gateway device. Because the meaning of these codes varies from air handler
to air handler, the plugin does not act on them, but since they are stored, user-provided scripts could interpret the values and react using specific
knowledge of the air handling unit installed.

The known values for `ERRSTATUS` are "OK", "ERR" or blank/empty. The "ERR" string indicates that an error is currently active at the gateway.
The blank/empty string indicates that the gateway has not made an "ERRSTATUS" or "ERRCODE" report to the plugin and may not be supported (see note below).

The `ERRCODE` variable will contain a comma-separated list of the last 10 error codes reported. It can be safely written to an empty (zero-length) string
value ("") if an external facility is used to read and interpret the codes and it needs to mark the errors "handled."

> NOTE: The IS-IR-WMP-1 gateway does not have two-way communication with the configured air handling device, so the error variables are not available when using that model gateway, or any future similar model (i.e. models that are not hardwired to the air handler and have two-way communication with it).

### Standard Services ###

In addition to the above services, the IntesisWMPGateway plug-in implements the following "standard" services for thermostats (IntesisDevice1 devices):

* `urn:upnp-org:serviceId:HVAC_UserOperatingMode1`: `SetModeTarget` (Off, AutoChangeOver, HeatOn, CoolOn), `GetModeTarget`, `GetModeStatus`
* `urn:upnp-org:serviceId:HVAC_FanOperatingMode1`: `SetMode` (Auto, ContinuousOn), `GetMode`
* `urn:upnp-org:serviceId:TemperatureSetpoint1`: `SetCurrentSetpoint`, `GetCurrentSetpoint`

The plug-in also provides many of the state variables behind these services. In addition, the plug-in maintains the `CurrentTemperature`
state variable of the `urn:upnp-org:serviceId:TemperatureSensor1` service (current ambient temperature as reported by the gateway).

> **IMPORTANT:** The model for handling fan mode differs significantly between Intesis and Vera. In Vera/UPnP, setting the fan mode to `ContinuousOn` turns the fan on, but does not change the operating mode of the air handling unit. For example, with the fan mode set to `ContinuousOn`, if the AHU is cooling mode, it continues to cool until setpoint is achieved, at which time cooling shuts down but the fan continues to run. In Intesis, to get continuous operation of the fan, one sets the (operating) mode to "Fan", which will stop the AHU from heating or cooling. Because of this, the plugin does not react to the `SetMode` action in service `urn:upnp-org:serviceId:HVAC_FanOperatingMode1` (it is quietly ignored). In addition, the `FanStatus` state can only be deduced in the "Off" or "FanOnly" operating modes, in which case the status will be "Off" or "On" respectively; in all other cases it will be "Unknown".

> **IMPORTANT:** Also note that I take a different view of `ModeTarget` and `ModeStatus` (in HVAC_UserOperatingMode1) from Vera. Vera mostly (although not consistently) sees the two as nearly equivalent, with the latter (`ModeStatus`) following `ModeTarget`. That is, if `ModeTarget` is set to "HeatOn", `ModeStatus` also becomes "HeatOn". This is not entirely in keeping with UPnP in my opinion. UPnP says, in essence, that `ModeTarget` is the *desired* operating mode, and `ModeStatus` is the *current actual* operating state. This may sound like the same thing, except that UPnP takes status much more temporally than Vera; that is, UPnP says if `ModeTarget` is "HeatOn", but there is no call for heat because the temperature is within the setpoint hysteresis (aka the "deadband"), then `ModeStatus` may be "InDeadBand", indicating that the unit is currently not doing anything. When the current temperature deviates too far from the setpoint and the call for heat comes, then `ModeStatus` goes to "HeatOn", indicating that the air handling unit is then providing heat. In other words, Vera says `ModeStatus` is effectively a confirmation of `ModeTarget`, while UPnP says that `ModeTarget` is the goal, and `ModeStatus` reflects the at-the-moment state of the unit's activity toward the goal. Vera, then, has had to introduce a new non-standard service and variable (`ModeState`) to communicate what could and should be communicated in the service-standard variable.

## ImperiHome Integration ##

ImperiHome does not, by default, detect many plugin devices, including ImperiHome WMP Gateway. However, it is possible to configure this plugin
for use with ImperiHome, as the plugin implements the [ImperiHome ISS API](http://dev.evertygo.com/api/iss).

To connect Intesis WMP Gateway to ImperiHome:

1. In ImperiHome, go into **My Objects**
1. Click **Add a new object**
1. Choose **ImperiHome Standard System**
1. In the **Local base API** field, enter
   `http://your-vera-local-ip/port_3480/data_request?id=lr_IntesisWMPGateway&command=ISS`
1. Click **Next** to connect.

ImperiHome should then populate your groups with your Intesis WMP Gateway plugin devices.

NOTE: The ISS gateway does not operate using remote access; it only operates within the LAN segment with local IP access to the Vera.

## Reporting Bugs/Enhancement Requests ##

Bug reports and enhancement requests are welcome! Please use the ["Issues" section](https://github.com/toggledbits/IntesisWMPGateway/issues) of the Github repository to open a new bug report or make an enhancement request.

## License ##

IntesisWMPGateway is offered under GPL (the GNU Public License) 3.0. See the [LICENSE](https://www.gnu.org/licenses/gpl-3.0.en.html) file for details.

<hr>Copyright 2017,2018 Patrick H. Rigney, All Rights Reserved
