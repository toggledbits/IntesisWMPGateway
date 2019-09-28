-- -----------------------------------------------------------------------------
-- L_IntesisWMPGateway.lua
-- Copyright 2017,2018 Patrick H. Rigney, All Rights Reserved
-- http://www.toggledbits.com/intesis/
-- This file is available under GPL 3.0. See LICENSE in documentation for info.
-- -----------------------------------------------------------------------------

--[[
	Overview
	--------------------------------------------------------------------------------------------
	This is the core implementation for the WMP protocol inferface. The interface plugin emul-
	ates a thermostat by providing the operating mode, fan mode, setpoint mode, and temperature
	sensor services common to those devices, and a UI with typical thermostat controls.

	There a couple of differences between the Vera/UPnP(-ish) model and Intesis model of a
	thermostat.

	1) In Vera, the concept of On/Off is a mode of the thermostat, where Intesis handles it
	   separately from the mode. When "off", this driver holds ModeStatus and ModeTarget at
	   "Off", while separately tracking the last real mode Intesis reports it is in. A switch
	   to "On" thus restores the intended mode to the service state until we receive notice of
	   a mode change otherwise.
	2) In Vera, the fan mode and status are handled separately. In WMP, we (currently) have no
	   feedback with respect to the fan's operation (is it currently running or not), and fan
	   auto vs on is again folded into an Intesis mode ("FAN"). So, we go to some trouble to
	   emulate Vera's model in the device state, for benefit of any interfaces, scenes or Lua a
	   user may employ. Note that the plugin uses the Vera/UPnP standard "FanOnly" state, and
	   maps it back and forth to Intesis' mode "FAN" (as it does with all modes, which are
	   slightly different between the two platforms).
	3) The Intesis "DRY" mode has no analog in Vera, but it is treated as a new mode within the
	   existing HVAC_UserOperatingMode1 service ("Dry") and mapped as needed.
	3) Intesis' fan speed has no analog in the Vera model, so it is handled entirely within the
	   plugin's service.
	4) Intesis' vane position control also has no analog in the Vera model, so it, too, is hand-
	   led entirely in the plugin's service.
	5) Some WMP devices can return ERRSTATUS and ERRCODE, which indicate operating states of the
	   controlled (by the gateway) device. Since these vary from manufacturer to manufacturer
	   and unit to unit, they are simply stored and displayed without further interpretation.
	   This means that the status of the plugin reflects the status of the WMP gateway itself,
	   not that of the air handling unit, which can cause some difference between the displayed
	   status of the plugin and the observed behavior of the air handler. This is a limitation
	   of the WMP protocol and the gateway's connection to the air handler, which in some cases
	   may be "arm's length" (e.g. the IS-IR-WMP-1 sends IR commands to the air handler, and can
	   only assume that the commands are received and obeyed).

--]]

module("L_IntesisWMPGateway1", package.seeall)

local math = require("math")
local string = require("string")
local socket = require("socket")

local _PLUGIN_NAME = "IntesisWMPGateway"
local _PLUGIN_VERSION = "2.4"
local _PLUGIN_URL = "http://www.toggledbits.com/intesis"
local _CONFIGVERSION = 020203

local debugMode = false
-- local traceMode = false

local MYSID = "urn:toggledbits-com:serviceId:IntesisWMPGateway1"
local MYTYPE = "urn:schemas-toggledbits-com:device:IntesisWMPGateway:1"

local DEVICESID = "urn:toggledbits-com:serviceId:IntesisWMPDevice1"
local DEVICETYPE = "urn:schemas-toggledbits-com:device:IntesisWMPDevice:1"

local OPMODE_SID = "urn:upnp-org:serviceId:HVAC_UserOperatingMode1"
local FANMODE_SID = "urn:upnp-org:serviceId:HVAC_FanOperatingMode1"
local SETPOINT_SID = "urn:upnp-org:serviceId:TemperatureSetpoint1"
local TEMPSENS_SID = "urn:upnp-org:serviceId:TemperatureSensor1"
local HADEVICE_SID = "urn:micasaverde-com:serviceId:HaDevice1"

local MODE_OFF = "Off"
local MODE_COOL = "CoolOn"
local MODE_HEAT = "HeatOn"
local MODE_AUTO = "AutoChangeOver"
local MODE_FAN = "FanOnly"
local MODE_DRY = "Dry"

local EMODE_NORMAL = "Normal"
-- local EMODE_ECO = "EnergySavingsMode"

local FANMODE_AUTO = "Auto"
-- local FANMODE_PERIODIC = "PeriodicOn"
local FANMODE_ON = "ContinuousOn"

-- Intesis EOL string. Can be CR only, doesn't need LF. The device takes either or both per their spec.
local INTESIS_EOL = string.char(13)
-- Default ping interval. This can overridden by state variable PingInterval.
local DEFAULT_PING = 32
-- Default refresh interval (GET,1:*). This can be overridden by state variable RefreshInterval
local DEFAULT_REFRESH = 64

local runStamp = {}
local devData = {}
local devicesByMAC = {}

local isALTUI = false
local isOpenLuup = false

local function dump(t, seen)
	if t == nil then return "nil" end
	if seen == nil then seen = {} end
	local sep = ""
	local str = "{ "
	for k,v in pairs(t) do
		local val
		if type(v) == "table" then
			if seen[v] then val = "(recursion)"
			else
				seen[v] = true
				val = dump(v, seen)
			end
		elseif type(v) == "string" then
			val = string.format("%q", v)
		elseif type(v) == "number" and (math.abs(v-os.time()) <= 86400) then
			val = tostring(v) .. "(" .. os.date("%x.%X", v) .. ")"
		else
			val = tostring(v)
		end
		str = str .. sep .. k .. "=" .. val
		sep = ", "
	end
	str = str .. " }"
	return str
end

local function L(msg, ...) -- luacheck: ignore 212
	local str
	local level = 50
	if type(msg) == "table" then
		str = tostring(msg.prefix or _PLUGIN_NAME) .. ": " .. tostring(msg.msg or msg[1])
		level = msg.level or level
	else
		str = _PLUGIN_NAME .. ": " .. tostring(msg)
	end
	str = string.gsub(str, "%%(%d+)", function( n )
			n = tonumber(n, 10)
			if n < 1 or n > #arg then return "nil" end
			local val = arg[n]
			if type(val) == "table" then
				return dump(val)
			elseif type(val) == "string" then
				return string.format("%q", val)
			elseif type(val) == "number" and math.abs(val-os.time()) <= 86400 then
				return tostring(val) .. "(" .. os.date("%x.%X", val) .. ")"
			end
			return tostring(val)
		end
	)
	luup.log(str, math.max(1,level))
	-- if traceMode then trace('log',str) end
end

local function D(msg, ...)
	if debugMode then
		L({msg=msg,prefix=_PLUGIN_NAME.."(debug)::"}, ... )
	end
end

local function split( str, sep )
	if sep == nil then sep = "," end
	local arr = {}
	if #str == 0 then return arr, 0 end
	local rest = string.gsub( str or "", "([^" .. sep .. "]*)" .. sep, function( m ) table.insert( arr, m ) return "" end )
	table.insert( arr, rest )
	return arr, #arr
end

-- Constraint the argument to the specified min/max
local function constrain( n, nMin, nMax )
	n = tonumber(n) or nMin
	if n < nMin then return nMin end
	if nMax ~= nil and n > nMax then return nMax end
	return n
end

-- Convert F to C
local function FtoC( temp )
	temp = tonumber(temp)
	assert( temp ~= nil )
	return ( temp - 32 ) * 5 / 9
end

-- Convert C to F
local function CtoF( temp )
	temp = tonumber(temp)
	assert( temp ~= nil )
	return ( temp * 9 / 5 ) + 32
end

-- See if value is within limits (default OK)
local function inLimit( lim, val, dev )
	if type(val) == "number" and devData[dev].limits[lim].range then
		if devData[dev].limits[lim].range.min and val < devData[dev].limits[lim].range.min then return false end
		if devData[dev].limits[lim].range.max and val > devData[dev].limits[lim].range.max then return false end
		return true
	end
	val = tostring(val)
	if (devData[dev].limits or {})[lim] then
		for _,v in ipairs(devData[dev].limits[lim].values or {}) do
			if val == v then return true end
		end
		return false
	end
	-- No limit data, just say it's OK.
	return true
end

local function askLuci(p)
	D("askLuci(%1)", p)
	local uci = require("uci")
	if uci then
		local ctx = uci.cursor(nil, "/var/state")
		if ctx then
			return ctx:get(unpack((split(p,"%."))))
		else
			D("askLuci() can't get context")
		end
	else
		D("askLuci() no UCI module")
	end
	return nil
end

-- Query UCI for WAN IP4 IP
local function getSystemIP4Addr( dev )
	D("getSystemIP4Attr(%1)", dev)
	local vera_ip = askLuci("network.wan.ipaddr")
	D("getSystemIP4Addr() got %1 from Luci", vera_ip)
	if not vera_ip then
		-- Fallback method
		local p = io.popen("/usr/bin/GetNetworkState.sh wan_ip")
		vera_ip = p:read("*a") or ""
		p:close()
		D("getSystemIP4Addr() got system ip4addr %1 using fallback", vera_ip)
	end
	return vera_ip:gsub("%c","")
end

-- Query UCI for WAN IP4 netmask
local function getSystemIP4Mask( dev )
	D("getSystemIP4Mask(%1)", dev)
	local mask = askLuci("network.wan.netmask");
	D("getSystemIP4Mask() got %1 from Luci", mask)
	if not mask then
		-- Fallback method
		local p = io.popen("/usr/bin/GetNetworkState.sh wan_netmask")
		mask = p:read("*a") or ""
		p:close()
		D("getSystemIP4Addr() got system ip4mask %1 using fallback", mask)
	end
	return mask:gsub("%c","")
