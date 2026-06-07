commands = {}
routes = {}
aliases = {}

spin = {
    real = 1,
    leme = 0,
    reme = 1,
    qeme = 0,
    sspin = 0
}

function say(msg, public)
    if public then
        SendPacket(2, "action|input\n|text|`0[`cRadiant`0] ``````" .. msg)
    else
        SendVariantList({
            [0] = "OnTalkBubble",
            [1] = GetLocal().netid,
            [2] = "`0[`cRadiant`0] ``````" .. msg
        })
    end
end

function print(msg)
    LogToConsole(msg)
end

function SendDialog(dialog)
    local dialog = {
        "set_bg_color|45,45,45,200|",
        "set_border_color|100,100,100,255|",
        dialog,
    }

    SendVariantList({
        [0] = "OnDialogRequest",
        [1] = table.concat(dialog, "\n")
    })
end



function postCommand(category, command, desc, icon, args, usage)

    local funcName = command:gsub("/", "") .. "Controller"

    if type(_G[funcName]) ~= "function" then
        print("`4Controller not found: `0" .. funcName)
        return false
    end

    routes[command] = _G[funcName]

    for _, data in ipairs(commands) do
        if data.category == category then

            table.insert(data.items, {
                cmd = command,
                desc = desc,
                args = args or false,
                usage = usage
            })

            print("`0Registered command: `c" .. command)
            return true
        end
    end

    table.insert(commands, {
        category = category,
        icon = icon,
        items = {
            {
                cmd = command,
                desc = desc,
                args = args or false,
                usage = usage
            }
        }
    })

    print("`0Registered command: `c" .. command)
    return true
end

function postAlias(alias, command)

    aliases[alias] = command

    print(
        "`0Registered alias: `c" ..
        alias ..
        " `0-> `c" ..
        command
    )

    return true
end

function getCommands()

    local result = {}

    for _, categoryData in ipairs(commands) do

        table.insert(result,
            "add_spacer|small"
        )

        table.insert(result,
            "add_label_with_icon|small|`c" ..
            categoryData.category ..
            ":|left|" ..
            categoryData.icon
        )

        for _, commandData in ipairs(categoryData.items) do

            local text =
                "add_smalltext|`c" ..
                commandData.cmd ..
                " `0(" ..
                commandData.desc ..
                ")|left"

            table.insert(result, text)
        end
    end

    return table.concat(result, "\n")
end

function commandHandler(type, packet)

    if type == 2 and packet:find("action|input\n|text|/") then

        local fullText = packet:match("|text|([^\n]+)")
        local command, args = fullText:match("^(%S+)%s*(.*)$")

        -- alias redirect
        if aliases[command] then
            command = aliases[command]
        end

        for _, categoryData in ipairs(commands) do
            for _, commandData in ipairs(categoryData.items) do

                if command == commandData.cmd then

                    -- command tidak menerima argumen
                    if not commandData.args and args ~= "" then
                        return false
                    end

                    -- command membutuhkan argumen
                    if commandData.args and args == "" then

                        if commandData.usage then
                            print(
                                "`0Usage: `c" ..
                                command ..
                                " " ..
                                commandData.usage
                            )
                        else
                            print(
                                "`4This command requires arguments."
                            )
                        end

                        return true
                    end

                    if not routes[command] then
                        print("`4Controller not found.")
                        return true
                    end

                    LogToConsole("`6" .. command)

                    if commandData.args then
                        routes[command](args)
                    else
                        routes[command]()
                    end

                    return true
                end

            end
        end

        return false
    end
end



function proxyController()
    proxyDialog = {
        "add_label_with_icon|big|`cRadiant Commands List|left|7188",
        getCommands(),
        "add_quick_exit"
    }

    SendDialog(table.concat(proxyDialog, "\n"))

end

