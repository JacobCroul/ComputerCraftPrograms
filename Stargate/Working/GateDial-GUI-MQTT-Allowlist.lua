--[[
==========================================
  STARGATE DIALING COMPUTER v6.0
  Allowlist edition: only dials gates the
  server says this computer may dial
==========================================
]]

-- ============================================
-- CONFIGURATION
-- ============================================
-- The one place to point this computer at the API: host or IP and port, no http://
local API_HOST = "127.0.0.1:5006"

local CONFIG = {
    STARGATE_NAME = "Earth",  -- Name of this Stargate. Its address is kept by the API, set it on /admin
    API_URL = "http://" .. API_HOST .. "/api",
    API_STATUS_URL = "http://" .. API_HOST .. "/api/status",
    WS_URL = "ws://" .. API_HOST .. "/ws",  -- Gate name appended at runtime
    PERMISSIONS_URL = "http://" .. API_HOST .. "/api/permissions",  -- Gate name appended at runtime
    PERMISSIONS_CACHE = "permissions.cache",  -- Last rules received, survives reboots
    PERMISSIONS_REFRESH = 60,  -- Seconds between HTTP refreshes (the websocket push is the main path)
    API_ENABLED = true,
    DEBUG_MODE = true
}

-- Everything dialable comes from the permission list the server sends. Until
-- one has been received (or loaded from the cache) this gate dials nothing.
local DESTINATIONS = {}  -- name -> address table, permitted gates only
local DESTINATION_ADDRESSES = {}  -- "1,2,3,4,5,6,0" -> name, for checking raw addresses
local ALLOW_CUSTOM_ADDRESS = false  -- true lets a typed-in address through
local permissionsLoaded = false
local lastPermissionsAttempt = 0  -- Last time we tried the HTTP refresh

-- Shared WebSocket connection (set by wsLoop, used by reportStatusToAPI)
local wsConnection = nil

-- Pushes one live feedback line to the server's feedback sensor. Lightweight
-- on purpose, no HTTP fallback, if the WS is down the line is just dropped,
-- it's a live feed rather than something that needs to persist.
local function reportLogToAPI(message)
    if not CONFIG.API_ENABLED or not wsConnection then
        return
    end

    local payload = textutils.serializeJSON({
        type    = "log",
        gate    = CONFIG.STARGATE_NAME,
        message = message,
    })
    pcall(wsConnection.send, payload)
end

-- ============================================
-- GLOBALS & STATE
-- ============================================
local monitor = nil
local interface = nil

local state = {
    gateType = "Unknown",
    interfaceType = "Unknown",
    hasIris = false,
    irisClosed = false,
    irisProgress = 0,  -- NEW
    status = "Initializing...",
    chevrons = {false, false, false, false, false, false, false, false, false},
    energy = 0,
    energyMax = 1,
    connectedAddress = nil,
    dialing = false,
    incoming = false
}

local eventLog = {}
local currentScreen = "main"

-- ============================================
-- UTILITY FUNCTIONS
-- ============================================

local function log(message, color)
    local timestamp = textutils.formatTime(os.time(), true)
    local entry = {
        time = timestamp,
        message = message,
        color = color or colors.white
    }
    
    table.insert(eventLog, 1, entry)
    if #eventLog > 7 then
        table.remove(eventLog)
    end
    
    if CONFIG.DEBUG_MODE then
        print("[" .. timestamp .. "] " .. message)
    end

    reportLogToAPI(timestamp .. " " .. message)
end

local function hasMethod(obj, methodName)
    if obj == nil then 
        return false 
    end
    return type(obj[methodName]) == "function"
end

-- ============================================
-- API STATUS REPORTING
-- ============================================