end

-- Compute broadcast address (IP4)
local function getSystemIP4BCast( dev )
	local broadcast = luup.variable_get( MYSID, "DiscoveryBroadcast", dev ) or ""
	if broadcast ~= "" then
		return broadcast
	end

	-- Do it the hard way.
	local vera_ip = getSystemIP4Addr( dev )
	local mask = getSystemIP4Mask( dev )
	D("getSystemIP4BCast() sys ip %1 netmask %2", vera_ip, mask)
	local a1,a2,a3,a4 = vera_ip:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)")
	local m1,m2,m3,m4 = mask:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)")
	local bit = require("bit")
	-- Yeah. This is my jam, baby!
	a1 = bit.bor(bit.band(a1,m1), bit.bxor(m1,255))
	a2 = bit.bor(bit.band(a2,m1), bit.bxor(m2,255))
	a3 = bit.bor(bit.band(a3,m3), bit.bxor(m3,255))
	a4 = bit.bor(bit.band(a4,m4), bit.bxor(m4,255))
	broadcast = string.format("%d.%d.%d.%d", a1, a2, a3, a4)
	D("getSystemIP4BCast() computed broadcast address is %1", broadcast)
	return broadcast
end

local function scanARP( dev, mac, ipaddr )
	D("scanARP(%1,%2,%3) luup.device=%4", dev, mac, ipaddr, luup.device)

	-- Vera arp is a function defined in /etc/profile (currently). ??? Needs some flexibility here.
	local pipe = io.popen("cat /proc/net/arp")
	local m = pipe:read("*a")
	pipe:close()
	local res = {}
	m:gsub("([^\r\n]+)", function( t )
			local p = { t:match("^([^%s]+)%s+([^%s]+)%s+([^%s]+)%s+([^%s]+)%s+(.*)$") }
			D("scanARP() handling line %1, data %2", t, p)
			if p ~= nil and p[4] ~= nil then
				local mm = p[4]:gsub("[:-]", ""):upper() -- clean MAC
				if ( mac or "" ) ~= "" then
					if mm == mac then
						table.insert( res, { mac=mac, ip=p[1] } )
					end
				elseif ( ipaddr or "" ) ~= "" then
					if ipaddr == p[1] and mm ~= "000000000000" then
						table.insert( res, { mac=mm, ip=ipaddr } )
					end
				end
			end
			return ""
		end
	)
	return res
end

-- Try to resolve a MAC address to an IP address. We do with with a broadcast ping
-- followed by an examination of the ARP table.
local function getIPforMAC( mac, dev )
	D("getIPforMAC(%1,%2)", mac, dev)
	assert(not isOpenLuup, "We don't know how to do this on openLuup, yet.")
	mac = mac:gsub("[%s:-]", ""):upper()
	local broadcast = getSystemIP4BCast( dev )
	os.execute("/bin/ping -4 -q -c 3 -w 1 " .. broadcast)
	return scanARP( dev, mac, nil )
end

-- Try to resolve IP address to a MAC address. Same process as above.
local function getMACforIP( ipaddr, dev )
	D("getMACforIP(%1,%2)", ipaddr, dev)
	assert(not isOpenLuup, "We don't know how to do this on openLuup, yet.")
	os.execute("/bin/ping -4 -q -c 3 " .. ipaddr)
	return scanARP( dev, nil, ipaddr )
end

-- Get numeric variable, or return default value if not set or blank
local function getVarNumeric( name, dflt, dev, serviceId )
	assert(name ~= nil)
	assert(dev ~= nil)
	if debugMode then assert(serviceId ~= nil) end
	if serviceId == nil then serviceId = MYSID end
	local s = luup.variable_get(serviceId, name, dev)
	if (s == nil or s == "") then return dflt end
	s = tonumber(s, 10)
	if (s == nil) then return dflt end
	return s
end

-- Set gateway status display. Also echos message to log.
local function gatewayStatus( msg, dev )
	msg = msg or ""
	assert( dev ~= nil )
	if msg ~= "" then L(msg) end -- don't clear clearing of status
	luup.variable_set( MYSID, "DisplayStatus", msg, dev )
end

-- Find WMP device by MAC address
local function findDeviceByMAC( mac, parentDev )
	D("findDeviceByMAC(%1,%2)", mac, parentDev)
	mac = (mac or ""):upper()
	-- Cached?
	if devicesByMAC[mac] ~= nil then return devicesByMAC[mac], luup.devices[devicesByMAC[mac]] end
	-- No, look for it.
	for n,d in pairs(luup.devices) do
		if d.device_type == DEVICETYPE and d.device_num_parent == parentDev and mac == d.id then
			devicesByMAC[mac] = n
			return n,d
		end
	end
	return nil
end

-- Return an array of the Luup device numbers of all child WMP devices of parent
local function inventoryChildren( parentDev )
	local children = {}
	for n,d in pairs( luup.devices ) do
		if d.device_type == DEVICETYPE and d.device_num_parent == parentDev then
			devicesByMAC[d.id] = n -- fast-track our cache of known children
			table.insert( children, n )
		end
	end
	return children
end

-- Close socket. This intended to be called using pcall(), so errors do not interrupt
-- the operation of the plugin. What errors? Anything. Make the effort to close no matter what.
local function closeSocket( dev )
	D("closeSocket(%1)", dev)
	-- Deliberate sequence of events here!
	devData[dev].isConnected = false
	if devData[dev].sock ~= nil then
		local x = devData[dev].sock
		devData[dev].sock = nil
		x:close()
	end
end

local function configureSocket( sock, dev )
	-- Keep timeout shorts so problems don't cause watchdog restarts.
	sock:settimeout( 1, "b" )
	sock:settimeout( 1, "r" )
	devData[dev].sock = sock
	devData[dev].isConnected = true
	devData[dev].lastinfo = 0
	devData[dev].lastdtm = 0
	devData[dev].lastRefresh = 0
	devData[dev].lastSendTime = os.time()
end

-- Open TCP connection to IntesisBox device
local function deviceConnectTCP( dev )
	D("deviceConnectTCP(%1)", dev)
	assert( dev ~= nil )

	if devData[dev].isConnected == true and devData[dev].sock ~= nil then return true end

	local ip = luup.variable_get( DEVICESID, "IPAddress", dev ) or ""
	local port = getVarNumeric( "TCPPort", 3310, dev, DEVICESID )
	D("deviceConnectTCP() connecting to %1:%2...", ip, port )
	local sock, err = socket.tcp()
	if sock then
		sock:settimeout( 5, "b" )
		sock:settimeout( 5, "r" )
		local status
		if ip ~= "" then
			status, err = sock:connect( ip, port )
		else
			status, err = false, "IP not configured"
		end
		if not status then
			L("Can't open %1 (%2) at %3:%4, %5", dev, luup.devices[dev].description, ip, port, err)
			devData[dev].isConnected = false
			sock:close()

			-- See if IP address has changed
			D("deviceConnectTCP() see if IP address changed")
			local newIPs = getIPforMAC( luup.devices[dev].id, dev )
			D("deviceConnectTCP() newIPs=%1", newIPs)
			if newIPs ~= nil then
				for _,newIP in ipairs( newIPs ) do
					if newIP.ip ~= ip then -- don't try what already failed
						D("deviceConnectTCP() attempting connect to %1:%2", newIP.ip, port)
						sock = socket.tcp() -- get a new socket
						sock:settimeout( 5, "b" )
						sock:settimeout( 5, "r" )
						status, err = sock:connect( newIP.ip, port )
						if status then
							-- Good connect! Store new address.
							L("IP address for %1 (%2) has changed, was %3, now %4", dev, luup.devices[dev].description, ip, newIP.ip)
							luup.variable_set( DEVICESID, "IPAddress", newIP.ip, dev )
							configureSocket( sock, dev )
							return true
						end
						D("deviceConnectTCP() failed on %1, %2", newIP.ip, err)
						sock:close()
					end
				end
				-- None of these IPs worked, or, one did... how do we know...
				return false
			else
				return false
			end
		end
	else
		L("Can't create TCP socket: %1", err)
		devData[dev].isConnected = false
		return false
	end

	L("Successful connection to %1 for %2 (%3)", ip, dev, luup.devices[dev].description)
	configureSocket( sock, dev )
	return true
end

-- Send a command
local function sendCommand( cmdString, dev )
	D("sendCommand(%1,%2)", cmdString, dev)
	assert(dev ~= nil)
	if type(cmdString) == "table" then cmdString = table.concat( cmdString ) end

	-- Store the last command for reference
	local cmd = cmdString .. INTESIS_EOL

	-- See if our socket is open. If not, open it.
	if not devData[dev].isConnected then
		if not deviceConnectTCP( dev ) then
			return false
		end
	end

	devData[dev].sock:settimeout( 2, "b" )
	devData[dev].sock:settimeout( 2, "r" )
	local nb, err = devData[dev].sock:send( cmd )
	if nb ~= nil then
		D("sendCommand() send succeeded, %1 bytes sent", nb)
		devData[dev].lastCommand = cmdString
		devData[dev].lastSendTime = os.time()
		return true
	elseif err == "timeout" then
		D("sendCommand() send timeout, continuing...")
		return true -- say OK, don't close connection
	elseif err == "closed" then
		D("sendCommand() peer closed connection")
	else
		D("sendCommand() socket.send returned %1, closing/restarting", err)
	end

	-- Close connection, will retry later.
	pcall( closeSocket, dev )
	return false -- for now, but a later attempt should re-open if we can

end

