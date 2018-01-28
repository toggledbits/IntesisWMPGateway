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
if luup == nil then luup = {} end -- for lint/check

module("L_IntesisWMPGateway1", package.seeall)

local _PLUGIN_NAME = "IntesisWMPGateway"
local _PLUGIN_VERSION = "1.0"
local _CONFIGVERSION = 010000

local debugMode = false
local traceMode = false

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
local MODE_FAN = "FanOnly"
local MODE_DRY = "Dry"

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
local isConnected = false

local runStamp = {}
local sysTemps = { unit="C", default=20, minimum=16, maximum=32 }

local isALTUI = false
local isOpenLuup = false

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
    -- if traceMode then trace('log',str) end
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

local function max( a, b )
    if a > b then return a end
    return b
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
        isConnected = false
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
            luup.variable_set( FANMODE_SID, "FanStatus", "Off", pdev )
        elseif args[2] == "ON" then
            -- When turning on, restore state of LastMode.
            local last = luup.variable_get( MYSID, "LastMode", pdev ) or MODE_AUTO
            luup.variable_set( OPMODE_SID, "ModeTarget", last, pdev )
            luup.variable_set( OPMODE_SID, "ModeStatus", last, pdev )
            if last == MODE_FAN then
                luup.variable_set( FANMODE_SID, "FanStatus", "On", pdev )
            else
                luup.variable_set( FANMODE_SID, "FanStatus", "Unknown", pdev )
            end
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

        local xmap = { ["COOL"]=MODE_COOL, ["HEAT"]=MODE_HEAT, ["AUTO"]=MODE_AUTO, ["FAN"]=MODE_FAN, ["DRY"]=MODE_DRY }
        -- Save as LastMode, and conditionally ModeStatus (see comment block above).
        local newMode = xmap[args[2]]
        if newMode == nil then 
            L("*** UNEXPECTED MODE '%1' RETURNED FROM WMP GATEWAY, IGNORED", args[2])
            return
        end
        luup.variable_set( MYSID, "LastMode", newMode, pdev )
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
        -- Store the setpoint temperature
        local ptemp = tonumber( args[2], 10 ) / 10
        if sysTemps.unit == "F" then
            ptemp = CtoF( ptemp )
        end
        D("handleCHN() received SETPTEMP %1, setpoint now %2", args[2], ptemp)
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
        -- Fan speed also doesn't have a 1-1 mapping with the service. Just track it.
        luup.variable_set( MYSID, "IntesisFANSP", args[2] or "", pdev )
    elseif args[1] == "VANEUD" then
        -- There's no analog in the service for vane position, so just store the data
        -- in case others want to use it.
        luup.variable_set( MYSID, "IntesisVANEUD", args[2] or "", pdev )
    elseif args[1] == "VANELR" then
        -- There's no analog in the service for vane position, so just store the data
        -- in case others want to use it.
        luup.variable_set( MYSID, "IntesisVANELR", args[2] or "", pdev )
    elseif args[1] == "ERRSTATUS" then
        -- Should be OK or ERR. Track.
        luup.variable_set( MYSID, "IntesisERRSTATUS", args[2] or "", pdev )
    elseif args[1] == "ERRCODE" then
        -- Values are dependent on the connected device. Track.
        luup.variable_set( MYSID, "IntesisERRCODE", args[2] or "", pdev )
    else
        D("handleCHN() unhandled function %1 in %2", args[1], msg)
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
    -- isConnected = false
end

-- Handle PONG response
function handlePONG( unit, segs, pdev )
    D("handlePONG(%1,%2,%3)", unit, segs, pdev)
    -- response to PING, returns signal strength
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

-- Update the display status. We don't really bother with this at the moment because the WMP
-- protocol doesn't tell us the running status of the unit (see comments at top of this file).
local function updateDisplayStatus( dev )
    local msg = "&nbsp;"
    if not isConnected then
        luup.variable_set( MYSID, "DisplayTemperature", "??.?", dev )
        msg = "Comm Fail"
    else
        local errst = luup.variable_get( MYSID, "IntesisERRSTATUS", dev ) or "OK"
        if errst ~= "OK" then
            local errc = luup.variable_get( MYSID, "IntesisERRCODE", dev ) or ""
            msg = string.format( "%s %s", errst, errc )
        end
    end
    luup.variable_set( MYSID, "DisplayStatus", msg, dev )
