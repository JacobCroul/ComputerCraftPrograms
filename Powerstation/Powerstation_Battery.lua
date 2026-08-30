-- PowerStation Battery Worker for CC:Tweaked
-- Read-only sensor worker
--
-- This worker:
--  - Reads energy stored in up to 3 battery boxes
--  - Aggregates their total FE and capacity locally (per Option A: sum in Lua, not the API)
--  - Reports the combined total to the Powerstation API
--
-- This worker does NOT receive commands. It is a pure telemetry source.

local CONFIG = {
    NODE_ID = "accumulator_node_1",  -- unique across all nodes
    NODE_TYPE = "accumulator",
    API_URL = "http://192.168.1.41:5007/ingest",

    -- Battery box sides (set to nil if unused)
    BATTERY_0 = "back",
    BATTERY_1 = "right",
    BATTERY_2 = "left",

    REPORT_INTERVAL = 5, -- seconds between reports
}

-- ============================================
-- PERIPHERAL SETUP
-- ============================================

local batteries = {}

local function tryWrap(side)
    if side then
        local p = peripheral.wrap(side)
        if p and p.getEnergy then
            return p
        end
    end
    return nil
end

batteries[1] = tryWrap(CONFIG.BATTERY_0)
batteries[2] = tryWrap(CONFIG.BATTERY_1)
batteries[3] = tryWrap(CONFIG.BATTERY_2)

-- Validate at least one battery exists
if not batteries[1] and not batteries[2] and not batteries[3] then
    error("[FATAL] No valid battery peripherals found")
end

-- ============================================
-- UTILS
-- ============================================

-- Sum energy and capacity across all connected batteries (Batt_1 + Batt_2 + Batt_3)
local function getTotals()
    local totalEnergy = 0
    local totalCapacity = 0

    for _, battery in pairs(batteries) do
        if battery then
            local okE, energy = pcall(battery.getEnergy)
            local okC, capacity = pcall(battery.getCapacity)

            if okE and type(energy) == "number" then
                totalEnergy = totalEnergy + energy
            end
            if okC and type(capacity) == "number" then
                totalCapacity = totalCapacity + capacity
            end
        end
    end

    return totalEnergy, totalCapacity
end

-- Send combined battery reading to the API
local function reportBattery(totalEnergy, totalCapacity, percent)
    local payload = textutils.serializeJSON({
        node_id = CONFIG.NODE_ID,
        type = CONFIG.NODE_TYPE,
        values = {
            energy = totalEnergy,
            capacity = totalCapacity,
            percent = percent,
        },
    })

    local response = http.post(
        CONFIG.API_URL,
        payload,
        { ["Content-Type"] = "application/json" }
    )

    if response then
        response.close()
        return true
    end

    print("[WARN] Failed to report battery data to API")
    return false
end

-- ============================================
-- MAIN LOOP
-- ============================================

print("=== Battery Worker Started ===")
print("Node ID: " .. CONFIG.NODE_ID)

while true do
    local totalEnergy, totalCapacity = getTotals()
    local percent = 0
    if totalCapacity > 0 then
        percent = math.floor((totalEnergy / totalCapacity) * 100)
    end

    reportBattery(totalEnergy, totalCapacity, percent)
    print("[RPT] Energy: " .. totalEnergy .. " / " .. totalCapacity .. " FE (" .. percent .. "%)")

    sleep(CONFIG.REPORT_INTERVAL)
end