function newsController()
    newsDialog = {
        "add_label_with_icon|big|`cRadiant Proxy `0By @lv3not7221|left|7188",
        "add_spacer|small",
        "add_label_with_icon|small|`cProxy Info:|left|16448",
        "add_smalltext|`cDeveloper: `0@lv3not7221|left",
        "add_smalltext|`cVersion: `0v1.0|left",
        "add_smalltext|`cDiscord: `0https://dsc.gg/7seventh",
        "add_spacer|small",
        "add_label_with_icon|small|`cChangelog:|left|6292",
        "add_smalltext|`0[`2+`0] `0Proxy Realeased|left",
        "add_spacer|big",
        table.concat(proxyDialog, "\n"),
    }

    SendDialog(table.concat(newsDialog, "\n"))
end

function gazetteController()
    SendPacket(2, "action|input\n|text|/news")
end

function spinController()
    spinDialog = {
        "add_label_with_icon|big|`cRoulette Wheel Settings|left|758",
        "add_spacer|small",
        "add_smalltext|`5Detect Real Or Fake Spin|left",
        "add_checkbox|real|`2Enable `0Real Spin Detector|" .. tostring(spin.real) .. "|",
        "add_smalltext|`5Shows Reme ON Number|left",
        "add_checkbox|reme|`2Enable `0Reme Mode|" .. tostring(spin.reme) .. "|",
        "add_smalltext|`5Shows Leme Number + X|left",
        "add_checkbox|leme|`2Enable `0Leme Mode|" .. tostring(spin.leme) .. "|",
        "add_smalltext|`5Shows Qeme Number|left",
        "add_checkbox|qeme|`2Enable `0Qeme Mode|" .. tostring(spin.qeme) .. "|",
        "add_smalltext|`5Only Shows Number In Spin Bubble|left",
        "add_checkbox|sspin|`2Enable `0Short Spin|" .. tostring(spin.sspin) .. "|",
        "end_dialog|spinDialog|Cancel|Save"
    }

    SendDialog(table.concat(spinDialog, "\n"))
end

function realController()
    if spin.real == 0 then
        spin.real = 1
    else
        spin.real = 0
    end
end

function remeController()
    if spin.reme == 0 then
        spin.reme = 1
        print("`0Reme Mode `2On")
        say("`0Reme Mode `2On", true)
    else
        spin.reme = 0
        print("`0Reme Mode `4Off")
        say("`0Reme Mode `4Off", true)
    end
end

function lemeController()
    if spin.leme == 0 then
        spin.leme = 1
        print("`0Leme Mode `2On")
        say("`0Leme Mode `2On")
    else
        spin.leme = 0
        print("`0Leme Mode `4Off")
        say("`0Leme Mode `4Off")
    end
end

function qemeController()
    if spin.qeme == 0 then
        spin.qeme = 1
        print("`0Qeme Mode `2On")
        say("`0Qeme Mode `2On")
    else
        spin.qeme = 0
        print("`0Qeme Mode `4Off")
        say("`0Qeme Mode `4Off")
    end
end

function sspinController()
    if spin.sspin == 0 then
        spin.sspin = 1
        print("`0Short Spin Mode `2On")
        say("`0Short Spin Mode `2On")
        
    else
        spin.sspin = 0
        print("`0Short Spin Mode `4Off")
        say("`0Short Spin Mode `4Off")
    end
end

function wrmController()

end

function wrpController()

end

function wrkController()

end

function wrbController()

end

function wController()

end

function dController()

end

function bController()

end

function bbController()

end



postCommand(
    "Info",
    "/proxy",
    "Shows Proxy Commands List",
    2586
)
postCommand(
    "Info",
    "/news",
    "Shows Radiant Proxy News Update"
)
postCommand(
    "Info",
    "/gazette",
    "Shows CreativePS Gazette"
)

