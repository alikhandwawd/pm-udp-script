local socket = require("socket")
local encoding = require("encoding")
encoding.default = 'CP1251'
u8 = encoding.UTF8
local server_ip = "188.127.241.232"
local server_port = 25791
local udp = assert(socket.udp())
udp:settimeout(0)
local registered = false
local playerId = nil
local playerName = nil
local clients = {}
local sampev = require("lib.samp.events")


local waitingForClientList = false

function main()
    while not isSampAvailable() do wait(100) end

    local wasInGame = false
    local myId = select(2, sampGetPlayerIdByCharHandle(PLAYER_PED))
    if myId and sampIsPlayerConnected(myId) and sampGetGamestate() == 3 then
        wasInGame = true
    end

    lua_thread.create(function()
        wait(3000)
        if not registered then
            if wasInGame then
                sampAddChatMessage("{FFFF00}[PM UDP] Скрипт перезагружен - авторегистрация...", -1)
            end
            registerPlayer()
        end
    end)

    sampRegisterChatCommand("register_pm", function()
        registerPlayer()
    end)

    sampRegisterChatCommand("pmlist", function()
        if not registered then
            sampAddChatMessage("{FF0000}[PM UDP] Вы ещё не зарегистрированы.", -1)
            return
        end
        waitingForClientList = true
        udp:sendto("requestlist", server_ip, server_port)
        lua_thread.create(function()
            wait(3000)
            if waitingForClientList then
                waitingForClientList = false
                sampAddChatMessage("{FF0000}[PM UDP] Нет ответа от сервера. Используется кешированный список:", -1)
                displayClientList()
            end
        end)
    end)

    sampRegisterChatCommand("pm", function(params)
        if not registered then
            sampAddChatMessage("{FF0000}[PM UDP] Вы ещё не зарегистрированы.", -1)
            return
        end
        local target, message = params:match("^(%S+)%s+(.+)$")
        if not target or not message then
            sampAddChatMessage("{FF0000}[PM UDP] Использование: /pm [id/ник] <текст>", -1)
            return
        end
        if tonumber(target) then
            target = tonumber(target)
            if target == playerId then
                sampAddChatMessage("{FF0000}[PM UDP] Нельзя отправить сообщение самому себе.", -1)
                return
            end
            if clients[target] then
                local targetName = clients[target]
                local sampId = getPlayerIdByNickname(targetName)
                if sampId == -1 then
                    sampAddChatMessage(string.format("{FF0000}[PM UDP] %s (ID %d) не в игре.", targetName, target), -1)
                    return
                end
                sendUdpMessage(playerId, target, message)
            else
                sampAddChatMessage(string.format("{FF0000}[PM UDP] ID %d не зарегистрирован.", target), -1)
            end
        else
            if target:lower():gsub("%s+", "") == playerName:lower():gsub("%s+", "") then
                sampAddChatMessage("{FF0000}[PM UDP] Нельзя отправить сообщение самому себе.", -1)
                return
            end
            local found = false
            for id, name in pairs(clients) do
                if name:lower():gsub("%s+", "") == target:lower():gsub("%s+", "") then
                    local sampId = getPlayerIdByNickname(name)
                    if sampId == -1 then
                        sampAddChatMessage(string.format("{FF0000}[PM UDP] %s не в игре.", name), -1)
                        return
                    end
                    sendUdpMessage(playerId, id, message)
                    found = true
                    break
                end
            end
            if not found then
                sampAddChatMessage(string.format("{FF0000}[PM UDP] %s не зарегистрирован.", target), -1)
            end
        end
    end)

    lua_thread.create(udpListenerLoop)
end

function sampev.onSendCommand(command)
    if command:sub(1, 3):lower() == "/pm" and command:len() > 4 then
        local params = command:sub(5)
        if not registered then
            sampAddChatMessage("{FF0000}[PM UDP] Вы ещё не зарегистрированы.", -1)
            return false
        end
        local target, message = params:match("^(%S+)%s+(.+)$")
        if not target or not message then
            sampAddChatMessage("{FF0000}[PM UDP] Использование: /pm [id/ник] <текст>", -1)
            return false
        end
        if tonumber(target) then
            target = tonumber(target)
            if target == playerId then
                sampAddChatMessage("{FF0000}[PM UDP] Нельзя отправить сообщение самому себе.", -1)
                return false
            end
            if clients[target] then
                local targetName = clients[target]
                local sampId = getPlayerIdByNickname(targetName)
                if sampId == -1 then
                    sampAddChatMessage(string.format("{FF0000}[PM UDP] %s (ID %d) не в игре.", targetName, target), -1)
                    return false
                end
                sendUdpMessage(playerId, target, message)
            else
                sampAddChatMessage(string.format("{FF0000}[PM UDP] ID %d не зарегистрирован.", target), -1)
            end
        else
            if target:lower():gsub("%s+", "") == playerName:lower():gsub("%s+", "") then
                sampAddChatMessage("{FF0000}[PM UDP] Нельзя отправить сообщение самому себе.", -1)
                return false
            end
            local found = false
            for id, name in pairs(clients) do
                if name:lower():gsub("%s+", "") == target:lower():gsub("%s+", "") then
                    local sampId = getPlayerIdByNickname(name)
                    if sampId == -1 then
                        sampAddChatMessage(string.format("{FF0000}[PM UDP] %s не в игре.", name), -1)
                        return false
                    end
                    sendUdpMessage(playerId, id, message)
                    found = true
                    break
                end
            end
            if not found then
                sampAddChatMessage(string.format("{FF0000}[PM UDP] %s не зарегистрирован.", target), -1)
            end
        end
        return false
    end
