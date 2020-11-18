-- -----------------------------------------------------------------------------
-- L_IntesisWMPGateway.lua
-- Copyright 2017,2020 Patrick H. Rigney, All Rights Reserved
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
	6) The LIMITS command doesn't seem to support unit IDs, but it seems logical each device
	   could have different limits. For now, the LIMITS response is applied to all devices.

--]]

module("L_IntesisWMPGateway1", package.seeall)

local math = require("math")
local string = require("string")
local socket = require("socket")

local _PLUGIN_NAME = "IntesisWMPGateway"
local _PLUGIN_VERSION = "3.0develop-20323"
local _PLUGIN_URL = "http://www.toggledbits.com/intesis"
local _CONFIGVERSION = 20204

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

local scheduler
local devData = {}
local devicesByMAC = {} -- ??? no longer used?
local pluginDevice
local intPing = DEFAULT_PING
local intRefresh = DEFAULT_REFRESH

local discoveryReload = false

local isConnected = false
local masterSocket = false
local usingProxy = false
local inBuffer = nil
local lastIncoming, lastdtm, lastSendTime, lastCommand
local infocmd = {} -- things to do when idle

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

local function E(msg, ...) L({level=1,msg=msg}, ...) end
local function W(msg, ...) L({level=2,msg=msg}, ...) end
local function T(msg, ...) L(msg, ...) if debug and debug.traceback then luup.log((debug.traceback())) end end

local function A(cond, m, ...)
	if not cond then
		T({level=0,msg=m or "Assertion failed!"}, ...)
		error("assertion failed") -- should be unreachable (after)
	end
end
local function AP( dev ) A(dev and (luup.devices[dev] or {}).device_type == MYTYPE, "Device %1 is not master/parent", dev) end

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


-- Initialize a variable if it does not already exist.
local function initVar( sid, name, dflt, dev )
	A( dev ~= nil and sid ~= nil)
	local currVal = luup.variable_get( sid, name, dev )
	if currVal == nil then
		luup.variable_set( sid, name, tostring(dflt), dev )
		return tostring(dflt)
	end
	return currVal
end

-- Set variable, only if value has changed.
local function setVar( sid, name, val, dev )
	A( dev ~= nil and sid ~= nil)
	val = (val == nil) and "" or tostring(val)
	local s = luup.variable_get( sid, name, dev )
	if s ~= val then
		luup.variable_set( sid, name, val, dev )
	end
	return s
end

-- Delete a state variable. Newer versions of firmware do this by setting nil;
-- older versions require a request.
local function deleteVar( sid, name, dev )
	if luup.variable_get( sid, name, dev ) then
		luup.variable_set( sid, name, "", dev )
		-- For firmware > 1036/3917/3918/3919 http://wiki.micasaverde.com/index.php/Luup_Lua_extensions#function:_variable_set
		luup.variable_set( sid, name, nil, dev )
	end
end

-- Get variable with possible default
local function getVar( name, dflt, dev, sid )
	A( name ~= nil and dev ~= nil and sid ~= nil )
	local s,t = luup.variable_get( sid, name, dev )
--	if debugMode and s == nil then T({level=2,msg="getVar() of undefined state variable %1/%2 on #%3"}, sid, name, dev) end
	if s == nil or s == "" then return dflt,0 end
	return s,t
end

-- Get numeric variable, or return default value if not set or blank
local function getVarNumeric( name, dflt, dev, sid )
	assert ( name ~= nil and dev ~= nil )
	A( dflt==nil or type(dflt)=="number", "Supplied default is not numeric or nil" )
	local s = getVar( name, dflt, dev, sid )
	return type(s)=="number" and s or tonumber(s) or dflt
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

TaskManager = function( luupCallbackName )
	local callback = luupCallbackName
	local runStamp = 1
	local tickTasks = { __sched={ id="__sched" } }
	local Task = { id=false, when=0 }
	local nextident = 0

	-- Schedule a timer tick for a future (absolute) time. If the time is sooner than
	-- any currently scheduled time, the task tick is advanced; otherwise, it is
	-- ignored (as the existing task will come sooner), unless repl=true, in which
	-- case the existing task will be deferred until the provided time.
	local function scheduleTick( tkey, timeTick, flags )
		local tinfo = tickTasks[tkey]
		assert( tinfo, "Task not found" )
		assert( type(timeTick) == "number" and timeTick > 0, "Invalid schedule time" )
		flags = flags or {}
		if ( tinfo.when or 0 ) == 0 or timeTick < tinfo.when or flags.replace then
			-- Not scheduled, requested sooner than currently scheduled, or forced replacement
			tinfo.when = timeTick
		end
		-- If new tick is earlier than next plugin tick, reschedule Luup timer
		if tickTasks.__sched.when == 0 then return end -- in queue processing
		if tickTasks.__sched.when == nil or timeTick < tickTasks.__sched.when then
			tickTasks.__sched.when = timeTick
			local delay = timeTick - os.time()
			if delay < 0 then delay = 0 end
			runStamp = runStamp + 1
			luup.call_delay( callback, delay, runStamp )
		end
	end

	-- Remove tasks from queue. Should only be called from Task::close()
	local function removeTask( tkey )
		tickTasks[ tkey ] = nil
	end

	-- Plugin timer tick. Using the tickTasks table, we keep track of
	-- tasks that need to be run and when, and try to stay on schedule. This
	-- keeps us light on resources: typically one system timer only for any
	-- number of devices.
	local function runReadyTasks( luupCallbackArg )
		local stamp = tonumber(luupCallbackArg)
		if stamp ~= runStamp then
			-- runStamp changed, different from stamp on this call, just exit.
			return
		end

		local now = os.time()
		local nextTick = nil
		tickTasks.__sched.when = 0 -- marker (run in progress)

		-- Since the tasks can manipulate the tickTasks table (via calls to
		-- scheduleTick()), the iterator is likely to be disrupted, so make a
		-- separate list of tasks that need service (to-do list).
		local todo = {}
		for t,v in pairs(tickTasks) do
			if t ~= "__sched" and ( v.when or 0 ) ~= 0 and v.when <= now then
				D("Task:runReadyTasks() ready %1 %2", v.id, v.when)
				table.insert( todo, v )
			end
		end

		-- Run the to-do list tasks.
		table.sort( todo, function( a, b ) return a.when < b.when end )
		for _,v in ipairs(todo) do
			D("Task:runReadyTasks() running %1", v.id)
			v:run()
		end

		-- Things change while we work. Take another pass to find next task.
		for t,v in pairs(tickTasks) do
			D("Task:runReadyTasks() waiting %1 %2", v.id, v.when)
			if t ~= "__sched" and ( v.when or 0 ) ~= 0 then
				if nextTick == nil or v.when < nextTick then
					nextTick = v.when
				end
			end
		end

		-- Reschedule scheduler if scheduled tasks pending
		if nextTick ~= nil then
			now = os.time() -- Get the actual time now; above tasks can take a while.
			local delay = nextTick - now
			if delay < 0 then delay = 0 end
			tickTasks.__sched.when = now + delay -- that may not be nextTick
			D("Task:runReadyTasks() next in %1", delay)
			luup.call_delay( callback, delay, luupCallbackArg )
		else
			tickTasks.__sched.when = nil -- remove when to signal no timer running
		end
	end

	function Task:schedule( when, flags, args )
		assert(self.id, "Can't reschedule() a closed task")
		if args then self.args = args end
		scheduleTick( self.id, when, flags )
		return self
	end

	function Task:delay( delay, flags, args )
		assert(self.id, "Can't delay() a closed task")
		if args then self.args = args end
		scheduleTick( self.id, os.time()+delay, flags )
		return self
	end

	function Task:suspend()
		self.when = 0
		return self
	end

	function Task:suspended() return self.when == 0 end

	function Task:run()
		assert(self.id, "Can't run() a closed task")
		self.when = 0
		local success, err = pcall( self.func, self, unpack( self.args or {} ) )
		if not success then L({level=1, msg="Task:run() task %1 failed: %2"}, self, err) end
		return self
	end

	function Task:close()
		removeTask( self.id )
		self.id = nil
		self.when = nil
		self.args = nil
		self.func = nil
		setmetatable(self,nil)
		return self
	end

	function Task:new( id, owner, tickFunction, args, desc )
		assert( id == nil or tickTasks[tostring(id)] == nil,
			"Task already exists with id "..tostring(id)..": "..tostring(tickTasks[tostring(id)]) )
		assert( type(owner) == "number" )
		assert( type(tickFunction) == "function" )

		local obj = { when=0, owner=owner, func=tickFunction, name=desc or tostring(owner), args=args }
		obj.id = tostring( id or obj )
		setmetatable(obj, self)
		self.__index = self
		self.__tostring = function(e) return string.format("Task(%s)", e.id) end

		tickTasks[ obj.id ] = obj
		return obj
	end

	local function getOwnerTasks( owner )
		local res = {}
		for k,v in pairs( tickTasks ) do
			if owner == nil or v.owner == owner then
				table.insert( res, k )
			end
		end
		return res
	end

	local function getTask( id )
		return tickTasks[tostring(id)]
	end

	-- Convenience function to create a delayed call to the given func in its own task
	local function delay( func, delaySecs, args )
		nextident = nextident + 1
		local t = Task:new( "_delay"..nextident, pluginDevice, func, args )
		t:delay( math.max(0, delaySecs) )
		return t
	end

	return {
		runReadyTasks = runReadyTasks,
		getOwnerTasks = getOwnerTasks,
		getTask = getTask,
		delay = delay,
		Task = Task,
		_tt = tickTasks
	}
