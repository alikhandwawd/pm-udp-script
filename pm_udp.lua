local socket = require("socket")
local encoding = require("encoding")
local requests = require("requests")
local ffi = require("ffi")

encoding.default = 'CP1251'
u8 = encoding.UTF8

-- Конфигурация
local script_version = "1.1"
local update_url = "https://raw.githubusercontent.com/alikhandwawd/pm-udp-script/main/version.txt"
local script_url = "https://raw.githubusercontent.com/alikhandwawd/pm-udp-script/main/pm_udp.lua"
local server_ip = "188.127.241.232"
local server_port = 25791

-- UDP и основные переменные
local udp = assert(socket.udp())
udp:settimeout(0)
local registered = false
local playerId = nil
local playerName = nil
local clients = {}
local sampev = require("lib.samp.events")

-- Переменные автообновления
local update_available = false
local new_version = nil
local waitingForClientList = false

-- FFI для работы с файлами
ffi.cdef[[
    int CreateDirectoryA(const char* lpPathName, void* lpSecurityAttributes);
    int GetFileAttributesA(const char* lpFileName);
    bool CopyFileA(const char* lpExistingFileName, const char* lpNewFileName, bool bFailIfExists);
    bool DeleteFileA(const char* lpFileName);
]]

function main()
    while not isSampAvailable() do wait(100) end
    
    -- Проверяем автообновление при запуске
    lua_thread.create(function()
        wait(2000)
        checkForUpdates()
    end)

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

    -- Регистрация команд
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
        handlePmCommand(params)
    end)

    -- Команды автообновления
    sampRegisterChatCommand("pmupdate", function()
        checkForUpdates(true)
    end)

    sampRegisterChatCommand("pminstall", function()
        if update_available then
            installUpdate()
        else
            sampAddChatMessage("{FF0000}[PM UDP] Нет доступных обновлений.", -1)
        end
    end)

    sampRegisterChatCommand("pmversion", function()
        sampAddChatMessage(string.format("{00FFFF}[PM UDP] Текущая версия: %s", script_version), -1)
        if update_available then
            sampAddChatMessage(string.format("{FFFF00}[PM UDP] Доступна версия: %s", new_version), -1)
        end
    end)

    sampRegisterChatCommand("pmtest", function()
        udp:sendto("test", server_ip, server_port)
        sampAddChatMessage("{FFFF00}[PM UDP] Тестируем соединение с сервером...", -1)
    end)

    lua_thread.create(udpListenerLoop)
    
    -- Автопроверка обновлений каждые 30 минут
    lua_thread.create(function()
        while true do
            wait(1800000) -- 30 минут
            checkForUpdates()
        end
    end)
    
    -- Периодическая отправка heartbeat для поддержания соединения
    lua_thread.create(function()
        while true do
            wait(15000) -- Каждые 15 секунд
            if registered and playerId then
                local heartbeatMsg = string.format("heartbeat|%d", playerId)
                udp:sendto(heartbeatMsg, server_ip, server_port)
            end
        end
    end)
    
    -- Проверка соединения и автопереподключение
    lua_thread.create(function()
        local lastConnectionTest = 0
        while true do
            wait(30000) -- Каждые 30 секунд
            local currentTime = os.time()
            
            -- Если прошло больше минуты с последнего теста
            if registered and currentTime - lastConnectionTest > 60 then
                lastConnectionTest = currentTime
                
                -- Тестируем соединение
                udp:sendto("test", server_ip, server_port)
                
                -- Если нет ответа в течение 10 секунд, переподключаемся
                lua_thread.create(function()
                    local testStartTime = os.time()
                    local connectionOk = false
                    local originalHandler = nil
                    
                    wait(10000) -- Ждем 10 секунд ответа
                    
                    if not connectionOk and os.time() - testStartTime >= 10 then
                        sampAddChatMessage("{FF0000}[PM UDP] Потеря соединения с сервером. Переподключаемся...", -1)
                        registered = false
                        wait(2000)
                        registerPlayer()
                    end
                end)
            end
        end
    end)
end

function checkForUpdates(manual)
    lua_thread.create(function()
        if manual then
            sampAddChatMessage("{FFFF00}[PM UDP] Проверяем обновления...", -1)
        end
        
        local response = requests.get(update_url, {
            headers = {
                ["User-Agent"] = "PM-UDP-Script/" .. script_version,
                ["Cache-Control"] = "no-cache"
            },
            timeout = 10
        })
        
        if response and response.status_code == 200 and response.text then
            local server_version = response.text:match("([%d%.]+)")
            
            if server_version and compareVersions(script_version, server_version) then
                update_available = true
                new_version = server_version
                
                sampAddChatMessage(string.format("{00FF00}[PM UDP] Доступно обновление до версии %s!", new_version), -1)
                sampAddChatMessage("{FFFF00}Используйте /pminstall для установки.", -1)
            else
                if manual then
                    sampAddChatMessage("{00FF00}[PM UDP] У вас установлена последняя версия.", -1)
                end
                update_available = false
            end
        else
            if manual then
                local error_msg = response and response.status_code or "нет соединения"
                sampAddChatMessage(string.format("{FF0000}[PM UDP] Ошибка проверки обновлений: %s", error_msg), -1)
            end
        end
    end)
end