postCommand(
    "Roulette",
    "/spin",
    "Opens Spin Settings Dialog [alias: /roulette, /game]",
    758
)
postAlias("/roulette", "/spin")
postAlias("/game", "/spin")
postCommand(
    "Roulette",
    "/real",
    "Enable Real or Fake Spin Detector"
)
postCommand(
    "Roulette",
    "/reme",
    "Enable Reme Game"
)
postCommand(
    "Roulette",
    "/leme",
    "Enable leme Game"
)
postCommand(
    "Roulette",
    "/qeme",
    "Enable qeme Game"
)
postCommand(
    "Roulette",
    "/sspin",
    "Enable Short Spin Roulette Wheel"
)
postCommand(
    "Wrench",
    "/wrm",
    "Opens Wrench Settings Dialog [alias: /wrenchmode]",
    32
)
postAlias("/wrenchmode", "/wrm")
postCommand(
    "Wrench",
    "/wrp",
    "Enable Wrench Pull / Fast Pull Mode [alias: /wrpull]"
)
postAlias("/wrpull", "/wrp")
postCommand(
    "Wrench",
    "/wrk",
    "Enable Wrench Kick / Fast Kick Mode [alias: /wrkick]"
)
postAlias("/wrkick", "/wrk")
postCommand(
    "Wrench",
    "/wrb",
    "Enable Wrench Ban / Fast Ban Mode [alias: /wrban]"
)
postAlias("/wrban", "/wrb")

postCommand(
    "Drop",
    "/w",
    "Drop World Lock [ex: /w 9]",
    1796,
    true,
    "<amount>"
)
postCommand(
    "Drop",
    "/d",
    "Drop Diamond Lock [ex: /d 9]",
    1796,
    true,
    "<amount>"
)
postCommand(
    "Drop",
    "/b",
    "Drop Blue Gem Lock [ex: /b 9]",
    1796,
    true,
    "<amount>"
)
postCommand(
    "Drop",
    "/bb",
    "Drop Black Gem Lock [ex: /b 9]",
    1796,
    true,
    "<amount>"
)

AddHook("OnSendPacket", "commandHandler", commandHandler)

-- SPIN HANDLER
function spinHandlerPacket(type, packet)

    if packet:find("action|dialog_return\ndialog_name|spinDialog") then
        real = tonumber(packet:match("real%|(%d+)"))
        reme = tonumber(packet:match("reme%|(%d+)"))
        leme = tonumber(packet:match("leme%|(%d+)"))
        qeme = tonumber(packet:match("qeme%|(%d+)"))
        sspin = tonumber(packet:match("sspin%|(%d+)"))
        lastSpin = tonumber(packet:match("lastSpin%|(%d+)"))

        if real == 0 then
            spin.real = 0
        else
            spin.real = 1
        end

        if reme == 0 then
            spin.reme = 0
        else
            spin.reme = 1
        end

        if leme == 0 then
            spin.leme = 0
        else
            spin.leme = 1
        end    
        
        if qeme == 0 then
            spin.qeme = 0
        else
            spin.qeme = 1
        end 

        if sspin == 0 then
            spin.sspin = 0
        else
            spin.sspin = 1
        end

        if lastSpin == 0 then
            spin.lastSpin = 0
        else
            spin.lastSpin = 1
        end 
        
    end
end

function spinHandlerVariant(var, netid)
    
    if var[0] == "OnTalkBubble" and var[2]:find("spun the wheel and got") then
        is_fake = var[2]:find("<") and var[2]:find(">")
        prefix = is_fake and "`4[FAKE] " or "`2[REAL] "
        prefix = (spin.real == 1 and prefix or "")

        local bubble_netid = tonumber(var[1]) or -1

        if bubble_netid == -1 then
            return false
        end

        num_str = var[2]:match("and got (.+)")

        if num_str then
            num = string.gsub(string.gsub(num_str, "!%]", ""), "`", "")
            onlynumber = string.sub(num, 2)
            clearspace = string.gsub(onlynumber, " ", "")
            h = string.gsub(string.gsub(clearspace, "!7", ""), "]", "")
            num_parsed = tonumber(h)

            suffix = 
            (spin.reme == 1 and rules("reme", num_parsed) or "") ..
            (spin.leme == 1 and rules("leme", num_parsed) or "") ..
            (spin.qeme == 1 and rules("qeme", num_parsed) or "")

            mid = (spin.sspin == 1 and "`0" .. num_parsed or var[2])
            
            if num_parsed then
                SendVariantList({
                    [0] = "OnTalkBubble",
                    [1] = var[1],
                    [2] = prefix .. mid .. suffix
                })
                return true
            end
        end

    end

    if var[0] == "OnConsoleMessage" and var[1]:find("spun the wheel and got") then
        suffix = " `2[REAL]"
        SendVariantList({
            [0] = "OnConsoleMessage",
            [1] = "`0[`cRadiant`0] " .. var[1] .. suffix
        })
        return true
    end