end

-- Tick handler for scheduler (TaskManager)
-- @export
function plugin_tick( stamp )
	D("plugin_tick(%1)", stamp)
	scheduler.runReadyTasks( stamp )
end

local function pluginReload()
	W( 'Requesting luup reload...' )
	luup.reload()
end

local function deferReload( delay, dev )
	local t = scheduler.getTask( 'reload' )
	if not t then
		t = scheduler.Task:new( 'reload', dev, pluginReload, {} )
	end
	t:delay( delay, { replace=true } )
end

-- See if value is within limits (default OK)
local function inLimit( lim, val, dev )
	A(dev and luup.devices[dev].device_type == DEVICETYPE)
	if type(val) == "number" and devData[dev].limits[lim].range then
		-- Check range
		if devData[dev].limits[lim].range.min and val < devData[dev].limits[lim].range.min then
			return false
		end
		if devData[dev].limits[lim].range.max and val > devData[dev].limits[lim].range.max then
			return false
		end
		return true
	end
	-- Check enumeration
	if (devData[dev].limits or {})[lim] then
		val = tostring(val)
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
	local broadcast = getVar( "DiscoveryBroadcast", "", dev, MYSID )
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
	A(not isOpenLuup, "We don't know how to do this on openLuup, yet.")
	os.execute("/bin/ping -4 -q -c 3 " .. ipaddr)
	return scanARP( dev, nil, ipaddr )
end

-- Set gateway status display. Also echos message to log.
local function gatewayStatus( msg, dev )
	AP(dev)
	setVar( MYSID, "DisplayStatus", msg or "", dev )
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

local function iterateChildren( parentDev )
	local children = inventoryChildren( parentDev )
	return function()
		local n = table.remove( children, 1 )
		return n, luup.devices[n]
	end
end

-- Close socket. This intended to be called using pcall(), so errors do not interrupt
-- the operation of the plugin. What errors? Anything. Make the effort to close no matter what.
local function closeSocket( dev )
	D("closeSocket(%1)", dev)
	-- Deliberate sequence of events here!
	gatewayStatus("Disconnected!", dev)
	W("Disconnected from gateway!")
	local t = scheduler.getTask( 'receiver' )
	if t then t:close() end
	isConnected = false
	if masterSocket then
		local x = masterSocket
		masterSocket = nil
		x:close()
	end
end

local deviceReceiveTask -- forward decl

local function configureSocket( sock, dev )
	-- Keep timeout shorts so problems don't cause watchdog restarts.
	sock:settimeout( 1, "b" )
	sock:settimeout( 1, "r" )
	masterSocket = sock
	isConnected = true
	inBuffer = nil
	infocmd = { "INFO", "LIMITS:*" }
	lastdtm = 0
	nextRefreshUnit = 0
	lastSendTime = os.time()
	lastIncoming = os.time()
	lastCommand = ""
	intPing = getVarNumeric( "PingInterval", usingProxy and 90 or DEFAULT_PING, dev, DEVICESID )
	if intPing > 100 then intPing = 100 end -- gateway disconnects after two minutes, so limit
	intRefresh = getVarNumeric( "RefreshInterval", usingProxy and 300 or DEFAULT_REFRESH, dev, DEVICESID )
	local t = scheduler.getTask( 'receiver' ) or
		scheduler.Task:new( 'receiver', dev, deviceReceiveTask, { dev } )
	t:delay( 1 )
end

local function _conn( dev, ip, port )
	D("_conn(%1,%2,%3)", dev, ip, port)
	usingProxy = false
	local sock = socket.tcp()
	if not sock then
		return false, "Can't get socket for connection"
	end
	-- Try SockProxy first
	local tryProxy = getVarNumeric( "UseProxy", 1, pluginDevice, MYSID ) ~= 0
	if tryProxy then
		sock:settimeout( 15 )
		local st,se = sock:connect( "127.0.0.1", 2504 )
		if st then
			local ans,ae = sock:receive("*l")
			if ans and ans:match("^OK TOGGLEDBITS%-SOCKPROXY") then
				sock:send(string.format("CONN %s:%d NTFY=%d/%s/HandleReceive RTIM=%d PACE=1\n",
					ip, port, dev, MYSID, 600*1000 ))
				ans,ae = sock:receive("*l")
				if ans and ans:match("^OK CONN") then
					D("_conn() connected using proxy")
					usingProxy = true
					return true, sock
				end
			end
			D("_conn() proxy negotiation failed: %1,%2", ans, ae)
			sock:shutdown("both")
		else
			D("_conn() proxy connection failed: %1", se)
		end
		-- No good. Close socket, make a new one.
		sock:close()
		sock = socket.tcp()
	end
	sock:settimeout( 15 )
	local r, e = sock:connect( ip, port )
	if r then
		D("_conn() direct connection", ip, port)
		if tryProxy then
			L({level=2,msg="%1 (#%2) connected without SockProxy; may be down or not installed. See https://github.com/toggledbits/sockproxyd"},
				(luup.devices[dev] or {}).description, dev)
		end
		return true, sock
	end
	sock:close()
	return false, string.format("Connection to %s:%s failed: %s", ip, port, tostring(e))
end

-- Open TCP connection to IntesisBox device
local function deviceConnectTCP( dev )
	D("deviceConnectTCP(%1)", dev)
	assert( dev ~= nil )

	if isConnected and masterSocket then return true end

	local ip = getVar( "IPAddress", "", dev, MYSID )
	local port = getVarNumeric( "TCPPort", 3310, dev, MYSID )
	D("deviceConnectTCP() connecting to %1:%2...", ip, port )
	local status,sock = _conn( dev, ip, port )
	if status then
		configureSocket( sock, dev )
		L("%1 (#%2) connected at %3:%4", luup.devices[dev].description, dev, ip, port)
		gatewayStatus( "Connected", dev )
		return true
	else
		L("Can't open %1 (%2) at %3:%4, %5", dev, luup.devices[dev].description, ip, port, sock)
		isConnected = false
		usingProxy = false

		-- See if IP address has changed
		D("deviceConnectTCP() see if IP address changed")
		local newIPs = getIPforMAC( luup.devices[dev].id, dev )
		D("deviceConnectTCP() newIPs=%1", newIPs)
		for _,newIP in ipairs( newIPs or {} ) do
			if newIP.ip ~= ip then -- don't try what already failed
				D("deviceConnectTCP() attempting connect to %1:%2", newIP.ip, port)
				status, sock = _conn( dev, newIP.ip, port )
				if status then
					-- Good connect! Store new address.
					L("IP address for %1 (%2) has changed, was %3, now %4", dev, luup.devices[dev].description, ip, newIP.ip)
					setVar( MYSID, "IPAddress", newIP.ip, dev )
					configureSocket( sock, dev )
					gatewayStatus( "Connected (new IP)", dev )
					return true
				end
				D("deviceConnectTCP() failed on %1, %2", newIP.ip, sock)
				sock:close()
			end
		end
		-- None of these IPs worked, or, one did... how do we know...
		D("deviceConnectTCP() didn't find device MAC %1 at any IP", luup.devices[dev].id )
	end
	W("Can't connect to gateway!")
	gatewayStatus( "Not connected!", dev )
	return false
end

