-- -----------------------------------------------------------------------------
-- L_IntesisWMPGateway.lua
-- Copyright 2017 Patrick H. Rigney, All Rights Reserved
-- http://www.toggledbits.com/intesis/
-- This file is available under GPL 3.0. See LICENSE in documentation for info.
-- -----------------------------------------------------------------------------

--[[ 
    Overview
    --------------------------------------------------------------------------------------------
    This is the core implementation for the WMP protocol inferface. The interface plugin emul-
    ates a thermostat by providing the operating mode, fan mode, setpoint mode, and temperature
    sensor services common to those devices, and a UI with typical thermostat controls.
    
    As presented, the Intesis WMP protocol provides a basic set of functions for controlling an
    autochangeover (dual heating and cooling) thermostat. The interface maintains a single temp-
    erature setpoint, rather than separate heating and cooling setpoints.
    
    The Intesis interface provides control messages only. At this time, WMP appears to be a one-
    way dialog with the controlled heating/cooling unit in that it does not itself directly
    communicate with the unit, so cannot retrieve and thus does not pass back any status infor-
    mation about the actual operation of the unit. That is, we can tell WMP to set the unit's
    setpoint temperature to 24C, and WMP will acknowledge that ITS setpoint is now 24C and that
    it presumably has sent that command to the unit (via IR, etc.), but WMP may not know if the
    unit received and accepted that command, or has the ability to receive any data or acknowledge-
    ment from the unit of what it believes the current setpoint to be. This probably works fine in
    most cases, but it is a thin integration. This fact restricts our implementation to tying
    "Target" and "Status" modes together. Since there is no way to know that setting a "Target"
    mode is achieved by the unit, we force the "Status" together where a target is set, and are
    simply assuming that our command has been successfully carried out from end to end.
    
    WMP also does not seem to offer any protocol commands or data that reflect the current state
    of the unit. For example. one can set the operating mode to "cooling," and WMP can (as stated
    above) confirm that it has requested the unit change its operating mode to cooling, but can-
    not tell us if the unit is actually cooling (trying to achieve setpoint) or idle (within the
    setpoint deadband). Therefore, the usual state messages have been removed from the interface,
    as state simply follows target and the information is thus redundant. Similarly, no other
    status information about the unit is available, such as fan status, filter change needed,
    etc.
    
    Another challenge in producing a "clean" implementation is that the WMP LIMITS command re-
    turns, among other data, the setpoint limits that the configured unit is capable of handling, 
    but does not return the resolution. That is, WMP will tell us the device will accept setpoint
    temperatures in the range of 18 to 30 C, for example, but will not tell us that temps must be
    set in whole degrees, half degrees, or tenths of degrees (the maximum resolution of the WMP
    protocol itself at the moment). This causes users with fahrenheit temperature units config-
    ured in their UI's to see wild-looking "jumps" in temperature with some units, where the unit
    may accept only whole degrees or half-degrees. This is more a point of awareness than any-
    thing, as Vera's native UI itself has little ability for us to dynamically modify the user
    interface controls (ALTUI, however, provides this ability easily). Although the author can-
    not confirm with the equipment on hand whether Intesis actually keeps resolution data in its
    unit configurations, it certainly seems reasonable that it would, and thus not terribly
    challenging for Intesis to extend the protocol to include an addition LIMITS response for 
    this purpose.
   
--]]

module("L_IntesisWMPGateway1", package.seeall)

local _PLUGIN_NAME = "IntesisWMPGateway"
local _PLUGIN_VERSION = "1.0"
local _CONFIGVERSION = 010000

local debugMode = false

local MYSID = "urn:toggledbits-com:serviceId:IntesisWMPGateway1"
local MYTYPE = "urn:schemas-toggledbits-com:device:IntesisWMPGateway:1"

local OPMODE_SID = "urn:upnp-org:serviceId:HVAC_UserOperatingMode1"
local FANMODE_SID = "urn:upnp-org:serviceId:HVAC_FanOperatingMode1"
local SETPOINT_SID = "urn:upnp-org:serviceId:TemperatureSetpoint1"
local TEMPSENS_SID = "urn:upnp-org:serviceId:TemperatureSensor1"
local HADEVICE_SID = "urn:micasaverde-com:serviceId:HaDevice1"

