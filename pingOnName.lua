commands = {}
routes = {}

username = os.getenv("username")
config = dofile("C:/Users/" .. username .. "/AppData/Local/Growtopia/scripts/proxySettings.lua")

function loadConfig(variable)
	file = io.open("C:/Users/" .. username .. "/AppData/Local/Growtopia/scripts/proxySettings.lua", "r")

	if not file then
		print("`4Couldnt open proxySettings.lua. `9Make sure u are using windows")
	end
	content = file:read("*all")
	file:close()

	pattern = content:match(variable .. "%s=%s*([^,%s]+)")
	value = pattern:gsub('"', "")

	return value

end

function editConfigVariable(variable, newValue)
	file = io.open("C:/Users/" .. username .. "/AppData/Local/Growtopia/scripts/proxySettings.lua", "r")

	if not file then
		print("`4Couldnt open proxySettings.lua. `9Make sure u are using windows")
	end
	content = file:read("*all")
	file:close()

	pattern = variable .. "%s=%s*([^,%s]+)"
	newVarValue = variable .. " = " .. newValue

	content = content:gsub(pattern, newVarValue)
	file = io.open("C:/Users/" .. username .. "/AppData/Local/Growtopia/scripts/proxySettings.lua", "w")
	if not file then
		print("`4Couldnt open proxySettings.lua. `9Make sure u are using windows")
	end
	file:write(content)
	file:close()
	print("`2Successfully `9updating config")
end

function print(msg)
	LogToConsole(msg)
end

function getCommands()
    local result = {}

    for _, categoryData in ipairs(commands) do
    	table.insert(result,
    		"add_spacer|small"
        )
        table.insert(result,
            "add_label_with_icon|small|`2" ..
            categoryData.category ..
            ":|left|" ..
            categoryData.icon
        )

        for _, commandData in ipairs(categoryData.items) do
            table.insert(result,
                "add_smalltext|`2" ..
                commandData.cmd ..
                " `9(" ..
                commandData.desc ..
                ")|left"
            )
        end
    end

    return table.concat(result, "\n")
end

function postCommand(category, command, desc, icon)
    -- Routing ke controller otomatis
    funcName = command:gsub("/", "")
    funcName = funcName .. "Controller"
	routes[command] = _G[funcName]
    -- Cari kategori yang sudah ada
    for _, data in ipairs(commands) do
        if data.category == category then
            table.insert(data.items, {
                cmd = command,
                desc = desc
            })

            print("`9Registered command: `2" .. command)
            return true
        end
    end

    -- Kategori belum ada, buat baru
    table.insert(commands, {
        category = category,
        icon = icon,
        items = {
            {
                cmd = command,
                desc = desc
            }
        }
    })

    print("`9Registered command: `2" .. command)
    return true
end


function commandHandler(type, packet)

    if type == 2 and packet:find("action|input\n|text|/") then

        local fullText = packet:match("|text|([^\n]+)")

        local command, args = fullText:match("^(%S+)%s*(.*)$")

        for _, categoryData in ipairs(commands) do
            for _, commandData in ipairs(categoryData.items) do

                if command == commandData.cmd then

                    LogToConsole("`6" .. command)

                    if routes[command] then

                        -- ada argumen
                        if args and args ~= "" then
                            routes[command](args)

                        -- tidak ada argumen
                        else
                            routes[command]()
                        end

                    end

                    return true
                end

            end
        end

        return false
    end
end

postCommand("Info", "/proxy", "Shows Proxy Commands", 660)
postCommand("Info", "/news", "Shows Proxy News And Commands")
postCommand("Info", "/gazette", "Shows CreativePS News")
postCommand("Info", "/dc", "Shows Proxy Discord Invite Link")


function proxyController()
	commandsList = {
		"add_label_with_icon|big|`2Proxy Commands|left|1790",
		getCommands(),
		"add_quick_exit"
	}

	SendVariantList({
		[0] = "OnDialogRequest",
		[1] = table.concat(commandsList, "\n")
	})
end

function newsController()
	newsDialog = {
		"add_label_with_icon|big|`2MERN PROXY by `5@amolemern|left|11550",
		"add_spacer|small",
		"add_label_with_icon|small|`2Proxy Info:|left|5956",
		"add_smalltext|`2Version: `91.0.0|left",
		"add_smalltext|`2Dev: `9AMOLE / @amolemern|left",
		"add_spacer|small",
		"add_label_with_icon|small|`2Update:|left|6128",
		"add_smalltext|`0[`2+`0] `0Proxy Released|left",
		"add_spacer|big",
		"add_label_with_icon|big|`2Proxy Commands|left|1790",
		getCommands(),
		"add_quick_exit"
	}

	SendVariantList({
		[0] = "OnDialogRequest",
		[1] = table.concat(newsDialog, "\n")
	})
end

function gazetteController()
	SendPacket(2, "action|input\n|text|/news")
end

function dcController()
	print("`9https://dsc.gg/7seventh")
end



AddHook("OnSendPacket", "commandHandler", commandHandler)