end

function displayClientList()
    local count = 0
    local onlineClients = {}


    for udpId, udpName in pairs(clients) do
        if udpId ~= playerId then

            local sampId = getPlayerIdByNickname(udpName)
            if sampId ~= -1 and sampId ~= nil then

                local actualName = sampGetPlayerNickname(sampId)
                if actualName and actualName == udpName then
                    count = count + 1
                    table.insert(onlineClients, {
                        udpId = udpId,
                        sampId = sampId,
                        name = udpName
                    })
                end
            end
        end
    end

    if count == 0 then
        sampAddChatMessage("{FFFF00}[PM UDP] Другие клиенты PM не в сети на этом сервере.", -1)
    else
        sampAddChatMessage(string.format("{00FFFF}[PM UDP] Онлайн клиенты PM на этом сервере (%d):", count), -1)

        table.sort(onlineClients, function(a, b) return a.sampId < b.sampId end)
        for _, client in ipairs(onlineClients) do
            sampAddChatMessage(string.format("{FFFFFF}  SA-MP ID %d (UDP ID %d): %s", client.sampId, client.udpId, client.name), -1)
        end
    end
end


function getPlayerIdByNickname(udpNickname)

    for i = 0, sampGetMaxPlayerId(false) do
        if sampIsPlayerConnected(i) then
            local sampName = sampGetPlayerNickname(i)
            if sampName and sampName == udpNickname then
                return i
            end
        end
    end


    local cleanUdpName = udpNickname:gsub("%[.-%]", ""):gsub("%s+", ""):lower()
    for i = 0, sampGetMaxPlayerId(false) do
        if sampIsPlayerConnected(i) then
            local sampName = sampGetPlayerNickname(i)
            if sampName then
                local cleanSampName = sampName:gsub("%[.-%]", ""):gsub("%s+", ""):lower()
                if cleanSampName == cleanUdpName then
                    return i
                end
            end
        end
    end

    return -1
end

function sampev.onServerMessage(color, text)

    local utf8_text = u8:decode(text)


    if text:find("успешно загрузился") or
       utf8_text:find("успешно загрузился") or
       text:find("загрузился") or
       utf8_text:find("загрузился") or
       text:find("successfully loaded") then

        lua_thread.create(function()
            wait(2000)
            registerPlayer()
        end)
    end
end

function sampev.onPlayerSpawn(playerId)

    local myId = select(2, sampGetPlayerIdByCharHandle(PLAYER_PED))
    if playerId == myId and not registered then
        lua_thread.create(function()
            wait(1000)
            registerPlayer()
        end)
    end
end

function registerPlayer()

    local myId = select(2, sampGetPlayerIdByCharHandle(PLAYER_PED))
    if not myId then

        myId = sampGetPlayerIdByCharHandle(PLAYER_PED)
    end


    if not myId or type(myId) ~= "number" then

        local result, id = sampGetPlayerIdByCharHandle(playerPed)
        if result then
            myId = id
        else
            myId = 0
        end
    end


    local myNickname = sampGetPlayerNickname(myId)
    if not myNickname or myNickname == "" then
        myNickname = "Player_" .. tostring(myId)
    end


    playerId = myId
    playerName = myNickname
    local message = string.format("register|%d|%s", playerId, playerName)
    udp:sendto(message, server_ip, server_port)
    registered = true
    sampAddChatMessage(string.format("{00FF00}[PM UDP] You have been registered as %s (ID: %d)", playerName, playerId), -1)
end

function sendUdpMessage(fromId, toId, message)
    local msg = string.format("pm|%d|%d|%s", fromId, toId, message)
    udp:sendto(msg, server_ip, server_port)
    sampAddChatMessage(string.format("{00FF00}[PM UDP] PM sent to ID %d: %s", toId, message), -1)
end

function udpListenerLoop()
    while true do
        local data, ip, port = udp:receivefrom()
        if data and data ~= "" then
            local parts = {}
            local partCount = 0
            
            -- More efficient string splitting
            for part in data:gmatch("[^|]+") do
                partCount = partCount + 1
                parts[partCount] = part
            end

            if partCount > 0 then
                local cmd = parts[1]

                if cmd == "pm" and partCount >= 4 then
                    local fromId, fromName, msg = parts[2], parts[3], parts[4]
                    if fromId and fromName and msg and msg ~= "" then
                        sampAddChatMessage(string.format("{00FFFF}[PM UDP] PM from %s[%s]: %s", fromName, fromId, msg), -1)
                    end
                    
                elseif cmd == "register" and partCount >= 3 then
                    local fromId, fromName = parts[2], parts[3]
                    local id = tonumber(fromId)
                    if id and fromName then
                        clients[id] = fromName
                    end

                elseif cmd == "clientlist" then
                    -- Clear and rebuild client list more efficiently
                    clients = {}
                    
                    -- Process pairs of id|name starting from index 2
                    for i = 2, partCount - 1, 2 do
                        local idStr, name = parts[i], parts[i + 1]
                        if idStr and name then
                            local id = tonumber(idStr)
                            if id then
                                clients[id] = name
                            end
                        end
                    end

                    if waitingForClientList then
                        waitingForClientList = false
                        displayClientList()
                    end
                end
            end
        end
        wait(50)
    end
end