-- Send a command
local function sendCommand( cmdString, dev )
	D("sendCommand(%1,%2)", cmdString, dev)
	assert(dev ~= nil)
	if type(cmdString) == "table" then cmdString = table.concat( cmdString ) end

	-- Store the last command for reference
	local cmd = cmdString .. INTESIS_EOL

	-- See if our socket is open. If not, open it.
	if not isConnected then
		if not deviceConnectTCP( dev ) then
			return false
		end
	end

	masterSocket:settimeout( 2, "b" )
	masterSocket:settimeout( 2, "r" )
	local nb, err = masterSocket:send( cmd )
	if nb ~= nil then
		D("sendCommand() send succeeded, %1 bytes sent", nb)
		lastCommand = cmdString
		lastSendTime = os.time()
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

-- Handle an ID response, no unit #. It's a gateway message.
-- Ex. ID:IS-IR-WMP-1,001122334455,192.168.0.177,ASCII,v1.0.5,-51,TEST,N
local function handleID( unit, segs, pdev, target )
	D("handleID(%1,%2,%3,%4)", unit, segs, pdev, target)
	AP( pdev )
	local args
	setVar( MYSID, "IntesisID", segs[2], pdev ) -- aka MAC
	args = split( segs[2], "," )
	setVar( MYSID, "Name", args[7] or "", pdev )
	setVar( MYSID, "SignalDB", args[6] or "", pdev )
	luup.attr_set( "manufacturer", "Intesis", pdev )
	luup.attr_set( "model", args[1] or "", pdev )
end

-- Handle an INFO response (nothing to do)
local function handleINFO( unit, segs, pdev, target )
	D("handleINFO(%1,%2,%3,%4)", unit, segs, pdev, target)
	AP( pdev )
end

-- Handle CHN response
-- Ex: CHN,1:MODE,COOL
local function handleCHN( unit, segs, pdev, target )
	D("handleCHN(%1,%2,%3,%4)", unit, segs, pdev, target)
	AP( pdev )
	local args
	args = split( string.upper( segs[2] ), "," )
	if args[1] == "ONOFF" then
		-- The on/off state is separate from mode in Intesis, but part of mode in the
		--   HVAC_UserOperatingMode1 service. See comments below on how we handle that.
		setVar( DEVICESID, "IntesisONOFF", args[2], target )
		if args[2] == "OFF" then
			-- Note we don't touch LastMode here!
			setVar( OPMODE_SID, "ModeTarget", MODE_OFF, target )
			setVar( OPMODE_SID, "ModeStatus", MODE_OFF, target )
			setVar( FANMODE_SID, "FanStatus", "Off", target )
		elseif args[2] == "ON" then
			-- When turning on, restore state of LastMode.
			local last = getVar( "LastMode", MODE_AUTO, target, DEVICESID )
			setVar( OPMODE_SID, "ModeTarget", last, target )
			setVar( OPMODE_SID, "ModeStatus", last, target )
			if last == MODE_FAN then
				setVar( FANMODE_SID, "FanStatus", "On", target )
			else
				setVar( FANMODE_SID, "FanStatus", "Unknown", target )
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
		setVar( DEVICESID, "IntesisMODE", args[2], target )

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
		setVar( DEVICESID, "LastMode", newMode, target )
		local currMode = getVar( "ModeStatus", MODE_OFF, target, OPMODE_SID )
		if currMode ~= MODE_OFF then
			setVar( OPMODE_SID, "ModeTarget", newMode, target )
			setVar( OPMODE_SID, "ModeStatus", newMode, target )
			if newMode == MODE_FAN or newMode == MODE_DRY then
				-- With Intesis in FAN and DRY mode, we know fan is running (speed is a separate matter)
				setVar( FANMODE_SID, "Mode", FANMODE_ON, target )
				setVar( FANMODE_SID, "FanStatus", "On", target )
			else
				-- In any other mode, fan is effectively auto and we don't know its state.
				setVar( FANMODE_SID, "Mode", FANMODE_AUTO, target )
				setVar( FANMODE_SID, "FanStatus", "Unknown", target )
			end
		end
	elseif args[1] == "SETPTEMP" then
		-- Store the setpoint temperature. Leave unchanged if out of range (usually thermostat in
		-- a mode where setpoint doesn't matter, e.g. FAN--at least once we've seen 32767 come back
		-- in that case).
		local ptemp = tonumber(args[2])
		if ptemp and ptemp >= 0 and ptemp < 1200 then
			ptemp = ptemp / 10
			if devData[target].sysTemps.unit == "F" then
				ptemp = CtoF( ptemp )
			end
			D("handleCHN() received SETPTEMP %1, setpoint now %2", args[2], ptemp)
			setVar( SETPOINT_SID, "CurrentSetpoint", string.format( "%.0f", ptemp ), target )
		else
			D("handleCHN() received SETPTEMP %1, ignored", args[2], ptemp)
		end
	elseif args[1] == "AMBTEMP" then
		-- Store the current ambient temperature
		local ptemp = tonumber( args[2], 10 ) / 10
		if devData[target].sysTemps.unit == "F" then
			ptemp = CtoF( ptemp )
		end
		local dtemp = string.format( "%2.1f", ptemp )
		D("handleCHN() received AMBTEMP %1, current temp %2", args[2], dtemp)
		setVar( TEMPSENS_SID, "CurrentTemperature", dtemp, target )
		setVar( DEVICESID, "DisplayTemperature", dtemp, target )
	elseif args[1] == "FANSP" then
		-- Fan speed also doesn't have a 1-1 mapping with the service. Just track it.
		setVar( DEVICESID, "IntesisFANSP", args[2] or "", target )
	elseif args[1] == "VANEUD" then
		-- There's no analog in the service for vane position, so just store the data
		-- in case others want to use it.
		setVar( DEVICESID, "IntesisVANEUD", args[2] or "", target )
	elseif args[1] == "VANELR" then
		-- There's no analog in the service for vane position, so just store the data
		-- in case others want to use it.
		setVar( DEVICESID, "IntesisVANELR", args[2] or "", target )
	elseif args[1] == "ERRSTATUS" then
		-- Should be OK or ERR. Track.
		setVar( DEVICESID, "IntesisERRSTATUS", args[2] or "", target )
	elseif args[1] == "ERRCODE" then
		-- Values are dependent on the connected device. Track.
		l = getVar( "IntesisERRCODE", "", target, DEVICESID )
		l = split( l or "" ) or {}
		table.insert( l, tostring(args[2]):gsub(",","%2C") )
		while #l > 10 do table.remove( l, 1 ) end
		setVar( DEVICESID, "IntesisERRCODE", table.concat( l, "," ), target )
	else
		D("handleCHN() unhandled function %1 in %2", args[1], segs)
	end
end

-- Handle LIMITS
--[[ PHR 2020-11-18: As of this writing, we don't know the real semantics of LIMIT
     when multiple units are controlled by the gateway. It seems logical that it
     should be on a per-unit basis, because different air handling units can surely
     have different limits/capabilities, but neither the LIMITS command nor response
     has a unit number. So, all we can do is apply the given limits everywhere,
     honoring to the exception for SETPTEMP where each Luup device can display
     different temperature units (unlikely, but possible). Maybe Intesis will
     resolve the lingering question/issue here at some point.
--]]
function handleLIMITS( unit, segs, pdev, target )
	D("handleLIMITS(%1,%2,%3,%4)", unit, segs, pdev, target)
	AP( pdev )
	if #segs >= 2 then
		local _,_,obj,lim = string.find( segs[2], "([^,]+),%[(.*)%]" )
		if obj then
			devData[pdev].limits[obj] = { values=split( lim ) or {} }
			setVar( MYSID, "Limits" .. obj, lim, pdev )
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
			-- Apply to all children as well
			for cn in iterateChildren( pdev ) do
				devData[cn].limits[obj] = devData[pdev].limits[obj]
				setVar( DEVICESID, "Limits" .. obj, lim, cn )
			end
		end
		if obj == "MODE" then
			-- For mode, we may need to enable or disable certain UI buttons
			local mm = { COOL=0, HEAT=0, AUTO=0, FAN=0, DRY=0 }
			for _,v in ipairs( devData[pdev].limits[obj].values ) do
				setVar( MYSID, "Mode"..v, 1, pdev )
				-- Apply to all children
				for cn in iterateChildren( pdev ) do
					setVar( DEVICESID, "Mode"..v, 1, cn )
				end
				mm[v] = nil
			end
			for k in pairs(mm) do
				setVar( MYSID, "Mode"..k, 0, pdev )
				for cn in iterateChildren( pdev ) do
					setVar( DEVICESID, "Mode"..k, 0, cn )
				end
			end
		elseif obj == "SETPTEMP" then
			local r = devData[pdev].limits[obj].range or {}
			-- Limits are always degC x 10
			if r.min then
				devData[pdev].sysTemps.minimum =
					devData[pdev].sysTemps.unit == "F" and CtoF(r.min / 10) or (r.min / 10)
			end
			if r.max then
				devData[pdev].sysTemps.maximum =
					devData[pdev].sysTemps.unit == "F" and CtoF(r.max / 10) or (r.max / 10)
			end
			-- Also apply to children
			for cn in iterateChildren( pdev ) do
				if r.min then
					devData[cn].sysTemps.minimum =
						devData[cn].sysTemps.unit == "F" and CtoF(r.min / 10) or (r.min / 10)
				end
				if r.max then
					devData[cn].sysTemps.maximum =
						devData[cn].sysTemps.unit == "F" and CtoF(r.max / 10) or (r.max / 10)
				end
			end
		end
	end
