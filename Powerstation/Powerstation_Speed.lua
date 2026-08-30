-- PowerStation Speed Monitor Client
-- Reports speed from Speedometer to the Powerstation API (read-only)

local CONFIG = {
    NODE_ID = "speedometer_1",    -- unique across all nodes
    NODE_TYPE = "speedometer",
    API_URL = "http://192.168.1.41:5007/ingest",
    PERIPHERAL_SIDE = "back",
    REPORT_INTERVAL = 5,
}

local adapter = peripheral.wrap(CONFIG.PERIPHERAL_SIDE)
if not adapter then
    error("[FATAL] No peripheral on side: " .. CONFIG.PERIPHERAL_SIDE)
end

local lastReportedSpeed = nil
local lastReportTime = 0

print("=== Speed Monitor Started ===")
print("Node ID: " .. CONFIG.NODE_ID)
print("")

while true do
    local now = os.clock()
    local speed = nil

    local success, result = pcall(function()
        return adapter.getSpeed()
    end)

    if success then
        speed = result
    end

    -- report on change, or as a heartbeat every REPORT_INTERVAL seconds
    local shouldReport = speed ~= nil and (speed ~= lastReportedSpeed or (now - lastReportTime) >= CONFIG.REPORT_INTERVAL)

    if shouldReport then
        local payload = textutils.serializeJSON({
            node_id = CONFIG.NODE_ID,
            type = CONFIG.NODE_TYPE,
            values = {
                speed = speed,
            },
        })

        local response = http.post(
            CONFIG.API_URL,
            payload,
            { ["Content-Type"] = "application/json" }
        )

        if response then
            print("[RPT] Speed: " .. speed .. " rpm")
            response.close()
            lastReportedSpeed = speed
            lastReportTime = now
        else
            print("[WARN] Failed to reach API")
        end
    end

    sleep(CONFIG.REPORT_INTERVAL)
end