local function reportStatusToAPI()
    if not CONFIG.API_ENABLED then 
        return 
    end
    
    -- This gate's own address is not reported: the API owns every address
    
    -- What we're DIALING or CONNECTED TO
    local dialedAddressStr = ""
    
    if state.dialing and state.currentDialingAddress then
        -- We're dialing - report destination
        if type(state.currentDialingAddress) == "table" then
            dialedAddressStr = table.concat(state.currentDialingAddress, ",")
        end
        
    elseif state.status == "CONNECTED" and state.connectedAddress then
        -- We're connected - report who we're connected to
        if type(state.connectedAddress) == "table" then
            dialedAddressStr = table.concat(state.connectedAddress, ",")
        elseif type(state.connectedAddress) == "string" then
            dialedAddressStr = state.connectedAddress
        end
    end
    
    -- Determine status string for API
    local apiStatus = "idle"
    if state.status == "CONNECTED" then
        apiStatus = "connected"
    elseif state.status == "DIALING..." then
        apiStatus = "dialing"
    elseif state.status == "INCOMING WORMHOLE" then
        apiStatus = "incoming"
    else
        apiStatus = "idle"
    end
    
    -- Determine iris state
    local irisState = "unknown"
    if state.hasIris then
        if state.irisClosed then
            irisState = "closed"
        else
            irisState = "open"
        end
    else
        irisState = "n/a"
    end
    
    -- Count locked chevrons - use REAL interface method if available
    local lockedCount = 0
    
    if hasMethod(interface, "getChevronsEngaged") then
        lockedCount = interface.getChevronsEngaged() or 0
    else
        -- Fallback: count from our state tracking
        for i = 1, 9 do
            if state.chevrons[i] then
                lockedCount = lockedCount + 1
            end
        end
    end
    
    -- Build query parameters (this gate's own address is the API's job)
    local queryParams = string.format(
        "?gate=%s&dialed_address=%s&status=%s&iris=%s&locked_chevrons=%d",
        textutils.urlEncode(CONFIG.STARGATE_NAME),
        textutils.urlEncode(dialedAddressStr),        -- What we're dialing/connected to
        textutils.urlEncode(apiStatus),
        textutils.urlEncode(irisState),
        lockedCount
    )
    
    -- === WebSocket (primary) ===
    -- Send status over WS if connected — fast and avoids an extra HTTP round-trip
    if wsConnection then
        local wsPayload = textutils.serializeJSON({
            type            = "status",
            gate            = CONFIG.STARGATE_NAME,
            dialed_address  = dialedAddressStr,
            status          = apiStatus,
            iris            = irisState,
            locked_chevrons = lockedCount,
        })
        local ok, err = pcall(wsConnection.send, wsPayload)
        if ok then
            return true
        else
            -- WS send failed — connection probably dropped; wsLoop will reconnect
            if CONFIG.DEBUG_MODE then
                print("[WS] Status send failed, falling back to HTTP: " .. tostring(err))
            end
            wsConnection = nil
        end
    end

    -- === HTTP fallback (used when WS is not connected) ===
    local fullURL = CONFIG.API_STATUS_URL .. queryParams
    local ok, response = pcall(http.post, fullURL, "")
    
    if ok and response then
        response.close()
        return true
    else
        if CONFIG.DEBUG_MODE then
            print("[API STATUS] Report failed: " .. tostring(response))
        end
        return false
    end
end

-- ============================================
-- PERMISSIONS (which gates this computer may dial)
-- ============================================
-- The server owns the rules. They arrive as a websocket push (on connect and
-- whenever the admin edits them), with an HTTP fetch as a backup, and are
-- cached to disk so a reboot while the API is down still has the last known
-- list. Addresses are compared in one normalised form, "1,2,3,4,5,6,0".