end

-- Handle ACK
function handleACK( unit, segs, pdev, target )
	D("handleACK(%1,%2,%3,%4)", unit, segs, pdev, target)
	AP( pdev )
	-- We've been heard; do nothing
	D("handMessage() ACK received, last command was %1", lastCommand)
end

-- Handle ERR
function handleERR( unit, segs, pdev, target )
	D("handleERR(%1,%2,%3,%4)", unit, segs, pdev, target)
	AP( pdev )
	W("WMP device returned ERR after %1: %2", lastCommand, segs)
end

-- Handle CLOSE, the server signalling that it is closing the connection.
function handleCLOSE( unit, segs, pdev, target )
	D("handleCLOSE(%1,%2,%3,%4)", unit, segs, pdev, target)
	AP( pdev )
	W("IntesisBox is closing connection")
	-- luup.set_failure( 1, pdev ) -- no active failure, let future comm error signal it
	-- isConnected = false
end

-- Handle PONG response
function handlePONG( unit, segs, pdev, target )
	D("handlePONG(%1,%2,%3,%4)", unit, segs, pdev, target)
	AP( pdev )
	-- response to PING, returns signal strength
	setVar( MYSID, "SignalDB", segs[2] or "", pdev )
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
	local segs
	segs = split( msg, ":" )
	if #segs < 1 then
		L("malformed response from unit, insufficient segments: %1", msg)
		return
	end

	-- The first segment contains the response type, for which many have a unit number (comma-separated from type)
	local resp = split( segs[1], "," ) or { "<UNDEFINED>" }
	local respType = string.upper( resp[1] or "" )
	local respUnit, devTarget
	if #resp > 1 then
		respUnit = tonumber( resp[2] )
		devTarget = (devData[pdev].units or {})[resp[2]] or false
		if not devTarget then
			L({level=2,msg="%1 (#%2) message for unit %3 ignored, no such unit. msg=%4"},
				luup.devices[pdev].description, pdev, resp[2], msg)
			return
		end
	else
		respUnit = nil
		devTarget = pdev
	end
	D("handleMessage() header %1 unit %2 target %3", segs[1], respUnit, devTarget)

	-- Dispatch the response
	local f = ResponseDispatch[ respType ]
	if f then
		f( respUnit, segs, pdev, devTarget )
	else
		D("Response from server could not be dispatched (type %1 in %2)", respType, msg)
	end
end

-- Receive data on the socket. Handle complete responses. Returns
-- true if any data was received, false otherwise.
local function deviceReceive( dev )
	D("deviceReceive(%1)", dev)
	if not isConnected then
		D("deviceReceive() socket is not connected")
		return false
	end

	-- We'd love for LuaSocket to have an option to just return as much data as it has...
	-- Loop for up to 255 bytes. That's an arbitrary choice to make sure we return
	-- to our caller if the peer is transmitting continuously.
	masterSocket:settimeout( 0, "b" )
	masterSocket:settimeout( 0, "r" )
	local count = 0
	while count < 255 do
		local b, err = masterSocket:receive(1)
		if b == nil then
			-- Timeouts are not a problem, but we stop looping when we get one.
			if err ~= "timeout" then
				D("deviceReceive() error %1", err)
				closeSocket( dev )
			end
			break
		end

		local ch = string.byte(b)
		lastIncoming = os.time() -- or socket milliseconds? Not sure we need that much accuracy...
		count = count + 1

		if ch == 13 or ch == 10 then
			-- End of line
			if inBuffer ~= nil then
				handleMessage( inBuffer, dev )
				inBuffer = nil
			end
		else
			-- Capture the character
			if inBuffer == nil then
				inBuffer = b
			else
				inBuffer = inBuffer .. b
			end
		end
	end
	return count > 0
end

local lastDelay = 1

deviceReceiveTask = function( task, dev )
	if deviceReceive( dev ) then
		-- Data received; reshorten turnaround
		lastDelay = 1
	else
		-- No data received; slowly extend delay
		lastDelay = math.min( lastDelay*2, 16 )
	end
	task:delay( usingProxy and 120 or lastDelay )
end

-- Update the display status. We don't really bother with this at the moment because the WMP
-- protocol doesn't tell us the running status of the unit (see comments at top of this file).
local function updateDeviceStatus( dev )
	local msg = "&nbsp;"
	if not isConnected then
		setVar( DEVICESID, "DisplayTemperature", "??.?", dev )
		msg = "Comm Fail"
	else
		local errst = getVar( "IntesisERRSTATUS", "OK", dev, DEVICESID )
		if errst ~= "OK" then
			local errc = getVar( "IntesisERRCODE", "", dev, DEVICESID )
			msg = string.format( "%s %s", errst, errc )
		end
	end
	setVar( DEVICESID, "DisplayStatus", msg, dev )
end

local function updateStatus( pdev )
	D("updateStatus(%1)", pdev)
	AP(pdev)

	for ch in iterateChildren( pdev ) do
		updateDeviceStatus( ch )
	end
	if isConnected then
		setVar( MYSID, "Failure", 0, pdev )
		gatewayStatus( "Connected " .. ( usingProxy and "via proxy" or "" ), pdev )
	else
		setVar( MYSID, "Failure", 1, pdev )
		gatewayStatus( "Not connected!", pdev )
	end
end

-- Handle a discovery response.
local function handleDiscoveryMessage( msg, parentDev )
	D("handleDiscoveryMessage(%1,%2)", msg, parentDev)
	AP(parentDev)

	-- Message format expected:
	-- DISCOVER:IS-IR-WMP-1,001DC9A183E1,192.168.0.177,ASCII,v1.0.5,-51,TEST,N,1
	local parts = split( msg, "," )
	parts[1] = parts[1] or ""
	local model = parts[1]:sub(10)
	if parts[1]:match( "^DISCOVER[\r\n]" ) then
		D("handleDiscoveryMessage() ignoring echo of discovery request")
		return false
	elseif string.sub( parts[1], 1, 9) ~= "DISCOVER:" then
		D("handleDiscoveryMessage() can't handle %1 message type", parts[1])
		return false
	elseif not string.match( model, "-WMP-" ) or parts[4] ~= "ASCII" then
		L("Discovery response from %1 (%2) model %3 not handled by this plugin. %4",
			parts[2], parts[3], model, msg)
		gatewayStatus( model .. " is not compatible", parentDev )
		return false

	end
	L("Received discovery response from %1 at %2", parts[2], parts[3])
	gatewayStatus( string.format("Response from %s at %s", tostring(parts[2]), tostring(parts[3])), parentDev )

	-- See if the device is already listed
	D("handleDiscoveryMessage() searching for existing device matching %1", parts[2])
	for k,v in pairs( luup.devices ) do
		if v.device_type == MYTYPE and v.device_num_parent == 0 then
			local s = getVar( "IntesisID", "", k, MYSID )
			s = split( s, "," )
			D("handleDiscoveryMessage() checking #%1 (%2) identified by %3", k, v.description, s[2])
			if #s >= 2 and parts[2] == s[2] then
				L("Discovery: response from %1 (%2), already known device #%3", parts[2], parts[3], k)
				gatewayStatus( string.format("%s at %s is already known", parts[2], parts[3]), parentDev )
				return false
			end
		end
	end

	if getVar( "IntesisID", "", parentDev, MYSID ) == "" then
		D("handleDiscoveryMessage() assigning discovered %1 to current master %2",
			parts[2], parentDev)
		L("Did not find device for gateway %1, configuring...", parts[2], parentDev)
		setVar( MYSID, "IntesisID", msg:sub(10), parentDev )
		setVar( MYSID, "IPAddress", parts[3], parentDev )
		return true
	end

	L("Did not find device for gateway %1, creating new gateway device...", parts[2], parentDev)
	-- Need to create a child device, which can only be done by re-creating all child devices.
	gatewayStatus( string.format("Adding %s at %s...", tostring(parts[2]), tostring(parts[3])), parentDev )

	local vv = {
		MYSID .. ",IntesisID=" .. msg:sub(10),
		MYSID .. ",IPAddress=" .. parts[3]
	}
	local ra,rb,rc,rd = luup.call_action(
		"urn:micasaverde-com:serviceId:HomeAutomationGateway1",
		"CreateDevice",
		{
			Description="IntesisBox "..parts[2],
			deviceType=MYTYPE,
			UpnpDevFilename="D_IntesisWMPGateway1.xml",
			UpnpImplFilename="I_IntesisWMPGateway1.xml",
			RoomNum=luup.attr_get( "room_num", parentDev ) or 0,
			StateVariables=table.concat( vv, "\n" )
		},
		0
	)
	local newdev = tonumber( rd.DeviceNum )
	D("handleDiscoveryMessage() new master is %1", newdev)
	if newdev then
		return true
	end

	gatewayStatus( "Failed to create new device", parentDev )
	W("Failed to create new master device for %1: %2,%3,%4,%5", parts[2],
		ra, rb, rc, rd)
	return false
