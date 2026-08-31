-- This program is a simple updater for various ComputerCraft programs.
-- It allows the user to download and install different programs from a self-hosted repository.
-- The programs include a mail system, a music player, a TicTacToe game, and Stargate utilities.
-- The updater provides a menu for the user to select which program to install.
-- It uses HTTP requests to download the files and saves them locally.
-- The program is designed to be run in the ComputerCraft mod for Minecraft.
-- The program is written in Lua and uses the ComputerCraft API for file handling and terminal input/output.
-- This program is free software: you can redistribute it and/or modify it under the terms of the MIT License.

-- The full URL for the updater: http://croul1.duckdns.org:3000/Jacob/ComputerCraftPrograms/raw/branch/main/updater.lua

--=====================================
-- Configuration
--=====================================
local SOURCES = {
  gitea = {
    name = "Gitea (Local)",
    root_url = "http://croul1.duckdns.org:3000/Jacob/ComputerCraftPrograms/raw/branch/main/"
  },
  github = {
    name = "GitHub",
    root_url = "https://raw.githubusercontent.com/TheAgent-1/ComputerCraftPrograms/main/"
  }
}

local root_url = nil
local updater_url = nil

--=====================================
-- Program Definitions
--=====================================
local programOrder = {"stargate", "powerstation", "todo", "ae2"}
local programs = {
  mail = {
    name = "Mail System",
    itemOrder = {"server", "client"},
    items = {
        server = {url = root_url .. "Mail/mail_server.lua", filename = "MailServer.lua"},
        client = {url = root_url .. "Mail/mail_client.lua", filename = "MailClient.lua"},
    }
  },
  music = {
    name = "Music Player (Broken)",
    itemOrder = {"player"},
    items = {
        player = {url = root_url .. "MusicPlayer/MusicPlayer.lua", filename = "MusicPlayer.lua"},
    }
  },
  tictactoe = {
    name = "TicTacToe (Broken)",
    itemOrder = {"server", "client"},
    items = {
        server = {url = root_url .. "TicTacToe/TicTacToe_server.lua", filename = "TicTacToeServer.lua"},
        client = {url = root_url .. "TicTacToe/TicTacToe_client.lua", filename = "TicTacToeClient.lua"},
    }
  },
  externalmail = {
    name = "External Mail System",
    itemOrder = {"client"},
    items = {
        client = {url = root_url .. "ExternalMail/mail_x_world.lua", filename = "MailXWorld.lua"},
    }
  },
  stargate = {
    name = "Stargate",
    itemOrder = {"dial", "auto", "manual", "full", "fullWS", "remoteDHD", "register"},
    items = {
        dial = {url = root_url .. "Stargate/Working/GateDial-Legacy-Hybrid.lua", filename = "GateDial-Legacy-Hybrid.lua", readmeUrl = root_url .. "Stargate/ReadMe.txt", readmeFilename = "Stargate_Readme.txt"},
        auto = {url = root_url .. "Stargate/Working/GateDial-Legacy-AutoAPI.lua", filename = "GateDial-Legacy-AutoAPI.lua", readmeUrl = root_url .. "Stargate/ReadMe.txt", readmeFilename = "Stargate_Readme.txt"},
        manual = {url = root_url .. "Stargate/Working/GateDial-Terminal-Manual.lua", filename = "GateDial-Terminal-Manual.lua", readmeUrl = root_url .. "Stargate/ReadMe.txt", readmeFilename = "Stargate_Readme.txt"},
        full = {url = root_url .. "Stargate/Working/GateDial-GUI-HTTP.lua", filename = "GateDial-GUI-HTTP.lua", readmeUrl = root_url .. "Stargate/ReadMe.txt", readmeFilename = "Stargate_Readme.txt"},
        fullWS = {url = root_url .. "Stargate/Working/GateDial-GUI-WS.lua", filename = "GateDial-GUI-WS.lua", readmeUrl = root_url .. "Stargate/ReadMe.txt", readmeFilename = "Stargate_Readme.txt"},
        remoteDHD = {url = root_url .. "Stargate/Working/RemoteDHD.lua", filename = "RemoteDHD.lua", readmeUrl = root_url .. "Stargate/ReadMe.txt", readmeFilename = "Stargate_Readme.txt"},
        register = {url = root_url .. "Stargate/Working/GateNetwork-Registry.lua", filename = "GateNetwork-Registry.lua", readmeUrl = root_url .. "Stargate/ReadMe.txt", readmeFilename = "Stargate_Readme.txt"},
    }
  },
  powerstation = {
    name = "Powerstation",
    itemOrder = {"battery", "relay", "rsc", "speed", "stress", "inner", "outer"},
    items = {
        battery = {url = root_url .. "Powerstation/Powerstation_Battery.lua", filename = "Powerstation_Battery.lua"},
        relay = {url = root_url .. "Powerstation/Powerstation_Relay.lua", filename = "Powerstation_Relay.lua"},
        rsc = {url = root_url .. "Powerstation/Powerstation_RSC.lua", filename = "Powerstation_RSC.lua"},
        speed = {url = root_url .. "Powerstation/Powerstation_Speed.lua", filename = "Powerstation_Speed.lua"},
        stress = {url = root_url .. "Powerstation/Powerstation_Stress.lua", filename = "Powerstation_Stress.lua"},
        inner = {url = root_url .. "Powerstation/Powerstation_Inner_Defence.lua", filename = "Powerstation_Inner_Defence.lua"},
        outer = {url = root_url .. "Powerstation/Powerstation_Outer_Defence.lua", filename = "Powerstation_Outer_Defence.lua"},
    }
  },
  todo = {
    name = "ToDo",
    itemOrder = {"app"},
    items = {
        app = {url = root_url .. "ToDo/ToDo.lua", filename = "ToDo.lua"},
    }
  },
  baseos = {
    name = "BaseOS",
    itemOrder = {"installer"},
    items = {
        installer = {url = root_url .. "BaseOS/BaseOS_Installer.lua", filename = "BaseOS_Installer.lua"},
    }
  },
  ae2 = {
    name = "AE2 Spatial Base",
    itemOrder = {"spatial"},
    items = {
        spatial = {url = root_url .. "AE2SpatialBase/Spatial.lua", filename = "Spatial.lua"},
    }
  },
  test = {
    name = "Test Programs",
    itemOrder = {"test1", "test2"},
    items = {
        test1 = {url = root_url .. "Test/test1.lua", filename = "test1.lua"},
        test2 = {url = root_url .. "Test/test2.lua", filename = "test2.lua"},
    }
  }
}