local function addressKey(address)
    local parts = {}
    if type(address) == "table" then
        for _, v in ipairs(address) do
            local n = tonumber(v)
            if not n then return nil end
            parts[#parts + 1] = tostring(math.floor(n))
        end
    elseif type(address) == "string" then
        for piece in string.gmatch(address, "[^,%-%s]+") do
            local n = tonumber(piece)
            if not n then return nil end
            parts[#parts + 1] = tostring(math.floor(n))
        end
    else
        return nil
    end
    if #parts == 0 then return nil end
    return table.concat(parts, ",")
end

local function parseAddress(str)
    local t = {}
    for piece in string.gmatch(str, "[^,%-%s]+") do
        local n = tonumber(piece)
        if not n then return nil end
        t[#t + 1] = n
    end
    if #t == 0 then return nil end
    return t
end

local function countDestinations()
    local n = 0
    for _ in pairs(DESTINATIONS) do
        n = n + 1
    end
    return n
end

-- Stable, alphabetical order so what the GUI draws and what a tap resolves to
-- can never disagree, even if a new list arrives in between.
local function sortedDestinations()
    local list = {}
    for name, address in pairs(DESTINATIONS) do
        list[#list + 1] = {name = name, address = address}
    end
    table.sort(list, function(a, b)
        return string.lower(a.name) < string.lower(b.name)
    end)
    return list
end

local function applyPermissions(data)
    if type(data) ~= "table" or type(data.allowed) ~= "table" then
        return false
    end

    local dests, byAddress = {}, {}
    for _, entry in ipairs(data.allowed) do
        if type(entry) == "table" and type(entry.name) == "string" and type(entry.address) == "string" then
            local addr = parseAddress(entry.address)
            if addr and string.lower(entry.name) ~= string.lower(CONFIG.STARGATE_NAME) then
                dests[entry.name] = addr
                byAddress[addressKey(addr)] = entry.name
            end
        end
    end

    DESTINATIONS = dests
    DESTINATION_ADDRESSES = byAddress
    ALLOW_CUSTOM_ADDRESS = (data.allow_custom_address == true)
    permissionsLoaded = true
    return true
end

-- Returns true (plus the destination's name) if this address may be dialed,
-- otherwise false and a reason. Every dial path goes through this.
local function isDialAllowed(address)
    if not permissionsLoaded then
        return false, "permissions not received yet"
    end

    local key = addressKey(address)
    if not key then
        return false, "invalid address"
    end

    if DESTINATION_ADDRESSES[key] then
        return true, DESTINATION_ADDRESSES[key]
    end
    if ALLOW_CUSTOM_ADDRESS then
        return true, "custom address"
    end
    return false, "address is not on this gate's permitted list"
end

local function savePermissionsCache(data)
    local ok, err = pcall(function()
        local f = fs.open(CONFIG.PERMISSIONS_CACHE, "w")
        if not f then
            error("cannot open " .. CONFIG.PERMISSIONS_CACHE)
        end
        f.write(textutils.serializeJSON(data))
        f.close()
    end)
    if not ok and CONFIG.DEBUG_MODE then
        print("[PERMS] Cache write failed: " .. tostring(err))
    end
end

local function loadPermissionsCache()
    if not fs.exists(CONFIG.PERMISSIONS_CACHE) then
        return false
    end
    local f = fs.open(CONFIG.PERMISSIONS_CACHE, "r")
    if not f then
        return false
    end
    local body = f.readAll()
    f.close()

    local ok, data = pcall(textutils.unserializeJSON, body)
    return ok and applyPermissions(data) or false
end

local function fetchPermissionsFromAPI()
    if not CONFIG.API_ENABLED then
        return false
    end

    local url = CONFIG.PERMISSIONS_URL .. "/" .. textutils.urlEncode(CONFIG.STARGATE_NAME)
    local ok, response = pcall(http.get, url)

    if ok and response then
        local body = response.readAll()
        response.close()

        local parseOk, data = pcall(textutils.unserializeJSON, body)
        if parseOk and applyPermissions(data) then
            savePermissionsCache(data)
            if CONFIG.DEBUG_MODE then
                print("[PERMS] Loaded " .. countDestinations() .. " permitted destinations")
            end
            return true
        end

        if CONFIG.DEBUG_MODE then
            print("[PERMS] Bad permissions response")
        end
        return false
    end

    if CONFIG.DEBUG_MODE then
        print("[PERMS] Fetch failed: " .. tostring(response))
    end
    return false
end

-- ============================================
-- HARDWARE DETECTION
-- ============================================

local function refreshPeripherals()
    interface = nil
    monitor = nil
    
    monitor = peripheral.find("monitor")
    if not monitor then
        error("[FATAL] No monitor found!")
    end
    
    monitor.setTextScale(0.5)
    monitor.setBackgroundColor(colors.black)
    monitor.setTextColor(colors.white)
    monitor.clear()
    
    local interfaceTypes = {
        "advanced_crystal_interface",
        "crystal_interface", 
        "basic_interface"
    }
    
    for _, iType in ipairs(interfaceTypes) do
        local found = peripheral.find(iType)
        if found then
            interface = found
            state.interfaceType = iType
            log("Found: " .. iType, colors.green)
            return true
        end
    end
    
    error("[FATAL] No Stargate interface found!")
end

local function detectGateType()
    if hasMethod(interface, "getStargateType") then
        state.gateType = interface.getStargateType() or "Unknown"
    elseif hasMethod(interface, "getVariant") then
        state.gateType = interface.getVariant() or "Unknown"
    else
        if state.interfaceType == "basic_interface" then
            state.gateType = "Milky Way"
        else
            state.gateType = "Universe/Pegasus"
        end
    end
    
    log("Gate Type: " .. state.gateType, colors.cyan)
end

local function detectIris()
    state.hasIris = hasMethod(interface, "getIrisProgress") or
                    hasMethod(interface, "closeIris") or 
                    hasMethod(interface, "openIris")
    
    if state.hasIris then
        log("Iris: DETECTED", colors.green)
        
        -- Get initial iris state
        if hasMethod(interface, "getIrisProgress") then
            local progress = interface.getIrisProgress()
            state.irisProgress = progress or 0
            
            if progress == 0 then
                state.irisClosed = false
                log("Iris state: OPEN", colors.green)
            elseif progress == 58 then
                state.irisClosed = true
                log("Iris state: CLOSED", colors.red)
            else
                state.irisClosed = (progress > 29)
                log("Iris state: MOVING (" .. progress .. "/58)", colors.yellow)
            end
        end
    else
        log("Iris: NOT FOUND", colors.yellow)
        state.irisProgress = 0
    end
end

local function listAvailableMethods()
    if not CONFIG.DEBUG_MODE then 
        return 
    end
    
    local methods = peripheral.getMethods(peripheral.getName(interface))
    
    print("\n========== INTERFACE METHODS ==========")
    for i, method in ipairs(methods) do
        print(string.format("%2d. %s", i, method))
    end
    print("========================================\n")
end

local function selfCheck()
    log("=== SELF-CHECK START ===", colors.yellow)
    
    refreshPeripherals()
    detectGateType()
    detectIris()
    listAvailableMethods()
    
    -- Start from the cached rules so a reboot with the API down still works
    if loadPermissionsCache() then
        log("Cached permissions: " .. countDestinations() .. " destinations", colors.cyan)
    else
        log("No cached permissions, dialing locked", colors.yellow)
    end

    -- Register with API, then ask what we are allowed to dial
    if CONFIG.API_ENABLED then
        log("Registering with API...", colors.cyan)
        reportStatusToAPI()
        log("Fetching permissions...", colors.cyan)
        if fetchPermissionsFromAPI() then
            log("Permissions synced: " .. countDestinations() .. " destinations", colors.green)
        else
            log("Permissions fetch failed, using cache", colors.yellow)
        end
        lastPermissionsAttempt = os.clock()
    end
    
    log("=== SELF-CHECK COMPLETE ===", colors.green)
    state.status = "Idle"
    os.sleep(2)
end

-- ============================================
-- STARGATE STATUS MONITORING
-- ============================================

local function updateEnergy()
    state.energy = 0
    state.energyMax = 1
    
    if not hasMethod(interface, "getEnergy") then
        return
    end
    
    local currentEnergy = interface.getEnergy()
    
    if currentEnergy == nil then
        return
    end
    
    state.energy = currentEnergy
    
    -- Try to find max energy - try all possible methods
    local maxEnergy = nil
    
    if hasMethod(interface, "getEnergyCapacity") then
        maxEnergy = interface.getEnergyCapacity()
        if CONFIG.DEBUG_MODE then
            print("Energy method: getEnergyCapacity() = " .. tostring(maxEnergy))
        end
    end
    
    if maxEnergy == nil and hasMethod(interface, "getMaxEnergy") then
        maxEnergy = interface.getMaxEnergy()
        if CONFIG.DEBUG_MODE then
            print("Energy method: getMaxEnergy() = " .. tostring(maxEnergy))
        end
    end
    
    if maxEnergy == nil and hasMethod(interface, "getEnergyTarget") then
        maxEnergy = interface.getEnergyTarget()
        if CONFIG.DEBUG_MODE then
            print("Energy method: getEnergyTarget() = " .. tostring(maxEnergy))
        end
    end
    
    -- If we still don't have max, use a sensible default
    if maxEnergy == nil or maxEnergy <= 0 then
        maxEnergy = currentEnergy  -- Assume we're at full
        if CONFIG.DEBUG_MODE then
            print("Energy method: Using current as max")
        end
    end
    
    state.energyMax = maxEnergy
    
    -- Debug output
    if CONFIG.DEBUG_MODE then
        print("Current Energy: " .. state.energy)
        print("Max Energy: " .. state.energyMax)
        print("Percentage: " .. math.floor((state.energy / state.energyMax) * 100) .. "%")
    end
end

local function updateGateStatus()
    local testInterface = peripheral.find(state.interfaceType)
    if testInterface ~= nil then
        interface = testInterface
    end
    
    updateEnergy()
    
    local isConnected = hasMethod(interface, "isStargateConnected") and interface.isStargateConnected()
    
    local isDialing = (hasMethod(interface, "isDialingOut") and interface.isDialingOut()) or
                      (hasMethod(interface, "isStargateDialingOut") and interface.isStargateDialingOut())
    
    local isWormholeOpen = hasMethod(interface, "isWormholeOpen") and interface.isWormholeOpen()
    
    if isConnected then
        state.status = "CONNECTED"
        
        if hasMethod(interface, "getDialedAddress") then
            state.connectedAddress = interface.getDialedAddress()
        elseif hasMethod(interface, "getConnectedAddress") then
            state.connectedAddress = interface.getConnectedAddress()
        end
        
    elseif isDialing then
        state.status = "DIALING..."
        
    elseif isWormholeOpen and not isConnected then
        state.status = "INCOMING WORMHOLE"
        state.incoming = true
        
    else
        state.status = "IDLE"
        state.connectedAddress = nil
        state.incoming = false
        
        if not state.dialing then
            for i = 1, 9 do
                state.chevrons[i] = false
            end
        end
    end
    
    -- Update iris progress
    if state.hasIris and hasMethod(interface, "getIrisProgress") then
        local progress = interface.getIrisProgress()
        state.irisProgress = progress or 0
        
        if progress == 0 then
            state.irisClosed = false
        elseif progress == 58 then
            state.irisClosed = true
        else
            -- In motion - keep last known state but update progress
            state.irisClosed = (progress > 29)
        end
    end
end

-- ============================================
-- GATE CONTROL FUNCTIONS
-- ============================================

local function openIris()
    if not state.hasIris then
        log("No iris installed!", colors.red)
        return
    end
    
    local currentProgress = state.irisProgress or 0
    
    if currentProgress == 0 then
        log("Iris already fully open", colors.yellow)
        return
    elseif currentProgress > 0 and currentProgress < 58 then
        log("Iris currently moving (progress: " .. currentProgress .. "/58)", colors.orange)
        log("Opening iris...", colors.green)
    else
        log("Opening iris from closed position...", colors.green)
    end
    
    if hasMethod(interface, "openIris") then
        local ok, err = pcall(function()
            interface.openIris()
        end)
        
        if ok then
            log("IRIS OPENING", colors.lime)
            reportStatusToAPI()  -- NEW!
        else
            log("ERROR opening iris: " .. tostring(err), colors.red)
        end
    else
        log("ERROR: No openIris method", colors.red)
    end
end

local function closeIris()
    if not state.hasIris then
        log("No iris installed!", colors.red)
        return
    end
    
    local currentProgress = state.irisProgress or 0
    
    if currentProgress == 58 then
        log("Iris already fully closed", colors.yellow)
        return
    elseif currentProgress > 0 and currentProgress < 58 then
        log("Iris currently moving (progress: " .. currentProgress .. "/58)", colors.orange)
        log("Closing iris...", colors.red)
    else
        log("Closing iris from open position...", colors.red)
    end
    
    if hasMethod(interface, "closeIris") then
        local ok, err = pcall(function()
            interface.closeIris()
        end)
        
        if ok then
            log("IRIS CLOSING", colors.red)
            reportStatusToAPI()  -- NEW!
        else
            log("ERROR closing iris: " .. tostring(err), colors.red)
        end
    else
        log("ERROR: No closeIris method", colors.red)
    end
end

local function disconnectGate()
    if state.status == "IDLE" then
        log("Gate already idle", colors.yellow)
        return
    end
    
    if hasMethod(interface, "disconnectStargate") then
        interface.disconnectStargate()
        log("DISCONNECTING GATE", colors.orange)
    elseif hasMethod(interface, "disconnect") then
        interface.disconnect()
        log("DISCONNECTING GATE", colors.orange)
    else
        log("ERROR: No disconnect method", colors.red)
    end
    
    for i = 1, 9 do
        state.chevrons[i] = false
    end
    
    reportStatusToAPI()  -- NEW!
end

-- ============================================
-- DIALING SYSTEM - CRYSTAL INTERFACE
-- ============================================

local function dialCrystalInterface(address)
    state.dialing = true
    log("CRYSTAL DIAL START", colors.cyan)
    
    local dialMethod = nil
    
    if hasMethod(interface, "engageSymbol") then
        dialMethod = "engageSymbol"
    elseif hasMethod(interface, "engage") then
        dialMethod = "engage"
    elseif hasMethod(interface, "dialAddress") then
        log("Using direct dial method", colors.lightBlue)
        interface.dialAddress(address)
        state.dialing = false
        return true
    else
        log("ERROR: No crystal dial method found!", colors.red)
        state.dialing = false
        return false
    end
    
    for i, symbol in ipairs(address) do
        if i > 9 then 
            break 
        end
        
        log("Chevron " .. i .. " -> Symbol " .. symbol, colors.lightBlue)
        
        local success, err = pcall(function()
            if dialMethod == "engageSymbol" then
                interface.engageSymbol(symbol)
            elseif dialMethod == "engage" then
                interface.engage(symbol)
            end
        end)
        
        if not success then
            log("ERROR engaging symbol: " .. tostring(err), colors.red)
            state.dialing = false
            return false
        end
        
        state.chevrons[i] = true
        os.sleep(1.5)
        
        if state.incoming then
            log("INCOMING - ABORT", colors.red)
            state.dialing = false
            return false
        end
    end
    
    state.dialing = false
    log("CRYSTAL DIAL COMPLETE", colors.green)
    reportStatusToAPI()  -- NEW!
    return true
end

-- ============================================
-- DIALING SYSTEM - BASIC INTERFACE (IMPROVED!)
-- ============================================

local function dialBasicInterface(address)
    state.dialing = true
    log("BASIC DIAL START", colors.cyan)
    
    -- Check required methods
    if not hasMethod(interface, "isCurrentSymbol") then
        log("ERROR: Missing isCurrentSymbol()", colors.red)
        state.dialing = false
        return false
    end
    
    if not hasMethod(interface, "openChevron") then
        log("ERROR: Missing openChevron()", colors.red)
        state.dialing = false
        return false
    end
    
    if not hasMethod(interface, "encodeChevron") then
        log("ERROR: Missing encodeChevron()", colors.red)
        state.dialing = false
        return false
    end
    
    -- Determine available rotation methods
    local hasRotateClockwise = hasMethod(interface, "rotateClockwise")
    local hasRotateAntiClockwise = hasMethod(interface, "rotateAntiClockwise")
    
    if not (hasRotateClockwise or hasRotateAntiClockwise) then
        log("ERROR: No rotation methods!", colors.red)
        state.dialing = false
        return false
    end
    
    -- Dial each symbol
    local direction = "clockwise"
    
    for i, targetSymbol in ipairs(address) do
        if i > 7 then 
            break 
        end
        
        log("=== CHEVRON " .. i .. " ===", colors.yellow)
        log("Target symbol: " .. targetSymbol, colors.lightBlue)
        
        -- Start rotation to target symbol
        if direction == "clockwise" and hasRotateClockwise then
            log("Rotating CLOCKWISE to " .. targetSymbol, colors.gray)
            interface.rotateClockwise(targetSymbol)
        elseif hasRotateAntiClockwise then
            log("Rotating ANTICLOCKWISE to " .. targetSymbol, colors.gray)
            interface.rotateAntiClockwise(targetSymbol)
        end
        
        -- Wait for rotation to complete
        log("Waiting for rotation...", colors.gray)
        local waitTime = 0
        local maxWait = 10
        
        while not interface.isCurrentSymbol(targetSymbol) and waitTime < maxWait do
            sleep(0.1)
            waitTime = waitTime + 0.1
            
            if state.incoming then
                log("INCOMING - ABORT", colors.red)
                state.dialing = false
                return false
            end
        end
        
        if waitTime >= maxWait then
            log("ERROR: Rotation timeout!", colors.red)
            state.dialing = false
            return false
        end
        
        -- Verify we're at the correct symbol
        if interface.isCurrentSymbol(targetSymbol) then
            log("Reached symbol " .. targetSymbol, colors.lime)
            log("Opening chevron " .. i .. "...", colors.cyan)
            
            -- STEP 1: Open chevron
            local ok1, err1 = pcall(function()
                interface.openChevron()
            end)
            
            if not ok1 then
                log("ERROR opening chevron: " .. tostring(err1), colors.red)
                state.dialing = false
                return false
            end
            
            sleep(1)  -- Wait for chevron to fully open
            
            log("Encoding chevron " .. i .. "...", colors.cyan)
            
            -- STEP 2: Encode/lock the chevron
            local ok2, err2 = pcall(function()
                interface.encodeChevron()
            end)
            
            if not ok2 then
                log("ERROR encoding chevron: " .. tostring(err2), colors.red)
                state.dialing = false
                return false
            end
            
            sleep(0.2)
            
            -- STEP 3: Close chevron ONLY if it's still open
            if hasMethod(interface, "isChevronOpen") and hasMethod(interface, "closeChevron") then
                if interface.isChevronOpen() then
                    log("Chevron still open - closing...", colors.gray)
                    local ok3, err3 = pcall(function()
                        interface.closeChevron()
                    end)
                    if not ok3 then
                        log("WARNING: closeChevron failed: " .. tostring(err3), colors.yellow)
                    else
                        log("Chevron closed", colors.gray)
                    end
                else
                    log("Chevron already closed (auto-closed by encode)", colors.gray)
                end
            end
            
            sleep(0.2)
            state.chevrons[i] = true
            log("Chevron " .. i .. " LOCKED!", colors.green)
        else
            log("ERROR: Not at correct symbol!", colors.red)
            state.dialing = false
            return false
        end
        
        -- Alternate direction for next symbol
        direction = (direction == "clockwise") and "anticlockwise" or "clockwise"
    end

    -- ==========================================
    -- FIX: Engage the Stargate after POO is encoded
    -- ==========================================
    if hasMethod(interface, "engageStargate") then
        local okEngage, errEngage = pcall(function()
            interface.engageStargate()
        end)
        if okEngage then
            log("Engaging Stargate...", colors.lime)
        else
            log("ERROR engaging stargate: " .. tostring(errEngage), colors.red)
        end
    end
    
    state.dialing = false
    log("BASIC DIAL COMPLETE!", colors.green)
    reportStatusToAPI()  -- NEW!
    return true
end

-- ============================================
-- MAIN DIAL FUNCTION
-- ============================================

local function dialAddress(address)
    -- The touch GUI, a named websocket dial and a typed-in address all end up
    -- here, so this one check covers every route.
    local permitted, why = isDialAllowed(address)
    if not permitted then
        log("DENIED: " .. tostring(why), colors.red)
        return false
    end

    if state.status ~= "IDLE" then
        log("Cannot dial - gate busy!", colors.red)
        return false
    end
    
    if state.dialing then
        log("Already dialing!", colors.red)
        return false
    end
    
    local testInterface = peripheral.find(state.interfaceType)
    if testInterface == nil then
        log("Interface lost! Refreshing...", colors.orange)
        refreshPeripherals()
    end
    
    log("Starting dial sequence...", colors.yellow)
    
    local success = false
    if state.interfaceType == "basic_interface" then
        success = dialBasicInterface(address)
    else
        success = dialCrystalInterface(address)
    end
    
    return success
end

-- ============================================
-- GUI RENDERING
-- ============================================

local function drawText(x, y, text, fg, bg)
    monitor.setCursorPos(x, y)
    if fg then 
        monitor.setTextColor(fg) 
    end
    if bg then 
        monitor.setBackgroundColor(bg) 
    end
    monitor.write(text)
end

local function drawButton(x, y, text, color)
    drawText(x, y, "[ " .. text .. " ]", color)
end

local function drawProgressBar(x, y, width, current, max)
    -- Nil safety
    current = current or 0
    max = max or 1
    
    local percent = (max > 0) and (current / max) or 0
    local filled = math.floor(width * percent)
    
    monitor.setCursorPos(x, y)
    monitor.setTextColor(colors.lime)
    monitor.write(string.rep("|", filled))
    monitor.setTextColor(colors.gray)
    monitor.write(string.rep("|", width - filled))
end

local function renderMainScreen()
    monitor.setBackgroundColor(colors.black)
    monitor.clear()
    
    -- Header
    drawText(1, 1, "STARGATE COMMAND - DIALING COMPUTER", colors.white)
    drawText(1, 2, string.rep("=", 50), colors.gray)
    
    -- Gate info on separate lines
    drawText(1, 4, "Gate: " .. state.gateType, colors.cyan)
    drawText(1, 5, "Interface: " .. state.interfaceType, colors.cyan)
    
    -- Status
    local statusColor = colors.yellow
    if state.status == "CONNECTED" then
        statusColor = colors.green
    elseif state.status == "INCOMING WORMHOLE" then
        statusColor = colors.red
    elseif state.status == "IDLE" then
        statusColor = colors.lightGray
    end
    
    drawText(1, 7, "STATUS: " .. state.status, statusColor)
    
    -- Connected Address
    if state.connectedAddress then
        local addrStr = "Unknown"
        if type(state.connectedAddress) == "table" then
            addrStr = table.concat(state.connectedAddress, "-")
        else
            addrStr = tostring(state.connectedAddress)
        end
        drawText(1, 8, "Address: " .. addrStr, colors.lightBlue)
    end
    
    -- Energy Bar (moved up to line 9)
    drawText(1, 9, "Energy:", colors.orange)
    drawProgressBar(10, 9, 30, state.energy, state.energyMax)
    local energyPct = math.floor((state.energy / state.energyMax) * 100)
    energyPct = math.min(energyPct, 100)
    drawText(42, 9, energyPct .. "%", colors.orange)
    
    -- Chevron Indicators (moved up to line 11)
    drawText(1, 11, "Chevrons:", colors.cyan)
    for i = 1, 7 do
        local symbol = state.chevrons[i] and "<#>" or "< >"
        local color = state.chevrons[i] and colors.lime or colors.gray
        drawText(11 + (i * 4), 11, symbol, color)
    end
    
    -- Iris Status (moved up to line 13)
    if state.hasIris then
        local irisProgress = state.irisProgress or 0
        local irisText = ""
        local irisColor = colors.gray
        
        if irisProgress == 0 then
            irisText = "OPEN"
            irisColor = colors.green
        elseif irisProgress == 58 then
            irisText = "CLOSED"
            irisColor = colors.red
        else
            irisText = "MOVING (" .. irisProgress .. "/58)"
            irisColor = colors.yellow
        end
        
        drawText(1, 13, "Iris: " .. irisText, irisColor)
    else
        drawText(1, 13, "Iris: N/A", colors.gray)
    end
    
    -- Control Buttons (moved up to line 15)
    drawButton(2, 15, "DIAL", colors.lime)
    drawButton(18, 15, "DISCONNECT", colors.red)
    
    if state.hasIris then
        drawButton(35, 15, "IRIS OPEN", colors.green)
        drawButton(35, 16, "IRIS CLOSE", colors.red)
    end
    
    drawButton(2, 17, "REFRESH HARDWARE", colors.orange)
    
    -- Event Log (moved up to line 19)
    drawText(1, 19, "EVENT LOG:", colors.white)
    drawText(1, 20, string.rep("-", 50), colors.gray)
    
    for i, entry in ipairs(eventLog) do
        if i <= 6 then
            local logText = entry.time .. " " .. entry.message
            if #logText > 48 then
                logText = logText:sub(1, 45) .. "..."
            end
            drawText(2, 20 + i, logText, entry.color)
        end
    end
end

local function renderDestinationScreen()
    monitor.setBackgroundColor(colors.black)
    monitor.clear()
    
    drawText(1, 1, "SELECT DESTINATION", colors.yellow)
    drawText(1, 2, string.rep("=", 50), colors.gray)
    
    -- Check if we have any destinations
    local destCount = 0
    for _ in pairs(DESTINATIONS) do
        destCount = destCount + 1
    end
    
    if destCount == 0 then
        drawText(3, 5, "No permitted destinations", colors.red)
        drawText(3, 6, permissionsLoaded and "Ask the admin to grant access" or "Waiting for permissions...", colors.yellow)
        drawButton(3, 8, "CANCEL", colors.red)
        return
    end
    
    local y = 4
    local i = 1
    for _, dest in ipairs(sortedDestinations()) do
        local name, address = dest.name, dest.address
        local addrStr = table.concat(address, "-")
        drawButton(3, y, i .. ". " .. name, colors.lime)
        drawText(3, y + 1, "    " .. addrStr, colors.gray)
        y = y + 3
        i = i + 1
    end
    
    drawButton(3, y + 1, "CANCEL", colors.red)
end

local function render()
    if currentScreen == "main" then
        renderMainScreen()
    elseif currentScreen == "destinations" then
        renderDestinationScreen()
    end
end

-- ============================================
-- INPUT HANDLING
-- ============================================

local function handleMainScreenClick(x, y)
    -- Dial button (row 15)
    if y == 15 and x >= 2 and x <= 15 then
        currentScreen = "destinations"
        render()
        return
    end
    
    -- Disconnect button (row 15)
    if y == 15 and x >= 18 and x <= 35 then
        disconnectGate()
        return
    end
    
    -- Iris OPEN button (row 15)
    if state.hasIris and y == 15 and x >= 35 and x <= 50 then
        openIris()
        return
    end
    
    -- Iris CLOSE button (row 16)
    if state.hasIris and y == 16 and x >= 35 and x <= 50 then
        closeIris()
        return
    end
    
    -- Refresh hardware button (row 17)
    if y == 17 and x >= 2 and x <= 25 then
        log("Refreshing hardware...", colors.orange)
        selfCheck()
        render()
        return
    end
end

local function handleDestinationClick(x, y)
    local destList = sortedDestinations()
    
    for i, dest in ipairs(destList) do
        local destY = 4 + ((i - 1) * 3)
        if (y == destY or y == destY + 1) and x >= 3 then
            log("Dialing: " .. dest.name, colors.green)
            currentScreen = "main"
            render()
            dialAddress(dest.address)
            return
        end
    end
    
    local cancelY = 4 + (#destList * 3) + 1
    if y >= cancelY and x >= 3 then
        currentScreen = "main"
        render()
        return
    end
end

-- ============================================
-- MAIN LOOPS
-- ============================================

local function statusUpdateLoop()
    while true do
        updateGateStatus()
        
        -- Report status to API
        reportStatusToAPI()
        
        -- Backup refresh of the permission list. The websocket push is the
        -- main path, and the timestamp moves on every attempt so a dead API
        -- is not hammered every loop.
        if os.clock() - lastPermissionsAttempt > CONFIG.PERMISSIONS_REFRESH then
            lastPermissionsAttempt = os.clock()
            fetchPermissionsFromAPI()
        end
        
        if currentScreen == "main" then
            render()
        end
        os.sleep(0.5)
    end
end

local function inputLoop()
    while true do
        local event, side, x, y = os.pullEvent("monitor_touch")
        
        if currentScreen == "main" then
            handleMainScreenClick(x, y)
        elseif currentScreen == "destinations" then
            handleDestinationClick(x, y)
        end
    end
end

-- ============================================
-- COMMAND HANDLER (shared by WS and HTTP loops)
-- ============================================

local function handleCommand(data)
    -- Commands are now pushed from the server instantly via WebSocket.
    -- 'data' must have: type="command", action, from, to (optional)
    if not data or data.action == nil then return end
    if data.action == "null" then return end

    -- Only act on commands addressed to this gate
    if data.from ~= CONFIG.STARGATE_NAME then
        if CONFIG.DEBUG_MODE then
            print("[WS] Command for '" .. tostring(data.from) .. "', not for me")
        end
        return
    end

    print("[WS] ✓ Command: " .. data.action .. (data.to and (" -> " .. data.to) or ""))

    if data.action == "open" then
        if data.to then
            -- Names are matched case-insensitively against the permitted list
            local address = nil
            for name, addr in pairs(DESTINATIONS) do
                if string.lower(name) == string.lower(data.to) then
                    address = addr
                    break
                end
            end
            if address then
                log("WS: Dialing " .. data.to, colors.cyan)
                dialAddress(address)
            else
                log("WS: '" .. data.to .. "' is not a permitted destination", colors.red)
            end
        elseif data.address then
            -- Manual address dial (typed in via the Dial Address text box on HAOS)
            local addressTable = {}
            for numStr in string.gmatch(data.address, "[^,]+") do
                local num = tonumber(numStr:match("^%s*(.-)%s*$"))
                if num then
                    table.insert(addressTable, num)
                end
            end

            if #addressTable > 0 then
                log("WS: Dialing manual address " .. data.address, colors.cyan)
                dialAddress(addressTable)
            else
                log("WS: Invalid manual address '" .. tostring(data.address) .. "'", colors.red)
            end
        else
            log("WS: Open command with no destination or address", colors.red)
        end

    elseif data.action == "close" then
        log("WS: Disconnect command", colors.orange)
        disconnectGate()

    elseif data.action == "iris-open" then
        if state.hasIris then
            log("WS: Open iris command", colors.green)
            openIris()
        else
            log("WS: No iris installed", colors.yellow)
        end

    elseif data.action == "iris-close" then
        if state.hasIris then
            log("WS: Close iris command", colors.red)
            closeIris()
        else
            log("WS: No iris installed", colors.yellow)
        end

    else
        if CONFIG.DEBUG_MODE then
            print("[WS] Unknown action: " .. tostring(data.action))
        end
    end
end


-- ============================================
-- WEBSOCKET LOOP (replaces apiLoop polling)
-- ============================================

local function wsLoop()
    if not CONFIG.API_ENABLED then
        if CONFIG.DEBUG_MODE then
            print("[WS] API disabled, WebSocket loop dormant")
        end
        while true do os.sleep(3600) end
    end

    local wsURL = CONFIG.WS_URL .. "/" .. CONFIG.STARGATE_NAME
    print("[WS] Connecting to " .. wsURL)

    while true do
        -- Attempt WebSocket connection
        local ws, err = http.websocket(wsURL)

        if ws then
            wsConnection = ws
            print("[WS] Connected! Real-time commands enabled.")
            log("WS: Connected", colors.lime)

            -- Receive loop — blocks until disconnection
            while true do
                local msg = ws.receive()

                if not msg then
                    -- Server closed the connection
                    print("[WS] Connection closed by server")
                    break
                end

                local parseOk, data = pcall(textutils.unserializeJSON, msg)
                if parseOk and data then
                    if data.type == "command" then
                        handleCommand(data)
                    elseif data.type == "permissions" then
                        if applyPermissions(data) then
                            savePermissionsCache(data)
                            log("Permissions updated: " .. countDestinations() .. " destinations", colors.cyan)
                            if currentScreen == "destinations" then
                                render()
                            end
                        end
                    end
                else
                    if CONFIG.DEBUG_MODE then
                        print("[WS] Received non-JSON message: " .. tostring(msg))
                    end
                end
            end

            -- Clean up
            wsConnection = nil
            pcall(ws.close)
            log("WS: Disconnected", colors.orange)
            print("[WS] Reconnecting in 5 seconds...")

        else
            print("[WS] Failed to connect: " .. tostring(err))
            print("[WS] Retrying in 10 seconds...")
        end

        -- Back-off before reconnect
        -- Status updates will fall back to HTTP in the meantime
        os.sleep(wsConnection == nil and 10 or 5)
    end
end

-- ============================================
-- MAIN ENTRY POINT
-- ============================================

local function main()
    print("===================================")
    print("  STARGATE DIALING COMPUTER v6.0 (Allowlist Edition)")
    print("===================================")
    print("")
    print("If you've swapped gates:")
    print("1. Shut down computer")
    print("2. Break & replace interface")
    print("3. Reconnect network cables")
    print("4. Toggle modems on")
    print("5. Restart computer")
    print("")
    print("Press any key to continue...")
    os.pullEvent("key")
    
    selfCheck()
    render()
    
    parallel.waitForAny(
        statusUpdateLoop,
        inputLoop,
        wsLoop
    )
end

local success, err = pcall(main)

if not success then
    if monitor then
        monitor.clear()
        monitor.setCursorPos(1, 1)
        monitor.setTextColor(colors.red)
        monitor.write("FATAL ERROR:")
        monitor.setCursorPos(1, 3)
        monitor.write(tostring(err))
    end
    
    print("\n[FATAL ERROR]")
    print(err)
    error(err)
end