-- Handle an ID response
-- Ex. ID:IS-IR-WMP-1,001122334455,192.168.0.177,ASCII,v1.0.5,-51,TEST,N
local function handleID( unit, segs, pdev )
	D("handleID(%1,%2,%3)", unit, segs, pdev)
	local args
	luup.variable_set( DEVICESID, "IntesisID", segs[2], pdev )
	args = split( segs[2], "," )
	luup.variable_set( DEVICESID, "Name", args[7] or "", pdev )
	luup.variable_set( DEVICESID, "SignalDB", args[6] or "", pdev )
	luup.attr_set( "manufacturer", "Intesis", pdev )
	luup.attr_set( "model", args[1] or "", pdev )
end

-- Handle an INFO response (nothing to do)
local function handleINFO( unit, segs, pdev )
	D("handleINFO(%1,%2,%3)", unit, segs, pdev)
end

-- Handle CHN response
-- Ex: CHN,1:MODE,COOL
local function handleCHN( unit, segs, pdev )
	D("handleCHN(%1,%2,%3)", unit, segs, pdev)
	local args
	args = split( string.upper( segs[2] ), "," )
	if args[1] == "ONOFF" then
		-- The on/off state is separate from mode in Intesis, but part of mode in the
		--   HVAC_UserOperatingMode1 service. See comments below on how we handle that.
		luup.variable_set( DEVICESID, "IntesisONOFF", args[2], pdev )
		if args[2] == "OFF" then
			-- Note we don't touch LastMode here!
			luup.variable_set( OPMODE_SID, "ModeTarget", MODE_OFF, pdev )
			luup.variable_set( OPMODE_SID, "ModeStatus", MODE_OFF, pdev )
			luup.variable_set( FANMODE_SID, "FanStatus", "Off", pdev )
		elseif args[2] == "ON" then
			-- When turning on, restore state of LastMode.
			local last = luup.variable_get( DEVICESID, "LastMode", pdev ) or MODE_AUTO
			luup.variable_set( OPMODE_SID, "ModeTarget", last, pdev )
			luup.variable_set( OPMODE_SID, "ModeStatus", last, pdev )
			if last == MODE_FAN then
				luup.variable_set( FANMODE_SID, "FanStatus", "On", pdev )
			else
				luup.variable_set( FANMODE_SID, "FanStatus", "Unknown", pdev )
			end
		else
			L("Invalid ONOFF state from device %1 in %2", args[2], segs)
		end
	elseif args[1] == "MODE" then
		if args[2] == nil then
			L("Malformed CHN segment %2 function data missing in %3", args[1], segs)
			return
		end
		-- Store this for use by others, just to have available
		luup.variable_set( DEVICESID, "IntesisMODE", args[2], pdev )

		--[[ Now map the Intesis mode into what the service allows. We track this into two
			 variables: the usual ModeStatus for the service, and our own LastMode. In the
			 service, "Off" is one of the possible states, where it's separate in Intesis.
			 So we only change the service status if we're actually ON. Otherwise, we just
			 save it in LastMode, and getting it back into ModeStatus happens later when
			 the device is turned back on (see above).

			 Note that there doesn't seem to be a guaranteed order for when ONOFF and MODE
			 appear, and it seems unlikely it would ever be desirable to assume it. This
			 mechanism should work regardless of the order in which these messages arrive.
		--]]

		local xmap = { ["COOL"]=MODE_COOL, ["HEAT"]=MODE_HEAT, ["AUTO"]=MODE_AUTO, ["FAN"]=MODE_FAN, ["DRY"]=MODE_DRY }
		-- Save as LastMode, and conditionally ModeStatus (see comment block above).
		local newMode = xmap[args[2]]
		if newMode == nil then
			L("*** UNEXPECTED MODE '%1' RETURNED FROM WMP GATEWAY, IGNORED", args[2])
			return
		end
		luup.variable_set( DEVICESID, "LastMode", newMode, pdev )
		local currMode = luup.variable_get( OPMODE_SID, "ModeStatus", pdev ) or MODE_OFF
		if currMode ~= MODE_OFF then
			luup.variable_set( OPMODE_SID, "ModeTarget", newMode, pdev )
			luup.variable_set( OPMODE_SID, "ModeStatus", newMode, pdev )
			if newMode == MODE_FAN or newMode == MODE_DRY then
				-- With Intesis in FAN and DRY mode, we know fan is running (speed is a separate matter)
				luup.variable_set( FANMODE_SID, "Mode", FANMODE_ON, pdev )
				luup.variable_set( FANMODE_SID, "FanStatus", "On", pdev )
			else
				-- In any other mode, fan is effectively auto and we don't know its state.
				luup.variable_set( FANMODE_SID, "Mode", FANMODE_AUTO, pdev )
				luup.variable_set( FANMODE_SID, "FanStatus", "Unknown", pdev )
			end
		end
	elseif args[1] == "SETPTEMP" then
		-- Store the setpoint temperature. Leave unchanged if out of range (usually thermostat in
		-- a mode where setpoint doesn't matter, e.g. FAN--at least once we've seen 32767 come back
		-- in that case).
		local ptemp = tonumber(args[2])
		if ptemp and ptemp >= 0 and ptemp < 1200 then
			ptemp = ptemp / 10
			if devData[pdev].sysTemps.unit == "F" then
				ptemp = CtoF( ptemp )
			end
			D("handleCHN() received SETPTEMP %1, setpoint now %2", args[2], ptemp)
			luup.variable_set( SETPOINT_SID, "CurrentSetpoint", string.format( "%.0f", ptemp ), pdev )
		else
			D("handleCHN() received SETPTEMP %1, ignored", args[2], ptemp)
		end
	elseif args[1] == "AMBTEMP" then
		-- Store the current ambient temperature
		local ptemp = tonumber( args[2], 10 ) / 10
		if devData[pdev].sysTemps.unit == "F" then
			ptemp = CtoF( ptemp )
		end
		local dtemp = string.format( "%2.1f", ptemp )
		D("handleCHN() received AMBTEMP %1, current temp %2", args[2], dtemp)
		luup.variable_set( TEMPSENS_SID, "CurrentTemperature", dtemp, pdev )
		luup.variable_set( DEVICESID, "DisplayTemperature", dtemp, pdev )
	elseif args[1] == "FANSP" then
		-- Fan speed also doesn't have a 1-1 mapping with the service. Just track it.
		luup.variable_set( DEVICESID, "IntesisFANSP", args[2] or "", pdev )
	elseif args[1] == "VANEUD" then
		-- There's no analog in the service for vane position, so just store the data
		-- in case others want to use it.
		luup.variable_set( DEVICESID, "IntesisVANEUD", args[2] or "", pdev )
	elseif args[1] == "VANELR" then
		-- There's no analog in the service for vane position, so just store the data
		-- in case others want to use it.
		luup.variable_set( DEVICESID, "IntesisVANELR", args[2] or "", pdev )
	elseif args[1] == "ERRSTATUS" then
		-- Should be OK or ERR. Track.
		luup.variable_set( DEVICESID, "IntesisERRSTATUS", args[2] or "", pdev )
	elseif args[1] == "ERRCODE" then
		-- Values are dependent on the connected device. Track.
		l = luup.variable_get( DEVICESID, "IntesisERRCODE", pdev )
		l = split( l or "" ) or {}
		table.insert( l, tostring(args[2]):gsub(",","%2C") )
		while #l > 10 do table.remove( l, 1 ) end
		luup.variable_set( DEVICESID, "IntesisERRCODE", table.concat( l, "," ), pdev )
	else
		D("handleCHN() unhandled function %1 in %2", args[1], segs)
	end
end

-- Handle LIMITS
function handleLIMITS( unit, segs, pdev )
	D("handleLIMITS(%1,%2,%3)", unit, segs, pdev)
	if #segs >= 2 then
		local _,_,obj,lim = string.find( segs[2], "([^,]+),%[(.*)%]" )
		if obj then
			devData[pdev].limits[obj] = { values=split( lim ) or {} }
			luup.variable_set( DEVICESID, "Limits" .. obj, lim, pdev )
			local mmin, mmax
			for _,v in ipairs(devData[pdev].limits[obj].values) do
				local vn = tonumber(v)
				if vn then
					if mmin == nil or vn < mmin then mmin = vn end
					if mmax == nil or vn > mmax then mmax = vn end
				end
			end
			if mmin or mmax then
				devData[pdev].limits[obj].range = { ['min']=mmin, ['max']=mmax }
			end
		end
		if obj == "MODE" then
			-- For mode, we may need to enable or disable certain UI buttons
			local mm = { COOL=0, HEAT=0, AUTO=0, FAN=0, DRY=0 }
			for _,v in ipairs( devData[pdev].limits[obj].values ) do
				luup.variable_set( DEVICESID, "Mode"..v, 1, pdev )
				mm[v] = nil
			end
			for k in pairs(mm) do
				luup.variable_set( DEVICESID, "Mode"..k, 0, pdev )
			end
		elseif obj == "SETPTEMP" then
			local r = devData[pdev].limits[obj].range or {}
			-- Limits are always degC x 10
			if r.min then
				devData[pdev].sysTemps.minimum = devData[pdev].sysTemps.unit == "F" and CtoF(r.min / 10) or (r.min / 10)
			end
			if r.max then
				devData[pdev].sysTemps.maximum = devData[pdev].sysTemps.unit == "F" and CtoF(r.max / 10) or (r.max / 10)
			end
		end
	end
end

-- Handle ACK
function handleACK( unit, segs, pdev )
	D("handleACK(%1,%2,%3)", unit, segs, pdev)
	-- We've been heard; do nothing
	D("handMessage() ACK received, last command %1", devData[pdev].lastCommand)
end

-- Handle ERR
function handleERR( unit, segs, pdev )
	D("handleERR(%1,%2,%3)", unit, segs, pdev)
	L("WMP device returned ERR after %1", devData[pdev].lastCommand)