end

function remeNum(number)
    number = tonumber(number)
    if not number then return "", "" end

    local num1 = math.floor(number / 10)
    local num2 = number % 10
    local sum = num1 + num2
    local result = tostring(sum):sub(-1)

    return result
end

function qemeNum(number)
    number = tonumber(number)
    if number == 0 then
        number = 1
    end
    if not number then return "", "" end

    local result = (number >= 10) and tostring(number):sub(-1) or tostring(number)

    return result
end

function rules(game, number)
    l1 = "`4"
    l2 = "`8"
    l3 = "`6"
    l4 = "`9"
    l5 = "`2"


    if game == "reme" then
        num = remeNum(number)
        num = tonumber(num)
        if num == 1 or num == 2 then
            return " `^REME " .. l1 .. num .. " "
        end
        if num == 3 or num == 4 then
            return " `^REME " .. l2 .. num .. " "
        end
        if num == 5 or num == 6 then
            return " `^REME " .. l3 .. num .. " "
        end
        if num == 7 or num == 8 then
            return " `^REME " .. l4 .. num .. " "
        end
        if num == 9 then
            return " `^REME " .. l5 .. num .. " "
        end
        if num == 0 then
            return " `^REME " .. l5 .. num .. "`0[`2X3`0] "
        end
    end

    if game == "leme" then
        num = remeNum(number)
        num = tonumber(num)
        if num == 2 or num == 3 then
            return "`5LEME " .. l1 .. num .. " "
        end
        if num == 4 or num == 5 then
            return "`5LEME " .. l2 .. num .. " "
        end
        if num == 6 or num == 7 then
            return "`5LEME " .. l3 .. num .. " "
        end
        if num == 8 or num == 9 then
            return "`5LEME " .. l4 .. num .. " "
        end
        if num == 0 then
            return "`5LEME " .. l5 .. num .. "`0[`2X4`0] "
        end
        if num == 1 then
            return "`5LEME " .. l5 .. num .. "`0[`2X3`0] "
        end
    end

    if game == "qeme" then
        num = qemeNum(number)
        num = tonumber(num)
        if num == 1 or num == 2 then
            return "`cQEME " .. l1 .. num .. " "
        end
        if num == 3 or num == 4 then
            return "`cQEME " .. l2 .. num .. " "
        end
        if num == 5 or num == 6 then
            return "`cQEME " .. l3 .. num .. " "
        end
        if num == 7 or num == 8 then
            return "`cQEME " .. l4 .. num .. " "
        end
        if num == 9 then
            return "`cQEME " .. l5 .. num .. " "
        end
        if num == 0 then
            return "`cQEME " .. l5 .. num .. "`0[`2X3`0] "
        end
    end

end

function wm(var)
    if var[0] == "OnConsoleMessage" then
        print("`0[`cRadiant`0] ``````" .. var[1])

        return true
    end

    if var[0] == "OnDialogRequest" then
        dialog = {}

        for line in var[1]:gmatch("[^\r\n]+") do
            table.insert(dialog, line)
        end

        table.insert(dialog, 1, "set_border_color|100,100,100,255|")
        table.insert(dialog, 2, "set_bg_color|45,45,45,200|")

        SendVariantList({
            [0] = "OnDialogRequest",
            [1] = table.concat(dialog, "\n")
        })
        return true
    end
end

AddHook("OnSendPacket", "spinHandler", spinHandlerPacket)
AddHook("OnVariant", "spinHandler", spinHandlerVariant)
AddHook("OnVariant", "watermark", wm)