local MODE_OFF = "Off"
local MODE_COOL = "CoolOn"
local MODE_HEAT = "HeatOn"
local MODE_AUTO = "AutoChangeOver"

local EMODE_NORMAL = "Normal"
local EMODE_ECO = "EnergySavingsMode"

local FANMODE_AUTO = "Auto"
local FANMODE_PERIODIC = "PeriodicOn"
local FANMODE_ON = "ContinuousOn"

-- Intesis EOL string. Can be CR only, doesn't need LF. The device takes either or both per their spec.
local INTESIS_EOL = string.char(13)
-- Default ping interval. This can overridden by state variable PingInterval.
local DEFAULT_PING = 15
-- Default refresh interval (GET,1:*). This can be overridden by state variable RefreshInterval
local DEFAULT_REFRESH = 60

local inBuffer = nil
local lastIncoming = 0
local lastCommand = nil
local lastRefresh = 0
local lastPing = 0

local runStamp = {}
local sysTemps = { unit="C", default=20, minimum=16, maximum=32 } 

local isALTUI = false
local isOpenLuup = false

local function ldump(name, t, seen)
    if seen == nil then seen = {} end
    local str = name
    if type(t) == "table" then
        if seen[t] then
            str = str .. " = " .. seen[t] .. "\n"
        else
            seen[t] = name
            str = str .. " = {}\n"
            local k,v
            for k,v in pairs(t) do
                if type(k) == "number" then
                    str = str .. ldump(string.format("%s[%d]", name, k), v, seen)
                else
                    str = str .. ldump(string.format("%s[%q]", name, tostring(k)), v, seen)
                end
            end
        end
    elseif type(t) == "string" then
        str = str .. " = " .. string.format("%q", t) .. "\n"
    else
        str = str .. " = " .. tostring(t) .. "\n"
    end
    return str
end

local function devdump(name, pdev, ddev)
    if ddev == nil then ddev = getVarNumeric( name, 0, pdev, MYSID ) end
    local str = string.format("\n-- Configured device %q (%d): ", name, ddev)
    if ddev == 0 then
        str = str .. "not defined\n"
    elseif luup.devices[ddev] == nil then
        str = str .. " not in luup.devices?"
    else
        str = str .. "\n" .. ldump(string.format("luup.devices[%d]", ddev), luup.devices[ddev])
    end
    if ddev > 0 then
        str = str .. "-- state"
        local status,body,httpStatus
        status,body,httpStatus = luup.inet.wget("http://localhost:3480/data_request?id=status&output_format=json&DeviceNum=" .. tostring(ddev), 30)
        if status == 0 then
            str = str .. "\n" .. body .. "\n"
        else
            str = str .. string.format("request returned %s, %q, %s\n", status, body, httpStatus)
        end
    end
    return str
end

local function dump(t)
    if t == nil then return "nil" end
    local k,v,str,val
    local sep = ""
    local str = "{ "
    for k,v in pairs(t) do
        if type(v) == "table" then
            val = dump(v)
        elseif type(v) == "function" then
            val = "(function)"
        elseif type(v) == "string" then
            val = string.format("%q", v)
        elseif type(v) == "number" then
            local d = v - os.time()
            if d < 0 then d = -d end
            if d <= 86400 then 
                val = string.format("%d (%s)", v, os.date("%X", v))
            else
                val = tostring(v)
            end
        else
            val = tostring(v)
        end
        str = str .. sep .. k .. "=" .. val
        sep = ", "
    end
    str = str .. " }"
    return str
end

local function L(msg, ...)
    local str
    if type(msg) == "table" then
        str = msg["prefix"] .. msg["msg"]
    else
        str = _PLUGIN_NAME .. ": " .. msg
    end
    str = string.gsub(str, "%%(%d+)", function( n )
            n = tonumber(n, 10)
            if n < 1 or n > #arg then return "nil" end
            local val = arg[n]
            if type(val) == "table" then
                return dump(val)
            elseif type(val) == "string" then
                return string.format("%q", val)
            elseif type(val) == "number" then
                local d = val - os.time()
                if d < 0 then d = -d end
                if d <= 86400 then 
                    val = string.format("%d (time %s)", val, os.date("%X", val))
                end
            end
            return tostring(val)
        end
    )
    luup.log(str)
end

local function D(msg, ...)
    if debugMode then
        L({msg=msg,prefix=_PLUGIN_NAME.."(debug)::"}, ... )
    end
