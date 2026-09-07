-- PowerStation Player Detector
-- Reports whether AgentPup is online, and whether they're within the base
-- bounding box, using Advanced Peripherals' Player Detector.

local CONFIG = {
    NODE_ID = "player_detector_1",   -- unique across all nodes
    NODE_TYPE = "player_detector",
    API_URL = "http://192.168.1.41:5007/ingest",
    PERIPHERAL_SIDE = "back",
    PLAYER_NAME = "AgentPup",
    REPORT_INTERVAL = 5,              -- seconds between reports

    -- Base bounding box (two opposite corners). Adjust to match your base's
    -- actual footprint - doesn't need to be exact, just generous enough to
    -- cover "at base" as you'd define it.
    BASE_POS_ONE = { x = 0,   y = 0,   z = 0 },
    BASE_POS_TWO = { x = 0,   y = 0,   z = 0 },
}

-- ============================================
-- PERIPHERAL SETUP
-- ============================================
local detector = peripheral.wrap(CONFIG.PERIPHERAL_SIDE)
if not detector then
    error("[FATAL] No peripheral found on side: " .. CONFIG.PERIPHERAL_SIDE)
end

if not detector.isPlayerInCoords then
    error("[FATAL] Peripheral does not have isPlayerInCoords method. Is this the Player Detector?")
end

-- ============================================
-- STATE TRACKING
-- ============================================
local lastReportedOnline = nil
local lastReportedAtBase = nil
local lastReportTime = 0

-- ============================================
-- HELPERS
-- ============================================
local function isPlayerOnline()
    local success, players = pcall(function()
        return detector.getOnlinePlayers()
    end)

    if not success or not players then
        return false
    end

    for _, name in ipairs(players) do
        if name == CONFIG.PLAYER_NAME then
            return true
        end
    end
    return false
end

local function isPlayerAtBase()
    local success, result = pcall(function()
        return detector.isPlayerInCoords(CONFIG.BASE_POS_ONE, CONFIG.BASE_POS_TWO, CONFIG.PLAYER_NAME)
    end)

    if success then
        return result == true
    end
    return false
end

local function reportState(online, atBase)
    local payload = textutils.serializeJSON({
        node_id = CONFIG.NODE_ID,
        type = CONFIG.NODE_TYPE,
        values = {
            online = online,
            at_base = atBase,
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
    return false
end

-- ============================================
-- MAIN LOOP
-- ============================================
print("=== Player Detector Started ===")
print("Node ID: " .. CONFIG.NODE_ID)
print("Tracking: " .. CONFIG.PLAYER_NAME)
print("")

while true do
    local now = os.clock()

    local online = isPlayerOnline()
    -- Only worth checking "at base" if they're online at all - avoids a
    -- pointless coordinate check (and possible false read) when they're
    -- not even connected.
    local atBase = online and isPlayerAtBase() or false

    local shouldReport = (online ~= lastReportedOnline)
        or (atBase ~= lastReportedAtBase)
        or ((now - lastReportTime) >= CONFIG.REPORT_INTERVAL)

    if shouldReport then
        if reportState(online, atBase) then
            lastReportedOnline = online
            lastReportedAtBase = atBase
            lastReportTime = now
            print("[RPT] Online: " .. tostring(online) .. ", At base: " .. tostring(atBase))
        else
            print("[WARN] Failed to reach API")
        end
    end

    sleep(CONFIG.REPORT_INTERVAL)
end