end

-- Handle CLOSE, the server signalling that it is closing the connection.
function handleCLOSE( unit, segs, pdev )
	D("handleCLOSE(%1,%2,%3)", unit, segs, pdev)
	L("DEVICE IS CLOSING CONNECTION!")
	-- luup.set_failure( 1, pdev ) -- no active failure, let future comm error signal it
	-- devData[pdev].isConnected = false
end

-- Handle PONG response
function handlePONG( unit, segs, pdev )
	D("handlePONG(%1,%2,%3)", unit, segs, pdev)
	-- response to PING, returns signal strength
	luup.variable_set( DEVICESID, "SignalDB", segs[2] or "", pdev )
end

local ResponseDispatch = {
	ID=handleID,
	INFO=handleINFO,
	CHN=handleCHN,
	LIMITS=handleLIMITS,
	ACK=handleACK,
	ERR=handleERR,
	PONG=handlePONG,
	CLOSE=handleCLOSE
}

-- Handle the message just received.
local function handleMessage( msg, pdev )
	D("handleMessage(%1)", msg)
	local segs, nSeg
	segs, nSeg = split( msg, ":" )
	if nSeg < 1 then
		L("malformed response from unit, insufficient segments: %1", msg)
		return
	end

	-- The first segment contains the response type, for which many have a unit number (comma-separated from type)
	local resp = split( segs[1], "," ) or { "<UNDEFINED>" }
	local respType = string.upper( resp[1] or "" )
	local respUnit = tonumber( resp[2], 10 ) or 0

	-- Dispatch the response
	local f = ResponseDispatch[ respType ]
	if f ~= nil then
		f( respUnit, segs, pdev )
	else
		D("Response from server could not be dispatched (type %1 in %2)", respType, msg)
	end
end

-- Receive data on the socket. Handle complete responses. Returns
-- true if any data was received, false otherwise.
local function deviceReceive( dev )
	D("deviceReceive(%1)", dev)
	if not devData[dev].isConnected then
		D("deviceReceive() socket is not connected")
		return false
	end

	-- We'd love for LuaSocket to have an option to just return as much data as it has...
	-- Loop for up to 255 bytes. That's an arbitrary choice to make sure we return
	-- to our caller if the peer is transmitting continuously.
	devData[dev].sock:settimeout( 0, "b" )
	devData[dev].sock:settimeout( 0, "r" )
	local count = 0
	while count < 255 do
		local b, err = devData[dev].sock:receive(1)
		if b == nil then
			-- Timeouts are not a problem, but we stop looping when we get one.
			if err ~= "timeout" then
				D("deviceReceive() error %1", err)
			end
			break
		end

		local ch = string.byte(b)
		devData[dev].lastIncoming = os.time() -- or socket milliseconds? Not sure we need that much accuracy...
		count = count + 1

		if ch == 13 or ch == 10 then
			-- End of line
			if devData[dev].inBuffer ~= nil then
				handleMessage( devData[dev].inBuffer, dev )
				devData[dev].inBuffer = nil
			end
		else
			-- Capture the character
			if devData[dev].inBuffer == nil then
				devData[dev].inBuffer = b
			else
				devData[dev].inBuffer = devData[dev].inBuffer .. b
			end
		end
	end
	return count > 0
end

-- Update the display status. We don't really bother with this at the moment because the WMP
-- protocol doesn't tell us the running status of the unit (see comments at top of this file).
local function updateDeviceStatus( dev )
	local msg = "&nbsp;"
	if not devData[dev].isConnected then
		luup.variable_set( DEVICESID, "DisplayTemperature", "??.?", dev )
		msg = "Comm Fail"
	else
		local errst = luup.variable_get( DEVICESID, "IntesisERRSTATUS", dev ) or "OK"
		if errst ~= "OK" then
			local errc = luup.variable_get( DEVICESID, "IntesisERRCODE", dev ) or ""
			msg = string.format( "%s %s", errst, errc )
		end
	end
	luup.variable_set( DEVICESID, "DisplayStatus", msg, dev )
end

-- Handle a discovery response.
local function handleDiscoveryMessage( msg, parentDev )
	D("handleDiscoveryMessage(%1,%2)", msg, parentDev)
	assert(parentDev ~= nil)
	assert(luup.devices[parentDev].device_type == MYTYPE, "parentDev must be gateway device type")

	-- Message format expected:
	-- DISCOVER:IS-IR-WMP-1,001DC9A183E1,192.168.0.177,ASCII,v1.0.5,-51,TEST,N,1
	local parts = split( msg, "," )
	parts[1] = parts[1] or ""
	local model = parts[1]:sub(10)
	if string.sub( parts[1], 1, 9) ~= "DISCOVER:" then
		D("handleDiscoveryMessage() can't handle %1 message type", parts[1])
		return
	elseif not string.match( model, "-WMP-" ) or parts[4] ~= "ASCII" then
		L("Discovery response from %1 (%2) model %3 not handled by this plugin. %4", parts[2], parts[3], model, msg)
		gatewayStatus( model .. " is not compatible", parentDev )
		return

	end
	gatewayStatus( string.format("Response from %s at %s", tostring(parts[2]), tostring(parts[3])), parentDev )

	-- See if the device is already listed
	local child = findDeviceByMAC( parts[2], parentDev )
	if child ~= nil then
		D("handleDiscoveryMessage() discovery response from %1 (%2), already have it as child %3", parts[2], parts[3], child)
		gatewayStatus( string.format("%s at %s is already known", parts[2], parts[3]), parentDev )
		return
	end

	L("Did not find %1 as child of %2, adding...", parts[2], parentDev)
	-- Need to create a child device, which can only be done by re-creating all child devices.
	gatewayStatus( string.format("Adding %s at %s...", tostring(parts[2]), tostring(parts[3])), parentDev )

	local children = inventoryChildren( parentDev )
	local ptr = luup.chdev.start( parentDev )
	for _,ndev in ipairs( children ) do
		local v = luup.devices[ndev]
		D("adding child %1 (%2)", v.id, v.description)
		luup.chdev.append( parentDev, ptr, v.id, v.description, "", "D_IntesisWMPDevice1.xml", "", "", false )
	end

	-- Now add newly discovered device
	L("Adding new child %1 (%2) model %3 name %4", parts[2], parts[3], model, parts[7])
	local newMAC = parts[2]
	local newName = parts[7] or (model .. " " .. newMAC:sub(-6))
	local ident = msg:sub(10)
	luup.chdev.append( parentDev, ptr,
		newMAC, -- id (altid)
		newName, -- description
		"", -- device type
		"D_IntesisWMPDevice1.xml", -- device file
		"", -- impl file
		DEVICESID .. ",IntesisID=" .. ident, -- state vars
		false -- embedded
	)

	-- Close children. This will cause a Luup reload if something changed.
	luup.chdev.sync( parentDev, ptr )
	L("Children done. I should be reloading...")
end

-- Fake a discovery message with the MAC and IP passed.
local function passGenericDiscovery( mac, ip, gateway, dev )
	D("passGenericDiscovery(%1,%2,%3,%4)", mac, ip, gateway, dev)
	assert(gateway ~= nil)
	assert(luup.devices[gateway].device_type == MYTYPE, "gateway arg not gateway device")
	handleDiscoveryMessage(
		string.format("DISCOVER:UNKNOWN-WMP-1,%s,%s,ASCII,v0.0.0,-99,IntesisDevice,N,1", mac, ip),
		gateway
	)
end

-- List of commands to send early after initialization (inquiries).
local infocmd = { "INFO", "LIMITS:*" }

function deviceTick( dargs )
	D("deviceTick(%1), luup.device=%2", dargs, luup.device)
	local dev, stamp = dargs:match("^(%d+):(%d+):(.*)$")
	dev = tonumber(dev, 10)
	assert(dev ~= nil, "Nil device in deviceTick()")
	stamp = tonumber(stamp, 10)
	if stamp ~= runStamp[dev] then
		D("deviceTick() received stamp %1, expecting %2; must be a newer thread started, exiting.", stamp, runStamp[dev])
		return
	end

	-- See if we received any data.
	devData[dev].lastDelay = devData[dev].lastDelay or 1
	if not devData[dev].isConnected then
		D("deviceTick() peer is not connected, trying to reconnect...")
		if sendCommand("ID", dev) then
			nextDelay = 1
		else
			D("deviceTick() can't connect peer, waiting...")
			nextDelay = 60 -- wait a good while before trying again.
			updateDeviceStatus( dev )
		end
	elseif deviceReceive( dev ) then
		nextDelay = 1 -- if we got data, turn around fast to get more, if we can.
	else
		-- No data received, idle stuff
		local now = os.time()
		local intPing = getVarNumeric( "PingInterval", DEFAULT_PING, dev, DEVICESID )
		local intRefresh = getVarNumeric( "RefreshInterval", DEFAULT_REFRESH, dev, DEVICESID )

		-- No data received. By default, next delay is 2 x previous delay, max 16
		nextDelay = math.min( 16, devData[dev].lastDelay * 2 )

		-- If it's been more than two refresh intervals or three pings since we
		-- received some data, we may be in trouble...
		if devData[dev].isConnected and ( (now - devData[dev].lastIncoming) >= math.min( 2 * intRefresh, 3 * intPing ) ) then
			L("Device receive timeout; marking disconnected!")
			pcall( closeSocket, dev )
			updateDeviceStatus( dev )
			nextDelay = 1
		elseif devData[dev].lastinfo < #infocmd then
			devData[dev].lastinfo = devData[dev].lastinfo + 1
			sendCommand(infocmd[devData[dev].lastinfo], dev)
			nextDelay = 1
		elseif devData[dev].lastRefresh + intRefresh <= now then
			sendCommand("GET,1:*", dev)
			devData[dev].lastRefresh = now
			nextDelay = 1
		elseif devData[dev].lastSendTime + intPing <= now then
			sendCommand("PING", dev)
			nextDelay = 1
		elseif devData[dev].lastdtm == nil or ( devData[dev].lastdtm + 3600 ) <= now then
			sendCommand(string.format("CFG:DATETIME,%s", os.date("%d/%m/%Y %H:%M:%S")), dev)
			devData[dev].lastdtm = now
			nextDelay = 1
		end
	end

	-- OK?
	if devData[dev].isConnected then
		luup.variable_set( DEVICESID, "Failure", 0, dev )
	else
		luup.variable_set( DEVICESID, "Failure", 1, dev )
	end

	-- Arm for another query.
	assert( nextDelay > 0 )
	D("deviceTick() arming for next tick in %1", nextDelay)
	luup.call_delay( "intesisDeviceTick", nextDelay, dargs )
	devData[dev].lastDelay = nextDelay