end

-- Take a string and split it around sep, returning table (indexed) of substrings
-- For example abc,def,ghi becomes t[1]=abc, t[2]=def, t[3]=ghi
-- Returns: table of values, count of values (integer ge 0)
local function split(s, sep)
    local t = {}
    local n = 0
    if s == nil or s == "" then return t,n end -- empty string returns nothing
    local i,j
    local k = 1
    repeat
        i, j = string.find(s, sep or "%s*,%s*", k)
        if (i == nil) then
            table.insert(t, string.sub(s, k, -1))
            n = n + 1
            break
        else
            table.insert(t, string.sub(s, k, i-1))
            n = n + 1
            k = j + 1
        end
    until k > string.len(s)
    return t, n
end

-- Constraint the argument to the specified min/max
local function constrain( n, nMin, nMax )
    n = tonumber(n, 10) or nMin
    if n < nMin then return nMin end
    if nMax ~= nil and n > nMax then return nMax end
    return n
end

-- Convert F to C
local function FtoC( temp )
    temp = tonumber(temp, 10)
    assert( temp ~= nil )
    return ( temp - 32 ) * 5 / 9
end

-- Convert C to F
local function CtoF( temp )
    temp = tonumber(temp, 10)
    assert( temp ~= nil )
    return ( temp * 9 / 5 ) + 32
end

-- Get numeric variable, or return default value if not set or blank
local function getVarNumeric( name, dflt, dev, serviceId )
    assert(name ~= nil)
    assert(dev ~= nil)
    if serviceId == nil then serviceId = MYSID end
    local s = luup.variable_get(serviceId, name, dev)
    if (s == nil or s == "") then return dflt end
    s = tonumber(s, 10)
    if (s == nil) then return dflt end
    return s
end

-- Send a command
local function sendCommand( cmdString, pdev )
    D("sendCommand(%1,%2)", cmdString, pdev)
    assert(pdev ~= nil)
    if type(cmdString) == "table" then cmdString = table.concat( cmdString ) end
    lastCommand = cmdString
    local cmd = cmdString .. INTESIS_EOL
    if ( luup.io.write( cmd ) ~= true ) then
        L("Can't transmit, communication error while attempting to send %1", cmdString)
        luup.set_failure( 1, pdev )
        return false
    end
    return true
end