end

-- Fake a discovery message with the MAC and IP passed.
local function passGenericDiscovery( mac, ip, gateway, dev )
	D("passGenericDiscovery(%1,%2,%3,%4)", mac, ip, gateway, dev)
	assert(gateway ~= nil)
	assert(luup.devices[gateway].device_type == MYTYPE, "gateway arg not gateway device")
	return handleDiscoveryMessage(
		string.format("DISCOVER:UNKNOWN-WMP-1,%s,%s,ASCII,v0.0.0,-99,IntesisDevice,N,1", mac, ip),
		gateway
	)
end

function masterTick( task, dev )
	D("masterTick(%1,%2)", task, dev)
	AP(dev)
	local now = os.time()

	if not isConnected then
		D("masterTick() peer is not connected, trying to reconnect...")
		if not sendCommand("ID", dev) then
			D("masterTick() can't connect peer, waiting...")
			task:delay( 60 )
		end
	end
	updateStatus( dev )

	-- Now connected?
	if isConnected then
		-- If it's been more than two refresh intervals or three pings since we
		-- received some data, we may be in trouble...
		local tm = lastIncoming + math.min( 2 * intRefresh, 3 * intPing )
		if now >= tm then
			L("Gateway receive timeout; marking disconnected!")
			pcall( closeSocket, dev )
			updateStatus( dev )
			task:delay( 1 ) -- reschedule to try to re-open quickly
		else
			task:schedule( tm )
		end

		-- See if we're due for any child refreshes
		for cn in iterateChildren( dev ) do
			if not devData[cn] then
				D("masterTick() child %1 may not be started yet", cn)
			elseif now >= ( ( devData[cn].lastRefresh or 0 ) + intRefresh ) then
				local unit = luup.devices[cn].id
				table.insert( infocmd, "GET," .. unit .. ":*" )
				devData[cn].lastRefresh = now
			end
		end

		-- Send queued commands
		tm = lastSendTime + intPing
		if #infocmd == 0 and now >= tm then
			table.insert( infocmd, "PING" )
		else
			task:schedule( tm )
		end
		if #infocmd > 0 then
			local cmd = table.remove( infocmd, 1 )
			D("masterTick() sending queued/idle command %1", cmd)
			sendCommand( cmd, dev )
			if #infocmd > 0 then
				-- More queued stuff to send, be quick
				task:delay( 5 )
			end
		elseif getVarNumeric( "SendDateTime", 1, dev, MYSID ) ~= 0 and
				now >= ( ( lastdtm or 0 ) + 3600 ) then
			-- Update clock. We don't use queue for this so not delayed by other cmds
			D("masterTick() updating device clock")
			sendCommand(string.format("CFG:DATETIME,%s", os.date("%d/%m/%Y %H:%M:%S")), dev)
			lastdtm = now
		end
	end
end

-- Do a one-time startup on a new device
local function deviceRunOnce( dev, parentDev )

	local rev = getVarNumeric("Version", 0, dev, DEVICESID)
	if rev == 0 then
		-- Initialize for new installation
		D("runOnce() Performing first-time initialization!")
		luup.attr_set( "category_num", 5, dev )
		luup.attr_set( "subcategory_num", 1, dev )
	end

	initVar(DEVICESID, "DisplayTemperature", "--.-", dev)
	initVar(DEVICESID, "DisplayStatus", "Configuring", dev)
	initVar(DEVICESID, "IntesisONOFF", "", dev)
	initVar(DEVICESID, "IntesisMODE", "", dev)
	initVar(DEVICESID, "IntesisFANSP", "", dev)
	initVar(DEVICESID, "IntesisVANEUD", "", dev)
	initVar(DEVICESID, "IntesisVANELR", "", dev)
	initVar(DEVICESID, "IntesisERRSTATUS", "", dev)
	initVar(DEVICESID, "IntesisERRCODE", "", dev)

	initVar(OPMODE_SID, "ModeTarget", MODE_OFF, dev)
	initVar(OPMODE_SID, "ModeStatus", MODE_OFF, dev)
	initVar(OPMODE_SID, "EnergyModeTarget", EMODE_NORMAL, dev)
	initVar(OPMODE_SID, "EnergyModeStatus", EMODE_NORMAL, dev)
	initVar(OPMODE_SID, "AutoMode", "1", dev)

	initVar(FANMODE_SID, "Mode", FANMODE_AUTO, dev)
	initVar(FANMODE_SID, "FanStatus", "Off", dev)

	-- Setpoint defaults. Note that we don't have sysTemps yet during this call.
	-- setVar(SETPOINT_SID, "Application", "DualHeatingCooling", dev)
	initVar(SETPOINT_SID, "SetpointAchieved", "0", dev)
	if luup.attr_get("TemperatureFormat",0) == "C" then
		initVar(SETPOINT_SID, "CurrentSetpoint", "18", dev)
	else
		initVar(SETPOINT_SID, "CurrentSetpoint", "64", dev)
	end

	initVar(HADEVICE_SID, "ModeSetting", "1:;2:;3:;4:", dev)

	-- Delete outdated
	deleteVar(DEVICESID, "IntesisID", dev)
	deleteVar(DEVICESID, "IPAddress", dev)
	deleteVar(DEVICESID, "TCPPort", dev)
	deleteVar(DEVICESID, "Name", dev)
	deleteVar(DEVICESID, "SignalDB", dev)
	deleteVar(DEVICESID, "ConfigurationUnits", dev)
	deleteVar(DEVICESID, "Failure", dev)
	deleteVar(DEVICESID, "Parent", dev)
	for _,v in ipairs{ "ONOFF", "MODE", "FANSP", "VANEUD", "VANELR", "SETPTEMP" } do
		deleteVar(DEVICESID, "Limits"..v, dev)
	end
	for _,v in ipairs{ "AUTO", "HEAT", "COOL", "DRY", "FAN" } do
		deleteVar(DEVICESID, "Mode"..v, dev)
	end
	deleteVar(HADEVICE_SID, "Commands", dev)
	-- Temporary
	deleteVar(DEVICESID, "Unit", dev)

	-- No matter what happens above, if our versions don't match, force that here/now.
	if rev < _CONFIGVERSION then
		setVar(DEVICESID, "Version", _CONFIGVERSION, dev)
	end
end