end

-- Do a one-time startup on a new device
local function deviceRunOnce( dev, parentDev )

	local rev = getVarNumeric("Version", 0, dev, DEVICESID)
	if rev == 0 then
		-- Initialize for new installation
		D("runOnce() Performing first-time initialization!")
		luup.variable_set(DEVICESID, "Parent", parentDev, dev )
		luup.variable_set(DEVICESID, "IPAddress", "", dev )
		luup.variable_set(DEVICESID, "TCPPort", "", dev )
		luup.variable_set(DEVICESID, "Name", "", dev)
		luup.variable_set(DEVICESID, "SignalDB", "", dev)
		luup.variable_set(DEVICESID, "DisplayTemperature", "--.-", dev)
		luup.variable_set(DEVICESID, "DisplayStatus", "", dev)
		luup.variable_set(DEVICESID, "ConfigurationUnits", "C", dev)
		luup.variable_set(DEVICESID, "Failure", 0, dev )
		-- Don't mess with IntesisID
		luup.variable_set(DEVICESID, "IntesisONOFF", "", dev)
		luup.variable_set(DEVICESID, "IntesisMODE", "", dev)
		luup.variable_set(DEVICESID, "IntesisFANSP", "", dev)
		luup.variable_set(DEVICESID, "IntesisVANEUD", "", dev)
		luup.variable_set(DEVICESID, "IntesisVANELR", "", dev)
		luup.variable_set(DEVICESID, "IntesisERRSTATUS", "", dev)
		luup.variable_set(DEVICESID, "IntesisERRCODE", "", dev)

		luup.variable_set(OPMODE_SID, "ModeTarget", MODE_OFF, dev)
		luup.variable_set(OPMODE_SID, "ModeStatus", MODE_OFF, dev)
		luup.variable_set(OPMODE_SID, "EnergyModeTarget", EMODE_NORMAL, dev)
		luup.variable_set(OPMODE_SID, "EnergyModeStatus", EMODE_NORMAL, dev)
		luup.variable_set(OPMODE_SID, "AutoMode", "1", dev)

		luup.variable_set(FANMODE_SID, "Mode", FANMODE_AUTO, dev)
		luup.variable_set(FANMODE_SID, "FanStatus", "Off", dev)

		-- Setpoint defaults. Note that we don't have sysTemps yet during this call.
		-- luup.variable_set(SETPOINT_SID, "Application", "DualHeatingCooling", dev)
		luup.variable_set(SETPOINT_SID, "SetpointAchieved", "0", dev)
		if luup.attr_get("TemperatureFormat",0) == "C" then
			luup.variable_set(SETPOINT_SID, "CurrentSetpoint", "18", dev)
		else
			luup.variable_set(SETPOINT_SID, "CurrentSetpoint", "64", dev)
		end

		luup.variable_set(HADEVICE_SID, "ModeSetting", "1:;2:;3:;4:", dev)

		luup.variable_set(DEVICESID, "Version", _CONFIGVERSION, dev)
		return
	end

	if rev < 020200 then
		L("Updating configuration for rev 020200")
		luup.variable_set(DEVICESID, "IPAddress", "", dev )
		luup.variable_set(DEVICESID, "TCPPort", "", dev )
	end
	if rev < 020202 then
		-- More trouble than it's worth
		luup.variable_set(HADEVICE_SID, "Commands", nil, dev)
	end

	-- No matter what happens above, if our versions don't match, force that here/now.
	if (rev ~= _CONFIGVERSION) then
		luup.variable_set(DEVICESID, "Version", _CONFIGVERSION, dev)
	end
end

-- Do startup of a child device
local function deviceStart( dev, parentDev )
	D("deviceStart(%1,%2)", dev, parentDev )

	-- Early inits
	devData[dev] = {}
	devData[dev].parentDev = parentDev
	devData[dev].isConnected = false
	devData[dev].sock = nil
	devData[dev].lastRefresh = 0
	devData[dev].lastCommand = ""
	devData[dev].lastSendTime = 0
	devData[dev].lastinfo = 0
	devData[dev].limits = {}

	-- Make sure the device is initialized. It may be new.
	deviceRunOnce( dev, parentDev )

	if isALTUI then
		local rc,rs,jj,ra = luup.call_action("urn:upnp-org:serviceId:altui1", "RegisterPlugin",
			{ newDeviceType=MYTYPE, newScriptFile="J_IntesisWMPDevice1_ALTUI.js", newDeviceDrawFunc="IntesisWMPDevice1_ALTUI.DeviceDraw" },
				dev )
			D("deviceStart() ALTUI's RegisterPlugin action returned resultCode=%1, resultString=%2, job=%3, returnArguments=%4", rc,rs,jj,ra)
	end

	luup.variable_set( DEVICESID, "DisplayStatus", "", dev )

	-- The device IP can change at any time, so always use the last discovery
	-- response. Make an effort here. It's not always easy.
	local ident = luup.variable_get( DEVICESID, "IntesisID", dev ) or ""
	D("deviceStart() last known ident is %1", ident)
	local parts = split( ident, "," )
	local devIP = parts[3] or ""
	if devIP == "" then
		L("Device IP could not be established for %1(%2) ID=%3", dev, luup.devices[dev].description, ident)
		luup.set_failure( 1, dev )
		return false, "Can't establish IP address from ident string"
	end
	D("deviceStart() updating device IP to %1", devIP)
	luup.variable_set( DEVICESID, "IPAddress", devIP, dev )
	luup.attr_set( "ip", "", dev )
	luup.attr_set( "mac", "", dev )

	--[[ Work out the system units, the user's desired display units, and the configuration units.
		 The user's desire overrides the system configuration. This is an exception provided in
		 case the user has a thermostat for which they want to operate in units other than the
		 system configuration. If the target units and the config units don't comport, modify
		 the interface configuration to use the target units and reload Luup.
	--]]
	local sysUnits = luup.attr_get("TemperatureFormat", 0) or "C"
	local forceUnits = luup.variable_get( DEVICESID, "ForceUnits", dev ) or ""
	local cfUnits = luup.variable_get( DEVICESID, "ConfigurationUnits", dev ) or ""
	local targetUnits = sysUnits
	if forceUnits ~= "" then targetUnits = forceUnits end
	D("deviceStart() system units %1, configured units %2, target units %3.", sysUnits, cfUnits, targetUnits)
	if cfUnits ~= targetUnits then
		-- Reset configuration for temperature units configured.
		L("Reconfiguring from %2 to %1, which will require a Luup restart.", targetUnits, cfUnits)
		luup.attr_set( "device_json", "D_IntesisWMPDevice1_" .. targetUnits .. ".json", dev )
		luup.variable_set( DEVICESID, "ConfigurationUnits", targetUnits, dev )
		luup.reload()
	end
	if targetUnits == "F" then
		devData[dev].sysTemps = { unit="F", default=70, minimum=60, maximum=90 }
	else
		devData[dev].sysTemps = { unit="C", default=21, minimum=16, maximum=32 }
	end

	-- A few things we care to keep an eye on.
	luup.variable_watch( "intesisVarChanged", DEVICESID, "IntesisERRSTATUS", dev )
	luup.variable_watch( "intesisVarChanged", DEVICESID, "IntesisERRCODE", dev )
	luup.variable_watch( "intesisVarChanged", SETPOINT_SID, "CurrentSetpoint", dev )
	luup.variable_watch( "intesisVarChanged", TEMPSENS_SID, "CurrentTemperature", dev )

	-- Schedule first tick on this device.
	runStamp[dev] = os.time() - math.random(1, 100000)
	luup.call_delay( "intesisDeviceTick", dev % 10, table.concat( { dev, runStamp[dev], "" }, ":" )) -- must provide 3 dargs

	-- Log in? Later. --

	-- Send some initial requests for data... NB: deadlock when we try these. Let the timer task catch us up.
	-- sendCommand( "ID", dev )
	-- sendCommand( "INFO", dev )

	L("Device %1 started!", dev)
	luup.set_failure( 0, dev )
	return true, "OK", _PLUGIN_NAME
end

local function discoveryByMAC( mac, dev )
	D("discoveryByMAC(%1,%2)", mac, dev)
	gatewayStatus( "Searching for " .. mac, dev )
	local res = getIPforMAC( mac, dev )
	if res == nil then
		gatewayStatus( "Device not found with MAC " .. mac, dev )
		return false
	end
	local first = res[1]
	D("discoveryByMAC() found IP %1 for MAC %2", first.ip, first.mac)
	passGenericDiscovery( first.mac, first.ip, dev )
end

