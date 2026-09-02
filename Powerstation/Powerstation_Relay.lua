-- PowerStation Relay Client
-- Reports throughput to the API, polls for on/off commands, applies them

local CONFIG = {
    NODE_ID = "relay_1",          -- unique across all nodes
    NODE_TYPE = "redstone_relay",
    API_INGEST_URL = "http://192.168.1.41:5007/ingest",
    API_COMMAND_URL = "http://192.168.1.41:5007/command",
    PERIPHERAL_SIDE = "back",     -- side wired to the Create redstone relay
    RELAY_SIDE = "back",          -- side for redstone output (drives the relay)
    OVERRIDE_SIDE = "left",       -- separate side wired ONLY to the manual override lever - must NOT share a wire with RELAY_SIDE, or this computer will read its own output back as "lever on"
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

-- ============================================
-- STATE TRACKING
-- ============================================
-- The relay block itself exposes no readable redstone signal in either
-- direction (confirmed via `redstone probe` - no input detected, and
-- getOutput only echoes the computer's own last command anyway). There is
-- no hardware path to read the relay's true state back from RELAY_SIDE.
--
-- Manual override: a lever, wired into a SEPARATE side (OVERRIDE_SIDE) not
-- shared with RELAY_SIDE, lets someone physically force the relay on
-- regardless of software state. The relay's actual physical power state is
-- naturally OR'd by vanilla redstone if the lever and RELAY_SIDE's output
-- both feed the same node at the relay - no extra logic needed for that
-- part. What we DO need extra logic for is *reporting* accurately: is_on
-- reported to HA = commandedState (what we last told it) OR the lever
-- reading on OVERRIDE_SIDE (confirmed via testing: reading the computer's
-- own output side back gives a false positive, so the lever must be on its
-- own dedicated side to be read cleanly).
local commandedState = false   -- assume off until a command says otherwise
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
            local newState = commandValue == true
            redstone.setOutput(CONFIG.RELAY_SIDE, newState)
            commandedState = newState
            print("[CMD] Relay " .. (commandedState and "ON" or "OFF"))
        end
    end

    -- 2. Report on/off state + throughput periodically (or when changed).
    -- is_on = commandedState (software) OR the lever reading on the
    -- dedicated OVERRIDE_SIDE (manual). Either one being true means the
    -- relay is genuinely powered, since the real relay input is a physical
    -- OR of these same two sources.
    -- is_on is decoupled from the throughput read so a failed/errored
    -- throughput read (e.g. nothing currently passing through) never
    -- blocks reporting the on/off state - that's the field the dashboard
    -- toggle depends on.
    local manualOverride = redstone.getInput(CONFIG.OVERRIDE_SIDE)
    local isOn = commandedState or manualOverride
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
            local sourceStr = manualOverride and " (manual override)" or ""
            print("[RPT] State: " .. (isOn and "ON" or "OFF") .. sourceStr .. ", Throughput: " .. throughputStr)
        end
    end

    -- 3. CRITICAL: yield to prevent "too long without yielding"
    sleep(1)
end