-- Do startup of a child device
local function deviceStart( dev, parentDev )
	D("deviceStart(%1,%2)", dev, parentDev )

	-- Early inits
	devData[dev] = {}
	devData[dev].limits = {}
	devData[dev].lastRefresh = 0

	-- Make sure the device is initialized. It may be new.
	deviceRunOnce( dev, parentDev )

	if isALTUI then
		local rc,rs,jj,ra = luup.call_action("urn:upnp-org:serviceId:altui1", "RegisterPlugin",
			{ newDeviceType=MYTYPE, newScriptFile="J_IntesisWMPDevice1_ALTUI.js", newDeviceDrawFunc="IntesisWMPDevice1_ALTUI.DeviceDraw" },
				dev )
			D("deviceStart() ALTUI's RegisterPlugin action returned resultCode=%1, resultString=%2, job=%3, returnArguments=%4", rc,rs,jj,ra)
	end

	setVar( DEVICESID, "DisplayStatus", "Starting...", dev )

	-- Copy unit number to state variable for static JSON access
	setVar( DEVICESID, "_ui_u", luup.devices[dev].id, dev )

	--[[ Work out the system units, the user's desired display units, and the configuration units.
		 The user's desire overrides the system configuration. This is an exception provided in
		 case the user has a thermostat for which they want to operate in units other than the
		 system configuration. If the target units and the config units don't comport, modify
		 the interface configuration to use the target units and reload Luup.
	--]]
	local sysUnits = luup.attr_get("TemperatureFormat", 0) or "C"
	local forceUnits = getVar( "ForceUnits", "", dev, DEVICESID )
	local targetUnits = ( forceUnits == "" ) and sysUnits or forceUnits
	D("deviceStart() system units %1, force units %2, target units %3.", sysUnits, forceUnits, targetUnits)
	local tempStatic = "D_IntesisWMPDevice1_" .. targetUnits .. ".json"
	if luup.attr_get( "device_json", dev ) ~= tempStatic then
		W("%2 (#%3) Reconfiguring temperature units to %1, which will require a Luup restart.",
			targetUnits, luup.devices[dev].description, dev)
		luup.attr_set( "device_json", tempStatic, dev )
		deferReload( 15, parentDev )
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

	L("Device %1 (#%2) started for unit %3 on gateway %4", luup.devices[dev].description, dev, 
		tonumber( luup.devices[dev].id ) or "INVALID", 
		getVar( "IntesisID", "INVALID", parentDev, MYSID ) )
	luup.set_failure( 0, dev )
	return true, "OK", _PLUGIN_NAME
end

local function discoveryByMAC( mac, dev )
	D("discoveryByMAC(%1,%2)", mac, dev)
	AP(dev)
	L("Discovery: seaerching for MAC %1", mac)
	gatewayStatus( "Searching for " .. mac, dev )
	local res = getIPforMAC( mac, dev )
	if res then
		local first = res[1]
		L("Discovery: found possible %1 for MAC %2", first.ip, first.mac)
		if passGenericDiscovery( first.mac, first.ip, dev ) then
			gatewayStatus( "Configuring " .. tostring(first.mac) .. " at " .. tostring(first.ip) )
			deferReload( 5, dev )
			return true
		end
		-- Fall through; status message already updated
	else
		W("Discovery: can't find device or IP for MAC %1", mac)
		gatewayStatus( "Device not found with MAC " .. mac, dev )
	end
	return false
end

-- Try to ping the device, and then find its MAC address in the ARP table.
local function discoveryByIP( ipaddr, dev )
	D("discoveryByIP(%1,%2)", ipaddr, dev)
	AP(dev)
	L("Discovery: trying IP %1", ipaddr)
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
			L("Discovery: failed to connect to %1, %2", ipaddr, err)
			gatewayStatus( "Device not found at IP " .. ipaddr , dev )
			return false
		end
	end
	local first = res[1]
	D("Discovery: found MAC %1 for IP %2", first.mac, first.ip)
	if passGenericDiscovery( first.mac, first.ip, dev ) then
		gatewayStatus( "Configuring " .. tostring(first.mac) .. " at " .. tostring(first.ip) )
		deferReload( 5, dev )
		return true
	end
	-- Fall through, status message already update
	return false
end

-- Tick for UDP discovery.
function discoveryTick( task, dev, expiration )
	D("discoveryTick(%1,%2)", dev, expiration)
	AP(dev)

	gatewayStatus( "Discovery running...", dev )

	local udp = devData[dev].discoverySocket
	if udp ~= nil then
		repeat
			udp:settimeout(1)
			local resp, peer, port = udp:receivefrom()
			if resp ~= nil then
				D("discoveryTick() received response from %1:%2", peer, port)
				if ( handleDiscoveryMessage( resp, dev ) ) then
					discoveryReload = true
				end
			end
		until resp == nil

		if expiration > os.time() then
			task:delay( 2 )
			return
		end

		D("discoveryTick() search time expired, closing")
		udp:close()
		devData[dev].discoverySocket = nil
	end
	task:close()
	D("discoveryTick() end of discovery")
	if discoveryReload then
		L("Discovery: new devices; arming to reload Luup")
		gatewayStatus( "Configuring new devices; reloading Luup", dev )
		deferReload( 5, dev )
	end
	L("Discovery ended with no new gateways found.")
	gatewayStatus( "Nothing new discovered.", dev )
end

-- Launch UDP discovery.
local function launchDiscovery( dev )
	D("launchDiscovery(%1)", dev)
	AP(dev)
	assert( not isOpenLuup, "Don't know how to get IP info on openLuup... yet")

	if devData[dev].discoverySocket then
		W("Attempt to launch discovery while it's already running ignored.")
		return false
	end

	discoveryReload = false

	L("Discovery: starting UDP broadcast discovery")
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
	local t = scheduler.Task:new( "discovery", dev, discoveryTick, { dev, os.time() + 30 } )
	t:delay( 0 )
end

-- Handle variable change callback
function varChanged( dev, sid, var, oldVal, newVal )
	D("varChanged(%1,%2,%3,%4,%5) luup.device is %6", dev, sid, var, oldVal, newVal, luup.device)
	-- assert(var ~= nil) -- nil if service or device watch (can happen on openLuup)
	-- assert(luup.device ~= nil) -- fails on openLuup, have discussed with author but no fix forthcoming as of yet.
	updateDeviceStatus( dev )
end

local function plugin_checkVersion(dev)
	assert(dev ~= nil)
	D("checkVersion() branch %1 major %2 minor %3, string %4, openLuup %5", luup.version_branch, luup.version_major, luup.version_minor, luup.version, isOpenLuup)
	if isOpenLuup then return false end -- v2 does not work on openLuup
	if ( luup.version_branch == 1 and luup.version_major >= 7 ) then
		setVar( MYSID, "UI7Check", "true", dev )
		return true
	end
	return false
end

-- Do one-time initialization for a gateway
local function plugin_runOnce(dev)
	AP(dev)

	local rev = getVarNumeric("Version", 0, dev, MYSID)
	if rev == 0 then
		-- Initialize for new installation
		D("runOnce() Performing first-time initialization!")
		luup.attr_set( "category_num", 1, dev )
	end

	initVar(MYSID, "DisplayStatus", "Configuring", dev)
	initVar(MYSID, "IntesisID", "", dev )
	initVar(MYSID, "IPAddress", "", dev )
	initVar(MYSID, "TCPPort", "", dev )
	initVar(MYSID, "UseProxy", "", dev)
	initVar(MYSID, "SignalDB", "", dev)
	initVar(MYSID, "PingInterval", "", dev)
	initVar(MYSID, "RefreshInterval", "", dev)
	initVar(MYSID, "RunStartupDiscovery", "", dev)
	initVar(MYSID, "Failure", "0", dev)
	initVar(MYSID, "DisplayStatus", "", dev)
	initVar(MYSID, "DebugMode", 0, dev)

	if rev < 020203 then
		setVar(MYSID, "DebugMode", 0, dev)
	end

	-- No matter what happens above, if our versions don't match, force that here/now.
	if rev < _CONFIGVERSION then
		setVar(MYSID, "Version", _CONFIGVERSION, dev)
	end
	return true -- indicate to caller we should keep going
end