end

-- Handle variable change callback
function varChanged( dev, sid, var, oldVal, newVal )
    D("varChanged(%1,%2,%3,%4,%5) luup.device is %6", dev, sid, var, oldVal, newVal, luup.device)
    -- assert(var ~= nil) -- nil if service or device watch (can happen on openLuup)
    -- assert(luup.device ~= nil) -- fails on openLuup, have discussed with author but no fix forthcoming as of yet.
    updateDisplayStatus( dev )
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

-- Set fan operating mode (ignored)
function actionSetFanMode( dev, newMode )
    D("actionSetFanMode(%1,%2)", dev, newMode)
    return false
end

-- Set fan speed. Empty/nil or 0 sets Auto.
function actionSetCurrentFanSpeed( dev, newSpeed )
    D("actionSetCurrentFanSpeed(%1,%2)", dev, newSpeed)
    newSpeed = tonumber( newSpeed, 10 ) or 0
    if newSpeed == 0 then
        return sendCommand( "SET,1:FANSP,AUTO", dev )
    end
    newSpeed = constrain( newSpeed, 1, nil ) -- ??? high limit
    return sendCommand( "SET,1:FANSP," .. newSpeed, dev )
end

-- Speed up the fan (implies switch out of auto, presumably)
function actionFanSpeedUp( dev )
    D("actionFanSpeedUp(%1)", dev)
    local speed = getVarNumeric( "IntesisFANSP", 0, dev ) + 1
    return actionSetCurrentFanSpeed( dev, speed )
end

-- Speed up the fan (implies switch out of auto, presumably)
function actionFanSpeedDown( dev )
    D("actionFanSpeedDown(%1)", dev)
    local speed = getVarNumeric( "IntesisFANSP", 2, dev ) - 1
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
    if newPos == nil or string.upper(newPos) == "AUTO" then newPos = "AUTO" end
    if newPos ~= "AUTO" then
        newPos = tonumber( newPos, 10 )
        if newPos == nil then
            return false
        end
        if newPos == 0 then
            newPos = "AUTO"
        else
            newPos = constrain( newPos, 1, 9 ) -- LIMITS???
        end
    end
    return sendCommand( "SET,1:VANEUD," .. tostring(newPos), dev )
end

-- Set vane up (relative)
function actionVaneUp( dev )
    D("actionVaneUp(%1)", dev )
    local pos = getVarNumeric( "IntesisVANEUD", 0, dev, MYSID )
    pos = constrain( pos - 1, 1, 9 )
    return actionSetVaneUD( dev, pos )
end

-- Set vane down (relative)
function actionVaneDown( dev )
    D("actionVaneDown(%1)", dev )
    local pos = getVarNumeric( "IntesisVANEUD", 0, dev, MYSID )
    pos = constrain( pos + 1, 1, 9 )
    return actionSetVaneUD( dev, pos )
end

-- Set vane (left/right) position.
function actionSetVaneLR( dev, newPos )
    D("actionSetVaneLR(%1,%2)", dev, newPos)
    if newPos == nil or string.upper(newPos) == "AUTO" then newPos = "AUTO" end
    if newPos ~= "AUTO" then
        newPos = tonumber( newPos, 10 )
        if newPos == nil then
            return false
        end
        if newPos == 0 then
            newPos = "AUTO"
        else
            newPos = constrain( newPos, 1, 9 ) -- ??? LIMITS
        end
    end
    return sendCommand( "SET,1:VANELR," .. tostring(newPos), dev )
end

-- Vane left
function actionVaneLeft( dev )
    D("actionVaneLeft(%1)", dev )
    local pos = getVarNumeric( "IntesisVANELR", 0, dev, MYSID )
    pos = constrain( pos - 1, 1, 9 )
    return actionSetVaneLR( dev, pos )