-- Handle an ID response
-- Ex. ID:IS-IR-WMP-1,001DC9A183E1,192.168.0.177,ASCII,v1.0.5,-51,TEST,N
local function handleID( unit, segs, pdev )
    D("handleID(%1,%2,%3)", unit, segs, pdev)
    local args
    luup.variable_set( MYSID, "IntesisID", segs[2], pdev )
    args = split( segs[2], "," )
    luup.variable_set( MYSID, "Name", args[7] or "", pdev )
    luup.variable_set( MYSID, "SignalDB", args[6] or "", pdev )
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
    local args, nArgs
    args, nArgs = split( string.upper( segs[2] ), "," )
    if args[1] == "ONOFF" then
        -- The on/off state is separate from mode in Intesis, but part of mode in the
        --   HVAC_UserOperatingMode1 service. See comments below on how we handle that.
        luup.variable_set( MYSID, "IntesisONOFF", args[2], pdev )
        if args[2] == "OFF" then
            -- Note we don't touch LastMode here!
            luup.variable_set( OPMODE_SID, "ModeTarget", MODE_OFF, pdev )
            luup.variable_set( OPMODE_SID, "ModeStatus", MODE_OFF, pdev )
        elseif args[2] == "ON" then
            -- When turning on, restore state of LastMode.
            local last = luup.variable_get( MYSID, "LastMode", pdev ) or MODE_AUTO
            luup.variable_set( OPMODE_SID, "ModeTarget", last, pdev )
            luup.variable_set( OPMODE_SID, "ModeStatus", last, pdev )
        else
            L("Invalid ONOFF state from device %1 in %2", args[2], msg)
        end
    elseif args[1] == "MODE" then
        if args[2] == nil then 
            L("Malformed CHN segment %2 function data missing in %3", args[1], msg)
            return
        end
        -- Store this for use by others, just to have available
        luup.variable_set( MYSID, "IntesisMODE", args[2], pdev )
        
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
        
        local xmap = { ["COOL"]=MODE_COOL, ["HEAT"]=MODE_HEAT, ["AUTO"]=MODE_AUTO }
        if xmap[args[2]] == nil then
            if args[2] == "FAN" then
                luup.variable_set( FANMODE_SID, "Mode", FANMODE_ON, pdev )
                luup.variable_set( FANMODE_SID, "FanStatus", "On", pdev )
            else
                -- Note specifically "DRY" is not supported
                L("Invalid MODE from device %1 in %2", args[2], msg)
            end
        else
            -- Save as LastMode, and conditionally ModeStatus (see comment block above).
            luup.variable_set( MYSID, "LastMode", xmap[args[2]], pdev )
            local currMode = luup.variable_get( OPMODE_SID, "ModeStatus", pdev ) or MODE_OFF
            if currMode ~= MODE_OFF then
                luup.variable_set( OPMODE_SID, "ModeTarget", xmap[args[2]], pdev )
                luup.variable_set( OPMODE_SID, "ModeStatus", xmap[args[2]], pdev )
            end
        end
    elseif args[1] == "SETPTEMP" then
        -- Store the setpoint temperature
        local ptemp = tonumber( args[2], 10 ) / 10
        if sysTemps.unit == "F" then
            ptemp = CtoF( ptemp )
        end
        luup.variable_set( SETPOINT_SID, "CurrentSetpoint", string.format( "%.0f", ptemp ), pdev )
    elseif args[1] == "AMBTEMP" then
        -- Store the current ambient temperature
        local ptemp = tonumber( args[2], 10 ) / 10 -- but, is it C or F?
        if sysTemps.unit == "F" then
            ptemp = CtoF( ptemp )
        end
        local dtemp = string.format( "%2.1f", ptemp )
        D("handleCHN() received AMBTEMP %1, current temp %2", args[2], dtemp)
        luup.variable_set( TEMPSENS_SID, "CurrentTemperature", dtemp, pdev )
        luup.variable_set( MYSID, "DisplayTemperature", dtemp, pdev )
    elseif args[1] == "FANSP" then
        --[[ Fan speed also doesn't have a 1-1 mapping with the service. So, we treat
             the Intesis AUTO status as "Unknown" (since we don't know if the fan is
             running or not, and how fast, and why). Otherwise, a specific fan speed
             is simply handled as an "On".
        --]]
        luup.variable_set( MYSID, "IntesisFANSP", args[2] or "", pdev )
        if args[2] == "AUTO" then
            luup.variable_set( FANMODE_SID, "Mode", FANMODE_AUTO, pdev )
            luup.variable_set( FANMODE_SID, "FanStatus", "Unknown", pdev ) -- Bummer.
            luup.variable_set( MYSID, "CurrentFanSpeed", "Auto", pdev ) -- our version
            -- Note that we don't set LastFanSpeed here, as we're tracking what isn't "Auto"
            luup.variable_set( MYSID, "DisplayFanStatus", "Auto", pdev )
        else
            local speed = tonumber( args[2], 10 )
            if speed == nil then return end
            luup.variable_set( FANMODE_SID, "Mode", FANMODE_ON, pdev )
            luup.variable_set( FANMODE_SID, "FanStatus", "On", pdev )
            luup.variable_set( MYSID, "CurrentFanSpeed", speed, pdev )
            luup.variable_set( MYSID, "LastFanSpeed", speed, pdev )
            luup.variable_set( MYSID, "DisplayFanStatus", string.format( "Speed %d", speed ) )
        end
    elseif args[1] == "VANEUD" then
        -- There's no analog in the service for vane position, so just store the data
        -- in case others want to use it.
        luup.variable_set( MYSID, "IntesisVANEUD", args[2] or "", pdev )
    elseif args[1] == "VANELR" then
        -- There's no analog in the service for vane position, so just store the data
        -- in case others want to use it.
        luup.variable_set( MYSID, "IntesisVANELR", args[2] or "", pdev )
    else
        L("Unhandled CHN function %1 in %2", args[1], msg)
    end
end