--=====================================
-- Utility Functions
--=====================================
local function downloadFile(url, filename)
    local ok, response = pcall(http.get, url)
    if not ok or not response then
        print("Failed to download " .. filename)
        return false
    end
    local status
    if response.getResponseCode then
        status = response.getResponseCode()
    end
    local content = response.readAll()
    response.close()
    if status and (status < 200 or status >= 300) then
        print("HTTP error " .. tostring(status) .. " for " .. filename)
        return false
    end
    local tmpName = filename .. ".tmp"
    local okWrite, err = pcall(function()
        local file = fs.open(tmpName, "w")
        file.write(content)
        file.close()
    end)
    if not okWrite then
        print("Failed to write file: " .. tostring(err))
        if fs.exists(tmpName) then fs.delete(tmpName) end
        return false
    end
    if fs.exists(filename) then fs.delete(filename) end
    local movedOk, moveErr = pcall(function() fs.move(tmpName, filename) end)
    if not movedOk then
        print("Failed to finalize download: " .. tostring(moveErr))
        if fs.exists(tmpName) then fs.delete(tmpName) end
        return false
    end
    print(filename .. " downloaded successfully.")
    return true
end

local function getInput()
    local s = read()
    if not s then return "" end
    s = s:match("^%s*(.-)%s*$")
    return s:upper()
end

local function pause()
    print("Press Enter to continue...")
    read()
end

local readmeCache = {}
local function downloadReadme(readmeUrl, readmeFilename)
    if not readmeUrl or not readmeFilename then
        return
    end
    if readmeCache[readmeFilename] then
        print("Run 'edit " .. readmeFilename .. "' to view the Readme")
        return
    end
    if downloadFile(readmeUrl, readmeFilename) then
        print("Run 'edit " .. readmeFilename .. "' to view the Readme")
        readmeCache[readmeFilename] = true
    end
end

local function selfUpdate()
    term.clear()
    term.setCursorPos(1, 1)
    print("Running Self Update...")
    if downloadFile(updater_url, "updater.lua") then
        print("Self Update Complete. Please restart the program.")
    else
        print("Self Update Failed")
    end
end

--=====================================
-- Source Selection
--=====================================
local function selectSource()
    term.clear()
    term.setCursorPos(1, 1)
    print("Updater - Select Source")
    print(string.rep("=", 30))
    print("1 - " .. SOURCES.gitea.name)
    print("2 - " .. SOURCES.github.name)
    write("Select an option: ")
    local choice = getInput()

    if choice == "2" then
        root_url = SOURCES.github.root_url
        print("Using " .. SOURCES.github.name .. ".")
    else
        root_url = SOURCES.gitea.root_url
        print("Using " .. SOURCES.gitea.name .. ".")
    end

    updater_url = root_url .. "updater.lua"
    sleep(1)
end

--=====================================
-- Installation Functions
--=====================================
local function installItem(categoryKey, itemKey)
    local category = programs[categoryKey]
    local item = category.items[itemKey]
    
    if not item then
        print("Invalid selection.")
        return
    end
    
    downloadFile(item.url, item.filename)
    
    if item.readmeUrl then
        downloadReadme(item.readmeUrl, item.readmeFilename)
    end
end

local function showCategoryItems(categoryKey)
    term.clear()
    term.setCursorPos(1, 1)
    local category = programs[categoryKey]
    print(category.name)
    print(string.rep("-", 30))
    
    local items = {}
    local index = 1
    local itemsToDisplay = category.itemOrder or {}
    
    if #itemsToDisplay == 0 then
        for key, _ in pairs(category.items) do
            table.insert(itemsToDisplay, key)
        end
    end
    
    for _, key in ipairs(itemsToDisplay) do
        local item = category.items[key]
        if item then
            items[tostring(index)] = key
            print(index .. " - " .. item.filename)
            index = index + 1
        end
    end
    
    write("Select an option: ")
    local choice = getInput()
    
    if items[choice] then
        installItem(categoryKey, items[choice])
    else
        print("Invalid option.")
    end

    pause()
end

--=====================================
-- Main Menu
--=====================================
local function main()
    term.clear()
    term.setCursorPos(1, 1)
    print("Updater - Program Installer")
    print(string.rep("=", 30))
    print("-1 - Self Update")
    print("0 - Exit")

    local categories = {}
    local index = 1
    for _, key in ipairs(programOrder) do
        local category = programs[key]
        if category then
            categories[tostring(index)] = key
            print(index .. " - " .. category.name)
            index = index + 1
        end
    end

    write("Select an option: ")
    local choice = getInput()

    if choice == "0" then
        term.clear()
        term.setCursorPos(1, 1)
        return false
    elseif choice == "-1" then
        selfUpdate()
        pause()
    elseif categories[choice] then
        showCategoryItems(categories[choice])
    else
        print("Invalid option.")
    end

    pause()

    return true
end

selectSource()

local shouldContinue = true
while shouldContinue do
    shouldContinue = main()
end