end

-- Vane right
function actionVaneRight( dev )
    D("actionVaneDown(%1)", dev )
    local pos = getVarNumeric( "IntesisVANELR", 0, dev, MYSID )
    pos = constrain( pos + 1, 1, 9 )
    return actionSetVaneLR( dev, pos )
end

-- Set the device name
function actionSetName( dev, newName )
    if not sendCommand( "CFG:DEVICENAME," .. string.upper( newName or "" ), dev ) then
        return false
    end
    return sendCommand( "ID", dev )
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

function plugin_requestHandler(lul_request, lul_parameters, lul_outputformat)
    D("plugin_requestHandler(%1,%2,%3)", lul_request, lul_parameters, lul_outputformat)
    local action = lul_parameters['command'] or "status"
    if action == "debug" then
        debugMode = not debugMode
    end
    if action == "ISS" then
        -- ImperiHome ISS Standard System API, see http://dev.evertygo.com/api/iss#types
        local dkjson = require('dkjson')
        local path = lul_parameters['path'] or "/devices"
        if path == "/system" then
            return dkjson.encode( { id="IntesisWMPGateway-" .. luup.pk_accesspoint, apiversion=1 } ), "application/json"
        elseif path == "/rooms" then
            local roomlist = { { id=0, name="No Room" } }
            local rn,rr
            for rn,rr in pairs( luup.rooms ) do 
                table.insert( roomlist, { id=rn, name=rr } )
            end
            return dkjson.encode( { rooms=roomlist } ), "application/json"
        elseif path == "/devices" then
            local devices = {}
            local lnum,ldev
            for lnum,ldev in pairs( luup.devices ) do
                if ldev.device_type == MYTYPE then
                    local issinfo = {}
                    table.insert( issinfo, issKeyVal( "curmode", map( { Off="Off",HeatOn="Heat",CoolOn="Cool",AutoChangeOver="Auto",Dry="Dry",FanOnly="Fan" }, luup.variable_get( OPMODE_SID, "ModeStatus", lnum ), "Off" ) ) )
                    table.insert( issinfo, issKeyVal( "curfanmode", map( { Auto="Auto",ContinuousOn="On",PeriodicOn="Periodic" }, luup.variable_get(FANMODE_SID, "Mode", lnum), "Auto" ) ) )
                    table.insert( issinfo, issKeyVal( "curtemp", luup.variable_get( TEMPSENS_SID, "CurrentTemperature", lnum ), { unit="°" .. sysTemps.unit } ) )
                    table.insert( issinfo, issKeyVal( "cursetpoint", getVarNumeric( "CurrentSetpoint", sysTemps.default, lnum, SETPOINT_SID ) ) )
                    table.insert( issinfo, issKeyVal( "step", 0.5 ) )
                    table.insert( issinfo, issKeyVal( "minVal", sysTemps.minimum ) )
                    table.insert( issinfo, issKeyVal( "maxVal", sysTemps.maximum ) )
                    table.insert( issinfo, issKeyVal( "availablemodes", "Off,Heat,Cool,Auto,Fan,Dry" ) )
                    table.insert( issinfo, issKeyVal( "availablefanmodes", "Auto" ) )
                    local dev = { id=tostring(lnum), 
                        name=ldev.description or ("#" .. lnum), 
                        ["type"]="DevThermostat", 
                        defaultIcon="https://www.toggledbits.com/intesis/assets/wmp_mode_auto.png",
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
                D("plugin_requestHandler(): don't know how to handle ISS response for %1", path)
                return false
            end
        end
    end

    -- Default, respond with status info.
    local status = {
        name=_PLUGIN_NAME,
        version=_PLUGIN_VERSION,
        config=_CONFIGVERSION,
        device=luup.device,
        ['debug']=debugMode,
        ['trace']=traceMode or false,
    }
    local dkjson = require('dkjson')
    return dkjson.encode( status ), "application/json"
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
        luup.variable_set(MYSID, "DisplayStatus", "", dev)
        luup.variable_set(MYSID, "PingInterval", DEFAULT_PING, dev)
        luup.variable_set(MYSID, "RefreshInterval", DEFAULT_REFRESH, dev)
        luup.variable_set(MYSID, "ConfigurationUnits", "C", dev)
        luup.variable_set(MYSID, "IntesisONOFF", "", dev)
        luup.variable_set(MYSID, "IntesisMODE", "", dev)
        luup.variable_set(MYSID, "IntesisFANSP", "", dev)
        luup.variable_set(MYSID, "IntesisVANEUD", "", dev)
        luup.variable_set(MYSID, "IntesisVANELR", "", dev)
        luup.variable_set(MYSID, "IntesisERRSTATUS", "", dev)
        luup.variable_set(MYSID, "IntesisERRCODE", "", dev)
        
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
    stepStamp,pdev,passthru = string.match( targ, "(%d+):(%d+):(.*)" )
    D("plugin_tick(%1) stepStamp %2, pdev %3, passthru %4", targ, stepStamp, pdev, passthru)
    pdev = tonumber( pdev, 10 )
    assert( pdev ~= nil and luup.devices[pdev] )
    stepStamp = tonumber( stepStamp, 10 )
    if stepStamp ~= runStamp[pdev] then
        D("plugin_tick() got stepStamp %1, expected %2, another thread running, so exiting...", stepStamp, runStamp[pdev])
        return
    end

    local now = os.time()
    local intPing = getVarNumeric( "PingInterval", DEFAULT_PING, pdev )
    local intRefresh = getVarNumeric( "RefreshInterval", DEFAULT_REFRESH, pdev )
    
    -- If it's been more than two refresh intervals or three pings since we
    -- received some data, we may be in trouble...
    if isConnected and ( (now - lastIncoming) >= max( 2 * intRefresh, 3 * intPing ) ) then
        L("Gateway receive timeout; marking disconnected!")
        isConnected = false
        updateDisplayStatus( pdev )
    else
        isConnected = true
    end

    -- Refresh or ping due?
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

    -- Other inits
    runStamp[dev] = os.time()
    inBuffer = nil
    lastIncoming = 0
    lastCommand = nil
    lastRefresh = 0
    lastPing = 0
    isConnected = true -- automatic by Luup in this configuration
    
    luup.variable_set( MYSID, "DisplayStatus", "", dev )
    
    -- Connect?
    local ip = luup.attr_get( "ip", dev ) or ""
    if ip == "" then
        L("WMP device IP is not configured.")
        luup.variable_set( MYSID, "DisplayStatus", "Not configured", dev )
        return false, "WMP device not configured", _PLUGIN_NAME
    end

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
    if targetUnits == "F" then
        sysTemps = { unit="F", default=70, minimum=60, maximum=90 }
    else
        sysTemps = { unit="C", default=21, minimum=16, maximum=32 }
    end

    -- A few things we care to keep an eye on.
    luup.variable_watch( "intesisVarChanged", MYSID, "IntesisERRSTATUS", dev )
    luup.variable_watch( "intesisVarChanged", MYSID, "IntesisERRCODE", dev )
    luup.variable_watch( "intesisVarChanged", SETPOINT_SID, "CurrentSetpoint", dev )
    luup.variable_watch( "intesisVarChanged", TEMPSENS_SID, "CurrentTemperature", dev )

    -- Log in? Later. --

    -- Send some initial requests for data...
    if not ( sendCommand( "ID", dev )  and sendCommand( "INFO", dev ) and sendCommand( "LIMITS:SETPTEMP", dev ) ) then
        L("Communication error at initialization, can't start.")
        luup.set_failure( 1, dev  )
        return false, "Device communication failure", _PLUGIN_NAME
    end

    -- Schedule our first tick.
    plugin_scheduleTick( 15, runStamp[dev], dev )

    L("Running!")
    luup.set_failure( 0, dev )
    return true, "OK", _PLUGIN_NAME
end

function plugin_getVersion()
    return _PLUGIN_VERSION, _PLUGIN_NAME, _CONFIGVERSION
end
