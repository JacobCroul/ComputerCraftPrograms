-- PowerStation Relay Client
-- Reports throughput + on/off state to the API, polls for commands, applies them.
--
-- The relay peripheral exposes isPowered() directly - this reads the block's
-- actual internal state, not a redstone wire, so it correctly reflects power
-- from ANY source (this computer's own setOutput, a manual lever, or both -
-- they combine naturally at the relay's own input). No separate override
-- wiring or software state tracking needed.

local CONFIG = {
    NODE_ID = "relay_1",          -- unique across all nodes
    NODE_TYPE = "redstone_relay",
    API_INGEST_URL = "http://192.168.1.41:5007/ingest",
    API_COMMAND_URL = "http://192.168.1.41:5007/command",
    PERIPHERAL_SIDE = "back",     -- side wired to the Create redstone relay
    RELAY_SIDE = "back",          -- side used to command the relay on/off
    POLL_INTERVAL = 2,            -- seconds between command polls
    REPORT_INTERVAL = 5,          -- seconds between state reports
}

-- ============================================
-- PERIPHERAL SETUP
-- ============================================
local relay = peripheral.wrap(CONFIG.PERIPHERAL_SIDE)
if not relay then
    error("[FATAL] No peripheral found on side: " .. CONFIG.PERIPHERAL_SIDE)
end

if not relay.isPowered then
    error("[FATAL] Peripheral does not have isPowered method. Is this the redstone relay?")
end

-- ============================================
-- STATE TRACKING
-- ============================================
local lastReportedThroughput = nil
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

local function reportState(values)
    local payload = textutils.serializeJSON({
        node_id = CONFIG.NODE_ID,
        type = CONFIG.NODE_TYPE,
        values = values,
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
print("=== Relay Client Started ===")
print("Node ID: " .. CONFIG.NODE_ID)
print("")

while true do
    local now = os.clock()

    -- 1. Poll for a pending command every POLL_INTERVAL seconds
    if (now - lastPollTime) >= CONFIG.POLL_INTERVAL then
        local commandValue = fetchCommand()
        lastPollTime = now

        if commandValue ~= nil then
            redstone.setOutput(CONFIG.RELAY_SIDE, commandValue == true)
            print("[CMD] Relay " .. (commandValue and "ON" or "OFF"))
        end
    end

    -- 2. Report on/off state + throughput periodically (or when changed).
    -- is_on comes straight from the peripheral's own isPowered() - the true
    -- state, regardless of whether it was set by this computer, a manual
    -- lever, or both. throughput read is kept separate so a failed read
    -- there never blocks reporting is_on.
    local isOn = relay.isPowered()
    local throughputOk, throughput = pcall(function()
        return relay.getThroughput()
    end)

    local stateChanged = (isOn ~= lastReportedState)
    local throughputChanged = throughputOk and (throughput ~= lastReportedThroughput)
    local heartbeatDue = (now - lastReportTime) >= CONFIG.REPORT_INTERVAL

    if stateChanged or throughputChanged or heartbeatDue then
        local values = { is_on = isOn }
        if throughputOk and throughput then
            values.throughput = throughput
        end

        if reportState(values) then
            lastReportedState = isOn
            if throughputOk then
                lastReportedThroughput = throughput
            end
            lastReportTime = now

            local throughputStr = (throughputOk and throughput) and (throughput .. " FE") or "n/a"
            print("[RPT] State: " .. (isOn and "ON" or "OFF") .. ", Throughput: " .. throughputStr)
        end
    end

    -- 3. CRITICAL: yield to prevent "too long without yielding"
    sleep(1)
end