-- Handle LIMITS (we don't)
function handleLIMITS( unit, segs, pdev )
    D("handleLIMITS(%1,%2,%3)", unit, segs, pdev)
end

-- Handle ACK
function handleACK( unit, segs, pdev )
    D("handleACK(%1,%2,%3)", unit, segs, pdev)
    -- We've been heard; do nothing
    D("handMessage() ACK received, last command %1", lastCommand)
end

-- Handle ERR
function handleERR( unit, segs, pdev )
    D("handleERR(%1,%2,%3)", unit, segs, pdev)
    L("WMP device returned ERR after %1", lastCommand)
end

-- Handle CLOSE, the server signalling that it is closing the connection.
function handleCLOSE( unit, segs, pdev )
    D("handleCLOSE(%1,%2,%3)", unit, segs, pdev)
    L("DEVICE IS CLOSING CONNECTION!")
    -- luup.set_failure( 1, pdev ) -- no active failure, let future comm error signal it
end

-- Handle PONG response
function handlePONG( unit, segs, pdev )
    D("handlePONG(%1,%2,%3)", unit, segs, pdev)
    -- response to PING, returns signal strength?
    luup.variable_set( MYSID, "SignalDB", segs[2] or "", pdev )
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
    local mm, nSeg
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

--[[ OUT

-- Update the display status. We don't really bother with this at the moment because the WMP 
-- protocol doesn't tell us the running status of the unit (see comments at top of this file).
local function updateDisplayStatus( dev )
    luup.variable_set( MYSID, "", modeStatus, dev )
end

-- Handle variable change callback
function varChanged( dev, sid, var, oldVal, newVal )
    D("varChanged(%1,%2,%3,%4,%5) luup.device is %6", dev, sid, var, oldVal, newVal, luup.device)
    -- assert(var ~= nil) -- nil if service or device watch (can happen on openLuup)
    -- assert(luup.device ~= nil) -- fails on openLuup, have discussed with author but no fix forthcoming as of yet.
    updateDisplayStatus( dev )
end
--]]

-- Action for SetModeTarget -- change current operating mode
function actionSetModeTarget( dev, newMode )
    D("actionSetModeTarget(%1,%2)", dev, newMode)
    if newMode == nil or type(newMode) ~= "string" then return end
    local xmap = { [MODE_AUTO]="AUTO", [MODE_HEAT]="HEAT", [MODE_COOL]="COOL" }
    if newMode == MODE_OFF then
        if not sendCommand( "SET,1:ONOFF,OFF", dev ) then
            return false
        end
    elseif xmap[newMode] ~= nil then
        if not sendCommand( "SET,1:ONOFF,ON", dev ) then
            return false
        end
        if not sendCommand( "SET,1:MODE," .. xmap[newMode], dev ) then
            return false
        end
    else
        L("Invalid target mode passed in action: %1", newMode)
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

-- Set fan operating mode.
function actionSetFanMode( dev, newMode )
    D("actionSetFanMode(%1,%2)", dev, newMode)
    -- We just change the mode here; the variable trigger does the rest.
    if string.match("Auto:ContinuousOn:PeriodicOn:", newMode .. ":") then
        if newMode == FANMODE_AUTO then
            if not sendCommand("SET,1:FANSP,AUTO", dev ) then
                return false
            end
        elseif newMode == FANMODE_ON then
            -- Restore last known manual fan speed, if any, or default.
            local speed = getVarNumeric( "LastFanSpeed", 1, dev ) -- default??? LIMITS???
            if not sendCommand("SET,1:FANSP," .. speed, dev ) then
                return false
            end
        else
            L("Fan mode %1 not supported, ignored", newMode)
            return false
        end
        return true
    else
        L("Fan mode %1 invalid, ignored", newMode)
    end
    return false
end

-- Set fan speed. Empty/nil or 0 sets Auto.
function actionSetCurrentFanSpeed( dev, newSpeed )
    D("actionSetCurrentFanSpeed(%1,%2)", dev, newSpeed)
    newSpeed = tonumber( newSpeed, 10 ) or 0
    if newSpeed == 0 then 
        return actionSetFanMode( dev, FANMODE_AUTO )
    end
    newSpeed = constrain( newSpeed, 1, nil ) -- ??? high limit
    return sendCommand( "SET,1:FANSP," .. newSpeed, dev )
end

-- Speed up the fan (implies switch out of auto, presumably)
function actionFanSpeedUp( dev )
    D("actionFanSpeedUp(%1)", dev)
    local speed = getVarNumeric( "CurrentFanSpeed", 0, dev ) + 1
    return actionSetCurrentFanSpeed( dev, speed )
end

-- Speed up the fan (implies switch out of auto, presumably)
function actionFanSpeedDown( dev )
    D("actionFanSpeedDown(%1)", dev)
    local speed = getVarNumeric( "CurrentFanSpeed", 2, dev ) - 1
    return actionSetCurrentFanSpeed( dev, speed )
end

-- Action to change (TemperatureSetpoint1) setpoint.
function actionSetCurrentSetpoint( dev, newSP )
    D("actionSetCurrentSetpoint(%1,%2) system units %3", dev, newSP, sysTemps.unit)

    newSP = tonumber(newSP, 10)
    if newSP == nil then return end
    newSP = constrain( newSP, sysTemps.minimum, sysTemps.maximum )
    
    -- Convert to C if needed
    if sysTemps.unit == "F" then
        newSP = FtoC( newSP )
    end
    D("actionSetCurrentSetpoint() new target setpoint is %1C", newSP)

    luup.variable_set( SETPOINT_SID, "SetpointAchieved", "0", dev )
    return sendCommand("SET,1:SETPTEMP," .. string.format( "%.0f", newSP * 10 ), dev )
end

-- Action to change energy mode (not implemented).
function actionSetEnergyModeTarget( dev, newMode )
    -- Store the target, but don't change status, because nothing changes, and signal failure.
    luup.variable_set( OPMODE_SID, "EnergyModeTarget", newMode, dev )
    return false
end

-- Set the device name
function actionSetName( dev, newName )
    if not sendCommand( "CFG:DEVICENAME," .. string.upper( newName or "" ), dev ) then
        return false
    end
    return sendCommand( "ID", dev )
end

function plugin_requestHandler(lul_request, lul_parameters, lul_outputformat)
    local action = lul_parameters['command'] or "dump"
    if action == "debug" then
        debugMode = true
        return
    end
    
    local target = tonumber(lul_parameters['devnum']) or luup.device
    local n
    local html = string.format("lul_request=%q\n", lul_request)
    html = html .. ldump("lul_parameters", lul_parameters)
    html = html .. ldump("luup.device", luup.device)
    html = html .. ldump("_M", _M)
    html = html .. ldump(string.format("luup.device[%s]", target), luup.devices[target])
    if lul_parameters['names'] ~= nil then
        html = html .. "-- dumping additional: " .. lul_parameters['names'] .. "\n"
        local nlist = split(lul_parameters['names'])
        for _,n in ipairs(nlist) do
            html = html .. ldump(n, _G[n])
        end
    end
    html = html .. devdump(dev)
    return "<pre>" .. html .. "</pre>"
end

local function plugin_checkVersion(dev)
    assert(dev ~= nil)
    D("checkVersion() branch %1 major %2 minor %3, string %4, openLuup %5", luup.version_branch, luup.version_major, luup.version_minor, luup.version, isOpenLuup)
    if isOpenLuup or ( luup.version_branch == 1 and luup.version_major >= 7 ) then
        local v = luup.variable_get( MYSID, "UI7Check", dev )
        if v == nil then luup.variable_set( MYSID, "UI7Check", "true", dev ) end
        return true
    end
    return false
end

local function plugin_runOnce(dev)
    assert(dev ~= nil)
    local rev = getVarNumeric("Version", 0, dev)
    if (rev == 0) then
        -- Initialize for new installation
        D("runOnce() Performing first-time initialization!")
        luup.variable_set(MYSID, "Name", "", dev)
        luup.variable_set(MYSID, "SignalDB", "", dev)
        luup.variable_set(MYSID, "DisplayTemperature", "--.-", dev)
        luup.variable_set(MYSID, "DisplayFanStatus", "", dev)
        luup.variable_set(MYSID, "DisplayStatus", "", dev)
        luup.variable_set(MYSID, "PingInterval", DEFAULT_PING, dev)
        luup.variable_set(MYSID, "RefreshInterval", DEFAULT_REFRESH, dev)
        luup.variable_set(MYSID, "ConfigurationUnits", "C", dev)
        
        luup.variable_set(OPMODE_SID, "ModeTarget", MODE_OFF, dev)
        luup.variable_set(OPMODE_SID, "ModeStatus", MODE_OFF, dev)
        luup.variable_set(OPMODE_SID, "EnergyModeTarget", EMODE_NORMAL, dev)
        luup.variable_set(OPMODE_SID, "EnergyModeStatus", EMODE_NORMAL, dev)
        luup.variable_set(OPMODE_SID, "AutoMode", "1", dev)

        luup.variable_set(FANMODE_SID, "Mode", FANMODE_AUTO, dev)
        luup.variable_set(FANMODE_SID, "FanStatus", "Off", dev)

        -- luup.variable_set(SETPOINT_SID, "Application", "DualHeatingCooling", dev)
        luup.variable_set(SETPOINT_SID, "SetpointAchieved", "0", dev)
        if luup.attr_get("TemperatureFormat",0) == "C" then
            luup.variable_set(SETPOINT_SID, "CurrentSetpoint", "18", dev)
        else
            luup.variable_set(SETPOINT_SID, "CurrentSetpoint", "64", dev)
        end
        
        luup.variable_set(MYSID, "Version", _CONFIGVERSION, dev)
        return
    end
    
--[[ Future config revisions should compare the current revision number and apply
     changes incrementally. The code below is an example of how to handle.
     
    if rev < 010100 then
        D("runOnce() updating config for rev 010100")
        -- Future. This code fragment is provided to demonstrate method.
        -- Insert statements necessary to upgrade configuration for version number indicated in conditional.
        -- Go one version at a time (that is, one condition block for each version number change).
    end
--]]
    
    -- No matter what happens above, if our versions don't match, force that here/now.
    if (rev ~= _CONFIGVERSION) then
        luup.variable_set(MYSID, "Version", _CONFIGVERSION, dev)
    end
end

-- Schedule next timer tick
function plugin_scheduleTick( dly, stepStamp, dev, passthru )
    dly = tonumber( dly, 10 )
    assert(dly ~= nil)
    assert(dev ~= nil)
    assert(passthru == nil or type(passthru) == "string")
    dly = constrain( dly, 5, 7200 )
    luup.call_delay( "intesisTick", dly, table.concat( { stepStamp, dev, passthru or "" }, ":" ) )
end

function plugin_tick(targ)
    local pdev, stepStamp, passthru
    stepStamp,pdev,passthru = string.match( targ, "(%d+):(%d+):.*" ) 
    D("plugin_tick(%1) stepStamp %2, pdev %3, passthru %4", targ, stepStamp, pdev, passthru)
    pdev = tonumber( pdev, 10 )
    assert( pdev ~= nil and luup.devices[pdev] )
    stepStamp = tonumber( stepStamp, 10 )
    if stepStamp ~= runStamp[pdev] then 
        D("plugin_tick() got stepStamp %1, expected %2, another thread running, so exiting...", stepStamp, runStamp[pdev])
        return
    end

    -- Refresh or ping due? 
    local now = os.time()
    local intPing = getVarNumeric( "PingInterval", DEFAULT_PING, pdev )
    local intRefresh = getVarNumeric( "RefreshInterval", DEFAULT_REFRESH, pdev )
    if lastRefresh + intRefresh <= now then
        if not sendCommand("GET,1:*", pdev) then return end
        lastRefresh = now
        lastPing = now -- refresh is a proxy for ping (keep the link up, any message will do)
    end
    if lastPing + intPing <= now then
        if not sendCommand("PING", pdev) then return end
        lastPing = now
    end
    
    -- When do we tick next?
    local nextPing = lastPing + intPing
    local nextRefresh = lastRefresh + intRefresh
    local nextDelay
    if nextRefresh < nextPing then
        nextDelay = nextRefresh - now
    else
        nextDelay = nextPing - now
    end

    -- Arm for another query.
    plugin_scheduleTick( nextDelay, stepStamp, pdev, passthru )
end

-- Accept data on the socket. Simple protocol, just accumulate chars until CR and/or LF is seen.
function plugin_handleIncoming( pdev, iData )
    local ch = string.byte(iData)
    lastIncoming = os.time() -- or socket milliseconds? Not sure we need that much accuracy...
    
    if ch == 13 or ch == 10 then
        -- End of line
        if inBuffer ~= nil then
            handleMessage( table.concat(inBuffer), pdev )
            inBuffer = nil
        end
    else
        -- Capture the character
        if inBuffer == nil then
            inBuffer = {}
        end
        table.insert( inBuffer, iData )
    end
end

-- Start-up initialization for plug-in.
function plugin_init(dev)
    D("plugin_init(%1)", dev)
    L("starting version %1 for device %2 WMP device IP %3", _PLUGIN_VERSION, dev, luup.attr_get( "ip", dev ) or "NOT SET" )
    
    -- Check for ALTUI and OpenLuup
    local k,v
    for k,v in pairs(luup.devices) do
        if v.device_type == "urn:schemas-upnp-org:device:altui:1" then
            local rc,rs,jj,ra
            D("init() detected ALTUI at %1", k)
            isALTUI = true
            rc,rs,jj,ra = luup.call_action("urn:upnp-org:serviceId:altui1", "RegisterPlugin", 
                { newDeviceType=MYTYPE, newScriptFile="J_IntesisWMPGateway1_ALTUI.js", newDeviceDrawFunc="IntesisWMPGateway_ALTUI.DeviceDraw" }, 
                k )
            D("init() ALTUI's RegisterPlugin action returned resultCode=%1, resultString=%2, job=%3, returnArguments=%4", rc,rs,jj,ra)
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
    plugin_runOnce(dev)
    
    -- Connected?
    local ip = luup.attr_get( "ip", dev ) or ""
    if ip == "" then
        L("WMP device IP is not configured.")
        return false, "WMP device not configured", _PLUGIN_NAME
    elseif luup.io.is_connected( dev ) ~= true then
        L("WMP device not connected (ip=%1)", ip )
        luup.variable_set( MYSID, "DisplayTemperature", "Comm error", dev )
        return false, "WMP device " .. ip .. " not connected", _PLUGIN_NAME
    end
    
    -- Other inits
    runStamp[dev] = os.time()
    inBuffer = nil
    lastIncoming = 0
    lastCommand = nil
    lastRefresh = 0
    lastPing = 0
    
    --[[ Work out the system units, the user's desired display units, and the configuration units.
         The user's desire overrides the system configuration. This is an exception provided in
         case the user has a thermostat for which they want to operate in units other than the
         system configuration. If the target units and the config units don't comport, modify
         the interface configuration to use the target units and reload Luup. 
    --]]
    local sysUnits = luup.attr_get("TemperatureFormat", 0) or "C"
    local forceUnits = luup.variable_get( MYSID, "ForceUnits", dev ) or ""
    local cfUnits = luup.variable_get( MYSID, "ConfigurationUnits", dev ) or ""
	local targetUnits = sysUnits
	if forceUnits ~= "" then targetUnits = forceUnits end
    D("plugin_init() system units %1, configured units %2, target units %3.", sysUnits, cfUnits, targetUnits)
    if cfUnits ~= targetUnits then
        -- Reset configuration for temperature units configured.
        L("Reconfiguring from %2 to %1, which will require a Luup restart.", targetUnits, cfUnits)
        luup.attr_set( "device_json", "D_IntesisWMPGateway1_" .. targetUnits .. ".json", dev )
        luup.variable_set( MYSID, "ConfigurationUnits", targetUnits, dev )
        luup.reload()
    end
    if targetUnits == "C" then    
        sysTemps = { unit="C", default=21, minimum=16, maximum=32 }
    else
        sysTemps = { unit="F", default=70, minimum=60, maximum=90 }
    end

--[[ OUT -- See comments at top
    
    -- A few things we care to look at.
    -- luup.variable_watch( "intesisVarChanged", SETPOINT_SID, "CurrentSetpoint", dev )
    luup.variable_watch( "intesisVarChanged", OPMODE_SID, "ModeStatus", dev )
    luup.variable_watch( "intesisVarChanged", FANMODE_SID, "Mode", dev )
    luup.variable_watch( "intesisVarChanged", FANMODE_SID, "FanStatus", dev )
--]]
    
    -- Log in? --

    -- Send some initial requests for data...
    if not ( sendCommand( "ID", dev )  and sendCommand( "INFO", dev ) and sendCommand( "LIMITS:SETPTEMP", dev ) ) then
        L("Communication error at initialization, can't start.")
        luup.set_failure( 1, dev  )
        return false, "Device communication failure", _PLUGIN_NAME
    end
    
    -- Schedule our first tick.
    plugin_scheduleTick( 15, runStamp[dev], dev, "PHR" )
    
    L("Running!")
    luup.set_failure( 0, dev )
    return true, "OK", _PLUGIN_NAME
end

function plugin_getVersion()
    return _PLUGIN_VERSION, _PLUGIN_NAME, _CONFIGVERSION
end
