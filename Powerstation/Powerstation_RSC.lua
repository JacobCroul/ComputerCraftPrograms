-- PowerStation RSC Client
-- Reports current target speed to the API, polls for new commands, applies them

local CONFIG = {
    NODE_ID = "rsc_1",            -- unique across all nodes
    NODE_TYPE = "rsc",
    API_INGEST_URL = "http://192.168.1.41:5007/ingest",
    API_COMMAND_URL = "http://192.168.1.41:5007/command",
    PERIPHERAL_SIDE = "back",
    ADAPTER_DIRECTION = "back",   -- Direction RSC is connected to adapter
    POLL_INTERVAL = 2,            -- seconds between command polls
    REPORT_INTERVAL = 5,          -- seconds between state reports
}

-- ============================================
-- PERIPHERAL SETUP
-- ============================================
local adapter = peripheral.wrap(CONFIG.PERIPHERAL_SIDE)
if not adapter then
    error("[FATAL] No peripheral found on side: " .. CONFIG.PERIPHERAL_SIDE)
end

if not adapter.setTargetSpeed then
    error("[FATAL] Peripheral does not have setTargetSpeed method. Is this a Digital Adapter with RSC?")
end

-- ============================================
-- STATE TRACKING
-- ============================================
local lastReportedSpeed = nil
local lastReportTime = 0
local lastPollTime = 0

-- ============================================
-- API FUNCTIONS
-- ============================================
local function fetchCommand()
    local response = http.get(CONFIG.API_COMMAND_URL .. "?node_id=" .. CONFIG.NODE_ID)
    if not response then
        print("[WARN] Cannot reach API for command poll")
        return nil
    end

    local body = response.readAll()
    response.close()

    local data = textutils.unserializeJSON(body)
    if not data then
        print("[ERROR] Failed to parse command response")
        return nil
    end

    return data.value
end

local function reportCurrentSpeed(speed)
    local payload = textutils.serializeJSON({
        node_id = CONFIG.NODE_ID,
        type = CONFIG.NODE_TYPE,
        values = {
            target_speed = speed,
        },
    })

    local response = http.post(
        CONFIG.API_INGEST_URL,
        payload,
        { ["Content-Type"] = "application/json" }
    )

    if response then
        response.close()
        return true
    end
    return false
end

-- ============================================
-- PERIPHERAL FUNCTIONS
-- ============================================
local function setRSCSpeed(speed)
    local success, err = pcall(function()
        adapter.setTargetSpeed(CONFIG.ADAPTER_DIRECTION, speed)
    end)

    if not success then
        print("[ERROR] Failed to set RSC speed: " .. tostring(err))
        return false
    end
    return true
end

local function getCurrentSpeed()
    local success, result = pcall(function()
        return adapter.getTargetSpeed(CONFIG.ADAPTER_DIRECTION)
    end)

    if success then
        return result
    end
    return nil
end

-- ============================================
-- MAIN LOOP
-- ============================================
print("=== RSC Client Started ===")
print("Node ID: " .. CONFIG.NODE_ID)
print("")

while true do
    local now = os.clock()

    -- 1. Poll for a pending command every POLL_INTERVAL seconds
    if (now - lastPollTime) >= CONFIG.POLL_INTERVAL then
        local commandValue = fetchCommand()
        lastPollTime = now

        if commandValue ~= nil then
            print("[CMD] Setting RSC to " .. tostring(commandValue))
            setRSCSpeed(commandValue)
        end
    end

    -- 2. Report current speed periodically (or when changed)
    local currentSpeed = getCurrentSpeed()

    if currentSpeed then
        local shouldReport = (currentSpeed ~= lastReportedSpeed) or ((now - lastReportTime) >= CONFIG.REPORT_INTERVAL)

        if shouldReport then
            if reportCurrentSpeed(currentSpeed) then
                lastReportedSpeed = currentSpeed
                lastReportTime = now
                print("[RPT] Reported speed: " .. currentSpeed)
            end
        end
    end

    -- 3. CRITICAL: yield to prevent "too long without yielding"
    sleep(1)
end