-- Try to ping the device, and then find its MAC address in the ARP table.
local function discoveryByIP( ipaddr, dev )
	D("discoveryByIP(%1,%2)", ipaddr, dev)
	gatewayStatus( "Searching for " .. ipaddr, dev )
	local res = getMACforIP( ipaddr, dev )
	if res == nil then
		-- Last-ditch effort, hard connect to port 3310? We're probably OK if successful.
		D("discoveryByIP() no MAC address found, trying direct connection")
		local sock = socket.tcp()
		sock:settimeout( 5, 'b' )
		sock:settimeout( 5, 'r' )
		local status, err = sock:connect( ipaddr, 3310 )
		if status then
			sock:close()
			L("IP discovery was unable to determine MAC address, but device is connectible. Proceeding with empty MAC.")
			res = { [1] = { mac = "000000000000", ip = ipaddr } }
		else
			D("discoveryByIP() failed to connect to %1, %2", ipaddr, err)
			gatewayStatus( "Device not found at IP " .. ipaddr , dev )
			return false
		end
	end
	local first = res[1]
	D("discoveryByIP() found MAC %1 for IP %2", first.mac, first.ip)
	passGenericDiscovery( first.mac, first.ip, dev )
end

-- Tick for UDP discovery.
function discoveryTick( dargs )
	D("discoveryTick(%1), luup.device=%2", dargs, luup.device)
	local dev, stamp = dargs:match("^(%d+):(%d+):(.*)$") -- ignore rest
	dev = tonumber(dev, 10)
	assert(dev ~= nil)
	assert(luup.devices[dev].device_num_parent == 0)
	stamp = tonumber(stamp, 10)
	if stamp ~= runStamp[dev] then
		L("discoveryTick() got stamp %1 expected %2; must be newer thread running, exiting", stamp, runStamp[dev])
		return
	end

	gatewayStatus( "Discovery running...", dev )

	local udp = devData[dev].discoverySocket
	if udp ~= nil then
		repeat
			udp:settimeout(1)
			local resp, peer, port = udp:receivefrom()
			if resp ~= nil then
				D("discoveryTick() received response from %1:%2", peer, port)
				handleDiscoveryMessage( resp, dev )
			end
		until resp == nil

		local now = os.time()
		local delta = now - devData[dev].discoveryTime
		if delta < 30 then
			luup.call_delay( "intesisDiscoveryTick", 2, dargs )
			return
		end
		D("discoveryTick() elapsed %1, closing", delta)
		udp:close()
		devData[dev].discoverySocket = nil
		devData[dev].discoveryTime = nil
	end
	D("discoveryTick() end of discovery")
	gatewayStatus( "", dev )
end

-- Launch UDP discovery.
local function launchDiscovery( dev )
	D("launchDiscovery(%1)", dev)
	assert(dev ~= nil)
	assert(luup.devices[dev].device_type == MYTYPE, "Discovery much be launched with gateway device")
	assert( not isOpenLuup, "Don't know how to get IP info on openLuup... yet")

	gatewayStatus( "Discovery running...", dev )

	local broadcast = getSystemIP4BCast( dev )

	-- Any of this can fail, and it's OK.
	local udp = socket.udp()
	local port = 3310
	assert(udp:setoption('broadcast', true))
	assert(udp:setoption('dontroute', true))
	assert(udp:setsockname('*', port))
	D("launchDiscovery() sending discovery request to %1:%2", broadcast, port)
	local stat,err = udp:sendto( "DISCOVER\r\n", broadcast, port)
	if stat == nil then
		L("Failed to send broadcast: %1", err)
	end

	devData[dev].discoverySocket = udp
	local now = os.time()
	devData[dev].discoveryTime = now

	runStamp[dev] = now
	luup.call_delay("intesisDiscoveryTick", 1, table.concat( { dev, runStamp[dev], "" }, ":") ) -- 3 dargs
end

-- Handle variable change callback
function varChanged( dev, sid, var, oldVal, newVal )
	D("varChanged(%1,%2,%3,%4,%5) luup.device is %6", dev, sid, var, oldVal, newVal, luup.device)
	-- assert(var ~= nil) -- nil if service or device watch (can happen on openLuup)
	-- assert(luup.device ~= nil) -- fails on openLuup, have discussed with author but no fix forthcoming as of yet.
	updateDeviceStatus( dev )
end

-- Action for SetModeTarget -- change current operating mode
function actionSetModeTarget( dev, newMode )
	D("actionSetModeTarget(%1,%2)", dev, newMode)
	if newMode == nil or type(newMode) ~= "string" then return end
	local xmap = { [MODE_AUTO]="AUTO", [MODE_HEAT]="HEAT", [MODE_COOL]="COOL", [MODE_FAN]="FAN", [MODE_DRY]="DRY" }
	if newMode == MODE_OFF then
		if not sendCommand( "SET,1:ONOFF,OFF", dev ) then
			return false
		end
	elseif xmap[newMode] ~= nil then
		if not inLimit( "MODE", xmap[newMode], dev ) then
			L({level=2,msg="Unsupported MODE %1 (configured device only supports %2)"}, xmap[newMode], devData[dev].limits.MODE.values)
			return false
		end
		if not sendCommand( "SET,1:ONOFF,ON", dev ) then
			return false
		end
		if not sendCommand( "SET,1:MODE," .. xmap[newMode], dev ) then
			return false
		end
	else
		L("Invalid target opreating mode passed in action: %1", newMode)
		return false
	end
	luup.variable_set( OPMODE_SID, "ModeTarget", newMode, dev )
	return true
end

-- Action for SetEnergyModeTarget
function actionSetEnergyModeTarget( dev, newMode )
	D("actionSetEnergyModeTarget(%1,%2)", dev, newMode)
	-- Not implemented for this control, but return benign.
	return true
end

-- Set fan operating mode (ignored)
function actionSetFanMode( dev, newMode )
	D("actionSetFanMode(%1,%2)", dev, newMode)
	return false
end

-- Set fan speed. Empty/nil or 0 sets Auto.
function actionSetCurrentFanSpeed( dev, newSpeed )
	D("actionSetCurrentFanSpeed(%1,%2)", dev, newSpeed)
	if (newSpeed or "0") == "0" then newSpeed = "AUTO" end
	if inLimit( "FANSP", tostring(newSpeed), dev ) then
		return sendCommand( "SET,1:FANSP," .. newSpeed, dev )
	end
	L({level=2,msg="Fan speed %1 out of range"}, newSpeed)
	return false
end

-- Speed up the fan (implies switch out of auto, presumably)
function actionFanSpeedUp( dev )
	D("actionFanSpeedUp(%1)", dev)
	local speed = getVarNumeric( "IntesisFANSP", 0, dev, DEVICESID ) + 1
	return inLimit( "FANSP", speed, dev ) and sendCommand( "SET,1:FANSP," .. speed, dev ) or false
end

-- Speed up the fan (implies switch out of auto, presumably)
function actionFanSpeedDown( dev )
	D("actionFanSpeedDown(%1)", dev)
	local speed = getVarNumeric( "IntesisFANSP", 2, dev, DEVICESID ) - 1
	return inLimit( "FANSP", speed, dev ) and sendCommand( "SET,1:FANSP," .. speed, dev ) or false
end

-- FanSpeed1 service action for 0-100 fan speed (0 is auto for us)
function actionSetFanSpeed( dev, level )
	level = tonumber( level ) or 0
	range = devData[dev].limits.FANSP.range
	scale = 100 / ((range.max or 9) - (range.min or 1) + 1)
	local speed = level > 0 and math.floor( ( level + scale - 1 ) / scale ) or 0
	L("Mapped fan from level %1%% using range %2 scale %3 to speed %4", level, range, scale, speed)
	return actionSetCurrentFanSpeed( dev, speed )
end

-- Action to change (TemperatureSetpoint1) setpoint.
function actionSetCurrentSetpoint( dev, newSP )
	D("actionSetCurrentSetpoint(%1,%2) system units %3", dev, newSP, devData[dev].sysTemps.unit)

	newSP = tonumber(newSP, 10)
	if newSP == nil then return end
	newSP = constrain( newSP, devData[dev].sysTemps.minimum, devData[dev].sysTemps.maximum )

	-- Convert to C if needed
	if devData[dev].sysTemps.unit == "F" then
		newSP = FtoC( newSP )
	end
	D("actionSetCurrentSetpoint() new target setpoint is %1C", newSP)

	luup.variable_set( SETPOINT_SID, "SetpointAchieved", "0", dev )
	if sendCommand("SET,1:SETPTEMP," .. string.format( "%.0f", newSP * 10 ), dev ) then
		return sendCommand( "GET,1:SETPTEMP", dev ) -- An immediate get to make sure display shows device limits
	end
	return false
end

-- Action to change energy mode (not implemented).
function actionSetEnergyModeTarget( dev, newMode )
	-- Store the target, but don't change status, because nothing changes, and signal failure.
	luup.variable_set( OPMODE_SID, "EnergyModeTarget", newMode, dev )
	return false
end

-- Set vane (up/down) position.
function actionSetVaneUD( dev, newPos )
	D("actionSetVaneUD(%1,%2)", dev, newPos)
	if (newPos or "0") == "0" then newPos = "AUTO" end
	if not inLimit( "VANEUD", tostring(newPos), dev ) then
		L({level=2,msg="Vane U-D position %1 is outside accepted range (%2); ignored"}, newPos, devData[dev].limits.VANEUD.values)
		return false
	end
	return sendCommand( "SET,1:VANEUD," .. tostring(newPos), dev )
end

-- Set vane up (relative)
function actionVaneUp( dev )
	D("actionVaneUp(%1)", dev )
	local pos = getVarNumeric( "IntesisVANEUD", 0, dev, DEVICESID ) - 1
	if pos <= 0 and inLimit( "VANEUD", "SWING", dev ) then
		pos = "SWING"
	end
	return inLimit( "VANEUD", pos, dev ) and sendCommand("SET,1:VANEUD," .. pos, dev) or false