-- Start-up initialization for plug-in.
function plugin_init(dev)
	D("plugin_init(%1)", dev)
	L("starting version %1 for gateway %2", _PLUGIN_VERSION,
		getVar( "IntesisID", "(not configured)", dev, MYSID ) )

	-- Up front inits
	pluginDevice = dev
	devData[dev] = {}
	devData[dev].units = {}
	devData[dev].limits = {}
	devData[dev].sysTemps = {}

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
		setVar( MYSID, "Failure", "1", dev )
		luup.set_failure( 1, dev )
		return false, "Unsupported system firmware", _PLUGIN_NAME
	end

	-- See if we need any one-time inits
	if not plugin_runOnce(dev) then
		luup.set_failure( 1, dev )
		return false, "Upgraded, delete old device", _PLUGIN_NAME
	end

	-- Other inits
	gatewayStatus( "Starting up...", dev )

	-- Start task manager
	scheduler = TaskManager( 'intesisTaskTick' )

	-- Check for children that need to be upgraded to 3.0
	if true then
		local needsReload = false
		for k,v in pairs(luup.devices) do
			if v.device_type == DEVICETYPE and v.device_num_parent == dev then
				-- Found child.
				D("plugin_init() checking child %1 (#%2)", v.description, k)
				-- Is this an old child in need of adoption by a newly-created master?
				local s = getVar( "IntesisID", "", k, DEVICESID )
				if s ~= "" then
					-- Pre-3.0 child has not been handled yet. Parent already have a child?
					if getVar( "IntesisID", "", dev, DEVICESID ) == "" then
						-- No gateway ID assigned to this parent yet. Move it up from child.
						D("plugin_init() assigning child's IntesisID to parent")
						setVar( MYSID, "IntesisID", s, dev )
						setVar( MYSID, "IPAddress", getVar( "IPAddress", "", k, DEVICESID ), dev )
						luup.attr_set( "altid", 1, k )
						deleteVar( DEVICESID, "IntesisID", k )
						deleteVar( DEVICESID, "IPAddress", k )
						needsReload = true
					else
						-- There's already an ID/IP assigned on this parent.
						-- Make a new master device for this ID/IP. The startup for the
						-- new master will take care of adding a default child/unit.]
						D("plugin_init() creating new master for %1", s)
						local m = split( s, "," ) or {}
						local newname = "IntesisBox " .. (m[2] or "Gateway")
						local vv = {
							MYSID .. ",IntesisID=" .. s,
							MYSID .. ",IPAddress=" .. getVar( "IPAddress", "", k, DEVICESID )
						}
						local ra,rb,rc,rd = luup.call_action(
							"urn:micasaverde-com:serviceId:HomeAutomationGateway1",
							"CreateDevice",
							{
								Description=newname,
								UpnpDevFilename="D_IntesisWMPGateway1.xml",
								UpnpImplFilename="I_IntesisWMPGateway1.xml",
								RoomNum=luup.attr_get( "room_num", k ) or 0,
								StateVariables=table.concat( vv, "\n" )
							},
							0
						)
						local newdev = tonumber( rd.DeviceNum )
						D("plugin_init() new master is %1, assigning %2", newdev, k)
						if newdev then
							deleteVar( DEVICESID, "IntesisID", k )
							deleteVar( DEVICESID, "IPAddress", k )
							L("Assigning child %1 (#%2) to new master %3 (#%4)", v.description, k, newname, newdev)
							setVar( DEVICESID, "DisplayStatus", "Upgrading...", k )
							luup.attr_set( "id_parent", newdev, k )
							luup.attr_set( "altid", "1", k )
							needsReload = true
						end
					end
				else
					D("plugin_init() child %1 (#%2) is already converted", v.description, k)
				end
			end
		end
		if needsReload then
			luup.set_failure( true, dev )
			deferReload( 5, dev )
			return false, "Upgrading devices...", _PLUGIN_NAME
		end
	end

	-- The device IP can change at any time, so always use the last discovery
	-- response. Make an effort here. It's not always easy.
	local ident = getVar( "IntesisID", "", dev, MYSID )
	if ident ~= "" then
		D("plugin_init() last known ident is %1", ident)
		local parts = split( ident, "," )
		local devIP = parts[3] or ""
		if devIP == "" then
			L("Device IP could not be established for %1(%2) ID=%3",
				dev, luup.devices[dev].description, ident)
			return false, "Can't establish IP address from ident string", _PLUGIN_NAME
		end
		D("plugin_init() updating device IP to %1", devIP)
		setVar( MYSID, "IPAddress", devIP, dev )
	else
		gatewayStatus( "Please run discovery", dev )
		L("Device IP could not be established for %1(%2) ID=%3; please run discovery.",
			dev, luup.devices[dev].description, ident)
		luup.set_failure( 0, dev )
		return true, "Please run discovery.", _PLUGIN_NAME
	end
	luup.attr_set( "ip", "", dev )
	luup.attr_set( "mac", "", dev )

	-- Launch the master tick.
	scheduler.Task:new( 'master', dev, masterTick, { dev } ):delay( 15 )

	-- Start up each of our children
	local children = inventoryChildren( dev )
	if #children == 0 then
		-- Create first child as unit 1 by default.
		local vv = {
			",room_num="..(luup.attr_get("room_num", dev) or "0")
		}
		local ptr = luup.chdev.start( dev )
		luup.chdev.append( dev, ptr,
			1, -- id (altid)
			"Unit 1", -- description
			"", -- device type
			"D_IntesisWMPDevice1.xml", -- device file
			"", -- impl file
			table.concat( vv, "\n" ), -- state vars
			false -- embedded
		)
		luup.chdev.sync( dev, ptr )
		return false, "Reconfiguring...", _PLUGIN_NAME
	end
	for _,cn in ipairs( children ) do
		local unit = tonumber( luup.devices[cn].id ) or -1
		L("Starting %2 (#%1) unit %3", cn, luup.devices[cn].description, unit)
		if unit < 0 then
			luup.set_failure( cn, true );
			setVar( DEVICESID, "Failure", 1, cn )
			setVar( DEVICESID, "DisplayStatus", "Unit number is not assigned", cn )
		elseif devData[dev].units[tostring(unit)] then
			luup.set_failure( cn, true );
			setVar( DEVICESID, "Failure", 1, cn )
			setVar( DEVICESID, "DisplayStatus", "Duplicate unit ID!", cn )
		else
			devData[dev].units[tostring(unit)] = cn
			luup.set_failure( cn, false );
			setVar( DEVICESID, "Failure", 0, cn ) -- IUPG
			local ok, err = pcall( deviceStart, cn, dev )
			if not ok then
				setVar( DEVICESID, "Failure", 1, cn )
				L("Device %1 (%2) failed to start, %3", cn, luup.devices[cn].description, err)
				gatewayStatus( "Device(s) failed to start!", dev )
			end
		end
	end

	-- Mark successful start (so far)
	L("Running!")
	luup.set_failure( 0, dev )
	return true, "OK", _PLUGIN_NAME
end

-- Action for SetModeTarget -- change current operating mode
function actionSetModeTarget( dev, newMode )
	D("actionSetModeTarget(%1,%2)", dev, newMode)
	if newMode == nil or type(newMode) ~= "string" then return end
	local xmap = { [MODE_AUTO]="AUTO", [MODE_HEAT]="HEAT", [MODE_COOL]="COOL", [MODE_FAN]="FAN", [MODE_DRY]="DRY" }
	local unit = luup.devices[dev].id
	if newMode == MODE_OFF then
		if not sendCommand( "SET," .. unit .. ":ONOFF,OFF", dev ) then
			return false
		end
	elseif xmap[newMode] ~= nil then
		if not inLimit( "MODE", xmap[newMode], dev ) then
			L({level=2,msg="Unsupported MODE %1 (configured device only supports %2)"}, xmap[newMode], devData[dev].limits.MODE.values)
			return false
		end
		if not sendCommand( "SET," .. unit .. ":ONOFF,ON", dev ) then
			return false
		end
		if not sendCommand( "SET," .. unit .. ":MODE," .. xmap[newMode], dev ) then
			return false
		end
	else
		L("Invalid target opreating mode passed in action: %1", newMode)
		return false
	end
	setVar( OPMODE_SID, "ModeTarget", newMode, dev )
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
	local unit = luup.devices[dev].id
	if inLimit( "FANSP", tostring(newSpeed), dev ) then
		return sendCommand( "SET," .. unit .. ":FANSP," .. newSpeed, dev )
	end
	L({level=2,msg="Fan speed %1 out of range"}, newSpeed)
	return false
end

-- Speed up the fan (implies switch out of auto, presumably)
function actionFanSpeedUp( dev )
	D("actionFanSpeedUp(%1)", dev)
	local speed = getVarNumeric( "IntesisFANSP", 0, dev, DEVICESID ) + 1
	local unit = luup.devices[dev].id
	return inLimit( "FANSP", speed, dev ) and sendCommand( "SET," .. unit .. ":FANSP," .. speed, dev ) or false
end

-- Speed up the fan (implies switch out of auto, presumably)
function actionFanSpeedDown( dev )
	D("actionFanSpeedDown(%1)", dev)
	local speed = getVarNumeric( "IntesisFANSP", 2, dev, DEVICESID ) - 1
	local unit = luup.devices[dev].id
	return inLimit( "FANSP", speed, dev ) and sendCommand( "SET,".. unit .. ":FANSP," .. speed, dev ) or false
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

	local unit = luup.devices[dev].id

	newSP = tonumber(newSP, 10)
	if newSP == nil then return end
	newSP = constrain( newSP, devData[dev].sysTemps.minimum, devData[dev].sysTemps.maximum )

	-- Convert to C if needed
	if devData[dev].sysTemps.unit == "F" then
		newSP = FtoC( newSP )
	end
	D("actionSetCurrentSetpoint() new target setpoint is %1C", newSP)

	setVar( SETPOINT_SID, "SetpointAchieved", "0", dev )
	if sendCommand("SET," .. unit .. ":SETPTEMP," .. string.format( "%.0f", newSP * 10 ), dev ) then
		return sendCommand( "GET," .. unit .. ":SETPTEMP", dev ) -- An immediate get to make sure display shows device limits
	end
	return false
