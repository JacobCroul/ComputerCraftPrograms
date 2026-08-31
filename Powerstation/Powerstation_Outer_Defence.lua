-- PowerStation Outer Defence Client
-- Controls a redstone link (defense tesla coils) via a single boolean.
-- Reports its own on/off state AND polls for commands from HA.

local CONFIG = {
    NODE_ID = "coils_2",          -- unique across all nodes
    NODE_TYPE = "switch",
    API_INGEST_URL = "http://192.168.1.41:5007/ingest",
    API_COMMAND_URL = "http://192.168.1.41:5007/command",
    REDSTONE_SIDE = "back",       -- side the redstone link output is wired to
    POLL_INTERVAL = 2,            -- seconds between command polls
    REPORT_INTERVAL = 5,          -- seconds between state reports
}

-- ============================================
-- STATE TRACKING
-- ============================================
local lastReportedState = nil
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

local function reportState(isOn)
    local payload = textutils.serializeJSON({
        node_id = CONFIG.NODE_ID,
        type = CONFIG.NODE_TYPE,
        values = {
            is_on = isOn,
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
-- MAIN LOOP
-- ============================================
print("=== Outer Defence Client Started ===")
print("Node ID: " .. CONFIG.NODE_ID)
print("")

while true do
    local now = os.clock()

    -- 1. Poll for a pending command every POLL_INTERVAL seconds
    if (now - lastPollTime) >= CONFIG.POLL_INTERVAL then
        local commandValue = fetchCommand()
        lastPollTime = now

        if commandValue ~= nil then
            redstone.setOutput(CONFIG.REDSTONE_SIDE, commandValue == true)
            print("[CMD] Coils " .. (commandValue and "ON" or "OFF"))
        end
    end

    -- 2. Report current state periodically (or when changed)
    local currentState = redstone.getOutput(CONFIG.REDSTONE_SIDE)

    local shouldReport = (currentState ~= lastReportedState) or ((now - lastReportTime) >= CONFIG.REPORT_INTERVAL)

    if shouldReport then
        if reportState(currentState) then
            lastReportedState = currentState
            lastReportTime = now
            print("[RPT] State: " .. (currentState and "ON" or "OFF"))
        end
    end

    -- 3. CRITICAL: yield to prevent "too long without yielding"
    sleep(1)
end