end

-- Set vane down (relative)
function actionVaneDown( dev )
	D("actionVaneDown(%1)", dev )
	local pos = getVarNumeric( "IntesisVANEUD", 0, dev, DEVICESID ) + 1
	return inLimit( "VANEUD", pos, dev ) and sendCommand("SET,1:VANEUD," .. pos, dev) or false
end

-- Set vane (left/right) position.
function actionSetVaneLR( dev, newPos )
	D("actionSetVaneLR(%1,%2)", dev, newPos)
	if (newPos or "0") == "0" then newPos = "AUTO" end
	if not inLimit( "VANELR", tostring(newPos), dev ) then
		L({level=2,msg="Vane L-R position %1 is outside accepted range; ignored"}, newPos, devData[dev].limits.VANELR.values)
		return false
	end
	return sendCommand( "SET,1:VANELR," .. tostring(newPos), dev )
end

-- Vane left
function actionVaneLeft( dev )
	D("actionVaneLeft(%1)", dev )
	local pos = getVarNumeric( "IntesisVANELR", 0, dev, DEVICESID ) - 1
	if pos <= 0 and inLimit( "VANELR", "SWING" ) then
		pos = "SWING"
	end
	return inLimit( "VANELR", pos, dev ) and sendCommand( "SET,1:VANELR," .. pos, dev ) or false
end

-- Vane right
function actionVaneRight( dev )
	D("actionVaneDown(%1)", dev )
	local pos = getVarNumeric( "IntesisVANELR", 0, dev, DEVICESID ) + 1
	return inLimit( "VANELR", pos, dev ) and sendCommand( "SET,1:VANELR," .. pos, dev ) or false
end

-- Set the device name
function actionSetName( dev, newName )
	if not sendCommand( "CFG:DEVICENAME," .. string.upper( newName or "" ), dev ) then
		return false
	end
	return sendCommand( "ID", dev )
end

function actionRunDiscovery( dev )
	launchDiscovery( dev )
end

function actionDiscoverMAC( dev, mac )
	local newMAC = (mac or ""):gsub("[%s:-]+", ""):upper()
	if newMAC:match("^[0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F]$") then
		discoveryByMAC( newMAC, dev )
	else
		gatewayStatus( "Invalid MAC address", dev )
		L("Discovery by MAC action failed, invalid MAC address: %1", mac)
	end
end

function actionDiscoverIP( dev, ipaddr )
	local newIP = (ipaddr or ""):gsub(" ", "")
	if newIP:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$") then
		discoveryByIP( newIP, dev )
	else
		gatewayStatus( "Invalid IP address", dev )
		L("Discovery by IP action failed, invalid IP address: %1", ipaddr)
	end
end

function actionSetDebug( dev, enabled )
	D("actionSetDebug(%1,%2)", dev, enabled)
	if enabled == 1 or enabled == "1" or enabled == true or enabled == "true" then
		debugMode = true
		D("actionSetDebug() debug logging enabled")
	end
end

local function plugin_checkVersion(dev)
	assert(dev ~= nil)
	D("checkVersion() branch %1 major %2 minor %3, string %4, openLuup %5", luup.version_branch, luup.version_major, luup.version_minor, luup.version, isOpenLuup)
	if isOpenLuup then return false end -- v2 does not work on openLuup
	if ( luup.version_branch == 1 and luup.version_major >= 7 ) then
		local v = luup.variable_get( MYSID, "UI7Check", dev )
		if v == nil then luup.variable_set( MYSID, "UI7Check", "true", dev ) end
		return true
	end
	return false
end