end

-- Action to change energy mode (not implemented).
function actionSetEnergyModeTarget( dev, newMode )
	-- Store the target, but don't change status, because nothing changes, and signal failure.
	setVar( OPMODE_SID, "EnergyModeTarget", newMode, dev )
	return false
end

-- Set vane (up/down) position.
function actionSetVaneUD( dev, newPos )
	D("actionSetVaneUD(%1,%2)", dev, newPos)
	local unit = luup.devices[dev].id
	if (newPos or "0") == "0" then newPos = "AUTO" end
	if not inLimit( "VANEUD", tostring(newPos), dev ) then
		L({level=2,msg="Vane U-D position %1 is outside accepted range (%2); ignored"}, newPos, devData[dev].limits.VANEUD.values)
		return false
	end
	return sendCommand( "SET," .. unit .. ":VANEUD," .. tostring(newPos), dev )
end

-- Set vane up (relative)
function actionVaneUp( dev )
	D("actionVaneUp(%1)", dev )
	local unit = luup.devices[dev].id
	local pos = getVarNumeric( "IntesisVANEUD", 0, dev, DEVICESID ) - 1
	if pos <= 0 and inLimit( "VANEUD", "SWING", dev ) then
		pos = "SWING"
	end
	return inLimit( "VANEUD", pos, dev ) and sendCommand("SET," .. unit .. ":VANEUD," .. pos, dev) or false
end

-- Set vane down (relative)
function actionVaneDown( dev )
	D("actionVaneDown(%1)", dev )
	local unit = luup.devices[dev].id
	local pos = getVarNumeric( "IntesisVANEUD", 0, dev, DEVICESID ) + 1
	return inLimit( "VANEUD", pos, dev ) and sendCommand("SET," .. unit .. ":VANEUD," .. pos, dev) or false
end

-- Set vane (left/right) position.
function actionSetVaneLR( dev, newPos )
	D("actionSetVaneLR(%1,%2)", dev, newPos)
	local unit = luup.devices[dev].id
	if (newPos or "0") == "0" then newPos = "AUTO" end
	if not inLimit( "VANELR", tostring(newPos), dev ) then
		L({level=2,msg="Vane L-R position %1 is outside accepted range; ignored"}, newPos, devData[dev].limits.VANELR.values)
		return false
	end
	return sendCommand( "SET," .. unit .. ":VANELR," .. tostring(newPos), dev )
end

-- Vane left
function actionVaneLeft( dev )
	D("actionVaneLeft(%1)", dev )
	local unit = luup.devices[dev].id
	local pos = getVarNumeric( "IntesisVANELR", 0, dev, DEVICESID ) - 1
	if pos <= 0 and inLimit( "VANELR", "SWING" ) then
		pos = "SWING"
	end
	return inLimit( "VANELR", pos, dev ) and sendCommand( "SET," .. unit .. ":VANELR," .. pos, dev ) or false
end

-- Vane right
function actionVaneRight( dev )
	D("actionVaneDown(%1)", dev )
	local unit = luup.devices[dev].id
	local pos = getVarNumeric( "IntesisVANELR", 0, dev, DEVICESID ) + 1
	return inLimit( "VANELR", pos, dev ) and sendCommand( "SET," .. unit .. ":VANELR," .. pos, dev ) or false
end

function actionSetUnitID( dev, unitid )
	unitid = tostring( unitid )
	if not unitid:match( "^[1-9][0-9]*$" ) then
		E("Action failed: invalid unit ID %1", unitid)
		return false
	end
	if tostring(luup.devices[dev].id) == unitid then
		W("Action ignored: %1 (#%2) unit ID is already %3", luup.devices[dev].description,
			dev, unitid)
		return true
	end
	local pdev = luup.devices[dev].device_num_parent
	for cn,d in iterateChildren( pdev ) do
		if tostring(d.id) == unitid then
			E("Action failed: unit %3 already in use by %1 (#%2)", d.description, cn, unitid)
			return false
		end
	end
	luup.attr_set( "altid", unitid, dev )
	setVar( DEVICESID, "_ui_u", unitid, dev )
	if luup.devices[dev].description:match( "^Unit %d+$" ) then
		luup.attr_set( "name", "Unit " .. unitid, dev )
	end
	L("Action succeeded: unit id set for %1 (#%2) to %3; reloading Luup...",
		luup.devices[dev].description, dev, unitid)
	setVar( DEVICESID, "DisplayStatus", "Wait; changing unit ID to "..unitid, dev )
	gatewayStatus( "Reloading for unit ID change", pdev )
	deferReload( 5, pdev )
	return true
end

-- Set the device name
function actionSetName( dev, newName )
	if not sendCommand( "CFG:DEVICENAME," .. string.upper( newName or "" ), dev ) then
		return false
	end
	return sendCommand( "ID", dev )
end

-- Delayed implementation of add unit action so UI can display status
-- (slow refresh requires a couple of seconds, and if the reload comes
-- too fast, the UI never updates the display and the user is left wondering
-- what's going on.
function delayAddUnit( task, dev )
	local ptr = luup.chdev.start( dev )
	local maxu = 0
	for cn,d in iterateChildren( dev ) do
		local n = tonumber( d.id )
		if n and n > maxu then maxu = n end
		D("actionAddUnit() appending %1 (#%2) unit %3 as existing device", d.description,
			cn, n)
		luup.chdev.append( dev, ptr, d.id, d.description, d.device_type, "", "", "", false )
	end
	maxu = maxu + 1
	luup.chdev.append( dev, ptr, maxu, "Unit "..maxu, "", "D_IntesisWMPDevice1.xml", "", "", false )
	W("New unit %1 added; Luup reload coming next...", maxu)
	luup.chdev.sync( dev, ptr )
	task:close()
end

function actionAddUnit( dev )
	AP(dev)
	scheduler.Task:new( 'addunit', dev, delayAddUnit, { dev } ):delay( 5 )
	L("Adding new unit")
	gatewayStatus( "Adding new unit and reloading Luup...", dev )
	return true
end

function actionRunDiscovery( dev )
	launchDiscovery( dev )
end

function actionDiscoverMAC( dev, mac )
	local newMAC = (mac or ""):gsub("[%s:-]+", ""):upper()
	if #newMAC ~= 12 or newMAC:match("[^0-9A-F]") then
		gatewayStatus( "Invalid MAC address", dev )
		W("Action failed: invalid MAC address provided: %1", mac)
	else
		discoveryByMAC( newMAC, dev )
	end
end

function actionDiscoverIP( dev, ipaddr )
	local newIP = (ipaddr or ""):gsub(" ", "")
	if newIP:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$") then
		discoveryByIP( newIP, dev )
	else
		gatewayStatus( "Invalid IP address", dev )
		L("Action failed: invalid IP address provided: %1", ipaddr)
	end
end

function actionHandleReceive( dev, params )
	D("actionHandleReceive(%1,%2)", dev, params)
	scheduler.getTask( 'receiver' ):delay( 0 )
end

function actionSetDebug( dev, enabled )
	D("actionSetDebug(%1,%2)", dev, enabled)
	if enabled == 1 or enabled == "1" or enabled == true or enabled == "true" then
		debugMode = true
		D("actionSetDebug() debug logging enabled")
	end
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
					table.insert( issinfo, issKeyVal( "curmode", map( { Off="Off",HeatOn="Heat",CoolOn="Cool",AutoChangeOver="Auto",Dry="Dry",FanOnly="Fan" }, getVar( "ModeStatus","Off", lnum, OPMODE_SID ) ) ) )
					table.insert( issinfo, issKeyVal( "curfanmode", map( { Auto="Auto",ContinuousOn="On",PeriodicOn="Periodic" }, getVar( "Mode", "Auto", lnum, FANMODE_SID) ) ) )
					table.insert( issinfo, issKeyVal( "curtemp", getVar("CurrentTemperature", "", lnum,  TEMPSENS_SID ), { unit="°" .. devData[lnum].sysTemps.unit } ) )
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
				local gwinfo = getDevice( k, k, v ) or {}
				gwinfo.children = {}
				for cn,cd in iterateChildren( k ) do
					table.insert( gwinfo.children, getDevice( cn, k, cd ) )
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