function compareVersions(current, new)
    local function parseVersion(version)
        local parts = {}
        for part in string.gmatch(version, "(%d+)") do
            table.insert(parts, tonumber(part))
        end
        return parts
    end
    
    local currentParts = parseVersion(current)
    local newParts = parseVersion(new)
    
    for i = 1, math.max(#currentParts, #newParts) do
        local currentPart = currentParts[i] or 0
        local newPart = newParts[i] or 0
        
        if newPart > currentPart then
            return true
        elseif newPart < currentPart then
            return false
        end
    end
    
    return false
end

function installUpdate()
    lua_thread.create(function()
        sampAddChatMessage("{FFFF00}[PM UDP] Загружаем обновление...", -1)
        
        local response = requests.get(script_url, {
            headers = {
                ["User-Agent"] = "PM-UDP-Script/" .. script_version,
                ["Cache-Control"] = "no-cache"
            },
            timeout = 30
        })
        
        if response and response.status_code == 200 and response.text and #response.text > 1000 then
            local script_path = thisScript().path
            local backup_path = script_path .. ".backup"
            local temp_path = script_path .. ".temp"
            
            -- Создаем резервную копию
            local current_file = io.open(script_path, "rb")
            if current_file then
                local current_content = current_file:read("*all")
                current_file:close()
                
                local backup_file = io.open(backup_path, "wb")
                if backup_file then
                    backup_file:write(current_content)
                    backup_file:close()
                end
            end
            
            -- Записываем новую версию во временный файл
            local temp_file = io.open(temp_path, "wb")
            if temp_file then
                temp_file:write(response.text)
                temp_file:close()
                
                -- Проверяем, что файл записался корректно
                local check_file = io.open(temp_path, "rb")
                if check_file then
                    local written_content = check_file:read("*all")
                    check_file:close()
                    
                    if #written_content == #response.text then
                        -- Заменяем основной файл
                        os.remove(script_path)
                        os.rename(temp_path, script_path)
                        
                        sampAddChatMessage(string.format("{00FF00}[PM UDP] Обновление до версии %s успешно установлено!", new_version), -1)
                        sampAddChatMessage("{FFFF00}[PM UDP] Скрипт будет перезагружен через 3 секунды.", -1)
                        
                        wait(3000)
                        thisScript():reload()
                    else
                        sampAddChatMessage("{FF0000}[PM UDP] Ошибка записи файла. Обновление отменено.", -1)
                        os.remove(temp_path)
                    end
                else
                    sampAddChatMessage("{FF0000}[PM UDP] Ошибка проверки записанного файла.", -1)
                end
            else
                sampAddChatMessage("{FF0000}[PM UDP] Ошибка создания временного файла.", -1)
            end
        else
            local size = response and response.text and #response.text or 0
            local status = response and response.status_code or "нет ответа"
            sampAddChatMessage(string.format("{FF0000}[PM UDP] Ошибка загрузки: статус %s, размер %d байт", status, size), -1)
        end
    end)
end

function handlePmCommand(params)
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
end

function sampev.onSendCommand(command)
    if command:sub(1, 3):lower() == "/pm" and command:len() > 4 then
        local params = command:sub(5)
        handlePmCommand(params)
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
    sampAddChatMessage(string.format("{FFFF00}[PM UDP] Отправляем сообщение ID %d: %s", toId, message), -1)
end

function udpListenerLoop()
    while true do
        local data, ip, port = udp:receivefrom()
        if data and data ~= "" then
            local parts = {}
            local partCount = 0
            
            for part in data:gmatch("[^|]+") do
                partCount = partCount + 1
                parts[partCount] = part
            end

            if partCount > 0 then
                local cmd = parts[1]

                if cmd == "pm" and partCount >= 4 then
                    local fromId, fromName, msg = parts[2], parts[3], parts[4]
                    local messageId = parts[5] -- Новый параметр для подтверждения доставки
                    
                    if fromId and fromName and msg and msg ~= "" then
                        sampAddChatMessage(string.format("{00FFFF}[PM UDP] PM from %s[%s]: %s", fromName, fromId, msg), -1)
                        
                        -- Отправляем подтверждение доставки, если есть messageId
                        if messageId then
                            local confirmMsg = string.format("delivery_confirm|%s", messageId)
                            udp:sendto(confirmMsg, server_ip, server_port)
                        end
                    end
                    
                elseif cmd == "heartbeat_request" then
                    -- Отвечаем на запрос heartbeat
                    if registered and playerId then
                        local heartbeatMsg = string.format("heartbeat|%d", playerId)
                        udp:sendto(heartbeatMsg, server_ip, server_port)
                    end
                    
                elseif cmd == "delivery_success" and partCount >= 3 then
                    local toId, message = parts[2], parts[3]
                    sampAddChatMessage(string.format("{00FF00}[PM UDP] ? %s", message), -1)
                    
                elseif cmd == "delivery_failed" and partCount >= 3 then
                    local toId, message = parts[2], parts[3]
                    sampAddChatMessage(string.format("{FF0000}[PM UDP] ? %s", message), -1)
                    
                elseif cmd == "error" and partCount >= 2 then
                    local errorMsg = parts[2]
                    sampAddChatMessage(string.format("{FF0000}[PM UDP] Ошибка: %s", errorMsg), -1)
                    
                elseif cmd == "register" and partCount >= 3 then
                    local fromId, fromName = parts[2], parts[3]
                    local id = tonumber(fromId)
                    if id and fromName then
                        clients[id] = fromName
                    end

                elseif cmd == "clientlist" then
                    clients = {}
                    
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
                    
                elseif cmd == "test_ok" then
                    sampAddChatMessage("{00FF00}[PM UDP] Соединение с сервером работает!", -1)
                end
            end
        end
        wait(50)
    end
end