-- Do one-time initialization for a gateway
local function plugin_runOnce(dev)
	assert(dev ~= nil)
	assert(luup.devices[dev].device_num_parent == 0, "plugin_runOnce should only run on parent device")

	local rev = getVarNumeric("Version", 0, dev, MYSID)
	if rev == 0 then
		-- Initialize for new installation
		D("runOnce() Performing first-time initialization!")
		luup.variable_set(MYSID, "DisplayStatus", "", dev)
		luup.variable_set(MYSID, "PingInterval", DEFAULT_PING, dev)
		luup.variable_set(MYSID, "RefreshInterval", DEFAULT_REFRESH, dev)
		luup.variable_set(MYSID, "RunStartupDiscovery", 1, dev)
		luup.variable_set(MYSID, "DebugMode", 0, dev)
		luup.variable_set(MYSID, "Version", _CONFIGVERSION, dev)
		return true -- tell caller to keep going
	end

	if rev < 020000 then
		--[[ Upgrade to version 2. For v2, the gateway becomes a passive UI stub,
			 and the bulk of the interface is done in child IntesisWMPDevice devices.
			 Since we can't convert a device from one type another, find an existing
			 v2 gateway device (create if needed), and signal delete of this old
			 device. If it has a child that matches this (old) device, we're good,
			 just stop functioning and signal the user that we need to be deleted.
			 This device will remain untouched and non-working.
			 Otherwise, signal a discovery using the parameters of this device. After
			 restart, we should re-enter this loop and find the child.
		--]]
		-- First, locate a v2 gateway. If we can't, create one and reload Luup.
		local gateway = nil
		for k,v in pairs(luup.devices) do
			if v.device_type == MYTYPE then
				local vv = getVarNumeric( "Version", 0, k, MYSID )
				if vv >= 020000 then
					gateway = k
					break
				end
				vv = luup.variable_get( MYSID, "AutoCreated", k ) or ""
				if vv ~= "" then
					-- Found an incompletely-initialized gateway device.
					L("Found gateway %1, but it has not completed initialization. Waiting.", k)
					return false
				end
			end
		end
		if gateway == nil then
			L("No v2 gateway device found. Creating!")
			luup.create_device( MYTYPE, "", "Intesis WMP Gateway", "D_IntesisWMPGateway1.xml",
				"I_IntesisWMPGateway1.xml", "", "",
				false, -- hidden
				false, -- invis
				0, -- parent
				0, -- room
				0, -- plugin
				MYSID .. ",AutoCreated=1", -- statevars
				0, -- pnpid
				"", -- nochildsync
				"", -- aeskey
				true, -- reload
				false -- nodupid
				)
			-- Reload Luup (should have been done by above, just just in case.
			luup.reload()
			return false -- tell caller to exit
		end
		L("Discovered v2 gateway #%1", gateway)

		-- Found a gateway. This is an pre-V2 child. See if it already exists as a child of gateway.
		local oldIdent = luup.variable_get( MYSID, "IntesisID", dev ) or ""
		local pOld = split( oldIdent, "," )
		local children = inventoryChildren( gateway ) -- gateway's children
		for _,k in ipairs( children ) do
			local childIdent = luup.variable_get( DEVICESID, "IntesisID", k ) or ""
			local pChild = split( childIdent, "," )
			if pChild[2] ~= nil and pChild[2] == pOld[2] then
				-- This device has already been replicated to a v2 child.
				L("Found existing child %1 of gateway %2 for %3 at %4", k, gateway, pChild[2], pChild[3])
				luup.attr_set( "name", "DELETE ME " .. pChild[2], dev )
				luup.variable_set( MYSID, "DisplayStatus", "DELETE THIS REDUNDANT DEVICE", dev )
				L("Stopping plugin for this device. Please delete this device.")
				return false
			end
		end

		-- At this point, we have a known v2 gateway, but no v2 child. Launch discovery with our
		-- known parameters against the gateway device.
		luup.variable_set( MYSID, "DisplayStatus", "Upgrading...", dev )
		passGenericDiscovery( pOld[2], pOld[3], gateway, dev )
		return false -- signal caller to not continue.
	end

	if rev < 020203 then
		luup.variable_set(MYSID, "DebugMode", 0, dev)
	end

	-- No matter what happens above, if our versions don't match, force that here/now.
	if (rev ~= _CONFIGVERSION) then
		luup.variable_set(MYSID, "Version", _CONFIGVERSION, dev)
	end
	return true -- indicate to caller we should keep going
end

-- Start-up initialization for plug-in.
function plugin_init(dev)
	D("plugin_init(%1)", dev)
	L("starting version %1 for device %2 gateway", _PLUGIN_VERSION, dev )

	-- Up front inits
	devData[dev] = {}
	math.randomseed( os.time() )

	if getVarNumeric("DebugMode", 0, dev, MYSID) ~= 0 then
		debugMode = true
		D("plugin_init() debug enabled by state variable")
	end

	-- Check for ALTUI and OpenLuup
	for _,v in pairs(luup.devices) do
		if v.device_type == "urn:schemas-upnp-org:device:altui:1" and v.device_num_parent == 0 then
			D("init() detected ALTUI")
			isALTUI = true
		elseif v.device_type == "openLuup" then
			D("init() detected openLuup")
			isOpenLuup = true
		end
	end

	-- Make sure we're in the right environment
	if not plugin_checkVersion(dev) then
		L("This plugin does not run on this firmware!")
		luup.variable_set( MYSID, "Failure", "1", dev )
		luup.set_failure( 1, dev )
		return false, "Unsupported system firmware", _PLUGIN_NAME
	end

	-- See if we need any one-time inits
	if not plugin_runOnce(dev) then
		luup.set_failure( 1, dev )
		return false, "Upgraded, delete old device", _PLUGIN_NAME
	end

	-- Other inits
	runStamp[dev] = os.time()
	gatewayStatus( "", dev )

	-- Start up each of our children
	local children = inventoryChildren( dev )
	if #children == 0 and getVarNumeric( "RunStartupDiscovery", 1, dev, MYSID ) ~= 0 then
		launchDiscovery( dev )
	end
	for _,cn in ipairs( children ) do
		L("Starting device %1 (%2)", cn, luup.devices[cn].description)
		luup.variable_set( DEVICESID, "Failure", 0, cn ) -- IUPG
		local ok, err = pcall( deviceStart, cn, dev )
		if not ok then
			luup.variable_set( DEVICESID, "Failure", 1, cn )
			L("Device %1 (%2) failed to start, %3", cn, luup.devices[cn].description, err)
			gatewayStatus( "Device(s) failed to start!", dev )
		end
	end

	-- Mark successful start (so far)
	L("Running!")
	luup.set_failure( 0, dev )
	return true, "OK", _PLUGIN_NAME
end

function plugin_getVersion()
	return _PLUGIN_VERSION, _PLUGIN_NAME, _CONFIGVERSION
end

local function issKeyVal( k, v, s )
	if s == nil then s = {} end
	s["key"] = tostring(k)
	s["value"] = tostring(v)
	return s
end

local function map( m, v, d )
	if m[v] == nil then return d end
	return m[v]
end

-- A "safer" JSON encode for Lua structures that may contain recursive references.
-- This output is intended for display ONLY, it is not to be used for data transfer.
local stringify
local function alt_json_encode( st, seen )
	seen = seen or {}
	str = "{"
	local comma = false
	for k,v in pairs(st) do
		str = str .. ( comma and "," or "" )
		comma = true
		str = str .. '"' .. k .. '":'
		if type(v) == "table" then
			if seen[v] then str = str .. '"(recursion)"'
			else
				seen[v] = k
				str = str .. alt_json_encode( v, seen )
			end
		else
			str = str .. stringify( v, seen )
		end
	end
	str = str .. "}"
	return str
end

-- Stringify a primitive type
stringify = function( v, seen )
	if v == nil then
		return "(nil)"
	elseif type(v) == "number" or type(v) == "boolean" then
		return tostring(v)
	elseif type(v) == "table" then
		return alt_json_encode( v, seen )
	end
	return string.format( "%q", tostring(v) )
end

local function getDevice( dev, pdev, v ) -- luacheck: ignore 212
	local dkjson = require("dkjson")
	if v == nil then v = luup.devices[dev] end
	local devinfo = {
		  devNum=dev
		, ['type']=v.device_type
		, description=v.description or ""
		, room=v.room_num or 0
		, udn=v.udn or ""
		, id=v.id
		, ['device_json'] = luup.attr_get( "device_json", dev )
		, ['impl_file'] = luup.attr_get( "impl_file", dev )
		, ['device_file'] = luup.attr_get( "device_file", dev )
		, manufacturer = luup.attr_get( "manufacturer", dev ) or ""
		, model = luup.attr_get( "model", dev ) or ""
	}
	local rc,t,httpStatus = luup.inet.wget("http://localhost/port_3480/data_request?id=status&DeviceNum=" .. dev .. "&output_format=json", 15)
	if httpStatus ~= 200 or rc ~= 0 then
		devinfo['_comment'] = string.format( 'State info could not be retrieved, rc=%d, http=%d', rc, httpStatus )
		return devinfo
	end
	local d = dkjson.decode(t)
	local key = "Device_Num_" .. dev
	if d ~= nil and d[key] ~= nil and d[key].states ~= nil then d = d[key].states else d = nil end
	devinfo.states = d or {}
	devinfo.devdata = devData[dev] or {}
	return devinfo
end

function plugin_requestHandler(lul_request, lul_parameters, lul_outputformat)
	D("plugin_requestHandler(%1,%2,%3)", lul_request, lul_parameters, lul_outputformat)
	local action = lul_parameters['action'] or lul_parameters['command'] or ""
	local deviceNum = tonumber( lul_parameters['device'], 10 ) or luup.device
	if action == "debug" then
		local err,msg,job,args = luup.call_action( MYSID, "SetDebug", { debug=1 }, deviceNum )
		return string.format("Device #%s result: %s, %s, %s, %s", tostring(deviceNum), tostring(err), tostring(msg), tostring(job), dump(args))
	end

	if action:sub( 1, 3 ) == "ISS" then
		-- ImperiHome ISS Standard System API, see http://dev.evertygo.com/api/iss#types
		local dkjson = require('dkjson')
		local path = lul_parameters['path'] or action:sub( 4 ) -- Work even if I'home user forgets &path=
		if path == "/system" then
			return dkjson.encode( { id="IntesisWMPGateway-" .. luup.pk_accesspoint, apiversion=1 } ), "application/json"
		elseif path == "/rooms" then
			local roomlist = { { id=0, name="No Room" } }
			for rn,rr in pairs( luup.rooms ) do
				table.insert( roomlist, { id=rn, name=rr } )
			end
			return dkjson.encode( { rooms=roomlist } ), "application/json"
		elseif path == "/devices" then
			local devices = {}
			for lnum,ldev in pairs( luup.devices ) do
				if ldev.device_type == DEVICETYPE then
					local issinfo = {}
					table.insert( issinfo, issKeyVal( "curmode", map( { Off="Off",HeatOn="Heat",CoolOn="Cool",AutoChangeOver="Auto",Dry="Dry",FanOnly="Fan" }, luup.variable_get( OPMODE_SID, "ModeStatus", lnum ), "Off" ) ) )
					table.insert( issinfo, issKeyVal( "curfanmode", map( { Auto="Auto",ContinuousOn="On",PeriodicOn="Periodic" }, luup.variable_get(FANMODE_SID, "Mode", lnum), "Auto" ) ) )
					table.insert( issinfo, issKeyVal( "curtemp", luup.variable_get( TEMPSENS_SID, "CurrentTemperature", lnum ), { unit="°" .. devData[lnum].sysTemps.unit } ) )
					table.insert( issinfo, issKeyVal( "cursetpoint", getVarNumeric( "CurrentSetpoint", devData[lnum].sysTemps.default, lnum, SETPOINT_SID ) ) )
					table.insert( issinfo, issKeyVal( "step", 0.5 ) )
					table.insert( issinfo, issKeyVal( "minVal", devData[lnum].sysTemps.minimum ) )
					table.insert( issinfo, issKeyVal( "maxVal", devData[lnum].sysTemps.maximum ) )
					table.insert( issinfo, issKeyVal( "availablemodes", "Off,Heat,Cool,Auto,Fan,Dry" ) )
					table.insert( issinfo, issKeyVal( "availablefanmodes", "Auto" ) )
					table.insert( issinfo, issKeyVal( "defaultIcon", "https://www.toggledbits.com/intesis/assets/wmp_mode_auto.png" ) )
					local dev = { id=tostring(lnum),
						name=ldev.description or ("#" .. lnum),
						["type"]="DevThermostat",
						params=issinfo }
					if ldev.room_num ~= nil and ldev.room_num ~= 0 then dev.room = tostring(ldev.room_num) end
					table.insert( devices, dev )
				end
			end
			return dkjson.encode( { devices=devices } ), "application/json"
		else
			local dev, act, p = string.match( path, "/devices/([^/]+)/action/([^/]+)/*(.*)$" )
			dev = tonumber( dev, 10 )
			if dev ~= nil and act ~= nil then
				act = string.upper( act )
				D("plugin_requestHandler() handling action path %1, dev %2, action %3, param %4", path, dev, act, p )
				if act == "SETMODE" then
					local newMode = map( { OFF="Off",HEAT="HeatOn",COOL="CoolOn",AUTO="AutoChangeOver",FAN="FanOnly",DRY="Dry" }, string.upper( p or "" ) )
					actionSetModeTarget( dev, newMode )
				elseif act == "SETFANMODE" then
					local newMode = map( { AUTO="Auto", ON="ContinuousOn", PERIODIC="PeriodicOn" }, string.upper( p or "" ) )
					actionSetFanMode( dev, newMode )
				elseif act == "SETSETPOINT" then
					local temp = tonumber( p, 10 )
					if temp ~= nil then
						actionSetCurrentSetpoint( dev, temp )
					end
				else
					D("plugin_requestHandler(): ISS action %1 not handled, ignored", act)
				end
			else
				D("plugin_requestHandler() malformed action request %1", path)
			end
			return "{}", "application/json"
		end
	end

	if action == "status" then
		local dkjson = require("dkjson")
		if dkjson == nil then return "Missing dkjson library", "text/plain" end
		local st = {
			name=_PLUGIN_NAME,
			version=_PLUGIN_VERSION,
			configversion=_CONFIGVERSION,
			author="Patrick H. Rigney (rigpapa)",
			url=_PLUGIN_URL,
			['type']=MYTYPE,
			responder=luup.device,
			timestamp=os.time(),
			system = {
				version=luup.version,
				isOpenLuup=isOpenLuup,
				isALTUI=isALTUI,
				units=luup.attr_get( "TemperatureFormat", 0 ),
			},
			devices={}
		}
		for k,v in pairs( luup.devices ) do
			if v.device_type == MYTYPE then
				local gwinfo = getDevice( k, luup.device, v ) or {}
				local children = inventoryChildren( k )
				gwinfo.children = {}
				for _,cn in ipairs( children ) do
					table.insert( gwinfo.children, getDevice( cn, luup.device ) )
				end
				table.insert( st.devices, gwinfo )
			end
		end
		return alt_json_encode( st ), "application/json"
	end

	return "<html><head><title>" .. _PLUGIN_NAME .. " Request Handler"
		.. "</title></head><body bgcolor='white'>Request format: <tt>http://" .. (luup.attr_get( "ip", 0 ) or "...")
		.. "/port_3480/data_request?id=lr_" .. lul_request
		.. "&action=</tt><p>Actions: status, debug, ISS"
		.. "<p>Imperihome ISS URL: <tt>...&action=ISS&path=</tt><p>Documentation: <a href='"
		.. _PLUGIN_URL .. "' target='_blank'>" .. _PLUGIN_URL .. "</a></body></html>"
		, "text/html"
end
