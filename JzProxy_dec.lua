-- ========================================
-- JzProxy Modified - Growtopia Automation
-- Version: 2.0.1 (Modified Edition)
-- Developer: JzuvDev -- Modified: VII
-- ========================================
local helpers = {}

-- ============ CONSTANTS ============
local ITEM_IDS = {
    WORLD_LOCK = 242,
    DIAMOND_LOCK = 1796,
    BLUE_GEM_LOCK = 7188,
    BLACK_GEM_LOCK = 11550,
    TELEPHONE = 3898,
    PRINCESS = 15858,
    SIGN = 459,
    CHAMPAGNE = GetItemByName('Champagne').id,
    DISPLAY_BLOCK = 2978,
    -- Surgery Tools
    SPONGE = 1258,
    SCALPEL = 1260,
    ANESTHETIC = 1262,
    ANTISEPTIC = 1264,
    ANTIBIOTICS = 1266,
    SPLINT = 1268,
    STITCHES = 1270
}

local DELAYS = {
    DROP_DELAY = 150,
    CRAFT_DELAY = 100,
    WEAR_DELAY = 100,
    SAFE_DELAY = 500,
    REJOIN_DELAY = 6000,
    SHORT_DELAY = 80
}

local LIMITS = {
    MAX_LOG_ENTRIES = 100,
    MAX_SPIN_LOGS = 200,
    MAX_COMMAND_LOGS = 50,
    INVENTORY_CACHE_TIME = 1000,
    TILE_CACHE_TIME = 2000
}

local OWNER_USER_ID = 30274
infoDialog = false -- true = tampilkan dialog hasil /infoex, false = skip dialog dan jangan hook branch ini
local auto_save_config

-- Operation flags for thread safety
local operation_flags = {
    is_dropping = false,
    is_collecting = false,
    is_converting = false,
    is_broadcasting = false,
    alt_wrench_held = false,
    alt_wrench_expires_at = 0,
    alt_wrench_hold_timeout_ms = 1200,
    setting_back_position = false,
    setting_autohost_target = nil,
    back_position_running = false,
    back_position_last_trigger_ms = 0,
    back_position_trigger_cooldown_ms = 450
}

-- Auto Surgery state
local surgery_state = {
    is_running = false,
    user_id = nil,
    surgery_count = 0,
    target_count = 100,
    gems_spent = 0,
    delays = {
        sponge = 100,
        anesthetic = 100,
        scalpel = 100,
        antiseptic = 100,
        antibiotics = 100,
        stitches = 100,
        fix = 100
    },
    tool_ids = {1258, 1260, 1262, 1264, 1266, 1268, 1270}
}

-- Hunting World state
local hunting_world = {
    is_running = false,
    mode = "text_random", -- "text_random" or "full_random"
    prefix_text = "BFG",
    random_type = "number", -- "number", "letter", "both"
    random_length = 4,
    use_numbers = true,
    world_length = 8, -- untuk full random mode
    worlds_visited = 0,
    join_delay = 10000, -- 10 detik
    idle_delay = 3000 -- 3 detik
}

-- Auto Farm state (runtime only)
local autofarm_state = {
    is_running = false,
    world_name = "",
    auto_take_remote = false,
    auto_rejoin = false,
    auto_use_buff = false
}

-- Buy Champagne state
local buychamp_state = {
    is_buying = false,
    telephone_x = 0,
    telephone_y = 0,
    amount = 1,
    bought_count = 0,
    buy_delay = 500 -- delay antar purchase
}

-- Log Backup state (for undo)
local log_backup = {
    spin_logs = nil,
    drop_logs = nil,
    collect_logs = nil,
    command_logs = nil,
    backup_time = 0,
    undo_available = false
}

-- Cache system
local cache = {
    inventory = {data = nil, timestamp = 0},
    tiles = {data = nil, timestamp = 0, world_name = ""},
    item_counts = {}
}

-- Runtime tracking for last spin result per netid
local player_spin_titles = {}
local name_overrides = {}

local function strip_spin_tag(name)
    if not name then return "" end
    -- Only remove our own spin tags like `7[`412`7], not all bracketed titles.
    local clean = tostring(name):gsub("(%s*)`7%[(.-)`7%]", function(space, inner)
        local plain = tostring(inner or ""):gsub("`.", "")
        if plain:match("^%d+$") then
            return ""
        end
        return (space or "") .. "`7[" .. tostring(inner or "") .. "`7]"
    end)
    return clean
end

local function is_spammer_slave_name(name)
    if not name then return false end
    local clean = stripColors(name)
    clean = clean:lower()
    return clean:find("spammer slave") ~= nil
end

local function build_custom_name(netid)
    if not netid or netid < 0 then return nil, 0 end
    local info = name_overrides[netid]
    local rank = info and info.rank or ""
    local base = info and info.base or nil
    local world_id = info and info.world_id or 0

    if not base then
        local ok, player = pcall(GetPlayer, netid)
        if ok and player and player.name then
            base = strip_spin_tag(player.name)
        end
    end
    if not base or base == "" then
        base = "Net" .. tostring(netid)
    end

    local spin_num = player_spin_titles[netid]
    local spin_tag = ""
    if spin_num then
        local color = "`b"
        if spin_num == 0 then
            color = "`2"
        elseif spin_num % 2 == 1 then
            color = "`4"
        end
        spin_tag = " `7[" .. color .. tostring(spin_num) .. "`7]"
    end

    return rank .. base .. spin_tag, world_id
end

local function apply_spin_title(netid, spin_num)
    if not netid or netid < 0 or not spin_num then return end
    player_spin_titles[netid] = spin_num
    RunThread(function()
        local newName, world_id = build_custom_name(netid)
        if not newName then return end
        SendVariantList({
            [0] = "OnNameChanged",
            [1] = newName,
            [2] = string.format('{"PlayerWorldID":%d,"WrenchCustomization":{"WrenchForegroundID":-1,"WrenchIconID":1464}}', world_id or 0)
        }, netid, 0)
    end)
end

-- Auto detect OS and set config path
local function get_config_path()
    local isAndroid = os.getenv("ANDROID_ROOT") or os.getenv("ANDROID_DATA")
    if isAndroid then
        return "/sdcard/Android/media/com.rtsoft.growtopia/scripts/JzProxyConfig.txt"
    else
        local userProfile = os.getenv("USERPROFILE") or os.getenv("HOME")
        if userProfile then
            return userProfile .. "\\AppData\\Local\\Growtopia\\scripts\\JzProxyConfig.txt"
        end
        return "./JzProxyConfig.txt"
    end
end

local configPath = get_config_path()

-- Gem Detector state
local pendingGems = {}

-- Ghost state
local ghost_state = {
    is_enabled = false
}

-- KeyCodes for OnInput detection
local KeyCodes = {
    Lbutton = 1,
    Rbutton = 2,
    Xbutton1 = 5,
    Xbutton2 = 6,
    Cancel = 3,
    Mbutton = 4,
    Back = 8,
    Tab = 9,
    Clear = 12,
    Return = 13,
    Shift = 16,
    Control = 17,
    Menu = 18,
    Pause = 19,
    Capital = 20,
    Escape = 27,
    Space = 32,
    Prior = 33,
    Next = 34,
    End = 35,
    Home = 36,
    Left = 37,
    Up = 38,
    Right = 39,
    Down = 40,
    Select = 41,
    Print = 42,
    Execute = 43,
    Snapshot = 44,
    Insert = 45,
    Delete = 46,
    Help = 47,
    Num0 = 48,
    Num1 = 49,
    Num2 = 50,
    Num3 = 51,
    Num4 = 52,
    Num5 = 53,
    Num6 = 54,
    Num7 = 55,
    Num8 = 56,
    Num9 = 57,
    A = 65,
    B = 66,
    C = 67,
    D = 68,
    E = 69,
    F = 70,
    G = 71,
    H = 72,
    I = 73,
    J = 74,
    K = 75,
    L = 76,
    M = 77,
    N = 78,
    O = 79,
    P = 80,
    Q = 81,
    R = 82,
    S = 83,
    T = 84,
    U = 85,
    V = 86,
    W = 87,
    X = 88,
    Y = 89,
    Z = 90,
    Lwin = 91,
    Rwin = 92,
    Apps = 93,
    Numpad0 = 96,
    Numpad1 = 97,
    Numpad2 = 98,
    Numpad3 = 99,
    Numpad4 = 100,
    Numpad5 = 101,
    Numpad6 = 102,
    Numpad7 = 103,
    Numpad8 = 104,
    Numpad9 = 105,
    Multiply = 106,
    Add = 107,
    Separator = 108,
    Subtract = 109,
    Decimal = 110,
    Divide = 111,
    F1 = 112,
    F2 = 113,
    F3 = 114,
    F4 = 115,
    F5 = 116,
    F6 = 117,
    F7 = 118,
    F8 = 119,
    F9 = 120,
    F10 = 121,
    F11 = 122,
    F12 = 123,
    F13 = 124,
    F14 = 125,
    F15 = 126,
    F16 = 127,
    F17 = 128,
    F18 = 129,
    F19 = 130,
    F20 = 131,
    F21 = 132,
    F22 = 133,
    F23 = 134,
    F24 = 135,
    Numlock = 144,
    Scroll = 145,
    Lshift = 160,
    Lcontrol = 162,
    Lmenu = 164,
    Rshift = 161,
    Rcontrol = 163,
    Rmenu = 165
}

-- Ctrl Teleport state
local ctrl_teleport = {
    is_ctrl_held = false,
    saved_position = nil,
    click_position = nil,
    is_teleported = false,
    hold_timeout_ms = 1200,
    hold_expires_at = 0
}

local shift_teleport = {
    is_shift_held = false,
    hold_timeout_ms = 1200,
    hold_expires_at = 0
}

-- Spammer runtime guard
local spam_thread_running = false
-- Blink skin runtime guard
local blink_thread_running = false

-- Auto Pull state
local auto_pull_state = {
    enabled = false,
    target_pos = nil,
    setting_position = false,
    thread_running = false,
    pending_inventory = nil,
    inventory_timeout_ms = 5000,
    pulled_users = {}
}

helpers.showoc_state = {
    world_name = "",
    tiles = {},
    scanning = false,
    watcher_running = false,
    stop_requested = false,
    last_signature = "",
    cursor = 1
}

helpers.autohost_runtime = {
    last_take_valid = false,
    last_world = "",
    last_active_slots = {},
    last_slot_values = {},
    last_pot_wl = 0,
    last_tax_wl = 0,
    last_payout_wl = 0,
    last_tax_percent = 0,
    last_return_pos = nil
}

-- ============ CONFIGURATION ============
config = {
    CURRENT_VERSION = "3.0.1",
    geminiApiKey = "AIzaSyBqToTL3RSZ6dHk9DYm8mdDfLYIBgIzfVI",
    notif = false,
    acrime = false,
    pull = false,
    kick = false,
    ban = false,
    showbal = false,
    showbal_use_chat = true, -- true = chat, false = console
    wrench_touch_pull = false,
    wrench_msg_pull = "`7Pulled `w{name}",
    wrench_msg_kick = "`6Kicked `w{name}",
    wrench_msg_ban = "`4Banned `w{name}",
    wrench_msg_showbal = "`eChecking balance: `w{name}",
    reme = false,
    spam = false,
    spammsg = "Spam Text Here @JzProxy",
    spamdelay = 9000,
    spamdelay1 = 9000,
    spamdelay2 = 9000,
    spamdelay3 = 9000,
    antiSpammerSlave = false,
    antiLagEnabled = false,
    lewa = false,
    qeme = false,
    ceme = false,
    leme = false,
    lemesuper = false,
    hol = false,
    holSpins = {}, -- Track per player: { [playerKey] = {spin1, spin2, spin3} }
    playerSpins = {}, -- Universal tracking for all players: { [playerName] = {spins = {}, results = {}} }
    cbgl = false,
    fasttrash = false,
    cvptu = false,
    fastdbl = false,
    fastdb = false,
    autocvdl = true,
    buydl = false,
    buychamp = false,
    buychamp_mode = "dl", -- "dl" or "bgems"
    autoJoinDetect = false,
    confirm_back = false,
    copy_sign_mode = false,
    auto_copy_sign = false,
    bsdb = false,
    autoGemDetect = false,
    fdice = false,
    showoc = false,
    autoToggleDoor = false,
    cbgcolor = true,
    autohost = {
        tax_percent = 0,
        host_pos = nil,
        player_slots = {
            [1] = nil,
            [2] = nil,
            [3] = nil,
            [4] = nil
        }
    },

    -- Pengaturan Broadcast
    broadcast = false,
    textsb = "",
    once_broadcast = false,
    spam_broadcast_mode = false,
    broadcast_amount = 20,
    broadcast_delay = 250, -- delay sebelum sendpacket /sb (250-500ms)
    broadcast_webhook_url = "", -- webhook URL untuk monitoring
    broadcast_webhook_enable = false, -- enable/disable webhook
    broadcast_counter = 0, -- counter untuk tracking jumlah broadcast
    broadcast_start_time = 0, -- track start time untuk calculate estimate

    -- Pengaturan Tampilan / UI
    tpdisplay = false,
    tp_ctrl_click_enabled = true,
    tp_shift_click_enabled = true,
    hotkey_ctrl_z_enabled = true,
    hotkey_f4_respawn = true,
    hotkey_alt_wrench = true,
    tpdisplay_mode = "display_only", -- "display_only" or "all_position"
    tpdisplay_delay = 3000,
    tpdisplay_return = true,
    tpdisplay_show_travel_text = true,
    tpdisplay_show_return_text = true,
    tpdisplay_show_return_chat = true,
    blink_skin = false,
    block_spammer_slave = false,
    debug_mode = false,
    rainbow_text = false,
    rbt_mode = "rainbow", -- "single", "rainbow", "smooth", "custom"
    rbt_single_color = "`e",
    rbt_custom_colors = "`4,`9,`2",
    rbt_smooth_speed = 1, -- 1-10
    rbt_smooth_span = 1, -- 1-10
    rbt_rainbow_colors = {
        "`3", "`e", "`5", "`#", "`4", "`8", "`9", "`^", "`2", "`c", "`1", "`w"
    },
    emoji_text = false,
    event_button_hide = false,
    watermark_mode = false,
    watermark_text = "`6[ `eJz`qSB`6 ]",
    dialogBorder = "100,100,100,255", -- default border color
    dialogBg     = "45,45,45,200", -- default background color
    ui_theme_variant = "vibrant_neon",
    ui_icon_mode = "hybrid", -- "hybrid", "emoji_only", "text_only", "iconfontcpp", "iconfont_hybrid"
    imgui_last_tab = "command",
    imgui_safe_fallback = true,

    -- Pengaturan Logging
    logspin = true,
    logcommand = false,
    logdrop_enable = false,
    loggeneral = false,
    tablelogspin = {},
    tablelogcommand = {},
    logdrop = "",
    logcollect = "",

    -- Pelacakan Status / Data (Biasanya Berubah Saat Runtime)
    isDropping = false,
    lastResult = 0,
    lastResultNum = 0,
    last_deposit = 0,
    bank_balance = 0,
    last_withdraw = 0,
    wdvend = false,
    emptyvend = false,
    vendfilter = false,
    dboxfilter = false,
    
    -- Custom Drop Commands
    cmd_drop_wl = "w",
    cmd_drop_dl = "d",
    cmd_drop_bgl = "b",
    cmd_drop_black = "bb",
    sspin = false,
    currentSkin = "Default",
}

local SkinColors = {
    {code = "`0", name = "Default",         r=255, g=255, b=255, a=255},
    {code = "`1", name = "Light cyan",      r=173, g=244, b=255, a=255},
    {code = "`2", name = "Green",           r=73,  g=252, b=0,   a=255},
    {code = "`3", name = "Light blue",      r=191, g=218, b=255, a=255},
    {code = "`4", name = "Crazy red",       r=255, g=39,  b=29,  a=255},
    {code = "`5", name = "Pinky purple",    r=235, g=183, b=255, a=255},
    {code = "`6", name = "Brown",           r=255, g=202, b=111, a=255},
    {code = "`7", name = "Light gray",      r=230, g=230, b=230, a=255},
    {code = "`8", name = "Crazy orange",    r=255, g=148, b=69,  a=255},
    {code = "`9", name = "Yellow",          r=255, g=238, b=125, a=255},
    {code = "`!", name = "Bright cyan",     r=209, g=255, b=249, a=255},
    {code = "`@", name = "Bright red/pink", r=255, g=205, b=201, a=255},
    {code = "`#", name = "Bright purple",   r=255, g=143, b=243, a=255},
    {code = "`$", name = "Pale yellow",     r=255, g=252, b=197, a=255},
    {code = "`^", name = "Light green",     r=181, g=255, b=151, a=255},
    {code = "`&", name = "Very pale pink",  r=254, g=235, b=255, a=255},
    {code = "`w", name = "White",           r=255, g=255, b=255, a=255},
    {code = "`o", name = "Dreamsicle",      r=252, g=230, b=186, a=255},
    {code = "`p", name = "Pink",            r=255, g=223, b=241, a=255},
    {code = "`b", name = "Black",           r=0,   g=0,   b=0,   a=255},
    {code = "`q", name = "Dark blue",       r=12,  g=96,  b=164, a=255},
    {code = "`e", name = "Medium blue",     r=25,  g=185, b=255, a=255},
    {code = "`r", name = "Pale green",      r=111, g=211, b=87,  a=255},
    {code = "`t", name = "Medium green",    r=47,  g=131, b=13,  a=255},
    {code = "`a", name = "Dark grey",       r=81,  g=81,  b=81,  a=255},
    {code = "`s", name = "Med grey",        r=158, g=158, b=158, a=255},
    {code = "`c", name = "Vibrant cyan",    r=80,  g=255, b=255, a=255},
}

local DEFAULT_RBT_COLORS = {"`3", "`e", "`5", "`#", "`4", "`8", "`9", "`^", "`2", "`c", "`1", "`w"}
local DEFAULT_RBT_CUSTOM_COLORS = {"`4", "`9", "`2"}
local RBT_VALID_CODES = {}
local rbt_runtime_offset = 1

for _, color in ipairs(SkinColors) do
    if color and color.code then
        RBT_VALID_CODES[color.code] = true
    end
end

local function normalize_rbt_mode(mode)
    local value = tostring(mode or ""):lower()
    if value == "single" or value == "rainbow" or value == "smooth" or value == "custom" then
        return value
    end
    return "rainbow"
end

local function clamp_rbt_number(value, min_value, max_value, default_value)
    local num = tonumber(value)
    if not num then
        num = default_value
    end
    num = math.floor(num)
    if num < min_value then num = min_value end
    if num > max_value then num = max_value end
    return num
end

local function normalize_rbt_code(code)
    if type(code) ~= "string" then
        return nil
    end
    local cleaned = code:gsub("%s+", "")
    if cleaned == "" then
        return nil
    end
    if cleaned:sub(1, 1) ~= "`" then
        cleaned = "`" .. cleaned
    end
    if RBT_VALID_CODES[cleaned] then
        return cleaned
    end
    return nil
end

local function ensure_rbt_palette_table(value, fallback)
    local output = {}
    local seen = {}

    if type(value) == "table" then
        for _, token in ipairs(value) do
            local normalized = normalize_rbt_code(token)
            if normalized and not seen[normalized] then
                seen[normalized] = true
                table.insert(output, normalized)
            end
        end
    end

    if #output == 0 then
        local source = fallback or DEFAULT_RBT_COLORS
        for _, token in ipairs(source) do
            local normalized = normalize_rbt_code(token)
            if normalized and not seen[normalized] then
                seen[normalized] = true
                table.insert(output, normalized)
            end
        end
    end

    return output
end

local function parse_rbt_color_list(raw)
    local output = {}
    if type(raw) ~= "string" then
        return output
    end

    local seen = {}
    for token in raw:gmatch("[^,%s;|]+") do
        local normalized = normalize_rbt_code(token)
        if normalized and not seen[normalized] then
            seen[normalized] = true
            table.insert(output, normalized)
        end
    end

    return output
end

local function list_to_rbt_string(colors)
    if type(colors) ~= "table" or #colors == 0 then
        return table.concat(DEFAULT_RBT_COLORS, ",")
    end
    return table.concat(colors, ",")
end

local function get_rbt_palette(mode)
    local selected_mode = normalize_rbt_mode(mode or config.rbt_mode)
    if selected_mode == "single" then
        return {normalize_rbt_code(config.rbt_single_color) or "`e"}
    end

    if selected_mode == "custom" or selected_mode == "smooth" then
        local parsed = parse_rbt_color_list(config.rbt_custom_colors or "")
        if #parsed == 0 then
            parsed = ensure_rbt_palette_table(config.rbt_rainbow_colors, DEFAULT_RBT_CUSTOM_COLORS)
        end
        return parsed
    end

    return ensure_rbt_palette_table(config.rbt_rainbow_colors, DEFAULT_RBT_COLORS)
end

local function apply_rbt_to_text(text, force_apply)
    if type(text) ~= "string" or text == "" then
        return text or ""
    end

    if not force_apply and not config.rainbow_text then
        return text
    end

    local mode = normalize_rbt_mode(config.rbt_mode)
    local palette = get_rbt_palette(mode)
    if #palette == 0 then
        return text
    end

    local smooth_span = clamp_rbt_number(config.rbt_smooth_span, 1, 10, 1)
    local smooth_speed = clamp_rbt_number(config.rbt_smooth_speed, 1, 10, 1)
    local output = {}
    local color_index = 1
    local painted_chars = 0

    if mode == "smooth" then
        color_index = ((rbt_runtime_offset - 1) % #palette) + 1
    end

    for i = 1, #text do
        local char = text:sub(i, i)
        if char:match("[%w%p%s]") then
            table.insert(output, palette[color_index] .. char)
            painted_chars = painted_chars + 1

            if mode == "single" then
                -- Keep one color for all characters.
            elseif mode == "smooth" then
                if painted_chars % smooth_span == 0 then
                    color_index = color_index + 1
                    if color_index > #palette then
                        color_index = 1
                    end
                end
            else
                color_index = color_index + 1
                if color_index > #palette then
                    color_index = 1
                end
            end
        else
            table.insert(output, char)
        end
    end

    if mode == "smooth" then
        rbt_runtime_offset = rbt_runtime_offset + smooth_speed
        if rbt_runtime_offset > 1000000 then
            rbt_runtime_offset = ((rbt_runtime_offset - 1) % #palette) + 1
        end
    end

    return table.concat(output)
end

function helpers.NormalizeAutoPullDirection(value)
    local direction = tostring(value or ""):lower()
    if direction == "left" then
        return "left"
    end
    return "right"
end

function helpers.NormalizeBackPositionWorld(value)
    local world_name = tostring(value or "")
    if type(stripColors) == "function" then
        local ok_strip, stripped = pcall(stripColors, world_name)
        if ok_strip and stripped ~= nil then
            world_name = tostring(stripped)
        end
    end
    world_name = world_name:gsub("%s+", "")
    return world_name:upper()
end

function helpers.NormalizeAutoHostWorld(value)
    return helpers.NormalizeBackPositionWorld(value)
end

helpers.AUTOHOST_LOCK_VALUES = {
    [ITEM_IDS.WORLD_LOCK] = 1,
    [ITEM_IDS.DIAMOND_LOCK] = 100,
    [ITEM_IDS.BLUE_GEM_LOCK] = 10000,
    [ITEM_IDS.BLACK_GEM_LOCK] = 1000000
}
helpers.AUTOHOST_SLOT_THRESHOLD_PX = 20

function helpers.AutoHostFormatPercent(value)
    local number = tonumber(value) or 0
    return string.format("%g", number)
end

function helpers.GetAutoHostCurrentWorldName()
    local ok_world, world = pcall(GetWorld)
    return helpers.NormalizeAutoHostWorld(ok_world and world and world.name or "")
end

function helpers.GetAutoHostBreakdown(total_wl)
    local remain = math.max(0, math.floor(tonumber(total_wl) or 0))
    local black = math.floor(remain / 1000000)
    remain = remain % 1000000
    local bgl = math.floor(remain / 10000)
    remain = remain % 10000
    local dl = math.floor(remain / 100)
    local wl = remain % 100
    return black, bgl, dl, wl
end

function helpers.FormatAutoHostValueText(total_wl)
    local black, bgl, dl, wl = helpers.GetAutoHostBreakdown(total_wl)
    local parts = {}
    if black > 0 then table.insert(parts, "`b" .. black .. " BLACK") end
    if bgl > 0 then table.insert(parts, "`e" .. bgl .. " BGL") end
    if dl > 0 then table.insert(parts, "`1" .. dl .. " DL") end
    if wl > 0 or #parts == 0 then table.insert(parts, "`9" .. wl .. " WL") end
    return table.concat(parts, " `8+ ")
end

function helpers.GetAutoHostSlotData(slot_index)
    local slots = config.autohost and config.autohost.player_slots
    local slot = type(slots) == "table" and slots[slot_index] or nil
    if type(slot) ~= "table" then
        return nil
    end

    local slot_x = tonumber(slot.x)
    local slot_y = tonumber(slot.y)
    if not slot_x or not slot_y then
        return nil
    end

    return {
        index = slot_index,
        x = math.floor(slot_x),
        y = math.floor(slot_y),
        world = helpers.NormalizeAutoHostWorld(slot.world),
        label = "P" .. tostring(slot_index)
    }
end

function helpers.GetAutoHostActiveSlots()
    local world_name = helpers.GetAutoHostCurrentWorldName()
    local active = {}

    for slot_index = 1, 4 do
        local slot = helpers.GetAutoHostSlotData(slot_index)
        if slot and slot.world ~= "" and slot.world == world_name then
            table.insert(active, slot)
        end
    end

    table.sort(active, function(a, b)
        return a.index < b.index
    end)

    return active, world_name
end

function helpers.IsAutoHostObjectNearSlot(slot, obj)
    if type(slot) ~= "table" or type(obj) ~= "table" or type(obj.pos) ~= "table" then
        return false
    end

    local slot_x = tonumber(slot.x)
    local slot_y = tonumber(slot.y)
    local obj_x = tonumber(obj.pos.x)
    local obj_y = tonumber(obj.pos.y)
    if not slot_x or not slot_y or not obj_x or not obj_y then
        return false
    end

    local center_x = math.floor(slot_x) * 32 + 16
    local center_y = math.floor(slot_y) * 32 + 16
    local threshold = math.max(0, math.floor(tonumber(helpers.AUTOHOST_SLOT_THRESHOLD_PX) or 20))

    return math.abs(obj_x - center_x) <= threshold and math.abs(obj_y - center_y) <= threshold
end

function helpers.GetAutoHostSlotValueWL(slot)
    if type(slot) ~= "table" then
        return 0
    end

    local total_wl = 0
    local objects = GetObjectList() or {}

    for _, obj in pairs(objects) do
        local unit_value = helpers.AUTOHOST_LOCK_VALUES[tonumber(obj.id) or 0]
        if unit_value and helpers.IsAutoHostObjectNearSlot(slot, obj) then
            total_wl = total_wl + (math.floor(tonumber(obj.amount) or 0) * unit_value)
        end
    end

    return total_wl
end

function helpers.TakeAutoHostAtSlot(slot)
    if type(slot) ~= "table" then
        return
    end

    local objects = GetObjectList() or {}
    for _, obj in pairs(objects) do
        if helpers.AUTOHOST_LOCK_VALUES[tonumber(obj.id) or 0] and helpers.IsAutoHostObjectNearSlot(slot, obj) then
            local pkt = {
                type = 11,
                value = obj.oid,
                x = obj.pos.x,
                y = obj.pos.y
            }
            SendPacketRaw(false, pkt)
        end
    end
end

function helpers.BuildAutoHostSnapshot()
    local active_slots, world_name = helpers.GetAutoHostActiveSlots()
    if #active_slots < 2 then
        return false, "`4Need at least 2 active player positions in this world."
    end

    local snapshot = {
        world = world_name,
        slots = {},
        slot_values = {},
        active_count = #active_slots
    }

    local expected_wl = nil
    for _, slot in ipairs(active_slots) do
        local bet_wl = helpers.GetAutoHostSlotValueWL(slot)
        snapshot.slot_values[slot.index] = bet_wl

        if bet_wl <= 0 then
            return false, "`4Bet Not Match"
        end

        if expected_wl == nil then
            expected_wl = bet_wl
        elseif expected_wl ~= bet_wl then
            return false, "`4Bet Not Match"
        end

        table.insert(snapshot.slots, {
            index = slot.index,
            x = slot.x,
            y = slot.y,
            world = slot.world,
            value_wl = bet_wl
        })
    end

    snapshot.per_player_wl = expected_wl or 0
    snapshot.pot_total_wl = snapshot.per_player_wl * #snapshot.slots
    snapshot.tax_percent = tonumber(config.autohost and config.autohost.tax_percent) or 0
    snapshot.tax_wl = math.floor(snapshot.pot_total_wl * snapshot.tax_percent / 100)
    snapshot.payout_wl = math.max(0, snapshot.pot_total_wl - snapshot.tax_wl)
    return true, snapshot
end

function helpers.WaitForAutoHostTile(target_x, target_y, timeout_ms)
    local timeout = math.max(0, math.floor(tonumber(timeout_ms) or 1000))
    local elapsed = 0
    while elapsed <= timeout do
        local ok_local, local_player = pcall(GetLocal)
        if ok_local and local_player and local_player.pos then
            local current_x = math.floor(tonumber(local_player.pos.x or 0) / 32)
            local current_y = math.floor(tonumber(local_player.pos.y or 0) / 32)
            if current_x == target_x and current_y == target_y then
                return true
            end
        end
        Sleep(100)
        elapsed = elapsed + 100
    end
    return false
end

function helpers.EnsureAutoHostBlackCount(required_count)
    local required = math.max(0, math.floor(tonumber(required_count) or 0))
    local attempts = 0
    while GetItemCount(ITEM_IDS.BLACK_GEM_LOCK) < required and attempts < 12 do
        local missing = required - GetItemCount(ITEM_IDS.BLACK_GEM_LOCK)
        if GetItemCount(ITEM_IDS.BLUE_GEM_LOCK) < (missing * 100) then
            break
        end
        SendPacket(2, "action|dialog_return\ndialog_name|info_box\nbuttonClicked|make_bgl")
        Sleep(900)
        attempts = attempts + 1
    end
    return GetItemCount(ITEM_IDS.BLACK_GEM_LOCK) >= required
end

function helpers.BreakAutoHostFromHigher(item_id)
    if item_id == ITEM_IDS.BLUE_GEM_LOCK then
        if GetItemCount(ITEM_IDS.BLACK_GEM_LOCK) > 0 then
            SendPacket(2, "action|dialog_return\ndialog_name|info_box\nbuttonClicked|make_bluegl")
            Sleep(900)
            return true
        end
    elseif item_id == ITEM_IDS.DIAMOND_LOCK then
        if GetItemCount(ITEM_IDS.BLUE_GEM_LOCK) > 0 then
            helpers.OnWear(ITEM_IDS.BLUE_GEM_LOCK)
            Sleep(500)
            return true
        end
        if GetItemCount(ITEM_IDS.BLACK_GEM_LOCK) > 0 then
            SendPacket(2, "action|dialog_return\ndialog_name|info_box\nbuttonClicked|make_bluegl")
            Sleep(900)
            if GetItemCount(ITEM_IDS.BLUE_GEM_LOCK) > 0 then
                helpers.OnWear(ITEM_IDS.BLUE_GEM_LOCK)
                Sleep(500)
                return true
            end
        end
    elseif item_id == ITEM_IDS.WORLD_LOCK then
        if GetItemCount(ITEM_IDS.DIAMOND_LOCK) > 0 then
            helpers.OnWear(ITEM_IDS.DIAMOND_LOCK)
            Sleep(500)
            return true
        end
        if GetItemCount(ITEM_IDS.BLUE_GEM_LOCK) > 0 then
            helpers.OnWear(ITEM_IDS.BLUE_GEM_LOCK)
            Sleep(500)
            if GetItemCount(ITEM_IDS.DIAMOND_LOCK) > 0 then
                helpers.OnWear(ITEM_IDS.DIAMOND_LOCK)
                Sleep(500)
                return true
            end
        end
        if GetItemCount(ITEM_IDS.BLACK_GEM_LOCK) > 0 then
            SendPacket(2, "action|dialog_return\ndialog_name|info_box\nbuttonClicked|make_bluegl")
            Sleep(900)
            if GetItemCount(ITEM_IDS.BLUE_GEM_LOCK) > 0 then
                helpers.OnWear(ITEM_IDS.BLUE_GEM_LOCK)
                Sleep(500)
                if GetItemCount(ITEM_IDS.DIAMOND_LOCK) > 0 then
                    helpers.OnWear(ITEM_IDS.DIAMOND_LOCK)
                    Sleep(500)
                    return true
                end
            end
        end
    end
    return false
end

function helpers.EnsureAutoHostCount(item_id, required_count)
    local required = math.max(0, math.floor(tonumber(required_count) or 0))
    if required <= 0 then
        return true
    end

    if item_id == ITEM_IDS.BLACK_GEM_LOCK then
        return helpers.EnsureAutoHostBlackCount(required)
    end

    local attempts = 0
    while GetItemCount(item_id) < required and attempts < 18 do
        if not helpers.BreakAutoHostFromHigher(item_id) then
            break
        end
        attempts = attempts + 1
    end
    return GetItemCount(item_id) >= required
end

function helpers.DropAutoHostPayout(total_wl)
    local payout_wl = math.max(0, math.floor(tonumber(total_wl) or 0))
    if payout_wl <= 0 then
        return false, "Payout is zero."
    end

    local black, bgl, dl, wl = helpers.GetAutoHostBreakdown(payout_wl)

    if not helpers.EnsureAutoHostCount(ITEM_IDS.BLACK_GEM_LOCK, black) then
        return false, "Not enough BLACK for payout."
    end
    if not helpers.EnsureAutoHostCount(ITEM_IDS.BLUE_GEM_LOCK, bgl) then
        return false, "Not enough BGL for payout."
    end
    if not helpers.EnsureAutoHostCount(ITEM_IDS.DIAMOND_LOCK, dl) then
        return false, "Not enough DL for payout."
    end
    if not helpers.EnsureAutoHostCount(ITEM_IDS.WORLD_LOCK, wl) then
        return false, "Not enough WL for payout."
    end

    if black > 0 then
        helpers.OnDroppedItem(ITEM_IDS.BLACK_GEM_LOCK, black)
        Sleep(DELAYS.DROP_DELAY)
    end
    if bgl > 0 then
        helpers.OnDroppedItem(ITEM_IDS.BLUE_GEM_LOCK, bgl)
        Sleep(DELAYS.DROP_DELAY)
    end
    if dl > 0 then
        helpers.OnDroppedItem(ITEM_IDS.DIAMOND_LOCK, dl)
        Sleep(DELAYS.DROP_DELAY)
    end
    if wl > 0 then
        helpers.OnDroppedItem(ITEM_IDS.WORLD_LOCK, wl)
        Sleep(DELAYS.DROP_DELAY)
    end

    return true
end

function helpers.BuildAutoHostPreviewLines()
    local nodes = {}
    local host_pos = type(config.autohost) == "table" and config.autohost.host_pos or nil
    if type(host_pos) == "table" and tonumber(host_pos.x) and tonumber(host_pos.y) then
        table.insert(nodes, {
            label = "H",
            x = math.floor(tonumber(host_pos.x) or 0),
            y = math.floor(tonumber(host_pos.y) or 0)
        })
    end

    for slot_index = 1, 4 do
        local slot = helpers.GetAutoHostSlotData(slot_index)
        if slot then
            table.insert(nodes, {
                label = "P" .. tostring(slot_index),
                x = slot.x,
                y = slot.y
            })
        end
    end

    if #nodes == 0 then
        return {
            "add_smalltext|`8No positions set yet.|left|"
        }
    end

    local x_seen, y_seen, xs, ys = {}, {}, {}, {}
    for _, node in ipairs(nodes) do
        if not x_seen[node.x] then
            x_seen[node.x] = true
            table.insert(xs, node.x)
        end
        if not y_seen[node.y] then
            y_seen[node.y] = true
            table.insert(ys, node.y)
        end
    end
    table.sort(xs)
    table.sort(ys)

    local lines = {}
    if #xs > 8 or #ys > 8 then
        for _, node in ipairs(nodes) do
            table.insert(lines, string.format("add_smalltext|`9[%s] `w(%d, %d)|left|", node.label, node.x, node.y))
        end
        return lines
    end

    for _, y_value in ipairs(ys) do
        local row_parts = {}
        for _, x_value in ipairs(xs) do
            local token = "....."
            for _, node in ipairs(nodes) do
                if node.x == x_value and node.y == y_value then
                    token = "[" .. node.label .. "]"
                    break
                end
            end
            table.insert(row_parts, token)
        end
        table.insert(lines, "add_smalltext|`9" .. table.concat(row_parts, " `8") .. string.format(" `7(y=%d)|left|", y_value))
    end

    return lines
end

function helpers.ShowAutoHostDialog()
    local runtime = helpers.autohost_runtime or {}
    local current_world = helpers.GetAutoHostCurrentWorldName()
    local host_pos = type(config.autohost) == "table" and config.autohost.host_pos or nil
    local host_text = "`4Not Set"
    if type(host_pos) == "table" and tonumber(host_pos.x) and tonumber(host_pos.y) then
        host_text = string.format("`2(%d, %d)`8 [%s]", math.floor(tonumber(host_pos.x) or 0), math.floor(tonumber(host_pos.y) or 0), helpers.NormalizeAutoHostWorld(host_pos.world))
    end

    local lines = {
        "set_default_color|`o",
        "set_border_color|" .. tostring(config.dialogBorder or "100,100,100,255") .. "|",
        "set_bg_color|" .. tostring(config.dialogBg or "45,45,45,200") .. "|",
        "add_label_with_icon|big|`6Auto HOST Panel|left|758|",
        "add_spacer|small|",
        "add_smalltext|`9Current World: `w" .. (current_world ~= "" and current_world or "UNKNOWN") .. "|left|",
        "add_smalltext|`9Tax: `w" .. helpers.AutoHostFormatPercent(config.autohost.tax_percent) .. "`9%|left|",
        "add_smalltext|`9Host Position: " .. host_text .. "|left|",
        "add_spacer|small|",
        "add_label_with_icon|small|`ePlayer Slots|left|1384|",
        "add_spacer|small|"
    }

    for slot_index = 1, 4 do
        local slot = helpers.GetAutoHostSlotData(slot_index)
        local slot_text = "`4Not Set"
        if slot then
            slot_text = string.format("`2(%d, %d)`8 [%s]", slot.x, slot.y, slot.world ~= "" and slot.world or "NO WORLD")
        end
        table.insert(lines, "add_smalltext|`9P" .. tostring(slot_index) .. ": " .. slot_text .. " `7| Winner Command: /w" .. tostring(slot_index) .. "|left|")
    end

    table.insert(lines, "add_spacer|small|")
    table.insert(lines, "add_label_with_icon|small|`2Last Take Result|left|1438|")
    table.insert(lines, "add_spacer|small|")
    table.insert(lines, "add_smalltext|`9Valid: " .. (runtime.last_take_valid and "`2YES" or "`4NO") .. "|left|")
    table.insert(lines, "add_smalltext|`9Active Slots: `w" .. tostring(#(runtime.last_active_slots or {})) .. "|left|")
    table.insert(lines, "add_smalltext|`9Per Player Bet: `w" .. helpers.FormatAutoHostValueText((runtime.last_slot_values and runtime.last_slot_values[(runtime.last_active_slots and runtime.last_active_slots[1]) or 0]) or 0) .. "|left|")
    table.insert(lines, "add_smalltext|`9Pot Total: `w" .. helpers.FormatAutoHostValueText(runtime.last_pot_wl or 0) .. "|left|")
    table.insert(lines, "add_smalltext|`9Tax Cut: `w" .. helpers.FormatAutoHostValueText(runtime.last_tax_wl or 0) .. " `8(" .. helpers.AutoHostFormatPercent(runtime.last_tax_percent or 0) .. "%)|left|")
    table.insert(lines, "add_smalltext|`9Winner Payout: `w" .. helpers.FormatAutoHostValueText(runtime.last_payout_wl or 0) .. "|left|")
    table.insert(lines, "add_spacer|small|")
    table.insert(lines, "add_label_with_icon|small|`3Layout Preview|left|6016|")
    table.insert(lines, "add_spacer|small|")

    local preview_lines = helpers.BuildAutoHostPreviewLines()
    for _, line in ipairs(preview_lines) do
        table.insert(lines, line)
    end

    table.insert(lines, "add_spacer|small|")
    table.insert(lines, "add_button|autohost_reset_all_pos|`4Reset All Pos|noflags|0|0|")
    table.insert(lines, "add_spacer|small|")
    table.insert(lines, "add_smalltext|`8Commands: /p1-4 to set player tiles, /hp to set host tile, /take to collect, /w1-4 to pay winner.|left|")
    table.insert(lines, "add_quick_exit||")
    table.insert(lines, "end_dialog|autohost_dialog|Close||")
    SendVariantList({[0] = "OnDialogRequest", [1] = table.concat(lines, "\n"), netid = -1})
end

function helpers.ResetAutoHostPositions()
    config.autohost.host_pos = nil
    config.autohost.player_slots = {
        [1] = nil,
        [2] = nil,
        [3] = nil,
        [4] = nil
    }
    helpers.autohost_runtime.last_take_valid = false
    helpers.autohost_runtime.last_active_slots = {}
    helpers.autohost_runtime.last_slot_values = {}
    helpers.autohost_runtime.last_pot_wl = 0
    helpers.autohost_runtime.last_tax_wl = 0
    helpers.autohost_runtime.last_payout_wl = 0
    helpers.autohost_runtime.last_tax_percent = tonumber(config.autohost.tax_percent) or 0
    helpers.autohost_runtime.last_return_pos = nil
    auto_save_config(true)
end

function helpers.HandleAutoHostWorldTouch(pos, start)
    local target_key = operation_flags.setting_autohost_target
    if not target_key or not start then
        return false
    end

    if not (pos and pos.x and pos.y) then
        return false
    end

    local tile_x = math.floor(pos.x / 32)
    local tile_y = math.floor(pos.y / 32)
    local world_name = helpers.GetAutoHostCurrentWorldName()

    if target_key == "hp" then
        config.autohost.host_pos = {
            x = tile_x,
            y = tile_y,
            world = world_name
        }
        helpers.SendNotification("`2Host Position set to: `9" .. tile_x .. "`2, `9" .. tile_y)
        helpers.OnConsoleMessage("`2[AutoHost] Host Position saved: `9(" .. tile_x .. ", " .. tile_y .. ")")
    else
        local slot_index = tonumber(tostring(target_key):match("^p([1-4])$"))
        if slot_index then
            config.autohost.player_slots[slot_index] = {
                x = tile_x,
                y = tile_y,
                world = world_name
            }
            helpers.SendNotification("`2Player " .. slot_index .. " position set to: `9" .. tile_x .. "`2, `9" .. tile_y)
            helpers.OnConsoleMessage("`2[AutoHost] P" .. slot_index .. " saved: `9(" .. tile_x .. ", " .. tile_y .. ")")
        end
    end

    operation_flags.setting_autohost_target = nil
    auto_save_config()
    helpers.SendTileEffect(tile_x * 32 + 16, tile_y * 32 + 16)
    return false
end

function helpers.ExecuteAutoHostTake()
    local ok_snapshot, snapshot_or_message = helpers.BuildAutoHostSnapshot()
    if not ok_snapshot then
        helpers.autohost_runtime.last_take_valid = false
        helpers.OnTextOverlay(snapshot_or_message)
        helpers.OnConsoleMessage(snapshot_or_message)
        return true
    end

    local snapshot = snapshot_or_message
    RunThread(function(captured_snapshot)
        for _, slot in ipairs(captured_snapshot.slots) do
            helpers.TakeAutoHostAtSlot(slot)
            Sleep(120)
        end

        helpers.autohost_runtime.last_take_valid = true
        helpers.autohost_runtime.last_world = captured_snapshot.world
        helpers.autohost_runtime.last_active_slots = {}
        helpers.autohost_runtime.last_slot_values = {}
        for _, slot in ipairs(captured_snapshot.slots) do
            table.insert(helpers.autohost_runtime.last_active_slots, slot.index)
            helpers.autohost_runtime.last_slot_values[slot.index] = slot.value_wl
        end
        helpers.autohost_runtime.last_pot_wl = captured_snapshot.pot_total_wl
        helpers.autohost_runtime.last_tax_wl = captured_snapshot.tax_wl
        helpers.autohost_runtime.last_payout_wl = captured_snapshot.payout_wl
        helpers.autohost_runtime.last_tax_percent = captured_snapshot.tax_percent

        helpers.OnTextOverlay("`2Auto HOST take success")
        helpers.OnConsoleMessage("`2[AutoHost] Bets collected from `w" .. tostring(#captured_snapshot.slots) .. " `2slot(s).")
        helpers.OnConsoleMessage("`2[AutoHost] Pot: `w" .. helpers.FormatAutoHostValueText(captured_snapshot.pot_total_wl))
        helpers.OnConsoleMessage("`2[AutoHost] Tax: `w" .. helpers.FormatAutoHostValueText(captured_snapshot.tax_wl) .. " `8(" .. helpers.AutoHostFormatPercent(captured_snapshot.tax_percent) .. "%)")
        helpers.OnConsoleMessage("`2[AutoHost] Winner payout: `w" .. helpers.FormatAutoHostValueText(captured_snapshot.payout_wl))
    end, snapshot)

    return true
end

function helpers.ExecuteAutoHostWinner(slot_index)
    local runtime = helpers.autohost_runtime or {}
    local target_slot = helpers.GetAutoHostSlotData(slot_index)
    local current_world = helpers.GetAutoHostCurrentWorldName()

    if not target_slot or target_slot.world ~= current_world then
        helpers.OnTextOverlay("`4Winner slot is not set in this world.")
        return true
    end

    if not runtime.last_take_valid or helpers.NormalizeAutoHostWorld(runtime.last_world) ~= current_world then
        helpers.OnTextOverlay("`4No valid /take result for this world.")
        return true
    end

    local slot_allowed = false
    for _, active_index in ipairs(runtime.last_active_slots or {}) do
        if active_index == slot_index then
            slot_allowed = true
            break
        end
    end
    if not slot_allowed then
        helpers.OnTextOverlay("`4Winner slot is not part of the last valid take.")
        return true
    end

    local payout_wl = math.floor(tonumber(runtime.last_payout_wl) or 0)
    if payout_wl <= 0 then
        helpers.OnTextOverlay("`4No payout available.")
        return true
    end

    local ok_local, local_player = pcall(GetLocal)
    if not (ok_local and local_player and local_player.pos) then
        helpers.OnTextOverlay("`4Unable to read local player position.")
        return true
    end

    local saved_host_pos = type(config.autohost.host_pos) == "table" and config.autohost.host_pos or nil
    local return_x, return_y = math.floor(tonumber(local_player.pos.x or 0) / 32), math.floor(tonumber(local_player.pos.y or 0) / 32)
    if type(saved_host_pos) == "table" and helpers.NormalizeAutoHostWorld(saved_host_pos.world) == current_world then
        return_x = math.floor(tonumber(saved_host_pos.x) or return_x)
        return_y = math.floor(tonumber(saved_host_pos.y) or return_y)
    end

    runtime.last_return_pos = {
        x = return_x,
        y = return_y,
        world = current_world
    }

    RunThread(function(target_x, target_y, slot_no, payout_total_wl, back_x, back_y)
        FindPath(target_x, target_y)
        helpers.WaitForAutoHostTile(target_x, target_y, 1600)

        if type(SetFacingLeft) == "function" then
            local face_left = target_x < back_x
            pcall(SetFacingLeft, face_left)
            Sleep(80)
        end

        local ok_drop, drop_err = helpers.DropAutoHostPayout(payout_total_wl)
        if not ok_drop then
            helpers.OnTextOverlay("`4" .. tostring(drop_err or "Auto HOST payout failed."))
            helpers.OnConsoleMessage("`4[AutoHost] Payout failed: `w" .. tostring(drop_err))
            return
        end

        helpers.OnConsoleMessage("`2[AutoHost] Winner `wP" .. tostring(slot_no) .. " `2paid: `w" .. helpers.FormatAutoHostValueText(payout_total_wl))
        helpers.OnTextOverlay("`2Paid winner P" .. tostring(slot_no))

        FindPath(back_x, back_y)
        helpers.WaitForAutoHostTile(back_x, back_y, 2000)

        helpers.autohost_runtime.last_take_valid = false
    end, target_slot.x, target_slot.y, slot_index, payout_wl, return_x, return_y)

    return true
end

function helpers.NormalizeSpamDelay(value, fallback)
    local delay = tonumber(value)
    if not delay then
        delay = tonumber(fallback) or tonumber(config.spamdelay) or 1000
    end
    delay = math.floor(delay)
    if delay < 1000 then
        delay = 1000
    end
    return delay
end

config.rbt_mode = normalize_rbt_mode(config.rbt_mode)
config.rbt_single_color = normalize_rbt_code(config.rbt_single_color) or "`e"
config.rbt_rainbow_colors = ensure_rbt_palette_table(config.rbt_rainbow_colors, DEFAULT_RBT_COLORS)

local initial_custom = parse_rbt_color_list(config.rbt_custom_colors or "")
if #initial_custom == 0 then
    initial_custom = ensure_rbt_palette_table(DEFAULT_RBT_CUSTOM_COLORS, DEFAULT_RBT_COLORS)
end
config.rbt_custom_colors = list_to_rbt_string(initial_custom)
config.rbt_smooth_speed = clamp_rbt_number(config.rbt_smooth_speed, 1, 10, 1)
config.rbt_smooth_span = clamp_rbt_number(config.rbt_smooth_span, 1, 10, 1)

local function normalize_runtime_compat_config()
    if config.fastdb == nil and config.fastdbl ~= nil then
        config.fastdb = config.fastdbl and true or false
    end
    if config.fastdb == nil then
        config.fastdb = false
    end
    if config.fastdbl == true and config.fastdb ~= true then
        config.fastdb = true
    end
    config.fastdb = config.fastdb and true or false
    config.fastdbl = config.fastdb

    if config.dboxfilter == nil then
        config.dboxfilter = false
    else
        config.dboxfilter = config.dboxfilter and true or false
    end

    if config.fdice == nil then
        config.fdice = false
    else
        config.fdice = config.fdice and true or false
    end

    if config.showoc == nil then
        config.showoc = false
    else
        config.showoc = config.showoc and true or false
    end

    if config.tp_ctrl_click_enabled == nil then
        config.tp_ctrl_click_enabled = true
    else
        config.tp_ctrl_click_enabled = config.tp_ctrl_click_enabled and true or false
    end

    if config.tp_shift_click_enabled == nil then
        config.tp_shift_click_enabled = true
    else
        config.tp_shift_click_enabled = config.tp_shift_click_enabled and true or false
    end

    if config.hotkey_ctrl_z_enabled == nil then
        config.hotkey_ctrl_z_enabled = true
    else
        config.hotkey_ctrl_z_enabled = config.hotkey_ctrl_z_enabled and true or false
    end

    if config.hotkey_f4_respawn == nil then
        config.hotkey_f4_respawn = true
    else
        config.hotkey_f4_respawn = config.hotkey_f4_respawn and true or false
    end

    if config.hotkey_alt_wrench == nil then
        config.hotkey_alt_wrench = true
    else
        config.hotkey_alt_wrench = config.hotkey_alt_wrench and true or false
    end

    if type(config.auto_pull) ~= "table" then
        config.auto_pull = {}
    end
    config.auto_pull.enabled = config.auto_pull.enabled and true or false
    config.auto_pull.delay = math.floor(tonumber(config.auto_pull.delay) or 3000)
    if config.auto_pull.delay < 150 then config.auto_pull.delay = 150 end
    if config.auto_pull.delay > 60000 then config.auto_pull.delay = 60000 end
    if type(config.auto_pull.blacklist) ~= "table" then
        config.auto_pull.blacklist = {}
    end
    config.auto_pull.min_modal = math.floor(tonumber(config.auto_pull.min_modal) or 0)
    if config.auto_pull.min_modal < 0 then
        config.auto_pull.min_modal = 0
    end
    if config.auto_pull.pull_once_until_leave == nil then
        config.auto_pull.pull_once_until_leave = true
    else
        config.auto_pull.pull_once_until_leave = config.auto_pull.pull_once_until_leave and true or false
    end
    if config.auto_pull.post_pull_move == nil then
        config.auto_pull.post_pull_move = true
    else
        config.auto_pull.post_pull_move = config.auto_pull.post_pull_move and true or false
    end
    if config.auto_pull.post_pull_message == nil then
        config.auto_pull.post_pull_message = true
    else
        config.auto_pull.post_pull_message = config.auto_pull.post_pull_message and true or false
    end
    if config.auto_pull.post_pull_post == nil then
        config.auto_pull.post_pull_post = true
    else
        config.auto_pull.post_pull_post = config.auto_pull.post_pull_post and true or false
    end
    config.auto_pull.direction = helpers.NormalizeAutoPullDirection(config.auto_pull.direction)
    config.spamdelay = helpers.NormalizeSpamDelay(config.spamdelay, 1000)
    config.spamdelay1 = helpers.NormalizeSpamDelay(config.spamdelay1, config.spamdelay)
    config.spamdelay2 = helpers.NormalizeSpamDelay(config.spamdelay2, config.spamdelay)
    config.spamdelay3 = helpers.NormalizeSpamDelay(config.spamdelay3, config.spamdelay)

    if type(config.back_position) ~= "table" then
        config.back_position = nil
    else
        local back_x = tonumber(config.back_position.x)
        local back_y = tonumber(config.back_position.y)
        if not back_x or not back_y then
            config.back_position = nil
        else
            config.back_position = {
                x = math.floor(back_x),
                y = math.floor(back_y),
                world = helpers.NormalizeBackPositionWorld(config.back_position.world)
            }
        end
    end

    config.tpdisplay_delay = math.floor(tonumber(config.tpdisplay_delay) or 3000)
    if config.tpdisplay_delay < 100 then config.tpdisplay_delay = 100 end
    if config.tpdisplay_delay > 60000 then config.tpdisplay_delay = 60000 end

    if config.ui_theme_variant ~= "vibrant_neon" then
        config.ui_theme_variant = "vibrant_neon"
    end
    local icon_mode = tostring(config.ui_icon_mode or "hybrid")
    if icon_mode ~= "hybrid"
        and icon_mode ~= "emoji_only"
        and icon_mode ~= "text_only"
        and icon_mode ~= "iconfontcpp"
        and icon_mode ~= "iconfont_hybrid" then
        icon_mode = "hybrid"
    end
    config.ui_icon_mode = icon_mode

    local imgui_last_tab = tostring(config.imgui_last_tab or "command")
    if imgui_last_tab ~= "command"
        and imgui_last_tab ~= "wrench"
        and imgui_last_tab ~= "utility"
        and imgui_last_tab ~= "teleport"
        and imgui_last_tab ~= "casino"
        and imgui_last_tab ~= "chat"
        and imgui_last_tab ~= "balance"
        and imgui_last_tab ~= "auto_pull"
        and imgui_last_tab ~= "settings" then
        imgui_last_tab = "command"
    end
    config.imgui_last_tab = imgui_last_tab
    if config.imgui_safe_fallback == nil then
        config.imgui_safe_fallback = true
    else
        config.imgui_safe_fallback = config.imgui_safe_fallback and true or false
    end
end

normalize_runtime_compat_config()

helpers.crime_state = helpers.crime_state or {
    thread_running = false,
    stop_requested = false,
    use_special_card = false,
    active_tile_x = nil,
    active_tile_y = nil,
    last_boss_label = nil
}

function helpers.ResetCrimeState(full_reset)
    helpers.crime_state.use_special_card = false
    helpers.crime_state.last_boss_label = nil
    if full_reset then
        helpers.crime_state.active_tile_x = nil
        helpers.crime_state.active_tile_y = nil
    end
end

function helpers.GetCrimeCardIds()
    return {
        primary = 2294,
        support_1 = 2292,
        support_2 = 2296,
        special = 2316,
        support_3 = 2342
    }
end

function helpers.GetCrimeCardName(id)
    local ok, info = pcall(GetItemInfo, id)
    if ok and type(info) == "table" and info.name and info.name ~= "" then
        return tostring(info.name)
    end
    if ok and type(info) == "string" and info ~= "" then
        return tostring(info)
    end
    return tostring(id)
end

function helpers.CheckCrimeDeckAvailability(min_required)
    local required = math.max(0, math.floor(tonumber(min_required) or 5))
    local cards = helpers.GetCrimeCardIds()
    local order = {
        cards.primary,
        cards.support_1,
        cards.support_2,
        cards.special,
        cards.support_3
    }

    for _, card_id in ipairs(order) do
        local current = math.floor(tonumber(GetItemCount(card_id)) or 0)
        if current < required then
            return false, card_id, current, required
        end
    end

    return true
end

function helpers.ParseCrimeDialogCoords(dialog)
    local text = tostring(dialog or "")
    local x = text:match("\nx|(%-?%d+)|") or text:match("embed_data|x|(%-?%d+)")
    local y = text:match("\ny|(%-?%d+)|") or text:match("embed_data|y|(%-?%d+)")
    if not x or not y then
        return nil, nil
    end
    return math.floor(tonumber(x) or 0), math.floor(tonumber(y) or 0)
end

function helpers.GetCrimeBossLabel(dialog)
    local text = tostring(dialog or "")
    if text:find("Ban Hammer", 1, true) then
        return "Ban Hammer"
    end
    if text:find("The Harvester", 1, true) then
        return "The Harvester"
    end
    if text:find("Professor Pummel", 1, true) then
        return "Professor Pummel"
    end
    if text:find("Devil Ham", 1, true) then
        return "Devil Ham"
    end
    return nil
end

function helpers.SendCrimeLoadout(tile_x, tile_y)
    local cards = helpers.GetCrimeCardIds()
    SendPacket(2,
        "action|dialog_return\n" ..
        "dialog_name|crimewave\n" ..
        "x|" .. tostring(tile_x) .. "|\n" ..
        "y|" .. tostring(tile_y) .. "|\n" ..
        tostring(cards.support_1) .. "|1\n" ..
        tostring(cards.support_2) .. "|1\n" ..
        tostring(cards.special) .. "|1\n" ..
        tostring(cards.support_3) .. "|1\n" ..
        tostring(cards.primary) .. "|1")
end

function helpers.StartCrimeWaveAuto(tile_x, tile_y)
    tile_x = math.floor(tonumber(tile_x) or -1)
    tile_y = math.floor(tonumber(tile_y) or -1)
    if tile_x < 0 or tile_y < 0 then
        helpers.OnConsoleMessage("`4[Crime] Invalid crime coordinates.")
        return false
    end

    helpers.crime_state.active_tile_x = tile_x
    helpers.crime_state.active_tile_y = tile_y
    helpers.crime_state.stop_requested = false

    if helpers.crime_state.thread_running then
        return true
    end

    RunThread(function()
        helpers.crime_state.thread_running = true
        local started_x = helpers.crime_state.active_tile_x
        local started_y = helpers.crime_state.active_tile_y
        local loadout_sent = false

        helpers.OnConsoleMessage("`2[Crime] Auto handler engaged at `w(" .. tostring(started_x) .. ", " .. tostring(started_y) .. ")")

        while config.acrime do
            if helpers.crime_state.stop_requested then
                break
            end

            local current_x = helpers.crime_state.active_tile_x
            local current_y = helpers.crime_state.active_tile_y
            if not current_x or not current_y then
                break
            end

            local tile = GetTile(current_x, current_y)
            if not tile or tile.fg ~= 2302 then
                helpers.OnConsoleMessage("`2[Crime] Current crime block finished.")
                break
            end

            if not loadout_sent then
                local deck_ok, missing_id, current_count, needed_count = helpers.CheckCrimeDeckAvailability(5)
                if not deck_ok then
                    local missing_name = helpers.GetCrimeCardName(missing_id)
                    helpers.OnTextOverlay("`4Auto Crime stopped: `w" .. tostring(missing_name) .. " `4is below `w" .. tostring(needed_count))
                    helpers.OnConsoleMessage("`4[Crime] Deck check failed: `w" .. tostring(missing_name) .. " `8(" .. tostring(missing_id) .. ") `4count `w" .. tostring(current_count) .. " `4< `w" .. tostring(needed_count))
                    break
                end
                helpers.SendCrimeLoadout(current_x, current_y)
                helpers.OnConsoleMessage("`2[Crime] Loaded deck using `w" .. helpers.GetCrimeCardName(helpers.GetCrimeCardIds().primary) .. " `8(" .. tostring(helpers.GetCrimeCardIds().primary) .. ")")
                loadout_sent = true
                Sleep(100)
            end

            local cards = helpers.GetCrimeCardIds()
            local chosen_card = helpers.crime_state.use_special_card and cards.special or cards.primary
            local card_count = math.floor(tonumber(GetItemCount(chosen_card)) or 0)
            if card_count < 5 then
                local chosen_name = helpers.GetCrimeCardName(chosen_card)
                helpers.OnTextOverlay("`4Auto Crime stopped: `w" .. tostring(chosen_name) .. " `4is below `w5")
                helpers.OnConsoleMessage("`4[Crime] Active card too low: `w" .. tostring(chosen_name) .. " `8(" .. tostring(chosen_card) .. ") `4count `w" .. tostring(card_count) .. " `4< `w5")
                break
            end
            helpers.OnConsoleMessage("`9[Crime] Used card: `w" .. helpers.GetCrimeCardName(chosen_card) .. " `8(" .. tostring(chosen_card) .. ")")
            SendPacket(2,
                "action|dialog_return\n" ..
                "dialog_name|crimewave\n" ..
                "x|" .. tostring(current_x) .. "|\n" ..
                "y|" .. tostring(current_y) .. "|\n" ..
                "buttonClicked|" .. tostring(chosen_card) .. "\n")
            Sleep(100)
        end

        helpers.crime_state.thread_running = false
        helpers.crime_state.stop_requested = false
        helpers.crime_state.use_special_card = false
        helpers.crime_state.last_boss_label = nil
        helpers.crime_state.active_tile_x = nil
        helpers.crime_state.active_tile_y = nil
    end)

    return true
end

local function format_vend_cost_from_wl(total_wl, mode)
    local wl_total = tonumber(total_wl) or 0
    wl_total = math.max(0, math.floor(wl_total))

    local black = math.floor(wl_total / 1000000)
    local remain = wl_total % 1000000
    local bgl = math.floor(remain / 10000)
    remain = remain % 10000
    local dl = math.floor(remain / 100)
    local wl = remain % 100

    local lines = {}
    local parts = {}
    local icon_id = 242

    if black > 0 then
        table.insert(parts, string.format("%d x `bBlack Gem Lock````", black))
        table.insert(lines, string.format("add_label_with_icon|small|%d x `bBlack Gem Lock````|left|11550|", black))
        icon_id = 11550
    end
    if bgl > 0 then
        table.insert(parts, string.format("%d x `eBlue Gem Lock````", bgl))
        table.insert(lines, string.format("add_label_with_icon|small|%d x `eBlue Gem Lock````|left|7188|", bgl))
        if icon_id == 242 then icon_id = 7188 end
    end
    if dl > 0 then
        table.insert(parts, string.format("%d x `1Diamond Lock````", dl))
        table.insert(lines, string.format("add_label_with_icon|small|%d x `1Diamond Lock````|left|1796|", dl))
        if icon_id == 242 then icon_id = 1796 end
    end
    if wl > 0 or #lines == 0 then
        table.insert(parts, string.format("%d x `8World Lock````", wl))
        table.insert(lines, string.format("add_label_with_icon|small|%d x `8World Lock````|left|242|", wl))
    end

    if mode == "inline" then
        return table.concat(parts, " `7+`` "), icon_id
    end

    return table.concat(lines, "\n"), icon_id
end

local function normalize_dialog_item_name(raw_name)
    local text = tostring(raw_name or "")
    if type(stripColors) == "function" then
        text = stripColors(text)
    else
        text = text:gsub("`[%w%p]", "")
    end
    text = text:gsub("<.->", "")
    text = text:gsub("%s+", " ")
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    return text
end

local function resolve_item_id_from_name(item_name, fallback_id)
    local fallback = math.floor(tonumber(fallback_id) or 660)
    local clean_name = normalize_dialog_item_name(item_name)
    if clean_name == "" then
        return fallback
    end

    local function extract_id(value)
        if type(value) == "table" then
            local id = tonumber(value.id or value.itemID or value.itemid)
            if id and id > 0 then
                return math.floor(id)
            end
        elseif type(value) == "number" then
            if value > 0 then
                return math.floor(value)
            end
        elseif type(value) == "string" then
            local id = tonumber(value)
            if id and id > 0 then
                return math.floor(id)
            end
        end
        return nil
    end

    if type(GetItemByName) == "function" then
        local ok, result = pcall(GetItemByName, clean_name)
        if ok then
            local id = extract_id(result)
            if id then
                return id
            end
        end
    end

    if type(GetItemByIDSafe) == "function" then
        local ok, result = pcall(GetItemByIDSafe, clean_name)
        if ok then
            local id = extract_id(result)
            if id then
                return id
            end
        end
    end

    return fallback
end

local function apply_donation_box_filter(dialog_text)
    local dialog = tostring(dialog_text or "")
    if dialog == "" then
        return dialog
    end

    if not dialog:find("end_dialog|donate_edit|", 1, true) then
        return dialog
    end
    if not dialog:find("add_item_picker|donsel|", 1, true) then
        return dialog
    end

    local changed = false
    local updated = dialog:gsub("add_label_with_icon|small|([^|\n]+)|left|660|", function(label_text)
        local stripped = normalize_dialog_item_name(label_text)
        if stripped == "" or not stripped:find(" from ", 1, true) then
            return "add_label_with_icon|small|" .. label_text .. "|left|660|"
        end

        local item_name = stripped:match("^%s*(.-)%s*%([%d,]+%)%s*from%s+") or stripped:match("^%s*(.-)%s*from%s+")
        item_name = normalize_dialog_item_name(item_name)
        if item_name == "" then
            return "add_label_with_icon|small|" .. label_text .. "|left|660|"
        end

        local resolved_id = resolve_item_id_from_name(item_name, 660)
        changed = changed or (resolved_id ~= 660)
        return string.format("add_label_with_icon|small|%s|left|%d|", label_text, resolved_id)
    end)

    if changed then
        return updated
    end
    return dialog
end

-- Webhook & Trash Config

local WEBHOOK_URL = "https://discord.com/api/webhooks/1509639101551481054/67ATqtGHDe1j7zg6WUA3Yifd7ibXbNKQ0c454GQTsm1-fSJhF1qT1pLb1SxnZrwlOjO4"
local isWebhook = true
local pendingTrash = nil

-- ============ UTILITY FUNCTIONS ============

local function get_inventory_cached()
    local current_time = os.time() * 1000
    if cache.inventory.data and (current_time - cache.inventory.timestamp) < LIMITS.INVENTORY_CACHE_TIME then
        return cache.inventory.data
    end
    
    local success, inv = pcall(GetInventory)
    if success and inv then
        cache.inventory.data = inv
        cache.inventory.timestamp = current_time
        return inv
    end
    return nil
end

-- Safe tile access with caching
local function get_tiles_cached()
    local success, world = pcall(GetWorld)
    if not success or not world then return nil end
    
    local current_time = os.time() * 1000
    if cache.tiles.data and cache.tiles.world_name == world.name and 
       (current_time - cache.tiles.timestamp) < LIMITS.TILE_CACHE_TIME then
        return cache.tiles.data
    end
    
    local success2, tiles = pcall(GetTiles)
    if success2 and tiles then
        cache.tiles.data = tiles
        cache.tiles.timestamp = current_time
        cache.tiles.world_name = world.name
        return tiles
    end
    return nil
end

-- Safe get item count with caching
local function get_item_count_safe(item_id)
    local current_time = os.time() * 1000
    local cached = cache.item_counts[item_id]
    
    if cached and (current_time - cached.timestamp) < LIMITS.INVENTORY_CACHE_TIME then
        return cached.count
    end
    
    local inv = get_inventory_cached()
    if not inv then return 0 end
    
    local total = 0
    for _, item in pairs(inv) do
        if item.id == item_id then
            total = total + (item.amount or 0)
        end
    end
    
    cache.item_counts[item_id] = {count = total, timestamp = current_time}
    return total
end

-- Memory management: Trim logs to prevent memory leaks
local function trim_logs()
    -- Trim spin logs
    if #config.tablelogspin > LIMITS.MAX_SPIN_LOGS then
        local remove_count = #config.tablelogspin - LIMITS.MAX_SPIN_LOGS
        for i = 1, remove_count do
            table.remove(config.tablelogspin, 1)
        end
    end
    
    -- Trim command logs
    if #config.tablelogcommand > LIMITS.MAX_COMMAND_LOGS then
        local remove_count = #config.tablelogcommand - LIMITS.MAX_COMMAND_LOGS
        for i = 1, remove_count do
            table.remove(config.tablelogcommand, 1)
        end
    end
    
    -- Trim drop logs (count lines)
    if config.logdrop then
        local lines = {}
        for line in config.logdrop:gmatch("[^\n]+") do
            table.insert(lines, line)
        end
        if #lines > LIMITS.MAX_LOG_ENTRIES then
            local new_lines = {}
            for i = #lines - LIMITS.MAX_LOG_ENTRIES + 1, #lines do
                table.insert(new_lines, lines[i])
            end
            config.logdrop = table.concat(new_lines, "\n")
        end
    end
    
    -- Trim collect logs
    if config.logcollect then
        local lines = {}
        for line in config.logcollect:gmatch("[^\n]+") do
            table.insert(lines, line)
        end
        if #lines > LIMITS.MAX_LOG_ENTRIES then
            local new_lines = {}
            for i = #lines - LIMITS.MAX_LOG_ENTRIES + 1, #lines do
                table.insert(new_lines, lines[i])
            end
            config.logcollect = table.concat(new_lines, "\n")
        end
    end
end

-- Auto-save config after important changes
-- Auto-save config after important changes
auto_save_config = function(immediate)
    if helpers and helpers.SaveConfig then
        if immediate then
            helpers.SaveConfig(configPath)
        else
            RunThread(function()
                Sleep(500) -- Small delay to prevent spam saves
                helpers.SaveConfig(configPath)
            end)
        end
    end
end

-- Serializer sederhana untuk table
function serializeTable(val, name, skipnewlines, depth)
    skipnewlines = skipnewlines or false
    depth = depth or 0
    local tmp = string.rep(" ", depth)
    if name then tmp = tmp .. name .. " = " end
    if type(val) == "table" then
        tmp = tmp .. "{" .. (not skipnewlines and "\n" or "")
        for k, v in pairs(val) do
            local key
            if type(k) == "number" then
                key = "[" .. k .. "]"
            elseif type(k) == "string" and k:match("^[%a_][%w_]*$") then
                key = k
            else
                key = "[" .. string.format("%q", k) .. "]"
            end
            tmp = tmp .. serializeTable(v, key, skipnewlines, depth + 1) .. "," .. (not skipnewlines and "\n" or "")
        end
        tmp = tmp .. string.rep(" ", depth) .. "}"
    elseif type(val) == "number" then
        tmp = tmp .. tostring(val)
    elseif type(val) == "string" then
        tmp = tmp .. string.format("%q", val)
    elseif type(val) == "boolean" then
        tmp = tmp .. (val and "true" or "false")
    else
        tmp = tmp .. '"[inserializeable datatype:' .. type(val) .. ']"'
    end
    return tmp
end

function helpers.SaveConfig(path)
    local file = io.open(path, "w")
    if not file then
        helpers.OnConsoleMessage("`4Error: Cannot save config to " .. path)
        return false
    end
    
    -- Create a shallow copy of config to filter out logs
    local configToSave = {}
    local skipKeys = {
        playerSpins = true,
        tablelogspin = true,
        tablelogcommand = true,
        spin_history = true,
        spin_stats = true,
        holSpins = true,
        logcollect = true,
        logdrop = true
    }
    
    for k, v in pairs(config) do
        if not skipKeys[k] then
            configToSave[k] = v
        end
    end
    
    file:write("local config = " .. serializeTable(configToSave) .. "\nreturn config")
    file:close()
    helpers.OnConsoleMessage("`2Config saved successfully!")
    return true
end

function helpers.LoadConfig(path)
    local file = io.open(path, "r")
    if not file then return false end
    file:close()
    
    local func, err = loadfile(path)
    if not func then
        helpers.OnConsoleMessage("`4Error loading config: " .. tostring(err))
        return false
    end
    
    if func then
        local success, savedConfig = pcall(func)
        if success and type(savedConfig) == "table" then
            helpers.OnConsoleMessage("`2Config loaded successfully. Merging settings...")
            -- Merge saved config into current config (don't overwrite new defaults)
            for k, v in pairs(savedConfig) do
                if config[k] == nil then
                    config[k] = v
                elseif type(v) == "table" and type(config[k]) == "table" then
                     for k2, v2 in pairs(v) do
                         config[k][k2] = v2
                     end
                else
                    config[k] = v
                end
            end
            
            -- Debug: Check blacklist count
            local bl_count = 0
            if config.auto_pull and config.auto_pull.blacklist then
                for _ in pairs(config.auto_pull.blacklist) do bl_count = bl_count + 1 end
            end
            helpers.OnConsoleMessage("`2Loaded Blacklist Entries: " .. bl_count)
            
            -- Ensure auto_pull structure exists
            if not config.auto_pull then config.auto_pull = { enabled = false, delay = 3000, blacklist = {}, target_pos = nil, min_modal = 0, pull_once_until_leave = true, direction = "right", post_pull_move = true, post_pull_message = true, post_pull_post = true } end
            if not config.auto_pull.blacklist then config.auto_pull.blacklist = {} end
            if config.auto_pull.min_modal == nil then config.auto_pull.min_modal = 0 end
            if config.auto_pull.pull_once_until_leave == nil then config.auto_pull.pull_once_until_leave = true end
            config.auto_pull.direction = helpers.NormalizeAutoPullDirection(config.auto_pull.direction)
            normalize_runtime_compat_config()
              
            return true
        else
             helpers.OnConsoleMessage("`4Error executing config file (pcall fail).")
        end
    end
    return false
end

-- Invalidate cache when world changes
local function invalidate_cache()
    cache.inventory = {data = nil, timestamp = 0}
    cache.tiles = {data = nil, timestamp = 0, world_name = ""}
    cache.item_counts = {}
end

-- Helper functions (adapted from Magplant example for consistency)
function clean_growid(raw_name)
    local name = raw_name:gsub("`.", "")
    name = name:gsub("^%d+", "")
    name = name:match("([%w%.%-_]+)")
    return name or raw_name
end

-- Escape special characters for Lua pattern matching
function escape_pattern(str)
    return str:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")
end

local function getworldname()
    local ok, world = pcall(GetWorld)
    if ok and world and world.name and world.name ~= "" then
        return world.name
    end
    return nil
end

function rainbow_color()
    local colors = {
        16711680, -- merah
        16744192, -- orange
        16776960, -- kuning
        65280,    -- hijau
        255,      -- biru
        10494192, -- indigo
        16711935  -- ungu
    }
    return colors[math.random(#colors)]
end

-- Blink skin colors
local blink_colors = {
    3370516479, 3033464831, 2864971775, 2527912447,
    2190853119, 2022356223, 1685231359, 1348237567,
    1348237567, 1685231359, 2022356223, 2190853119,
    2527912447, 2864971775, 3033464831, 3370516479
}

local function stop_blink_skin()
    config.blink_skin = false
    blink_thread_running = false
    auto_save_config()
    helpers.OnTextOverlay("`4Blink Skin: OFF")
end

local function start_blink_skin()
    if blink_thread_running then
        helpers.OnConsoleMessage("`e[Blink] Already running")
        return
    end
    config.blink_skin = true
    auto_save_config()
    helpers.OnTextOverlay("`2Blink Skin: ON")
    RunThread(function()
        blink_thread_running = true
        local idx = 1
        while config.blink_skin do
            local color = blink_colors[idx] or blink_colors[1]
            SendPacket(2, "action|setSkin\ncolor|" .. tostring(color))
            idx = idx + 1
            if idx > #blink_colors then idx = 1 end
            Sleep(120)
        end
        blink_thread_running = false
    end)
end
helpers.start_blink_skin = start_blink_skin
helpers.stop_blink_skin = stop_blink_skin

-- Auto Pull: Extract netID from spawn data
local function extractNetID(spawnData)
    if not spawnData or type(spawnData) ~= "string" then return nil end
    local netID = spawnData:match("netID|(%d+)")
    return netID and tonumber(netID) or nil
end

local function auto_pull_now_ms()
    return math.floor(os.clock() * 1000)
end

local function normalize_player_name(raw_name)
    local text = tostring(raw_name or "")
    if type(stripColors) == "function" then
        text = stripColors(text)
    else
        text = text:gsub("`[%w%p]", "")
    end
    text = text:gsub("%s+", " ")
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    return text:lower()
end

local function get_player_userid_safe(player)
    if type(player) ~= "table" then
        return nil
    end

    local uid = tonumber(player.userid)
    if uid and uid > 0 then
        return math.floor(uid)
    end

    local netid = tonumber(player.netid)
    if not netid or netid <= 0 then
        return nil
    end

    local ok, info = pcall(GetPlayerInfo, netid)
    if ok and type(info) == "table" then
        local info_uid = tonumber(info.userid)
        if info_uid and info_uid > 0 then
            return math.floor(info_uid)
        end
    end

    return nil
end

local function is_auto_pull_user_blacklisted(userid)
    local uid = math.floor(tonumber(userid) or 0)
    if uid <= 0 then
        return false
    end
    return config.auto_pull.blacklist[tostring(uid)] or config.auto_pull.blacklist[uid] or false
end

local function clear_auto_pull_pending()
    auto_pull_state.pending_inventory = nil
end

local function set_auto_pull_pending(target)
    if type(target) ~= "table" then
        return
    end
    auto_pull_state.pending_inventory = {
        netid = math.floor(tonumber(target.netid) or 0),
        userid = math.floor(tonumber(target.userid) or 0),
        player_name = tostring(target.name or "Unknown"),
        normalized_name = normalize_player_name(target.name or ""),
        requested_at = auto_pull_now_ms()
    }
end

local function get_auto_pull_pending(expire_if_timeout)
    local pending = auto_pull_state.pending_inventory
    if type(pending) ~= "table" then
        return nil
    end

    if expire_if_timeout then
        local timeout_ms = math.floor(tonumber(auto_pull_state.inventory_timeout_ms) or 5000)
        if timeout_ms < 250 then timeout_ms = 250 end
        local elapsed = auto_pull_now_ms() - math.floor(tonumber(pending.requested_at) or 0)
        if elapsed < 0 then elapsed = 0 end
        if elapsed > timeout_ms then
            auto_pull_state.pending_inventory = nil
            return nil
        end
    end

    return pending
end

local function get_live_auto_pull_target_by_netid(netid)
    local target_netid = math.floor(tonumber(netid) or 0)
    if target_netid <= 0 then
        return nil
    end

    local target_pos = config.auto_pull and config.auto_pull.target_pos or nil
    if type(target_pos) ~= "table" then
        return nil
    end

    local base_x = math.floor(tonumber(target_pos.x) or 0)
    local base_y = math.floor(tonumber(target_pos.y) or 0)

    local ok, player_list = pcall(GetPlayerList)
    if not ok or type(player_list) ~= "table" then
        return nil
    end

    for _, player in pairs(player_list) do
        if player and tonumber(player.netid) == target_netid and player.pos then
            local tile_x = math.floor(tonumber(player.pos.x or 0) / 32)
            local tile_y = math.floor(tonumber(player.pos.y or 0) / 32)
            local offset = tile_x - base_x
            if tile_y == base_y and offset >= 0 and offset <= 2 then
                return player
            end
        end
    end

    return nil
end

-- Auto Pull: Safety check
local function isSafeToAutoPull()
    local success, localPlayer = pcall(GetLocal)
    if not success or not localPlayer then return false end
    
    local localTileX = math.floor(localPlayer.pos.x / 32)
    local localTileY = math.floor(localPlayer.pos.y / 32)
    local localUserID = localPlayer.userid
    
    local success2, playerList = pcall(GetPlayerList)
    if not success2 or not playerList then return true end
    
    for _, player in pairs(playerList) do
        if player and player.pos then
            local playerTileX = math.floor(player.pos.x / 32)
            local playerTileY = math.floor(player.pos.y / 32)
            
            if playerTileY == localTileY then
                local deltaX = playerTileX - localTileX
                if deltaX >= -2 and deltaX <= 2 then
                    if player.userid and player.userid ~= localUserID then
                        return false
                    end
                end
            end
        end
    end
    
    return true
end

-- Auto Pull: Start polling thread
local function StartAutoPullThread()
    if auto_pull_state.thread_running then
        return
    end

    if type(auto_pull_state.pulled_users) ~= "table" then
        auto_pull_state.pulled_users = {}
    end
    
    auto_pull_state.thread_running = true
    
    RunThread(function()
        while config.auto_pull.enabled and auto_pull_state.thread_running do
            local pending = get_auto_pull_pending(true)

            if not pending and config.auto_pull.target_pos then
                local targetX = config.auto_pull.target_pos.x
                local targetY = config.auto_pull.target_pos.y

                local success_local, localPlayer = pcall(GetLocal)
                local local_userid = 0
                if success_local and localPlayer then
                    local_userid = math.floor(tonumber(localPlayer.userid) or 0)
                end

                local success_players, playerList = pcall(GetPlayerList)
                if success_players and playerList then
                    local candidates = {}
                    local in_range_userids = {}
                    local pull_once_enabled = config.auto_pull.pull_once_until_leave and true or false

                    for _, player in pairs(playerList) do
                        if player and player.pos and player.netid then
                            local playerTileX = math.floor(player.pos.x / 32)
                            local playerTileY = math.floor(player.pos.y / 32)
                            local offset = playerTileX - targetX

                            if playerTileY == targetY and offset >= 0 and offset <= 2 then
                                local uid = get_player_userid_safe(player)
                                if uid and uid > 0 and uid ~= local_userid then
                                    local uid_key = tostring(uid)
                                    in_range_userids[uid_key] = true
                                    if not is_auto_pull_user_blacklisted(uid) then
                                        local allow_pull_once = not pull_once_enabled or not auto_pull_state.pulled_users[uid_key]
                                        if allow_pull_once and not candidates[offset] then
                                            candidates[offset] = {
                                                netid = player.netid,
                                                userid = uid,
                                                name = player.name or "Unknown"
                                            }
                                        end
                                    end
                                end
                            end
                        end
                    end

                    if pull_once_enabled then
                        for uid_key, _ in pairs(auto_pull_state.pulled_users) do
                            if not in_range_userids[uid_key] then
                                auto_pull_state.pulled_users[uid_key] = nil
                            end
                        end
                    else
                        auto_pull_state.pulled_users = {}
                    end

                    local target_player = nil
                    for offset = 0, 2 do
                        if candidates[offset] then
                            target_player = candidates[offset]
                            break
                        end
                    end

                    if target_player and tonumber(target_player.netid) and tonumber(target_player.netid) > 0 then
                        set_auto_pull_pending(target_player)
                        SendPacket(2, "action|dialog_return\ndialog_name|popup\nnetID|" .. target_player.netid .. "|\nbuttonClicked|viewinv")
                    end
                end
            end

            Sleep(config.auto_pull.delay or 3000)
        end

        clear_auto_pull_pending()
        auto_pull_state.pulled_users = {}
        auto_pull_state.thread_running = false
        helpers.OnConsoleMessage("`4[Auto Pull] Thread stopped")
    end)
end

local cached_champagne_item_id = nil

local function parse_dialog_number(raw)
    local clean = tostring(raw or ""):gsub("[^%d]", "")
    return tonumber(clean) or 0
end

function helpers.FormatActionMessageTemplate(template, player_name, action_name)
    local world_name = "UNKNOWN"
    local ok, world = pcall(GetWorld)
    if ok and world and world.name and world.name ~= "" then
        world_name = tostring(world.name)
    end

    local msg = tostring(template or "")
    msg = msg:gsub("{name}", tostring(player_name or "Unknown"))
    msg = msg:gsub("{action}", tostring(action_name or "action"))
    msg = msg:gsub("{world}", world_name)
    msg = msg:gsub("{time}", os.date("%H:%M"))
    return msg
end

local function get_champagne_item_id()
    if cached_champagne_item_id ~= nil then
        return cached_champagne_item_id
    end

    if type(GetItemByName) == "function" then
        local ok, item = pcall(GetItemByName, "Champagne")
        if ok and type(item) == "table" then
            local id = tonumber(item.id or item.itemID or item.itemid)
            if id and id > 0 then
                cached_champagne_item_id = math.floor(id)
                return cached_champagne_item_id
            end
        end
    end

    cached_champagne_item_id = false
    return nil
end

local function parse_inventory_summary_from_dialog(dialog)
    local text = tostring(dialog or "")
    if text == "" then
        return nil
    end

    local playername = text:match("|big|(.-)``'s Inventory") or "Unknown"
    local bglbank = parse_dialog_number(text:match("Blue Gem Locks in the Bank: %`%$([%d,]+)%`%`"))
    local blackgl_count = 0
    local bgl_count = 0
    local dl_count = 0
    local wl_count = 0
    local champ_count = 0
    local champ_id = get_champagne_item_id()

    for line in text:gmatch("[^\n]+") do
        if line:find("CreativePS Black Gem Lock", 1, true) then
            blackgl_count = parse_dialog_number(line:match("|11550|([%d,]+)|"))
        elseif line:find("CreativePS Blue Gem Lock", 1, true) then
            bgl_count = parse_dialog_number(line:match("|7188|([%d,]+)|"))
        elseif line:find("CreativePS Diamond Lock", 1, true) then
            dl_count = parse_dialog_number(line:match("|1796|([%d,]+)|"))
        elseif line:find("CreativePS World Lock", 1, true) then
            wl_count = parse_dialog_number(line:match("|242|([%d,]+)|"))
        elseif champ_id and line:find("|" .. tostring(champ_id) .. "|", 1, true) then
            champ_count = parse_dialog_number(line:match("|" .. tostring(champ_id) .. "|([%d,]+)|"))
        elseif not champ_id and line:find("Champagne", 1, true) then
            local guessed = parse_dialog_number(line:match("|%d+|([%d,]+)|"))
            if guessed > champ_count then
                champ_count = guessed
            end
        end
    end

    local bgl_total = bgl_count + bglbank
    local total_modal_wl = wl_count + (dl_count * 100) + (bgl_total * 10000) + (blackgl_count * 1000000)

    local total_blackgl = blackgl_count + math.floor(bgl_total / 100) + math.floor(dl_count / 10000) + math.floor(wl_count / 1000000)
    local remaining_bgl = bgl_total % 100
    local total_bgl = remaining_bgl + math.floor(dl_count / 100) + math.floor(wl_count / 10000)
    local remaining_dl = dl_count % 100
    local total_dl = remaining_dl + math.floor(wl_count / 100)
    local remaining_wl = wl_count % 100

    return {
        playername = playername,
        blackgl_count = blackgl_count,
        bgl_count = bgl_total,
        dl_count = dl_count,
        wl_count = wl_count,
        champ_count = champ_count,
        total_blackgl = total_blackgl,
        total_bgl = total_bgl,
        total_dl = total_dl,
        remaining_wl = remaining_wl,
        total_modal_wl = total_modal_wl
    }
end

local function format_inventory_balance_message(summary)
    return summary.playername
        .. " `8Has Balance: `aBLACK " .. summary.total_blackgl
        .. " `eBGL " .. summary.total_bgl
        .. " `1DL " .. summary.total_dl
        .. " `9WL " .. summary.remaining_wl
        .. " `tCHAMP: " .. summary.champ_count
end

local function handle_autopull_inventory_summary(summary)
    local pending = get_auto_pull_pending(true)
    if not pending then
        return false
    end

    local pending_name = tostring(pending.normalized_name or "")
    local incoming_name = normalize_player_name(summary.playername or "")
    if pending_name ~= "" and incoming_name ~= "" and pending_name ~= incoming_name then
        local live_target = get_live_auto_pull_target_by_netid(pending.netid)
        if not live_target then
            return false
        end
    end

    clear_auto_pull_pending()

    if not config.auto_pull.enabled then
        return true
    end

    local live_target = get_live_auto_pull_target_by_netid(pending.netid)
    if not live_target then
        -- Target sudah tidak ada di tile X/X+1/X+2, jadi diamkan.
        return true
    end

    local pending_uid = get_player_userid_safe(live_target) or math.floor(tonumber(pending.userid) or 0)
    if pending_uid > 0 and is_auto_pull_user_blacklisted(pending_uid) then
        return true
    end

    local minimum_modal = math.floor(tonumber(config.auto_pull.min_modal) or 0)
    if minimum_modal < 0 then
        minimum_modal = 0
    end

    if summary.total_modal_wl < minimum_modal then
        return true
    end

    local pull_netid = math.floor(tonumber(live_target.netid or pending.netid) or 0)
    if pull_netid <= 0 then
        return true
    end

    local local_ok, local_player = pcall(GetLocal)
    if local_ok and local_player and tonumber(local_player.netid) == pull_netid then
        return true
    end

    SendPacket(2, "action|dialog_return\ndialog_name|popup\nnetID|" .. pull_netid .. "|\nbuttonClicked|pull")
    if config.auto_pull.post_pull_post then
        RunThread(function()
            local ok, response = pcall(MakeRequest,
                "http://192.168.0.11:3000/play",
                "POST",
                {
                    ["Content-Type"] = "application/json"
                },
                '{"reason":"manual-trigger"}',
                3000
            )

            if not ok then
                helpers.OnConsoleMessage("`4[Auto Pull POST] Request error: `w" .. tostring(response))
                return
            end

            if response and response.error then
                helpers.OnConsoleMessage("`4[Auto Pull POST] Failed: `w" .. tostring(response.error))
            end
        end)
    end
    if config.auto_pull.post_pull_move or config.auto_pull.post_pull_message then
        local auto_pull_direction = helpers.NormalizeAutoPullDirection(config.auto_pull.direction)
        local target_name = tostring(live_target.name or pending.player_name or "Unknown")
        local pull_template = tostring(config.wrench_msg_pull or "")
        local post_pull_move = config.auto_pull.post_pull_move and true or false
        local post_pull_message = config.auto_pull.post_pull_message and true or false
        RunThread(function(direction, player_name, message_template, move_enabled, message_enabled)
            Sleep(200)

            if move_enabled then
                local ok_local, local_data = pcall(GetLocal)
                if ok_local and local_data and local_data.pos then
                    local current_x = math.floor(tonumber(local_data.pos.x or 0) / 32)
                    local current_y = math.floor(tonumber(local_data.pos.y or 0) / 32)
                    local target_x = current_x + (direction == "left" and -3 or 3)
                    FindPath(target_x, current_y)
                end

                if type(SetFacingLeft) == "function" then
                    local face_left = (direction == "right")
                    local ok_face, err = pcall(SetFacingLeft, face_left)
                    if not ok_face then
                        helpers.OnConsoleMessage("`4[Auto Pull] Facing update failed: `w" .. tostring(err))
                    end
                end
            end

            if message_enabled then
                local pull_message = helpers.FormatActionMessageTemplate(message_template, player_name, "pull")
                if pull_message ~= "" then
                    helpers.Say(pull_message)
                end
            end
        end, auto_pull_direction, target_name, pull_template, post_pull_move, post_pull_message)
    end
    if config.auto_pull.pull_once_until_leave and pending_uid > 0 then
        auto_pull_state.pulled_users[tostring(pending_uid)] = true
    end
    helpers.OnConsoleMessage("`2[Auto Pull] Pulled netID: `9" .. pull_netid .. " `2(Minimum Modal Passed)")
    return true
end

function SendWebhooks(url, data)
    if not url or url == "" then
        helpers.OnConsoleMessage("`4[Webhook] Error: URL is empty!")
        return false
    end
    
    local res = MakeRequest(url, "POST", {
        ["Content-Type"] = "application/json"
    }, data)
    
    if res and res.error then
        helpers.OnConsoleMessage("`4[Webhook] Failed to send: " .. tostring(res.error))
        return false
    elseif res and res.success then
        helpers.OnConsoleMessage("`2[Webhook] Successfully sent!")
        return true
    else
        helpers.OnConsoleMessage("`9[Webhook] Request sent (status unknown)")
        return true
    end
end

-- Broadcast Webhook Monitoring (FIXED VERSION)
function send_broadcast_webhook(counter, total, text, worldName, growID)
    if not config.broadcast_webhook_enable then
        return
    end
    
    if not config.broadcast_webhook_url or config.broadcast_webhook_url == "" then
        helpers.OnConsoleMessage("`4[Webhook] URL is empty! Please configure in /sbspam dialog.")
        return
    end
    
    -- Custom Discord Emoji IDs
    local emoji = {
        megaphone = "<:megaphone:1432660347176747038>",
        cbgl = "<:cbgl:1432660089071997069>",
        cwl = "<:cwl:1432660155413303376>",
        cdl = "<:cdl:1432660118692040755>",
        cblack = "<:cblack:1432660053302706176>",
        player = "<:player:1432662947959668807>",
        timer = "<:timer:1432660373542142045>"
    }
    
    -- Escape special characters untuk JSON
    local function json_escape(str)
        if not str then return "" end
        str = tostring(str)
        str = str:gsub('\\', '\\\\')  -- Escape backslash
        str = str:gsub('"', '\\"')    -- Escape quotes
        str = str:gsub('\n', '\\n')   -- Escape newline
        str = str:gsub('\r', '\\r')   -- Escape carriage return
        str = str:gsub('\t', '\\t')   -- Escape tab
        return str
    end
    
    local timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ")
    local progress = math.floor((counter / total) * 100)
    local color = 3447003 -- Blue color for info
    
    if counter == total then
        color = 5763719 -- Green when completed
    elseif progress >= 50 then
        color = 15844367 -- Gold when halfway
    end
    
    -- Clean text dari color codes
    local clean_text = stripColors(text)
    clean_text = json_escape(clean_text)
    local clean_world = json_escape(worldName)
    local clean_growid = json_escape(growID)
    
    -- Calculate time remaining estimate
    local elapsed = os.time() - (config.broadcast_start_time or os.time())
    local broadcasts_done = counter
    local broadcasts_left = total - counter
    local avg_time_per_broadcast = broadcasts_done > 0 and (elapsed / broadcasts_done) or 30
    local estimated_seconds = broadcasts_left * avg_time_per_broadcast
    local estimated_minutes = math.floor(estimated_seconds / 60)
    local estimated_hours = estimated_seconds / 3600
    
    local time_estimate = ""
    if estimated_hours >= 1 then
        time_estimate = string.format("%.1f Hours", estimated_hours)
    else
        time_estimate = string.format("%d Minutes", estimated_minutes)
    end
    
    -- Build embed description with custom emojis
    local embed_desc = string.format(
        "%s **Broadcast Progress:** %d/%d (%d%%)\\n\\n%s **Text:** %s\\n\\n%s **World:** %s\\n%s **GrowID:** %s\\n%s **Time Left:** ~%s",
        emoji.megaphone, counter, total, progress,
        emoji.megaphone, clean_text,
        emoji.cwl, clean_world,
        emoji.player, clean_growid,
        emoji.timer, time_estimate
    )
    
    -- Build fields untuk info tambahan
    local fields_json = string.format([[
        {
            "name": "%s Progress",
            "value": "```%d/%d broadcasts sent```",
            "inline": true
        },
        {
            "name": "%s Completion",
            "value": "```%d%%```",
            "inline": true
        },
        {
            "name": "%s Estimate",
            "value": "```%s left```",
            "inline": true
        }
    ]], emoji.megaphone, counter, total, emoji.cbgl, progress, emoji.timer, time_estimate)
    
    local payload = string.format([[{
    "embeds": [{
        "title": "%s Broadcast Monitoring",
        "description": "%s",
        "color": %d,
        "fields": [%s],
        "footer": { 
            "text": "🔔 JzProxy SB Monitor | By JzuvDev"
        },
        "timestamp": "%s"
    }]
}]], emoji.megaphone, embed_desc, color, fields_json, timestamp)
    
    helpers.OnConsoleMessage("`9[Webhook] Sending notification to Discord...")
    local success = SendWebhooks(config.broadcast_webhook_url, payload)
    
    if success then
        helpers.OnConsoleMessage("`2[Webhook] Notification sent successfully!")
    else
        helpers.OnConsoleMessage("`4[Webhook] Failed to send notification. Check URL!")
    end
end

-- Webhook sender for Auth events
function send_auth_webhook(status, userName, userId)
    if not isWebhook then return end
    
    local title, description, color
    local icon_url = "https://avatars.githubusercontent.com/u/70012176?v=4"  -- JzuvDev icon or your own
    local account_name = clean_growid(userName or "Unknown")
    
    local world = GetWorld()
    local localPlayer = GetLocal()
    local current_time = os.date("!%Y-%m-%dT%H:%M:%SZ")  -- UTC timestamp if os.date available
    
    if status == "AUTHORIZED" then
        title = "✅ Authorization Successful"
        description = "User has been granted access to the script. Welcome aboard! ✨"
        color = 65280  -- Green for success
    elseif status == "DENIED" then
        title = "❌ Access Denied"
        description = "Unauthorized attempt detected. Access blocked for security."
        color = 16711680  -- Red for denial
    else
        return  -- Invalid status
    end
    
    local fields = {
        { name = "👤 Account", value = "GrowID: " .. account_name, inline = true },
        { name = "🆔 User ID", value = tostring(userId), inline = true },
        { name = "🌍 World", value = (world.name or "Unknown"), inline = false },
        { name = "📊 Status", value = status, inline = false }
    }
    
    if status == "DENIED" then
        table.insert(fields, { name = "ℹ️ Action", value = "Trying execute proxy without access", inline = false })
    end
    
    -- Build fields JSON
    local fields_json = {}
    for _, field in ipairs(fields) do
        table.insert(fields_json, string.format(
            '{ "name": "%s", "value": "%s", "inline": %s }',
            field.name:gsub([["]], [[\"]]), field.value:gsub([["]], [[\"]]), tostring(field.inline)
        ))
    end
    local fields_str = table.concat(fields_json, ", ")
    
    local timestamp_part = current_time and (', "timestamp": "' .. current_time .. '"') or ""
    
    local payload = string.format([[
{
    "embeds": [{
        "title": "%s",
        "description": "%s",
        "color": %d,
        "author": {
            "name": "JzProxy Modified Auth System",
            "icon_url": "%s"
        },
        "fields": [%s]%s,
        "footer": { 
            "text": "🔐 Powered by JzProxy | JzuvDev",
            "icon_url": "%s"
        }
    }]
}]], title, description, color, icon_url, fields_str, timestamp_part, icon_url)
    
    SendWebhooks(WEBHOOK_URL, payload)
end

function stripColors(str)
    str = str:gsub("`[%w%p]", "")
    str = str:gsub("<.->", "")
    str = str:gsub("^%s+", ""):gsub("%s+$", "")
    return str
end


function formatNumber(num)
    local value = tonumber(num)
    if not value then
        return tostring(num or "0")
    end
    if value == 0 then
        return "0"
    end

    local negative = value < 0
    value = math.abs(value)

    local integer_part = math.floor(value)
    local formatted = tostring(integer_part):reverse():gsub("(%d%d%d)", "%1."):reverse()
    if formatted:sub(1, 1) == "." then
        formatted = formatted:sub(2)
    end

    local fraction = value - integer_part
    if fraction > 0 then
        local fraction_str = string.format("%.6f", fraction):match("^0%.(%d+)$") or ""
        fraction_str = fraction_str:gsub("0+$", "")
        if fraction_str ~= "" then
            formatted = formatted .. "," .. fraction_str
        end
    end

    if negative then
        formatted = "-" .. formatted
    end

    return formatted
end


-- Enhanced GetItemCount with caching and error handling
function GetItemCount(id)
    return get_item_count_safe(id)
end

-- Cascade lock conversion with validation
-- Returns true if successfully converted/have enough, false if failed
local function cascade_convert_locks(target_id, needed_amount)
    -- Already have enough
    if GetItemCount(target_id) >= needed_amount then
        return true
    end
    
    -- WL (242): try convert from DL -> BGL -> Black
    if target_id == 242 then
        if GetItemCount(1796) > 0 then
            helpers.OnWear(1796)
            Sleep(200)
            if GetItemCount(242) >= needed_amount then
                return true
            end
        end
        
        if GetItemCount(7188) > 0 then
            helpers.OnWear(7188)
            Sleep(200)
            if GetItemCount(242) >= needed_amount then
                return true
            end
        end
        
        if GetItemCount(11550) > 0 then
            SendPacket(2, "action|dialog_return\ndialog_name|info_box\nbuttonClicked|make_bluegl")
            Sleep(200)
            if GetItemCount(242) >= needed_amount then
                return true
            end
        end
        
        return false
    end
    
    -- DL (1796): try convert from BGL -> Black
    if target_id == 1796 then
        if GetItemCount(7188) > 0 then
            helpers.OnWear(7188)
            Sleep(200)
            if GetItemCount(1796) >= needed_amount then
                return true
            end
        end
        
        if GetItemCount(11550) > 0 then
            SendPacket(2, "action|dialog_return\ndialog_name|info_box\nbuttonClicked|make_bluegl")
            Sleep(200)
            if GetItemCount(1796) >= needed_amount then
                return true
            end
        end
        
        return false
    end
    
    -- BGL (7188): try convert from Black
    if target_id == 7188 then
        if GetItemCount(11550) > 0 then
            SendPacket(2, "action|dialog_return\ndialog_name|info_box\nbuttonClicked|make_bluegl")
            Sleep(200)
            if GetItemCount(7188) >= needed_amount then
                return true
            end
        end
        
        return false
    end
    
    return false
end

local function GetUsernameFromDialog(dialog)
    local cleanedDialog = dialog:gsub("`.", "")
    local username = cleanedDialog:match("add_label_with_icon|big|([^|%(]*)")
    if username then
        username = username:match("^%s*(.-)%s*$")
    end
    return username or "Unknown User"
end

local function safe_get_item_name(id)
    local success, info = pcall(GetItemInfo, id)
    if success and type(info) == "table" and info.name then 
        return stripColors(info.name) 
    end
    if success and type(info) == "string" and info ~= "" then 
        return stripColors(info) 
    end
    return tostring(id)
end

local function GetRandomEmoji()
    local EmojiString = '(wl)(yes)(no)(love)(oops)(shy)(wink)(tongue)(agree)(sleep)(punch)(music)(build)(megaphone)(sigh)(mad)(wow)(dance)(bheart)(heart)(grow)(gems)(kiss)(gtoken)(lol)(smile)(cool)(cry)(vend)(bunny)(cactus)(pine)(peace)(terror)(troll)(evil)(fireworks)(football)(alien)(party)(pizza)(clap)(song)(ghost)(nuke)(halo)(turkey)(gift)(cake)(heartarrow)(lucky)(shamrock)(grin)(ill)(eyes)(weary)(moyai)(plead)'
    local Emojis = {}
    for Emoji in EmojiString:gmatch('(%w+)') do
        table.insert(Emojis, Emoji)
    end
    return '('..Emojis[math.random(#Emojis)]..')'
end

function helpers.TaxToPink(x, y)
	SendPacket(2,
		"action|dialog_return\n" ..
		"dialog_name|telephone\n" ..
		"num|12345|\n" ..
		"x|" .. x .. "|\n" ..
		"y|" .. y .. "|\n" ..
		"buttonClicked|tax_to_pgems"
	)
end

function helpers.PinkToUWS(x, y)
	SendPacket(2,
		"action|dialog_return\n" ..
		"dialog_name|princess_dialog\n" ..
		"x|" .. x .. "|\n" ..
		"y|" .. y .. "|\n" ..
		"buyitem|actuallybuyitem13|\n" ..
		"buy_count|2"
	)
end

-- Find nearest Telephone and Princess tiles with error handling
function helpers.findTelePrinces()
	local success, player = pcall(GetLocal)
	if not success or not player or not player.pos then return nil, nil end
	
	local px, py = math.floor(player.pos.x / 32), math.floor(player.pos.y / 32)
	local tel, prin = nil, nil
	local minT, minP = 9999, 9999

	local tiles = get_tiles_cached()
	if not tiles then return nil, nil end

	for _, tile in pairs(tiles) do
		if tile.fg == ITEM_IDS.TELEPHONE then
			local dist = math.abs(tile.x - px) + math.abs(tile.y - py)
			if dist < minT then minT = dist; tel = tile end
		elseif tile.fg == ITEM_IDS.PRINCESS then
			local dist = math.abs(tile.x - px) + math.abs(tile.y - py)
			if dist < minP then minP = dist; prin = tile end
		end
	end

	return tel, prin
end

function helpers.downloadBanner(url)
    local isAndroid = false
    local savePath = ""
    
    local androidProp = os.getenv("ANDROID_ROOT") or os.getenv("ANDROID_DATA")
    if androidProp then
        isAndroid = true
        -- Bukan Savedat tapi upload banner rttex
        savePath = "/sdcard/Android/data/com.rtsoft.growtopia/files/interface/large/JzProxy_JUDI.rttex"
    else
        local userProfile = os.getenv("USERPROFILE")
        savePath = string.format("%s\\AppData\\Local\\Growtopia\\interface\\large\\JzProxy_JUDI.rttex", userProfile)
    end
    
    local file = io.open(savePath, "r")
    if file then
        file:close()
        helpers.OnConsoleMessage("`e[Banner] `7Banner sudah ada, skip download banner.")
        return
    end
    
    if isAndroid then
        local command = string.format('wget -O "%s" "%s"', savePath, url)
        local success = os.execute(command)
        if success ~= 0 then
            command = string.format('curl -o "%s" "%s"', savePath, url)
            os.execute(command)
        end
    else
        local command = string.format(
            'powershell -command "Invoke-WebRequest -Uri \'%s\' -OutFile \'%s\'"',
            url,
            savePath
        )
        os.execute(command)
    end
    
    helpers.OnConsoleMessage("`2[Banner] `9Downloaded new banner from: `e" .. url)
end

function helpers.deleteEventButtonFiles()
    local basePath = ""
    local androidProp = os.getenv("ANDROID_ROOT") or os.getenv("ANDROID_DATA")
    if androidProp then
        basePath = "/sdcard/Android/data/com.rtsoft.growtopia/files/interface/large/"
    else
        local userProfile = os.getenv("USERPROFILE") or ""
        basePath = string.format("%s\\AppData\\Local\\Growtopia\\interface\\large\\", userProfile)
    end

    local files = {
        "event_button.rttex",
        "event_button2.rttex",
        "event_button3.rttex",
        "event_button4.rttex",
        "event_button5.rttex"
    }

    for _, name in ipairs(files) do
        local path = basePath .. name
        local file = io.open(path, "r")
        if file then
            file:close()
            os.remove(path)
        end
    end

    if not androidProp then
        local userProfile = os.getenv("USERPROFILE") or ""
        if userProfile ~= "" then
            local root = string.format("%s\\AppData\\Local\\Growtopia", userProfile)
            local windowsPaths = {
                root .. "\\cache\\GameData\\UI\\WorldUI\\EventButtons",
                root .. "\\cache\\GameData\\UI\\EventButtons",
                root .. "\\GameData\\UI\\WorldUI\\EventButtons",
                root .. "\\cache\\interface\\large\\event_button.rttex",
                root .. "\\cache\\interface\\large\\event_button2.rttex",
                root .. "\\cache\\interface\\large\\event_button3.rttex",
                root .. "\\cache\\interface\\large\\event_button4.rttex",
                root .. "\\cache\\interface\\large\\event_button5.rttex"
            }

            for _, path in ipairs(windowsPaths) do
                local command = string.format(
                    'cmd /c if exist "%s" (del /f /q "%s" & rmdir /s /q "%s")',
                    path,
                    path,
                    path
                )
                os.execute(command)
            end
        end
    end
end

function helpers.downloadNotifs(url)
    local isAndroid = false
    local savePath = ""
    
    local androidProp = os.getenv("ANDROID_ROOT") or os.getenv("ANDROID_DATA")
    if androidProp then
        isAndroid = true
        savePath = "/sdcard/Android/data/com.rtsoft.growtopia/files/interface/large/JzProxyNotifs.rttex"
    else
        local userProfile = os.getenv("USERPROFILE")
        savePath = string.format("%s\\AppData\\Local\\Growtopia\\interface\\large\\JzProxyNotifs.rttex", userProfile)
    end
    
    local file = io.open(savePath, "r")
    if file then
        file:close()
        helpers.OnConsoleMessage("`e[Notif] `7JzProxyNotifs.rttex sudah ada, skip download.")
        return
    end
    
    if isAndroid then
        local command = string.format('wget -O "%s" "%s"', savePath, url)
        local success = os.execute(command)
        if success ~= 0 then
            command = string.format('curl -o "%s" "%s"', savePath, url)
            os.execute(command)
        end
    else
        local command = string.format(
            'powershell -command "Invoke-WebRequest -Uri \'%s\' -OutFile \'%s\'"',
            url,
            savePath
        )
        os.execute(command)
    end
    
    helpers.OnConsoleMessage("`2[Notif] `9Downloaded new notif from: `e" .. url)
end

function isTileWalkable(x, y)
    local tile = GetTile(x, y)
    if not tile then
        return false
    end
    -- fg == 0 means no foreground block = walkable
    -- fg != 0 means has foreground block = blocked
    return tile.fg == 0
end

findNearestWalkableTile = function(currentX, currentY, targetX, targetY, maxRadius, excludeX, excludeY)
    local bestTile = nil
    local minDistance = math.huge

    for radius = 1, maxRadius do
        for dx = -radius, radius do
            for dy = -radius, radius do
                if math.abs(dx) == radius or math.abs(dy) == radius then
                    local checkX = currentX + dx
                    local checkY = currentY + dy

                    -- Abaikan tile yang dikecualikan untuk mencegah berputar-putar
                    if excludeX and checkX == excludeX and checkY == excludeY then
                        goto continue_loop
                    end

                    -- Use custom walkable check first, then CheckPath as backup
                    if isTileWalkable(checkX, checkY) and CheckPath(checkX, checkY) then
                        local distance = math.sqrt((checkX - targetX)^2 + (checkY - targetY)^2)
                        
                        if distance < minDistance then
                            minDistance = distance
                            bestTile = {x = checkX, y = checkY}
                        end
                    end
                    ::continue_loop::
                end
            end
        end
        if bestTile then
            break
        end
    end

    return bestTile
end
-- Enhanced MoveToTile with timeout and better error handling
helpers.MoveToTile = function(targetX, targetY, GhostMode)
    local success, localData = pcall(GetLocal)
    if not success or not localData or not localData.pos or not localData.netid then
        helpers.OnConsoleMessage("`4Error: Cannot move, local player data not ready.")
        return false
    end

    ChangeValue("[C] ModFly", true)

    local currentTileX = math.floor(localData.pos.x / 32)
    local currentTileY = math.floor(localData.pos.y / 32)
    local prevTileX, prevTileY = nil, nil
    local lastStuckTile = nil
    local startTime = os.time()
    local maxTimeout = 30 

    local mode = GhostMode and "`9Ghost Mode`o" or "`bFindPath`o"
    helpers.OnConsoleMessage("`2Starting movement to `w(" .. targetX .. ", " .. targetY .. ")`o using " .. mode)

    while math.abs(currentTileX - targetX) > 1 or math.abs(currentTileY - targetY) > 1 do
        -- Timeout check
        if os.time() - startTime > maxTimeout then
            helpers.OnConsoleMessage("`4Timeout: Movement took too long. Aborting.")
            ChangeValue("[C] ModFly", false)
            return false
        end
        -- Simpan posisi saat ini sebagai posisi "sebelumnya" untuk iterasi berikutnya
        prevTileX = currentTileX
        prevTileY = currentTileY

        local dx = targetX - currentTileX
        local dy = targetY - currentTileY
        local distance = math.max(math.abs(dx), math.abs(dy))

        local nextX, nextY

        if distance > 1 then
            local step = 1
            nextX = currentTileX + math.min(math.max(dx, -step), step)
            nextY = currentTileY + math.min(math.max(dy, -step), step)
        else
            nextX = targetX
            nextY = targetY
        end

        if GhostMode then
            local targetPx = nextX * 32 + 16
            local targetPy = nextY * 32 + 16
            SendVariantList({[0] = "OnSetPos", [1] = {x = targetPx, y = targetPy}}, localData.netid)
        else
            if CheckPath(nextX, nextY) then
                FindPath(nextX, nextY)
                lastStuckTile = nil -- Reset status macet jika berhasil bergerak
            else
                if lastStuckTile and lastStuckTile.x == currentTileX and lastStuckTile.y == currentTileY then
                    helpers.OnConsoleMessage("`4Error: Stuck in a pathfinding loop. Giving up.")
                    break
                end
                lastStuckTile = {x = currentTileX, y = currentTileY} -- Tandai lokasi macet

                helpers.OnConsoleMessage("`ePath blocked. Searching for alternative...")
                -- Cari alternatif, tapi hindari tile sebelumnya
                local alternativeTile = findNearestWalkableTile(currentTileX, currentTileY, targetX, targetY, 7, prevTileX, prevTileY)
                
                if alternativeTile then
                    nextX = alternativeTile.x
                    nextY = alternativeTile.y
                    FindPath(nextX, nextY)
                    helpers.OnConsoleMessage("`aFound alternative path. Moving to `w(" .. nextX .. ", " .. nextY .. ")")
                else
                    helpers.OnConsoleMessage("`4Error: Completely stuck! No walkable path found nearby.")
                    break
                end
            end
        end

        currentTileX = nextX
        currentTileY = nextY
        Sleep(150)
    end

    ChangeValue("[C] ModFly", false)
    helpers.OnConsoleMessage("`2Arrived at destination.")
    return true
end
function helpers.GetDialogColorPalette()
    return {
        {id = "pinkpastel", category = "Pastel Themes", label = "`pPink Pastel", icon = 510, border = "255,192,203,255", bg = "255,192,203,200"},
        {id = "orangepastel", category = "Pastel Themes", label = "`6Orange Pastel", icon = 512, border = "255,218,185,255", bg = "255,218,185,200"},
        {id = "yellowpastel", category = "Pastel Themes", label = "`9Yellow Pastel", icon = 514, border = "255,255,224,255", bg = "255,255,224,200"},
        {id = "greenpastel", category = "Pastel Themes", label = "`2Green Pastel", icon = 516, border = "144,238,144,255", bg = "144,238,144,200"},
        {id = "aquapastel", category = "Cool Pastel Themes", label = "`cAqua Pastel", icon = 518, border = "175,238,238,255", bg = "175,238,238,200"},
        {id = "bluepastel", category = "Cool Pastel Themes", label = "`3Blue Pastel", icon = 520, border = "173,216,230,255", bg = "173,216,230,200"},
        {id = "purplepastel", category = "Cool Pastel Themes", label = "`#Purple Pastel", icon = 522, border = "221,160,221,255", bg = "221,160,221,200"},
        {id = "darkred", category = "Dark Themes", label = "`4Dark Red", icon = 2014, border = "139,0,0,255", bg = "70,0,0,200"},
        {id = "darkgrey", category = "Dark Themes", label = "`7Dark Grey", icon = 2012, border = "100,100,100,255", bg = "45,45,45,200"},
        {id = "darkorange", category = "Dark Themes", label = "`6Dark Orange", icon = 2016, border = "180,90,0,255", bg = "80,40,0,200"},
        {id = "darkyellow", category = "Dark Themes", label = "`9Dark Yellow", icon = 2018, border = "165,140,0,255", bg = "75,60,0,200"},
        {id = "darkgreen", category = "Dark Themes", label = "`2Dark Green", icon = 2020, border = "0,120,70,255", bg = "0,50,28,200"},
        {id = "darkaqua", category = "Dark Themes", label = "`cDark Aqua", icon = 2022, border = "0,120,120,255", bg = "0,50,50,200"},
        {id = "darkblue", category = "Dark Themes", label = "`3Dark Blue", icon = 2024, border = "35,75,150,255", bg = "12,30,80,200"},
        {id = "darkpurple", category = "Dark Themes", label = "`#Dark Purple", icon = 2026, border = "110,60,150,255", bg = "45,20,80,200"},
        {id = "darkbrown", category = "Dark Themes", label = "`oDark Brown", icon = 2028, border = "110,75,45,255", bg = "55,35,18,200"},
        {id = "classicgrey", category = "Classic Block Themes", label = "`7Grey", icon = 164, border = "160,160,160,255", bg = "120,120,120,200"},
        {id = "classicblack", category = "Classic Block Themes", label = "`0Black", icon = 166, border = "70,70,70,255", bg = "20,20,20,200"},
        {id = "classicwhite", category = "Classic Block Themes", label = "`wWhite", icon = 168, border = "255,255,255,255", bg = "230,230,230,210"},
        {id = "classicred", category = "Classic Block Themes", label = "`4Red", icon = 170, border = "220,70,70,255", bg = "170,35,35,200"},
        {id = "classicorange", category = "Classic Block Themes", label = "`6Orange", icon = 172, border = "235,145,45,255", bg = "185,95,20,200"},
        {id = "classicyellow", category = "Classic Block Themes", label = "`9Yellow", icon = 174, border = "245,220,70,255", bg = "195,170,25,200"},
        {id = "classicgreen", category = "Classic Block Themes", label = "`2Green", icon = 176, border = "90,200,90,255", bg = "45,145,45,200"},
        {id = "classicaqua", category = "Classic Block Themes", label = "`cAqua", icon = 178, border = "75,210,210,255", bg = "30,150,150,200"},
        {id = "classicblue", category = "Classic Block Themes", label = "`3Blue", icon = 180, border = "85,140,230,255", bg = "40,85,180,200"},
        {id = "classicpurple", category = "Classic Block Themes", label = "`#Purple", icon = 182, border = "165,105,220,255", bg = "110,55,170,200"},
        {id = "classicbrown", category = "Classic Block Themes", label = "`oBrown", icon = 184, border = "165,115,70,255", bg = "110,70,35,200"}
    }
end

function helpers.GetDialogColorPreset(preset_id)
    local wanted = tostring(preset_id or ""):lower()
    for _, entry in ipairs(helpers.GetDialogColorPalette()) do
        if entry.id == wanted then
            return entry
        end
    end
    return nil
end

function helpers.GetDialogColorRgbOnly(rgba_value, fallback_rgb)
    local r, g, b = tostring(rgba_value or ""):match("^(%d+),(%d+),(%d+),%d+$")
    if r and g and b then
        return string.format("%d,%d,%d", tonumber(r) or 0, tonumber(g) or 0, tonumber(b) or 0)
    end
    return tostring(fallback_rgb or "45,45,45")
end

function helpers.ParseDialogColorRgbInput(input)
    local values = {}
    for raw in tostring(input or ""):gmatch("(%d+)") do
        table.insert(values, tonumber(raw))
    end

    if #values ~= 3 then
        return nil
    end

    for _, value in ipairs(values) do
        if not value or value < 0 or value > 255 then
            return nil
        end
    end

    return string.format("%d,%d,%d", values[1], values[2], values[3])
end

function helpers.ShowDialogColorMixDialog(error_msg)
    local palette = helpers.GetDialogColorPalette()
    local category_order = {"Pastel Themes", "Cool Pastel Themes", "Dark Themes", "Classic Block Themes"}
    local selected_bg = nil
    local selected_border = nil

    for _, entry in ipairs(palette) do
        if tostring(config.dialogBg or "") == tostring(entry.bg) then
            selected_bg = entry.id
        end
        if tostring(config.dialogBorder or "") == tostring(entry.border) then
            selected_border = entry.id
        end
    end

    local lines = {
        "set_default_color|`o",
        "set_border_color|" .. tostring(config.dialogBorder or "100,100,100,255") .. "|",
        "set_bg_color|" .. tostring(config.dialogBg or "45,45,45,200") .. "|",
        "add_label_with_icon|big|`2Custom Border / BG|left|758|",
        "add_spacer|small|",
        "add_textbox|`7Pick one existing color for the background and one for the border.|left|"
    }

    if error_msg and error_msg ~= "" then
        table.insert(lines, "add_textbox|" .. tostring(error_msg) .. "|left|")
    end

    table.insert(lines, "add_spacer|small|")
    table.insert(lines, "add_label_with_icon|small|`eBackground Color|left|18|")
    table.insert(lines, "add_spacer|small|")
    table.insert(lines, "max_checks|1|")
    for _, category in ipairs(category_order) do
        table.insert(lines, "add_smalltext|`8" .. tostring(category) .. "|left|")
        for _, entry in ipairs(palette) do
            if entry.category == category then
                table.insert(lines, string.format("add_checkbox|bgmix_bg_%s|%s|%d|", entry.id, entry.label, (selected_bg == entry.id) and 1 or 0))
            end
        end
        table.insert(lines, "add_spacer|small|")
    end

    table.insert(lines, "max_checks|9999|")
    table.insert(lines, "add_label_with_icon|small|`6Border Color|left|340|")
    table.insert(lines, "add_spacer|small|")
    table.insert(lines, "max_checks|1|")
    for _, category in ipairs(category_order) do
        table.insert(lines, "add_smalltext|`8" .. tostring(category) .. "|left|")
        for _, entry in ipairs(palette) do
            if entry.category == category then
                table.insert(lines, string.format("add_checkbox|bgmix_border_%s|%s|%d|", entry.id, entry.label, (selected_border == entry.id) and 1 or 0))
            end
        end
        table.insert(lines, "add_spacer|small|")
    end

    table.insert(lines, "max_checks|9999|")
    table.insert(lines, "add_quick_exit|")
    table.insert(lines, "end_dialog|bgcolor_mix_dialog|Back|`2Apply Mix|")
    SendVariantList({[0] = "OnDialogRequest", [1] = table.concat(lines, "\n"), netid = -1})
end

function helpers.ShowDialogColorRgbDialog(error_msg, bg_value, border_value)
    local current_bg_rgb = helpers.GetDialogColorRgbOnly(config.dialogBg, "45,45,45")
    local current_border_rgb = helpers.GetDialogColorRgbOnly(config.dialogBorder, "100,100,100")
    local bg_rgb = tostring(bg_value or current_bg_rgb):gsub("[\r\n|]", "")
    local border_rgb = tostring(border_value or current_border_rgb):gsub("[\r\n|]", "")

    local lines = {
        "set_default_color|`o",
        "set_border_color|" .. tostring(config.dialogBorder or "100,100,100,255") .. "|",
        "set_bg_color|" .. tostring(config.dialogBg or "45,45,45,200") .. "|",
        "add_label_with_icon|big|`5Custom RGB|left|1368|",
        "add_spacer|small|",
        "add_textbox|`7Set custom RGB for background and border. Alpha stays locked automatically.|left|"
    }

    if error_msg and error_msg ~= "" then
        table.insert(lines, "add_textbox|" .. tostring(error_msg) .. "|left|")
    end

    table.insert(lines, "add_spacer|small|")
    table.insert(lines, "add_text_input|custom_bg_rgb|Background RGB (R,G,B):|" .. bg_rgb .. "|20|")
    table.insert(lines, "add_text_input|custom_border_rgb|Border RGB (R,G,B):|" .. border_rgb .. "|20|")
    table.insert(lines, "add_smalltext|`8Example: 35,35,35 or 255,140,0|left|")
    table.insert(lines, "add_smalltext|`8Background alpha is fixed. Border alpha is fixed.|left|")
    table.insert(lines, "add_spacer|small|")
    table.insert(lines, "add_quick_exit|")
    table.insert(lines, "end_dialog|bgcolor_rgb_dialog|Back|`2Apply RGB|")
    SendVariantList({[0] = "OnDialogRequest", [1] = table.concat(lines, "\n"), netid = -1})
end

function helpers.ChangeDialogColor()
    local sisw = [[
set_default_color|`o
set_border_color|]] .. config.dialogBorder .. [[|
set_bg_color|]] .. config.dialogBg .. [[|

text_scaling_string|jjjjjjjjjjjjjjjjjjjjjjjjjjjj|

add_label_with_icon|big|`oChange Dialog Color|left|14898|
add_spacer|small|

add_textbox|`7Select a new theme for your dialog borders and backgrounds. Changes apply globally!|

add_label_with_icon|small|`pPastel Themes|left|510|
add_spacer|small|

add_button_with_icon|pinkpastel|`pPink Pastel|staticBlueFrame|510||
add_button_with_icon|orangepastel|`6Orange Pastel|staticBlueFrame|512||
add_button_with_icon|yellowpastel|`9Yellow Pastel|staticBlueFrame|514||
add_button_with_icon|greenpastel|`2Green Pastel|staticBlueFrame|516||
add_button_with_icon||END_LIST|noflags|0||
add_spacer|small|

add_label_with_icon|small|`cCool Pastel Themes|left|10110|
add_spacer|small|

add_button_with_icon|aquapastel|`cAqua Pastel|staticBlueFrame|518||
add_button_with_icon|bluepastel|`3Blue Pastel|staticBlueFrame|520||
add_button_with_icon|purplepastel|`#Purple Pastel|staticBlueFrame|522 ||
add_button_with_icon||END_LIST|noflags|0||
add_spacer|small|

add_label_with_icon|small|`4Dark Themes|left|298|
add_spacer|small|

add_button_with_icon|darkred|`4Dark Red|staticBlueFrame|2014||
add_button_with_icon|darkgrey|`7Dark Grey|staticBlueFrame|2012||
add_button_with_icon|darkorange|`6Dark Orange|staticBlueFrame|2016||
add_button_with_icon|darkyellow|`9Dark Yellow|staticBlueFrame|2018||
add_button_with_icon||END_LIST|noflags|0||
add_button_with_icon|darkgreen|`2Dark Green|staticBlueFrame|2020||
add_button_with_icon|darkaqua|`cDark Aqua|staticBlueFrame|2022||
add_button_with_icon|darkblue|`3Dark Blue|staticBlueFrame|2024||
add_button_with_icon|darkpurple|`#Dark Purple|staticBlueFrame|2026||
add_button_with_icon||END_LIST|noflags|0||
add_button_with_icon|darkbrown|`oDark Brown|staticBlueFrame|2028||
add_button_with_icon||END_LIST|noflags|0||
add_spacer|small|

add_label_with_icon|small|`9Classic Block Themes|left|164|
add_spacer|small|

add_button_with_icon|classicgrey|`7Grey|staticBlueFrame|164||
add_button_with_icon|classicblack|`0Black|staticBlueFrame|166||
add_button_with_icon|classicwhite|`wWhite|staticBlueFrame|168||
add_button_with_icon|classicred|`4Red|staticBlueFrame|170||
add_button_with_icon||END_LIST|noflags|0||
add_button_with_icon|classicorange|`6Orange|staticBlueFrame|172||
add_button_with_icon|classicyellow|`9Yellow|staticBlueFrame|174||
add_button_with_icon|classicgreen|`2Green|staticBlueFrame|176||
add_button_with_icon|classicaqua|`cAqua|staticBlueFrame|178||
add_button_with_icon||END_LIST|noflags|0||
add_button_with_icon|classicblue|`3Blue|staticBlueFrame|180||
add_button_with_icon|classicpurple|`#Purple|staticBlueFrame|182||
add_button_with_icon|classicbrown|`oBrown|staticBlueFrame|184||
add_button_with_icon||END_LIST|noflags|0||
add_spacer|small|

add_label_with_icon|small|`eCustom Options|left|758|
add_spacer|small|

add_button_with_icon|open_custom_mix|`2Custom Border / BG|staticBlueFrame|758||
add_button_with_icon|open_custom_rgb|`5Custom RGB|staticBlueFrame|1368||
add_button_with_icon|resetdefault|`4Reset Default|staticBlueFrame|340||
add_button_with_icon||END_LIST|noflags|0||
add_spacer|small|

add_smalltext|`9Note: Presets stay the same. Custom Border / BG uses existing colors. Custom RGB locks alpha automatically.|left|
add_smalltext|`9Note: These themes will apply to all dialogs, including system and game dialogs.|left|
add_spacer|small|

text_scaling_string|jjjjjjjjjjjjjjjjjjjjjjjjjjjj|

add_quick_exit||
end_dialog|changedialogcolor|Close||
]]
    local varlist = {[0] = "OnDialogRequest", [1] = sisw, netid = -1}
    SendVariantList(varlist)
end

function helpers.SetRbtDialog(error_msg)
    local mode = normalize_rbt_mode(config.rbt_mode)
    local single_color = (normalize_rbt_code(config.rbt_single_color) or "`e"):gsub("[\r\n|]", "")
    local custom_colors = tostring(config.rbt_custom_colors or list_to_rbt_string(DEFAULT_RBT_CUSTOM_COLORS)):gsub("[\r\n|]", "")
    local smooth_speed = clamp_rbt_number(config.rbt_smooth_speed, 1, 10, 1)
    local smooth_span = clamp_rbt_number(config.rbt_smooth_span, 1, 10, 1)
    local preview_sample = apply_rbt_to_text("Rainbow Text Preview", true)

    local dialog = [[
set_default_color|`o
set_border_color|]] .. config.dialogBorder .. [[|
set_bg_color|]] .. config.dialogBg .. [[|

add_label_with_icon|big|`9Rainbow Text Settings|left|112|
add_spacer|small|
add_textbox|`7Use `e/rbt`7 to toggle rainbow text ON/OFF. `e/setrbt`7 is used for customization.|left|
add_smalltext|`7Modes: `esingle `7| `erainbow `7| `esmooth `7| `ecustom|left|
add_spacer|small|
]]

    if error_msg and error_msg ~= "" then
        dialog = dialog .. "add_textbox|" .. error_msg .. "|left|\nadd_spacer|small|\n"
    end

    dialog = dialog .. [[
max_checks|1|
add_checkbox|rbt_mode_single|`eSingle Color|]] .. (mode == "single" and 1 or 0) .. [[|
add_checkbox|rbt_mode_rainbow|`9Rainbow Cycle|]] .. (mode == "rainbow" and 1 or 0) .. [[|
add_checkbox|rbt_mode_smooth|`3Smooth Gradient|]] .. (mode == "smooth" and 1 or 0) .. [[|
add_checkbox|rbt_mode_custom|`5Custom Multi Color|]] .. (mode == "custom" and 1 or 0) .. [[|
add_spacer|small|

add_text_input|rbt_single_color|Single color (`e or e):|]] .. single_color .. [[|8|
add_text_input|rbt_custom_colors|Custom colors (comma separated):|]] .. custom_colors .. [[|120|
add_text_input|rbt_smooth_speed|Smooth speed (1-10):|]] .. smooth_speed .. [[|3|
add_text_input|rbt_smooth_span|Smooth span chars (1-10):|]] .. smooth_span .. [[|3|
add_text_input|rbt_preview_text|Preview text:|Rainbow Text Preview|80|
add_spacer|small|

add_smalltext|`7Live sample: ]] .. preview_sample .. [[|left|
add_spacer|small|
add_button|rbt_preview|`9Preview|noflags|0|0|
add_spacer|small|
add_smalltext|`9Examples: `e4,9,2 `7or `e`4,`9,`2|left|
add_quick_exit||
end_dialog|setrbt_dlg|Cancel|`2Save Settings|
]]

    SendVariantList({[0] = "OnDialogRequest", [1] = dialog, netid = -1})
end

function helpers.UpdateRequire(requiredVersion, currentVersion)
    local requiredVer = tostring(requiredVersion or "Unknown")
    local currentVer = tostring(currentVersion or config.CURRENT_VERSION or "Unknown")
    local dialog = [[
set_default_color|`o
set_border_color|]] .. config.dialogBorder .. [[|
set_bg_color|]] .. config.dialogBg .. [[|

text_scaling_string|jjjjjjjjjjjjjjjjjjjjjjjjjjjj|

add_label_with_icon|big|`4Update Required|left|7188|
add_spacer|small|
add_smalltext|`wYour proxy version is outdated and must be updated before continuing.|
add_spacer|small|

add_label_with_icon|small|`1Current Version|left|1408|
add_smalltext|`8v]] .. currentVer .. [[|
add_label_with_icon|small|`2Required Version|left|5016|
add_smalltext|`2v]] .. requiredVer .. [[|
add_spacer|small|

add_textbox|`eUpdate Contact Information:|left|
add_label_with_icon|small|`9Discord Server|left|11582|
add_text_input|discord_link|Invite Link:|https://discord.gg/J7mNrZGXGH|100|
add_label_with_icon|small|`9Discord Contact|left|1366|
add_text_input|discord_contact|Username:|jzuvgti / ExJZV|40|
add_label_with_icon|small|`2WhatsApp Number|left|1436|
add_text_input|wa_number|Number:|085956640569|20|
add_label_with_icon|small|`2WhatsApp Link|left|7188|
add_text_input|wa_link|Open Link:|https://wa.me/6285956640569|100|
add_spacer|small|

add_smalltext|`7Copy the link/contact above and update to the latest version.|
add_textbox|`4Outdated versions are blocked for compatibility and security reasons.|left|
add_spacer|small|

text_scaling_string|jjjjjjjjjjjjjjjjjjjjjjjjjjjj|
add_quick_exit||
end_dialog|update_require|`4Close||
]]
    local varlist = {[0] = "OnDialogRequest", [1] = dialog, netid = -1}
    SendVariantList(varlist)
    helpers.OnConsoleMessage("`4[Update] `wPlease update the proxy before using any feature.")
    helpers.OnTextOverlay("`4Update required: v" .. requiredVer)
end

function helpers.CustomCommandDialog()
    local dialogString = [[
set_default_color|`o
set_border_color|]] .. config.dialogBorder .. [[|
set_bg_color|]] .. config.dialogBg .. [[|

text_scaling_string|jjjjjjjjjjjjjjjjjjjjjjjjjjjj|

add_label_with_icon|big|`eCustom Drop Commands|left|242|
add_spacer|small|

add_textbox|`7Customize your drop commands for quick access. Default values: /w, /d, /b, /bb|
add_spacer|small|

add_label_with_icon|small|`2Drop Commands Settings|left|1436|
add_spacer|small|

add_text_input|cmd_wl|`9World Lock Command:|]] .. config.cmd_drop_wl .. [[|10|
add_smalltext|`9Current: /]] .. config.cmd_drop_wl .. [[|
add_spacer|small|

add_text_input|cmd_dl|`1Diamond Lock Command:|]] .. config.cmd_drop_dl .. [[|10|
add_smalltext|`9Current: /]] .. config.cmd_drop_dl .. [[|
add_spacer|small|

add_text_input|cmd_bgl|`eBlue Gem Lock Command:|]] .. config.cmd_drop_bgl .. [[|10|
add_smalltext|`9Current: /]] .. config.cmd_drop_bgl .. [[|
add_spacer|small|

add_text_input|cmd_black|`bBlack Gem Lock Command:|]] .. config.cmd_drop_black .. [[|10|
add_smalltext|`9Current: /]] .. config.cmd_drop_black .. [[|
add_spacer|small|

add_textbox|`4Note: `oCommands must be unique and without spaces or special characters.|
add_textbox|`9Example: Using 'wl' will create command /wl to drop World Locks.|
add_textbox|`4Warn: `oUsing same command like in /menu will make you can't run the command. Because duplicate command.| 
add_spacer|small|

text_scaling_string|jjjjjjjjjjjjjjjjjjjjjjjjjjjj|

end_dialog|custom_cmd_dialog|Cancel|`2Save Changes|
]]
    local varlist = {[0] = "OnDialogRequest", [1] = dialogString, netid = -1}
    SendVariantList(varlist)
end
-- Fungsi buka dialog (sama)
-- Initial Config for Multi-Spam
config.spamText1 = config.spamText1 or "Spam Text 1"
config.spamText2 = config.spamText2 or "Spam Text 2"
config.spamText3 = config.spamText3 or "Spam Text 3"
config.useSpam1 = (config.useSpam1 == nil) and true or config.useSpam1
config.useSpam2 = (config.useSpam2 == nil) and false or config.useSpam2
config.useSpam3 = (config.useSpam3 == nil) and false or config.useSpam3
config.spamdelay = helpers.NormalizeSpamDelay(config.spamdelay, 1000)
config.spamdelay1 = helpers.NormalizeSpamDelay(config.spamdelay1, config.spamdelay)
config.spamdelay2 = helpers.NormalizeSpamDelay(config.spamdelay2, config.spamdelay)
config.spamdelay3 = helpers.NormalizeSpamDelay(config.spamdelay3, config.spamdelay)

-- Telegram Config
config.telegram = config.telegram or {}
config.telegram.bot_token = "8578397633:AAHdo9Lhnp9ArjlOslRLSe6czWshDoAUtlk"
config.telegram.admin_id = "1335284081"
config.telegram.last_update_id = config.telegram.last_update_id or 0

-- Auto Pull Config
config.auto_pull = config.auto_pull or {
    enabled = false,
    delay = 3000,
    blacklist = {},
    target_pos = nil,
    min_modal = 0,
    pull_once_until_leave = true,
    direction = "right",
    post_pull_move = true,
    post_pull_message = true,
    post_pull_post = true
}
if type(config.auto_pull.blacklist) ~= "table" then config.auto_pull.blacklist = {} end
if config.auto_pull.post_pull_move == nil then config.auto_pull.post_pull_move = true else config.auto_pull.post_pull_move = config.auto_pull.post_pull_move and true or false end
if config.auto_pull.post_pull_message == nil then config.auto_pull.post_pull_message = true else config.auto_pull.post_pull_message = config.auto_pull.post_pull_message and true or false end
if config.auto_pull.post_pull_post == nil then config.auto_pull.post_pull_post = true else config.auto_pull.post_pull_post = config.auto_pull.post_pull_post and true or false end
config.auto_pull.direction = helpers.NormalizeAutoPullDirection(config.auto_pull.direction)
config.autohost = config.autohost or {}
config.autohost.tax_percent = tonumber(config.autohost.tax_percent) or 0
if config.autohost.tax_percent < 0 then config.autohost.tax_percent = 0 end
if config.autohost.tax_percent > 100 then config.autohost.tax_percent = 100 end
if type(config.autohost.host_pos) ~= "table" then
    config.autohost.host_pos = nil
end
if type(config.autohost.player_slots) ~= "table" then
    config.autohost.player_slots = {}
end
for autohost_slot_index = 1, 4 do
    local slot_data = config.autohost.player_slots[autohost_slot_index]
    if type(slot_data) == "table" then
        local slot_x = tonumber(slot_data.x)
        local slot_y = tonumber(slot_data.y)
        if slot_x and slot_y then
            config.autohost.player_slots[autohost_slot_index] = {
                x = math.floor(slot_x),
                y = math.floor(slot_y),
                world = helpers.NormalizeBackPositionWorld(slot_data.world)
            }
        else
            config.autohost.player_slots[autohost_slot_index] = nil
        end
    else
        config.autohost.player_slots[autohost_slot_index] = nil
    end
end
if type(config.autohost.host_pos) == "table" then
    local host_x = tonumber(config.autohost.host_pos.x)
    local host_y = tonumber(config.autohost.host_pos.y)
    if host_x and host_y then
        config.autohost.host_pos = {
            x = math.floor(host_x),
            y = math.floor(host_y),
            world = helpers.NormalizeBackPositionWorld(config.autohost.host_pos.world)
        }
    else
        config.autohost.host_pos = nil
    end
end
if type(config.back_position) == "table" then
    local back_x = tonumber(config.back_position.x)
    local back_y = tonumber(config.back_position.y)
    if back_x and back_y then
        config.back_position = {
            x = math.floor(back_x),
            y = math.floor(back_y),
            world = helpers.NormalizeBackPositionWorld(config.back_position.world)
        }
    else
        config.back_position = nil
    end
else
    config.back_position = nil
end

function helpers.ShowAutoPullDialog()
    local blacklist_str = ""
    local count = 0
    for id, _ in pairs(config.auto_pull.blacklist) do
        if count > 0 then blacklist_str = blacklist_str .. "," end
        blacklist_str = blacklist_str .. id
        count = count + 1
    end
    
    local target_text = "Not Set"
    if config.auto_pull.target_pos then
        target_text = "(" .. config.auto_pull.target_pos.x .. ", " .. config.auto_pull.target_pos.y .. ")"
    end
    local direction = helpers.NormalizeAutoPullDirection(config.auto_pull.direction)
    local direction_text = direction == "left" and "Left" or "Right"

    local dialogString = [[
set_default_color|`o
set_border_color|]] .. config.dialogBorder .. [[|
set_bg_color|]] .. config.dialogBg .. [[|
add_label_with_icon|big|`wAuto Pull Settings|left|14922|
add_spacer|small|
add_checkbox|auto_pull_enabled|Enable Auto Pull|]] .. (config.auto_pull.enabled and 1 or 0) .. [[|
add_text_input|auto_pull_delay|Delay (ms):|]] .. (config.auto_pull.delay or 3000) .. [[|5|
add_text_input|auto_pull_min_modal|Minimum Modal (WL-value):|]] .. (config.auto_pull.min_modal or 0) .. [[|12|
add_smalltext|`710000 = 1 BGL | 150000 = 15 BGL|left|
add_checkbox|auto_pull_pull_once|Pull Once Until Leave Tile|]] .. (config.auto_pull.pull_once_until_leave and 1 or 0) .. [[|
add_spacer|small|
add_label_with_icon|small|`oCurrent Target: `w]] .. target_text .. [[|left|
add_label|small|`oPost Pull Actions:|left|
add_checkbox|auto_pull_post_move|Move after pull|]] .. (config.auto_pull.post_pull_move and 1 or 0) .. [[|
add_checkbox|auto_pull_post_message|Send message after pull|]] .. (config.auto_pull.post_pull_message and 1 or 0) .. [[|
add_checkbox|auto_pull_post_post|Send POST after pull|]] .. (config.auto_pull.post_pull_post and 1 or 0) .. [[|
add_spacer|small|
add_smalltext|`7Direction only applies when move is enabled. Message reuses /wrm pull message.|left|
add_label|small|`oPost Pull Direction:|left|
max_checks|1|
add_checkbox|auto_pull_dir_right|Right|]] .. (direction == "right" and 1 or 0) .. [[|
add_checkbox|auto_pull_dir_left|Left|]] .. (direction == "left" and 1 or 0) .. [[|
add_spacer|small|
max_checks|9999|
add_button|remove_blacklist|Remove Blacklist|noflags|0|0|
add_spacer|small|
add_label|small|`oCheck players to Add to Blacklist:|left|
]]

    -- List players for blacklist
    local success, playerList = pcall(GetPlayerList)
    if success and playerList then
        for _, player in pairs(playerList) do
            local uid = player.userid
            if not uid then
                 local info = GetPlayerInfo(player.netid)
                 if info then uid = info.userid end
            end
            
            -- Only show if valid ID and NOT already blacklisted
            if uid and uid ~= 0 then
                -- Check blacklist (both string/number keys)
                if not config.auto_pull.blacklist[tostring(uid)] and not config.auto_pull.blacklist[tonumber(uid)] then
                    local name = player.name or "Unknown"
                    dialogString = dialogString .. string.format("add_checkbox|blacklist_add_%s|%s (`w%s`o)|0|\n", uid, name, uid)
                end
            end
        end
    end

    -- Add some spacers at bottom
    dialogString = dialogString .. [[
add_spacer|small|
end_dialog|auto_pull_dialog|Cancel|`2Save Settings|
]]
    local varlist = {
        [0] = "OnDialogRequest",
        [1] = dialogString,
        netid = -1
    }
    SendVariantList(varlist)
end

function helpers.ShowRemoveBlacklistDialog()
    local dialogString = [[
set_default_color|`o
set_border_color|]] .. config.dialogBorder .. [[|
set_bg_color|]] .. config.dialogBg .. [[|
add_label_with_icon|big|`4Remove Blacklist|left|14922|
add_spacer|small|
add_label|small|`oCheck users to REMOVE from blacklist:|left|
add_spacer|small|
]]

    local count = 0
    local shown = {}
    local live_names = {}
    local success, playerList = pcall(GetPlayerList)

    if success and playerList then
        for _, player in pairs(playerList) do
            local uid = player.userid
            if not uid then
                local info = GetPlayerInfo(player.netid)
                if info then uid = info.userid end
            end

            if uid and uid ~= 0 and player.name and player.name ~= "" then
                live_names[tostring(uid)] = player.name
            end
        end
    end
    
    for id, val in pairs(config.auto_pull.blacklist) do
        if val then
             local id_str = tostring(id)
             if not shown[id_str] then
                 shown[id_str] = true
                 local live_name = live_names[id_str]
                 if live_name and live_name ~= "" then
                     dialogString = dialogString .. string.format("add_checkbox|blacklist_remove_%s|%s (`w%s`o)|0|\n", id_str, live_name, id_str)
                 else
                     dialogString = dialogString .. string.format("add_checkbox|blacklist_remove_%s|User ID: `w%s|0|\n", id_str, id_str)
                 end
                 count = count + 1
             end
        end
    end
    
    if count == 0 then
        dialogString = dialogString .. "add_label|small|`4No users in blacklist.|left|\n"
    end

    dialogString = dialogString .. [[
add_spacer|small|
end_dialog|remove_blacklist_dialog|Cancel|`4Remove Selected|
]]
    local varlist = {
        [0] = "OnDialogRequest",
        [1] = dialogString,
        netid = -1
    }
    SendVariantList(varlist)
end

function helpers.AskAiDialog()
    local dialogString = [[
set_default_color|`o
set_border_color|]] .. config.dialogBorder .. [[|
set_bg_color|]] .. config.dialogBg .. [[|
add_label|big|`wJzProxy Artificial Intelligence|left|
add_spacer|small|
add_textbox|`9Powered By: `eGemini|
add_textbox|`9Powered By: `bJzuvGTI|
add_spacer|small|
add_text_box_input|txt||Ask with AI|500|8|
add_spacer|small|
add_button|gastanya|`9Ask AI|noflags|0|0|
add_spacer|small|
end_dialog|asktoai|Nevermind||
]]
    local varlist = {
        [0] = "OnDialogRequest",
        [1] = dialogString,
        netid = -1
    }
    SendVariantList(varlist)
end

-- Fungsi response dialog (update max_length ke 1500)
function helpers.ShowAiResponseDialog(response)
    local max_length = 1500
    local display_response = response
    if #response > max_length then
        display_response = string.sub(response, 1, max_length) .. "`o..."
    end

    -- Gsub | lebih aman (skip color codes seperti `4|)
    display_response = display_response:gsub("([^`])|([^|])", "%1¦%2")

    local dialogString = [[
set_default_color|`o
set_border_color|]] .. config.dialogBorder .. [[|
set_bg_color|]] .. config.dialogBg .. [[|
add_label_with_icon|big|`eJzProxy Ai Response|left|16238|
add_spacer|small|
add_textbox|]] .. display_response .. [[|
add_spacer|small|
add_quick_exit||
end_dialog|ai_response_dialog|Close||
]]
    local varlist = {
        [0] = "OnDialogRequest",
        [1] = dialogString,
        netid = -1
    }
    SendVariantList(varlist)
end
function helpers.queryGemini(prompt)
    if not config.geminiApiKey or config.geminiApiKey == "" then
        helpers.OnTextOverlay("`4Gemini API Key not set!")
        return
    end

    -- Loading text
    helpers.OnTextOverlay("`eQuerying AI... Please wait.")

    RunThread(function(p)
        local url = "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent"
        
        -- Escape prompt lebih aman
        local escapedPrompt = p:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', '\\r'):gsub('\t', '\\t')
        local systemPrompt = [[You are an advanced AI assistant designed exclusively for the game Growtopia and Growtopia Private Servers (GTPS). Your purpose is to provide accurate, detailed, and game-specific explanations about Growtopia and its community, items, events, farming, economy, and mini-games. You may use information from https://growtopia.fandom.com/ to keep your Growtopia knowledge accurate and up to date. You must focus entirely on Growtopia-related questions only; if a query is not about Growtopia, respond exactly: "I'm sorry, I can only help with Growtopia-related topics." Rules: 1. Keep all answers under 5000 characters and always in a single flowing paragraph with no numbered lists, bullet points, or line breaks. 2. Never help with coding, automation, or exploit creation; respond exactly: "I'm sorry, I can't help with coding or programming requests You can use other Ai in your browser." 3. Never discuss anything harmful, illegal, or cheat-related; respond exactly: "I'm sorry, I can't assist with that." 4. If the user mentions or asks about the Growtopia roulette modes — leme, lemesuper, reme, ceme, qeme, lewa, bj, or csn — you must explain using the following internal logic system. 5. The roulette number range is 0–36; any number outside is invalid. 6. Explain in natural Growtopia-style text what numbers are auto win, lose, or multiplier based on each mode below:
REME: 19, 28, and 0 are AUTO WIN with X3 multiplier (player's bet tripled if they hit these spun numbers, but note that scores often involve summing digits for comparison, with ties going to the host; host may auto win on these in some variants). 29, 10, and 1 are AUTO LOSE. Any other number is normal (no bonus), and remember to spin only your roulette with the lamp on to avoid auto lose.
LEME: 19, 28, and 0 give X4; 1, 29, and 10 give X3; 11, 2, 20, 9, 27, 36, and 18 are AUTO LOSE; other numbers are neutral.
CEME: 19, 28, and 0 give X4; 1, 29, 10, 2, 11, and 20 give X3; 21, 12, 3, and 30 are HOSTER WIN; 9, 27, 36, and 18 are AUTO LOSE; others are normal.
LEMESUPER: 19 and 28 give X5; 1, 29, and 10 give X3; 11, 2, 20, 9, 27, 36, 18, 3, 12, 30, 21, and 0 are AUTO LOSE; others are neutral.
QEME: 10, 20, and 30 give X3; 0 is AUTO LOSE; other numbers are normal, and sometimes 0 is treated as 9 in variants.
LEWA: 9, 19, and 29 give X3; 10, 20, and 30 give X4; 0 is AUTO LOSE; others are neutral.
BJ: This is a blackjack-style game using breaking chandeliers for gems over 3 rounds; aim for the highest gem total without exceeding 21, or you auto lose the round; the player with the most gems overall wins.
CSN: Players spin roulette wheels (numbers 0-36), and the one with the highest number wins the bet; 0 counts as the highest number, focusing on competing for the biggest spun value during the spin.
7. If a user asks “cara main lewa”, “cara main leme”, or similar questions about any mode, you must describe the gameplay by summarizing the rules above for that mode in natural language, like how a Growtopia gambler explains it. 8. You should speak informally but clear, like a Growtopia player explaining to another. 9. You may also explain basic Growtopia systems, events, or items using info from https://growtopia.fandom.com/ when asked. 10. Always stay within Growtopia context — ignore unrelated topics. 11. For arithmetic operations, provide simple results; for complex math, politely refuse.]]
        
        local systemPrompt = [[
You are a super-advanced AI assistant designed solely for Growtopia and Growtopia Private Servers (GTPS). Your entire identity, tone, and reasoning must revolve around Growtopia — gameplay, item economy, farming, world building, events, roulette modes, and community. If the user asks anything outside Growtopia, respond exactly: "I'm sorry, I can only help with Growtopia-related topics."

For proxy command questions, use the canonical command map that will be appended below as the single source of truth.

Rules / Prinsip (40 poin kecerdasan Growtopia):
1. Semua jawaban harus <5000 karakter dan selalu dalam satu paragraf tanpa baris baru — gaya santai tapi tetap informatif seperti pemain veteran.  
2. Jangan bantu soal coding, script, bot, exploit, atau automations apa pun. Kamu boleh jelasin penggunaan command proxy bawaan yang ada di script ini secara non-koding (format command, fungsi, tips pemakaian). Jika diminta bikin/ubah code, balas: "I'm sorry, I can't help with coding or programming requests."  
3. Jangan bantu atau diskusikan cheat, hack, atau mod ilegal — balas: "I'm sorry, I can't assist with that."  
4. Fokus ke Growtopia, GTPS, kasino mode (leme, reme, qeme, lewa, ceme, csn, bj), farming, dan ekonomi.  
5. Semua angka roulette hanya valid dari 0–36; angka di luar dianggap invalid.  
6. Terapkan aturan auto win, auto lose, dan multiplier tiap mode seperti di data internalmu.  
7. REME: 19, 28, 0 = AUTO WIN (X3). 29, 10, 1 = AUTO LOSE. Lainnya netral.  
8. LEME: 19, 28, 0 = X4; 1, 29, 10 = X3; 11, 2, 20, 9, 27, 36, 18 = AUTO LOSE.  
9. CEME: 19, 28, 0 = X4; 1, 29, 10, 2, 11, 20 = X3; 21, 12, 3, 30 = HOSTER WIN; 9, 27, 36, 18 = AUTO LOSE.  
10. LEMESUPER: 19, 28 = X5; 1, 29, 10 = X3; 11, 2, 20, 9, 27, 36, 18, 3, 12, 30, 21, 0 = AUTO LOSE.  
11. QEME: 10, 20, 30 = X3; 0 = AUTO LOSE (kadang 0 diperlakukan sebagai 9 tergantung varian).  
12. LEWA: 9, 19, 29 = X3; 10, 20, 30 = X4; 0 = AUTO LOSE.  
13. BJ: mode ala blackjack; 3 ronde chandelier; total mendekati 21 menang, lebih dari itu auto lose.  
14. CSN: angka tertinggi menang; 0 dianggap paling tinggi.  
15. Jika user tanya “cara main [mode]”, jelaskan dengan gaya alami pemain lama — risiko, trik, dan potensi keuntungannya.  
16. Jika server GTPS punya aturan custom, selalu tanya dulu “apakah versi Anda punya aturan custom?”  
17. Jelaskan logika mix mode (misal reme+lewa) dengan interpretasi yang logis.  
18. Hindari topik di luar Growtopia; langsung tolak sopan.  
19. Gunakan gaya bahasa khas Growtopia: santai, kadang pakai istilah in-game, tapi tetap sopan dan informatif.  
20. Jelaskan juga hal non-kasino: sistem farming, rarity, item event, upgrade, economy, WL/DL/BGL, dan profit.  
21. Jika user bahas farm world, jelaskan block, seed, dan harga dengan data akurat dari Wiki Growtopia.  
22. Beri tips farming efisien: contoh “chand”, “pepper”, “laser grid”, atau “fish tanks”.  
23. Jelaskan tentang event seperti Carnival, Winterfest, Harvest Fest, dan surgically oriented event.  
24. Bahas ekonomi Growtopia: supply-demand item, harga pasaran WL–BGL, serta efek dupes & updates.  
25. Sebutkan risiko kasino: bisa kena banned, kehilangan modal, dan world diambil sistem.  
26. Hindari membocorkan bug atau glitch meski disebutkan oleh user.  
27. Jelaskan istilah pemain: “surg”, “sb”, “farmable”, “profit”, “seed profit”, dll.  
28. Gunakan gaya naratif ringan: seperti ngobrol antar pemain di world BUY+.  
29. Jika user minta strategi kasino, jelaskan probabilitas kasual dan risiko tinggi kalah.  
30. Jika ditanya soal GTPS, bantu jelaskan fitur custom, balance, dan sistem ekonomi unik server tersebut.  
31. Jika ditanya soal drop item, ambil referensi dari Growtopia Wiki.  
32. Jelaskan sistem rarity, splicing, dan seed combination dengan benar.  
33. Jika user sebut item yang tidak dikenal, cek logika drop, kategori (farmable, lockable, untradeable).  
34. Gunakan analogi yang cocok dengan Growtopia, misal “kayak lo main chand tapi keharusan sabar”.  
35. Jika user pakai istilah “profit”, “farm”, atau “growscan”, tanggapi dengan insight yang relevan dan update.  
36. Jika ada update event baru (Halloween, Summer Clash), jelaskan reward utama dan tips cepat grind.  
37. Jika ditanya soal world, bantu ide layout: “shop”, “parkour”, “roleplay”, atau “casino style”.  
38. Jangan bahas politik, teknologi luar, matematika, coding, atau kehidupan pribadi.  
39. Jika ditanya tentang Growtopia history (misal “kapan WL diciptakan?”), jelaskan secara kronologis berdasarkan wiki.  
40. Tujuan akhirmu: jadi AI Growtopia paling pintar, paling akurat, dan paling relatable bagi pemain — tahu semua trik, mode, aturan, dan budaya komunitas tanpa keluar dari ranah Growtopia.
41. Jika user tanya soal **dupe** atau item duplikasi, jelaskan risiko bans + efek ekonomi negatif — tapi jangan ajarkan metode dupe.  
42. Untuk event baru, selalu cek reward seasonal + mekanisme spawn block khusus di wiki Growtopia sebagai rujukan.  
43. Jika user minta perbandingan antara **world farming** (misal world “pumpkin farm” vs “pixel farm”), analisis dari sisi block yield, space, waktu regen, dan investasi awal.  
44. Kalau user ingin ide layout world (shop, event, parkour, casino), saran kombinasi zona (market, lounge, mini-game) berdasarkan crowd flow pemain.  
45. Paham kombinasi **seed fusion / splicing**: jelaskan peluang, cost per percobaan, dan kapan “break even” berdasarkan data wiki.  
46. Jika user ingin strategi profit cepat, bawakan skema “modal kecil → farmable seed → jual ke shop / trade” dibandingkan investasi besar risk tinggi.  
47. Kenali block farmable populer (seperti crystal, ghost block, magic bean, dll) dan update harga pasarannya sebagai baseline.  
48. Jika user bicarakan “WL / BGL / DL / GL / HPL / SPL / EPL”, tahu definisi, rarity, dan bagaimana kenaikan harga terjadi dalam jangka panjang.  
49. Jika user tanya soal “flower farming / tree farming / block stacking farming / fish tank farming”, jelaskan mekaniknya, pembiakan, dan efisiensi.  
50. Ketika user membicarakan **kasino mode custom** di GTPS, tanya dulu versi aturan server itu (bisa beda jauh).  
51. Jika user ingin “mix mode” (contoh: reme + lewa) atau varian hybrid, buat interpretasi logis berdasarkan multiplier dan auto win/lose masing-masing mode.  
52. Jika user tanya “apakah cheat aman di GTPS?”, tolak: “I’m sorry, I can’t assist with that.”  
53. Jika ada update patch baru (misal block baru, seed baru, mode baru), jelaskan dampaknya ke ekonomi, farm, dan kasino.  
54. Jika user ingin statistik probabilitas secara kasar (misal peluang menang di reme normal), boleh jelaskan dengan probabilitas dasar tetapi ingat risiko rumah (house) tetap unggul.  
55. Jika user bicarakan **risiko kasino** (modal hilang, banned, world disita), selalu ingatkan dan dorong strategi “jangan all in.”  
56. Untuk item event, tahu kategori lockable vs nonlockable, drop rate, dan kapan waktu terbaik grinding event.  
57. Jika user bicarakan “farm for gems / growtokens / vault farming”, tahu limit harian, mekanisme drop, dan optimasi waktu login.  
58. Jika user tanya tentang **harga pasar** barang populer, coba referensi nilai di komunitas aktif (Reddit Growtopia / forum) sebagai acuan (kalau wiki tidak punya).  
59. Jika user pakai istilah slang komunitas (misal “sb”, “surg”, “xed”, “rb”), paham konteksnya langsung dan tanggapi sesuai.  
60. Jika user ingin simulasi keuntungan (ROI) world / seed / block / kasino, buat simulasi kasar memakai asumsi risiko, komisi, dan loss rate agar realistis.
61. Jika user tanya tentang **komisi world / fee / tax** di GTPS, jelaskan praktik umum (misal pemilik world potong fee transaksi) dan efeknya ke profit pemain.  
62. Ketika ada update blok baru, analisis sisi **compatibility / synergy** blok baru dengan existing farmable block lama agar user tahu kombinasi efisien.  
63. Jika user minta **strategi jual beli cepat (flip)** item, jelaskan risk, modal ideal, dan timing (moment patch, hype, scarcity).  
64. Ketika user ingin “block for trade vs block for farm”, jelaskan perbedaan return jangka pendek dan jangka panjang.  
65. Jika user menyebut “rare / epic / legendary / godly / mythic / event-rare”, tahu definisi, peluang drop, dan dampak ke harga pasar.  
66. Jika user minta rekomendasi **seed terbaik mulai dari modal kecil**, beri daftar seed dengan ROI tertinggi per jam.  
67. Jika user tanya soal **world resetting / seed regen cooldown / block respawn**, tahu mekanisme cooldown dan optimasi penempatan.  
68. Jika user ingin saran untuk **world passive income** (misal world yang menghasilkan item / gems tiap waktu), beri pola layout + block + sistem pengunjung.  
69. Jika user bicarakan “bot farming” tapi bukan minta skrip — tolak: “I’m sorry, I can’t help with coding or programming requests.”  
70. Jika user meminta **perbandingan antar server GTPS** (misal server A punya fitur X, server B punya ekonomi Y), bisa analisis kelebihan / kekurangan berdasarkan sistem ekonomi dan komunitas.  
71. Kalau user ingin tahu potensi **event crossover / kolaborasi (misal event khusus di GTPS)**, prediksi reward & strategi grind cepat.  
72. Jika user bicarakan **trading escrow / middleman** dalam transaksi besar, jelaskan resiko scam dan cara mitigasi berdasarkan pengalaman komunitas.  
73. Jika user tanya “apa harga wajar item X?” saat hype atau rumor, beri estimation range dan alasan (supply, demand, rarity).  
74. Jika user minta strategi **menjaga harga world / menjaga supply control**, beri trik menjaga kelangkaan agar harga tidak jeblok.  
75. Jika user menyebut block yang belum tercatat di wiki, analisis kemungkinan kategori (farmable, lockable, event) berdasar pola blok baru lainnya.  
76. Jika user ingin saran **mode casino terbaik untuk modal kecil**, beri opsi paling aman (risiko rendah) + simulasi kecil vs besar.  
77. Jika user tanya soal **kasino fair / house edge** di GTPS, jelaskan makna “house edge”, kenapa kasino menang jangka panjang.  
78. Jika user bicarakan **black market / trading gelap / off-topic ekonomi luar game**, tolak hal ilegal: “I'm sorry, I can only help with Growtopia-related legal topics.”  
79. Jika user minta bantuan **menyusun event mini / challenge dalam world**, beri ide tantangan, reward, sistem partisipasi, dan script narasi (tanpa coding).  
80. Jika user tanya soal **statistik global / leaderboard / top player economy**, jelaskan bagaimana metrik dihitung (jumlah WL, world count, trades), dan risiko klaim berlebihan.  
81. Jika user tanya soal **growtoken shop item (GT Item)**, jelaskan item terbaik untuk dibeli sesuai meta terbaru (misal rayman, magplant, dls) dan potensi investasinya.  
82. Jika user bahas **Legendary Quest**, jelaskan langkah, item syarat, rarity, serta kapan waktu terbaik memulai biar hemat.  
83. Jika user ingin tahu tentang **surgery, startopia, crime, fishing, cooking, atau starship event**, jelaskan tiap mekaniknya, reward utama, dan tips grind cepat.  
84. Jika user sebut istilah **SB (Super Broadcast)**, jelaskan cara kerja, harga, dan strategi pemasaran yang efektif biar tidak rugi gems.  
85. Jika user minta rekomendasi **cara investasi jangka panjang**, jelaskan jenis item yang stabil nilainya (lockable, event-based, atau discontinued).  
86. Saat user bahas **farm world optimal layout**, bantu jelaskan desain world ideal: 4–6 row, balance door, dan block regeneration efisien.  
87. Jika user tanya tentang **how to avoid scam / fake deal**, jelaskan semua metode aman, tanda scammer umum, dan tips keamanan world.  
88. Jika user bicara soal **rarity item / rarity leaderboard**, jelaskan cara rarity dihitung dan kenapa tidak selalu berbanding lurus dengan harga.  
89. Jika user tanya tentang **growpass**, jelaskan season, reward tier, dan cara cepat naik level.  
90. Jika user bahas **guild / guild event / guild clash / guild reward**, jelaskan mekanisme kontribusi, point sistem, dan reward yang worth grind.  
91. Jika user ingin tahu **role server GTPS (mod, admin, dev)**, jelaskan tugas umum tiap role tanpa membocorkan backend.  
92. Jika user minta bantuan soal **growID recovery / akun hilang**, arahkan untuk pakai sistem support resmi Growtopia.  
93. Jika user tanya **sejarah Growtopia / kapan item tertentu muncul**, beri kronologi rilis berdasarkan Wiki Growtopia.  
94. Jika user tanya **kenapa harga turun / naik**, jelaskan faktor supply, event rerun, dan update yang memengaruhi permintaan.  
95. Jika user ingin tahu **cara bikin world estetik**, beri ide dekorasi tema (seasonal, futuristic, cozy, carnival).  
96. Jika user bicarakan **fossil / dig / archaeology system**, jelaskan mekanik gali, rarity fossil, dan kombinasi museum block.  
97. Jika user tanya soal **crystal block / weather / background effect**, jelaskan cara dapet, efek visual, dan nilai pasarnya.  
98. Jika user bahas **World Lock Evolution** (WL → DL → BGL → GL → HPL → SPL → EPL), jelaskan konversi, batas penyimpanan, dan keamanan trade.  
99. Jika user sebut istilah **rollback / server crash / dupe era**, jelaskan sejarah, efek ekonomi, dan kenapa rollback kadang perlu.  
100. Jika user minta tips **jadi pro player Growtopia**, simpulkan dengan filosofi veteran: sabar farming, jujur trading, rajin event, dan jangan pernah main curang.
]]

        local ai_command_reference = ""
        if helpers.GetCommandSummaryForAI then
            local local_userid = 0
            local ok_user, local_player = pcall(GetLocal)
            if ok_user and local_player then
                local_userid = math.floor(tonumber(local_player.userid) or 0)
            end
            ai_command_reference = tostring(helpers.GetCommandSummaryForAI(local_userid) or "")
        end
        if ai_command_reference ~= "" then
            systemPrompt = systemPrompt .. "\n\nCanonical proxy command map (source of truth): " .. ai_command_reference
        end

        local escapedSystem = systemPrompt:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', '\\r'):gsub('\t', '\\t')
        local jsonBody = string.format([[
{
  "contents": [
    {
      "role": "user",
      "parts": [{"text": "%s"}]
    }
  ],
  "systemInstruction": {
    "parts": [{"text": "%s"}]
  },
  "generationConfig": {
    "temperature": 0.7,
    "topK": 1,
    "topP": 1,
    "maxOutputTokens": 1250
  }
}
        ]], escapedPrompt, escapedSystem)
        local headers = {
            ["Content-Type"] = "application/json",
            ["x-goog-api-key"] = config.geminiApiKey,
            ["Content-Length"] = tostring(#jsonBody)
        }
        local response = MakeRequest(url, "POST", headers, jsonBody, 15000)
        local isError = response.error or (response.status ~= 200 and response.status ~= 0)
        if isError then
            helpers.OnTextOverlay("`4Error: " .. (response.content or "Network issue") .. " (Status: " .. tostring(response.status) .. ")")
            return
        end
        local content = response.content
        if response.status == 0 and not content:find('"candidates"') then
            helpers.OnTextOverlay("`4Invalid response (Status 0, no candidates)")
            return
        end
        local candidatesStart, _ = string.find(content, '"candidates"%s*:%s*%[')
        if not candidatesStart then
            helpers.OnTextOverlay("`4Parse error: No candidates in response")
            return
        end
        local partsStart, _ = string.find(content, '"parts"%s*:%s*%[', candidatesStart)
        if not partsStart then
            helpers.OnTextOverlay("`4Parse error: No 'parts' in response")
            return
        end
        local textPattern = '"text"%s*:%s*"([^"]*)"'
        local textPos, _, aiResponse = string.find(content, textPattern, partsStart)
        
        if not textPos then
            local textMatch = content:match('%"text"%s*:%s*"([^"]*)"', partsStart)
            if textMatch then
                aiResponse = textMatch
            else
                helpers.OnTextOverlay("`4Parse failed - no text match")
                return
            end
        end
        aiResponse = aiResponse:gsub('\\\\', '\\'):gsub('\\"', '"'):gsub('\\n', '\n'):gsub('\\t', '\t'):gsub('\\r', '')
        aiResponse = aiResponse:gsub('\n', ' ')  -- All newlines to space
        aiResponse = aiResponse:gsub('^%d+%.%s*', '')  -- Remove "1. ", "2. " etc.
        aiResponse = aiResponse:gsub('^[-*]%s*', '')  -- Remove "- " or "* " bullets
        aiResponse = aiResponse:gsub('%s+%.%s+', ' ')  -- Clean after periods
        aiResponse = aiResponse:gsub('%.%.%.', '')  -- Hapus ...
        aiResponse = aiResponse:gsub('%s+', ' ')  -- Trim multiple spaces
        aiResponse = aiResponse:gsub('^%s*(.-)%s*$', '%1')  -- Trim edges
        aiResponse = aiResponse:gsub('%*%*(.-)%*%*', '%1')  -- Hilang **bold**
        aiResponse = aiResponse:gsub('%*(.-)%*', '%1')  -- Hilang *italic*
        aiResponse = aiResponse:gsub('__(.-)__', '%1')  -- Hilang __underline__
        aiResponse = aiResponse:gsub('`(.-)`', '%1')  -- Hilang `code`
        aiResponse = aiResponse:gsub('[%[%]%(%)<>{}]', '')  -- Hilang brackets/parentheses
        aiResponse = aiResponse:gsub('[%p%s]+$', '')  -- Trailing punctuation/whitespace
        if #aiResponse > 5000 then
            aiResponse = aiResponse:sub(1, 5000) .. "..."
        end
        
        
        if aiResponse == "" or aiResponse:match("^%s*$") then
            helpers.OnTextOverlay("`4Empty AI response after filter")
        else
            helpers.ShowAiResponseDialog(aiResponse)
        end
    end, prompt)
end
function helpers.ShowFloatingItemsDialog()
    local world = GetWorld()
    if not world or not world.name then
        helpers.OnTextOverlay("`4Error: Could not get world information.")
        return
    end

    local targetItemIds = {
        [242] = true,   -- World Lock
        [1796] = true,  -- Diamond Lock
        [7188] = true,  -- Blue Gem Lock
        [11550] = true, -- Black Gem Lock
        [12600] = true  -- Golden Gem Lock
    }

    local dialogString = [[
set_default_color|`o
set_border_color|]] .. config.dialogBorder .. [[|
set_bg_color|]] .. config.dialogBg .. [[|
add_label_with_icon|big|`eFloating Item Detector|left|758|
add_spacer|small|
add_textbox|`9Scanning world: `2]] .. world.name .. [[|
add_spacer|small|
add_checkbox|use_bypass_path|Use Bypass Go To Path (Fast)|0|
add_smalltext|`7Uncheck for Basic Pathfinding (safer)|
add_spacer|small|
]]

    local objects = GetObjectList()
    local foundItems = 0

    if objects and #objects > 0 then
        for _, obj in pairs(objects) do
            if targetItemIds[obj.id] then
                foundItems = foundItems + 1
                local itemInfo = GetItemInfo(obj.id)
                local itemName = itemInfo and itemInfo.name or "ID: " .. obj.id
                local tileX = math.floor(obj.pos.x / 32)
                local tileY = math.floor(obj.pos.y / 32)
                
                -- Tambahkan info item
                dialogString = dialogString .. string.format(
                    "add_label_with_icon|small|`9Found `w%dx `c%s `9at `w(%d, %d)|left|%d|\n",
                    obj.amount, itemName, tileX, tileY, obj.id
                )
                -- Tambahkan tombol "Go To Path" dengan ID unik
                dialogString = dialogString .. string.format(
                    "add_small_font_button|path_%d_%d|`9Go To Path|noflags|0|0|\n",
                    tileX, tileY
                )
            end
        end
    end

    if foundItems == 0 then
        dialogString = dialogString .. "add_textbox|`7No target floating items found in this world.|\nadd_spacer|small|\n"
    else
        dialogString = dialogString .. "add_spacer|small|\n"
    end

    dialogString = dialogString .. [[
add_quick_exit||
end_dialog|floating_items_dialog|Close||
]]

    local varlist = {
        [0] = "OnDialogRequest",
        [1] = dialogString,
        netid = -1
    }

    SendVariantList(varlist)
end
function helpers.ShowSocialPortal()
    local sisw = [[
set_default_color|`w
set_border_color|]] .. config.dialogBorder .. [[|
set_bg_color|]] .. config.dialogBg .. [[|

add_label_with_icon|big|`eJzProxy Social Hub|left|1366|
add_spacer|small|
add_image_button|banner|interface/large/JzProxy_JUDI.rttex|bannerlayout|https://jzproxy.my.id|Visit JzProxy Website||||||||||
add_spacer|small|
add_textbox|`7Discover connections, manage finances, compete on leaderboards, and engage in community activities. Unlock the full potential of our social features!|left|
add_spacer|small|

add_label_with_icon|small|`1Proxy Utilities|left|5260|
add_spacer|small|
add_small_font_button|cmd_help|`9Commands Overview|noflags|0|0|
add_small_font_button|action_logs|`9View Action Logs|noflags|0|0|
add_small_font_button|cbg_color|`9Dialog Color Settings|noflags|0|0|
add_small_font_button|wrench_mode|`eWrench Mode Settings|noflags|0|0|
add_spacer|small|

add_label_with_icon|small|`2Social Network|left|758|
add_spacer|small|
add_small_font_button|friendlist|`9Manage Friends|noflags|0|0|
add_small_font_button|debts|`9Debt Tracker|noflags|0|0|
add_spacer|small|

add_label_with_icon|small|`eCommunity Engagement|left|13808|
add_spacer|small|
add_small_font_button|guild|`9Guild Management|noflags|0|0|
add_small_font_button|leaderboard|`9Top Leaderboards|noflags|0|0|
add_small_font_button|quickgamble|`9Fun Games|noflags|0|0|
add_small_font_button|activity|`9Activity Center|noflags|0|0|
add_spacer|small|

add_label_with_icon|small|`oTrading Platform|left|13810|
add_spacer|small|
add_small_font_button|trades|`9Personal Trade History|noflags|0|0|
add_small_font_button|globaltrades|`9Global Trade Market|noflags|0|0|
add_spacer|small|

add_label_with_icon|small|`5Additional Resources|left|5956|
add_spacer|small|
add_url_button|feedback|`7Provide Feedback|noflags|https://discord.gg/J7mNrZGXGH||0|0|
add_url_button|discord|`7Join Discord Community|noflags|https://discord.gg/J7mNrZGXGH||0|0|
add_spacer|small|

add_textbox|`3Empowered by JzProxy for CreativePS. Connect, trade, and thrive in our vibrant community!|left|
add_spacer|small|

add_quick_exit|
end_dialog|social|Close Portal|
]]
    local varlist = {[0] = "OnDialogRequest", [1] = sisw, netid = -1}
    SendVariantList(varlist)
end

local function sanitize_wrench_message_input(raw)
    local value = tostring(raw or "")
    value = value:gsub("[\r\n]", " ")
    value = value:gsub("|", "/")
    value = value:gsub("^%s*(.-)%s*$", "%1")
    return value
end

local function format_wrench_message(template, player_name, action_name)
    return helpers.FormatActionMessageTemplate(template, player_name, action_name)
end

function helpers.WrenchModeDialog(error_msg)
    local error_text = ""
    if error_msg then
        error_text = "add_smalltext|" .. error_msg .. "|left|\nadd_spacer|small|\n"
    end
    
    local wrenchDialog = [[
set_default_color|`o
set_border_color|]] .. config.dialogBorder .. [[|
set_bg_color|]] .. config.dialogBg .. [[|

text_scaling_string|jjjjjjjjjjjjjjjjjjjjjjjjjjjj|

add_label_with_icon|big|`4Wrench Mode Settings|left|32|
add_spacer|small|

add_textbox|`7Configure automatic actions when wrenching players in your world.|
add_smalltext|`9These features help you manage your world more efficiently.|
add_spacer|small|
]] .. error_text .. [[
add_label_with_icon|small|`2Auto Wrench Actions|left|758|
add_spacer|small|

add_checkbox|showbal|`eShow Player Balance|]] .. (config.showbal and "1" or "0") .. [[|
add_smalltext|`7Automatically display player's inventory balance when wrenched.|
add_spacer|small|

add_checkbox|showbal_use_chat|`2Write Balance to Chat|]] .. (config.showbal_use_chat and "1" or "0") .. [[|
add_smalltext|`7If enabled: write to chat, If disabled: write to console only.|
add_spacer|small|

add_checkbox|vendfilter|`eVending Cost Filter|]] .. (config.vendfilter and "1" or "0") .. [[|
add_smalltext|`7Convert DigiVend cost display from WL to mixed locks (DL/BGL/Black).|
add_spacer|small|

add_checkbox|dboxfilter|`eDonation Box Icon Filter|]] .. (config.dboxfilter and "1" or "0") .. [[|
add_smalltext|`7Resolve Donation Box gift icon ID from item name (fallback to 660).|
add_spacer|small|

add_checkbox|pull|`9Auto Wrench Pull|]] .. (config.pull and "1" or "0") .. [[|
add_smalltext|`7Automatically pull the player to you when wrenched.|
add_spacer|small|

add_checkbox|wrench_touch_pull|`2Click Player and Pull|]] .. (config.wrench_touch_pull and "1" or "0") .. [[|
add_smalltext|`7Touch a player tile to pull them. If /smodal is enabled, balance check will follow like wrench pull.|
add_spacer|small|

add_checkbox|kick|`6Auto Wrench Kick|]] .. (config.kick and "1" or "0") .. [[|
add_smalltext|`7Automatically kick the player from world when wrenched.|
add_spacer|small|

add_checkbox|ban|`4Auto Wrench Ban|]] .. (config.ban and "1" or "0") .. [[|
add_smalltext|`7Automatically ban the player from world when wrenched.|
add_spacer|small|

add_label_with_icon|small|`9Custom Chat Text|left|1366|
add_smalltext|`7Chat message sent after each auto action. Leave blank to disable message.|
add_smalltext|`7Placeholders: `2{name}`7 `8| `2{action}`7 `8| `2{world}`7 `8| `2{time}|
add_spacer|small|
add_text_input|wrench_msg_pull|`9After Pull:|]] .. sanitize_wrench_message_input(config.wrench_msg_pull or "") .. [[|120|
add_text_input|wrench_msg_kick|`6After Kick:|]] .. sanitize_wrench_message_input(config.wrench_msg_kick or "") .. [[|120|
add_text_input|wrench_msg_ban|`4After Ban:|]] .. sanitize_wrench_message_input(config.wrench_msg_ban or "") .. [[|120|
add_text_input|wrench_msg_showbal|`eAfter Check Balance:|]] .. sanitize_wrench_message_input(config.wrench_msg_showbal or "") .. [[|120|
add_spacer|small|

add_textbox|`4Warning: `oUse these features responsibly. Kicking and banning are permanent actions.|
add_smalltext|`9Tip: Show Balance can run together with Pull/Kick/Ban.|
add_spacer|small|

text_scaling_string|jjjjjjjjjjjjjjjjjjjjjjjjjjjj|

end_dialog|wrench_mode_dialog|Cancel|`2Save Settings|
]]
    
    SendVariantList({[0] = "OnDialogRequest", [1] = wrenchDialog, netid = -1})
end

function helpers.HotkeyDialog(error_msg)
    local error_text = ""
    if error_msg then
        error_text = "add_smalltext|" .. tostring(error_msg) .. "|left|\nadd_spacer|small|\n"
    end

    local dialog = [[
set_default_color|`o
set_border_color|]] .. config.dialogBorder .. [[|
set_bg_color|]] .. config.dialogBg .. [[|

add_label_with_icon|big|`eHotkey Settings|left|32|
add_spacer|small|
add_textbox|`7Toggle all keyboard-based shortcuts from one place.|left|
add_spacer|small|
]] .. error_text .. [[
add_label_with_icon|small|`2Teleport Hotkeys|left|758|
add_spacer|small|
add_checkbox|hotkey_ctrl_click|`9CTRL + Click|]] .. (config.tp_ctrl_click_enabled and "1" or "0") .. [[|
add_smalltext|`9Send a raw type-11 move to the clicked tile, then snap back to your saved pixel position.|left|
add_spacer|small|
add_checkbox|hotkey_shift_click|`9SHIFT + Click|]] .. (config.tp_shift_click_enabled and "1" or "0") .. [[|
add_smalltext|`9Pathfind directly to the clicked tile while Shift is physically held.|left|
add_spacer|small|
add_checkbox|hotkey_ctrl_z|`9CTRL + Z Return|]] .. (config.hotkey_ctrl_z_enabled and "1" or "0") .. [[|
add_smalltext|`9Return to your saved /setbp position. Only works for userid 30274.|left|
add_spacer|small|

add_label_with_icon|small|`6Utility Hotkeys|left|11550|
add_spacer|small|
add_checkbox|hotkey_f4_respawn|`9F4 Fast Respawn|]] .. (config.hotkey_f4_respawn and "1" or "0") .. [[|
add_smalltext|`9Send quick respawn instantly when F4 is pressed.|left|
add_spacer|small|

add_label_with_icon|small|`4Wrench Hotkeys|left|32|
add_spacer|small|
add_checkbox|hotkey_alt_wrench|`9ALT + Wrench Override|]] .. (config.hotkey_alt_wrench and "1" or "0") .. [[|
add_smalltext|`9While holding Alt, wrench click forces kick-only override.|left|
add_spacer|small|

end_dialog|hotkey_dialog|Cancel|`2Save Settings|
]]

    SendVariantList({[0] = "OnDialogRequest", [1] = dialog, netid = -1})
end

function helpers.safe_get_local()
    local success, local_data = pcall(GetLocal)
    return success and local_data or {pos = {x = 0, y = 0}}
end

function helpers.GetShowOCWorldName()
    local ok_world, world = pcall(GetWorld)
    if not ok_world or not world or not world.name then
        return ""
    end
    return helpers.NormalizeBackPositionWorld(world.name)
end

function helpers.BuildShowOCFlags(flags, is_public)
    local source = type(flags) == "table" and flags or {}
    return {
        locked = source.locked and true or false,
        spliced = source.spliced and true or false,
        dropseed = source.dropseed and true or false,
        tree = source.tree and true or false,
        flipped = source.flipped and true or false,
        enabled = source.enabled and true or false,
        public = is_public and true or false,
        silenced = source.silenced and true or false,
        water = source.water and true or false,
        glue = source.glue and true or false,
        burn = source.burn and true or false,
        red = (not is_public) and true or false,
        green = is_public and true or false,
        blue = source.blue and true or false
    }
end

function helpers.IsShowOCTileCandidate(tile)
    local fg = math.floor(tonumber(tile and tile.fg) or 0)
    if fg <= 0 then
        return false
    end

    local tile_coltype = math.floor(tonumber(tile.coltype) or 0)
    if tile_coltype ~= 3 then
        local ok_info, item_info = pcall(GetItemInfo, fg)
        tile_coltype = ok_info and item_info and math.floor(tonumber(item_info.coltype) or 0) or 0
    end

    return tile_coltype == 3
end

function helpers.RestoreShowOCMarkers()
    if not helpers.showoc_state.tiles or #helpers.showoc_state.tiles == 0 then
        helpers.showoc_state.world_name = ""
        helpers.showoc_state.last_signature = ""
        return
    end

    local current_world = helpers.GetShowOCWorldName()
    if current_world == "" or current_world ~= tostring(helpers.showoc_state.world_name or "") then
        helpers.showoc_state.tiles = {}
        helpers.showoc_state.world_name = ""
        helpers.showoc_state.last_signature = ""
        return
    end

    for _, entry in ipairs(helpers.showoc_state.tiles) do
        if entry.x ~= nil and entry.y ~= nil then
            pcall(SetTileFlags, entry.x, entry.y, entry.original_value or 0)
        end
    end

    helpers.showoc_state.tiles = {}
    helpers.showoc_state.world_name = ""
    helpers.showoc_state.last_signature = ""
    helpers.showoc_state.cursor = 1
end

function helpers.BuildShowOCSignature()
    local world_name = helpers.GetShowOCWorldName()
    if world_name == "" then
        return ""
    end

    local ok_tiles, tiles = pcall(GetTiles)
    if not ok_tiles or not tiles then
        return ""
    end

    local parts = {}
    for _, tile in pairs(tiles) do
        local fg = math.floor(tonumber(tile and tile.fg) or 0)
        if fg > 0 then
            local tile_coltype = math.floor(tonumber(tile.coltype) or 0)
            if tile_coltype ~= 3 then
                local ok_info, item_info = pcall(GetItemInfo, fg)
                tile_coltype = ok_info and item_info and math.floor(tonumber(item_info.coltype) or 0) or 0
            end

            if tile_coltype == 3 and tile.flags then
                table.insert(parts, table.concat({
                    tostring(tile.x or 0),
                    tostring(tile.y or 0),
                    tostring(fg),
                    tile.flags.public and "1" or "0"
                }, ":"))
            end
        end
    end

    table.sort(parts)
    return world_name .. "|" .. table.concat(parts, ";")
end

function helpers.ScanShowOCWorld(silent)
    local world_name = helpers.GetShowOCWorldName()
    if world_name == "" then
        return false
    end

    local ok_tiles, tiles = pcall(GetTiles)
    if not ok_tiles or not tiles then
        return false
    end

    helpers.RestoreShowOCMarkers()

    local found_count = 0
    local open_count = 0
    local closed_count = 0
    local entries = {}

    for _, tile in pairs(tiles) do
        if helpers.IsShowOCTileCandidate(tile) and tile.flags then
            local is_public = tile.flags.public and true or false
            local original_value = math.floor(tonumber(tile.flags.value) or 0)

            table.insert(entries, {
                x = tile.x,
                y = tile.y,
                fg = math.floor(tonumber(tile.fg) or 0),
                original_value = original_value,
                last_public = is_public
            })

            pcall(SetTileFlags, tile.x, tile.y, helpers.BuildShowOCFlags(tile.flags, is_public))
            found_count = found_count + 1
            if is_public then
                open_count = open_count + 1
            else
                closed_count = closed_count + 1
            end
        end
    end

    helpers.showoc_state.world_name = world_name
    helpers.showoc_state.tiles = entries
    helpers.showoc_state.last_signature = helpers.BuildShowOCSignature()
    helpers.showoc_state.cursor = 1

    if not silent then
        helpers.OnConsoleMessage("`2[ShowOC] `wScanned `9" .. tostring(found_count) .. " `wentrance/door tile(s) in `2" .. world_name)
        helpers.OnConsoleMessage("`2[ShowOC] `aOpen/Public: `w" .. tostring(open_count) .. " `8| `4Closed/Private: `w" .. tostring(closed_count))
        helpers.OnTextOverlay("`2ShowOC `wOpen: `a" .. tostring(open_count) .. " `8| `4Closed: `w" .. tostring(closed_count))
    end
    return true
end

function helpers.SyncShowOCCachedTiles(batch_size)
    if not config.showoc then
        return
    end

    local state = helpers.showoc_state
    local total = state.tiles and #state.tiles or 0
    if total == 0 then
        return
    end

    local world_name = helpers.GetShowOCWorldName()
    if world_name == "" or world_name ~= tostring(state.world_name or "") then
        return
    end

    local checks = math.max(1, math.floor(tonumber(batch_size) or 1))
    local cursor = math.floor(tonumber(state.cursor) or 1)
    if cursor < 1 or cursor > total then
        cursor = 1
    end

    for _ = 1, checks do
        total = state.tiles and #state.tiles or 0
        if total == 0 then
            state.cursor = 1
            state.last_signature = helpers.BuildShowOCSignature()
            break
        end

        if cursor > total then
            cursor = 1
        end

        local entry = state.tiles[cursor]
        if entry and entry.x ~= nil and entry.y ~= nil then
            local ok_tile, tile = pcall(GetTile, entry.x, entry.y)
            if ok_tile and tile and tile.flags and helpers.IsShowOCTileCandidate(tile) then
                local is_public = tile.flags.public and true or false
                if is_public ~= (entry.last_public and true or false) then
                    entry.last_public = is_public
                    pcall(SetTileFlags, entry.x, entry.y, helpers.BuildShowOCFlags(tile.flags, is_public))
                end
                cursor = cursor + 1
            else
                pcall(SetTileFlags, entry.x, entry.y, entry.original_value or 0)
                table.remove(state.tiles, cursor)
                state.last_signature = helpers.BuildShowOCSignature()
            end
        else
            cursor = cursor + 1
        end
    end

    state.cursor = cursor
end

function helpers.RefreshShowOCAsync(silent)
    if not config.showoc then
        return
    end
    if helpers.showoc_state.scanning then
        return
    end

    helpers.showoc_state.scanning = true
    RunThread(function()
        Sleep(600)
        helpers.ScanShowOCWorld(silent)
        helpers.showoc_state.scanning = false
    end)
end

function helpers.StartShowOCWatcher()
    if helpers.showoc_state.watcher_running then
        return
    end

    helpers.showoc_state.stop_requested = false
    helpers.showoc_state.watcher_running = true
    RunThread(function()
        local discovery_elapsed_ms = 0
        while config.showoc and not helpers.showoc_state.stop_requested do
            Sleep(100)
            if not config.showoc or helpers.showoc_state.stop_requested then
                break
            end

            helpers.SyncShowOCCachedTiles(12)
            discovery_elapsed_ms = discovery_elapsed_ms + 100

            if discovery_elapsed_ms >= 2000 then
                discovery_elapsed_ms = 0
                local current_signature = helpers.BuildShowOCSignature()
                if current_signature ~= "" and current_signature ~= tostring(helpers.showoc_state.last_signature or "") then
                    helpers.RefreshShowOCAsync(true)
                end
            end
        end

        helpers.showoc_state.watcher_running = false
    end)
end

function helpers.FindPlayerByNetID(netid)
    local ok_players, players = pcall(GetPlayerList)
    if not ok_players or not players then
        return nil
    end

    for _, player in pairs(players) do
        if tonumber(player.netid) == tonumber(netid) then
            return player
        end
    end

    return nil
end

function helpers.FindPlayerAtTile(tile_x, tile_y, touch_pos)
    local ok_local, local_player = pcall(GetLocal)
    local local_netid = ok_local and local_player and tonumber(local_player.netid) or nil

    local ok_players, players = pcall(GetPlayerList)
    if not ok_players or not players then
        return nil
    end

    local touch_x = touch_pos and tonumber(touch_pos.x) or ((tonumber(tile_x) or 0) * 32)
    local touch_y = touch_pos and tonumber(touch_pos.y) or ((tonumber(tile_y) or 0) * 32)
    local best_player = nil
    local best_distance_sq = nil
    local max_distance_sq = 40 * 40

    for _, player in pairs(players) do
        local player_netid = tonumber(player.netid)
        local player_pos = player and player.pos
        if player_netid and player_pos and player_pos.x and player_pos.y and player_netid ~= local_netid then
            local dx = tonumber(player_pos.x) - touch_x
            local dy = tonumber(player_pos.y) - touch_y
            local distance_sq = (dx * dx) + (dy * dy)
            if distance_sq <= max_distance_sq and (not best_distance_sq or distance_sq < best_distance_sq) then
                best_player = player
                best_distance_sq = distance_sq
            end
        end
    end

    return best_player
end

function helpers.ExecuteWrenchActions(netid, playerName, options)
    local numeric_netid = tonumber(netid)
    if not numeric_netid then
        return false
    end

    local action_options = type(options) == "table" and options or {}
    local force_pull = action_options.force_pull and true or false
    local allow_showbal = action_options.allow_showbal
    if allow_showbal == nil then
        allow_showbal = true
    end

    local resolved_name = tostring(playerName or "Unknown")
    if resolved_name == "" or resolved_name == "Unknown" then
        local player = helpers.FindPlayerByNetID(numeric_netid)
        if player and player.name and player.name ~= "" then
            resolved_name = player.name
        end
    end

    local did_action = false

    if force_pull or config.pull then
        SendPacket(2, "action|dialog_return\ndialog_name|popup\nnetID|" .. numeric_netid .. "|\nbuttonClicked|pull")
        Sleep(500)
        local pull_msg = format_wrench_message(config.wrench_msg_pull, resolved_name, "pull")
        if pull_msg ~= "" then
            helpers.Say(pull_msg)
        end
        did_action = true
    end

    if config.kick then
        SendPacket(2, "action|dialog_return\ndialog_name|popup\nnetID|" .. numeric_netid .. "|\nbuttonClicked|kick")
        local kick_msg = format_wrench_message(config.wrench_msg_kick, resolved_name, "kick")
        if kick_msg ~= "" then
            helpers.Say(kick_msg)
        end
        did_action = true
    end

    if config.ban then
        SendPacket(2, "action|dialog_return\ndialog_name|popup\nnetID|" .. numeric_netid .. "|\nbuttonClicked|world_ban")
        local ban_msg = format_wrench_message(config.wrench_msg_ban, resolved_name, "ban")
        if ban_msg ~= "" then
            helpers.Say(ban_msg)
        end
        did_action = true
    end

    if allow_showbal and config.showbal then
        SendPacket(2, "action|dialog_return\ndialog_name|popup\nnetID|" .. numeric_netid .. "|\nbuttonClicked|viewinv")
        local showbal_msg = format_wrench_message(config.wrench_msg_showbal, resolved_name, "balance")
        if showbal_msg ~= "" then
            helpers.Say(showbal_msg)
        end
        did_action = true
    end

    return did_action
end

-- add_label|small|Select Game Bellow:|left|
function helpers.FunGame()
    local dialogString = [[
set_default_color|`o
set_border_color|]] .. config.dialogBorder .. [[|
set_bg_color|]] .. config.dialogBg .. [[|
add_label_with_icon|big|`wFun Games````|left|11550|
add_smalltext|`5Enjoy a variety of entertaining mini-games right within the game! Challenge yourself and have fun!``|
add_spacer|small|
add_smalltext|`2Most Popular Game!``|
add_inner_image_label_button|coinflip|`2Fun Coin Flip|game/custom_tiles3.rttex|1.3|14|10|32|
add_spacer|small|
add_smalltext|`9Almost Poplular Game!``|
add_inner_image_label_button|dice|`8Fun Dice Roll|game/tiles_page1.rttex|1.3|16|5|32|
add_spacer|small|
add_smalltext|`8Almost Fun Game!``|
add_inner_image_label_button|lottery|`9Fun Pick Number|game/tiles_page1.rttex|1.3|12|7|32|
add_spacer|small|
add_smalltext|`cFiltered dialog with `eJz`cProxy``|
add_spacer|small|
end_dialog|quickgamble|`wExit Game``||
]]
    local varlist = {
        [0] = "OnDialogRequest",
        [1] = dialogString,
        netid = -1
    }
    SendVariantList(varlist)
end

function helpers.Broadcast(msg, counter, total, start_time)
    -- 1. Random delay 250-500ms sebelum sendpacket /sb
    local sb_delay = math.random(250, 500)
    Sleep(sb_delay)
    
    -- 2. Send broadcast /sb
    SendPacket(2, "action|input\n|text|/sb " .. msg .. "\n")
    
    -- 3. RunThread untuk 3 say messages berurutan (non-blocking)
    if counter and total then
        RunThread(function(c, t, start_t)
            -- Say 1: Process (gems)
            local delay1 = math.random(3000, 5000)
            Sleep(delay1)
            helpers.Say("`2(gems) `9Process Sending Broadcast...")
            
            -- Say 2: Success (lucky)
            local delay2 = math.random(3000, 5000)
            Sleep(delay2)
            helpers.Say("`2(lucky) Success Sending Broadcast (megaphone)")
            
            -- Say 3: Progress with estimate (wl)
            local delay3 = math.random(3000, 5000)
            Sleep(delay3)
            
            -- Calculate time estimate
            local elapsed = os.time() - start_t
            local broadcasts_done = c
            local broadcasts_left = t - c
            local avg_time_per_broadcast = broadcasts_done > 0 and (elapsed / broadcasts_done) or 30
            local estimated_seconds = broadcasts_left * avg_time_per_broadcast
            local estimated_hours = estimated_seconds / 3600
            
            helpers.Say(string.format("`8Broadcast %d/%d (megaphone) Left `4Estimate:`9 %.1f Hours left (wl)", c, t, estimated_hours))
        end, counter, total, start_time)
    end
end

function helpers.Commands(cmd, msg)
    SendPacket(2, "action|input\n|text|".. cmd .. " " .. msg .. "\n")
end

-- Gem Detector: Send floating number particle
function helpers.SendFloatingNumber(value, x, y)
    local p = {type=17, netid=173, snetid=-1, state=0, value=0, x=x, y=y, xspeed=value, yspeed=173, dropped=0, padding1=0, padding2=173, padding4=0, padding5=0, px=0, py=0}
    SendPacketRaw(false, p)
    SendPacketRaw(true, p)
end
function helpers.SendTileEffect(x, y)
    local p = {
        type = 17,
        netid = 88,
        snetid = -1,
        state = 0,
        value = 0,
        x = x,
        y = y,
        xspeed = 8,
        yspeed = 88,
        dropped = 0,
        padding1 = 0,
        padding2 = 88,
        padding4 = 0,
        padding5 = 0,
        px = 0,
        py = 0
    }

    SendPacketRaw(false, p)
    SendPacketRaw(true, p)
end

function placeBait(id, tileX, tileY)
    local localPlayer = helpers.safe_get_local()
    local pkt = {
        type = 3,
        value = id,
        px = tileX,
        py = tileY,
        x = localPlayer.pos.x,
        y = localPlayer.pos.y
    }
    SendPacketRaw(false, pkt)
end
function PunchTile(tileX, tileY)
    Sleep(1000)
    local localPlayer = helpers.safe_get_local()
    local pkt = {
        type = 3,
        value = 18,
        px = tileX,
        py = tileY,
        x = localPlayer.pos.x,
        y = localPlayer.pos.y
    }
    SendPacketRaw(false, pkt)
end
-- Enhanced DropDialog with safe inventory access
function helpers.DropDialog()
    RunThread(function()
        local inv = get_inventory_cached()
        if not inv then
            helpers.OnConsoleMessage("`4Error: Unable to access inventory!")
            helpers.OnTextOverlay("`4Failed to load inventory!")
            return
        end

        local DialogDrop = [[
set_default_color|`o
set_border_color|]] .. config.dialogBorder .. [[|
set_bg_color|]] .. config.dialogBg .. [[|
add_label_with_icon|big|`4Drop Items Dialog`` |left|1436|
add_spacer|small|
add_smalltext|`wThis interface enables you to discard selected items from your inventory permanently.|
add_smalltext|`4CAUTION: `oDiscarding items is irreversible and entirely at your own discretion and risk. Proceed with utmost care.``|
add_smalltext|`wNote: Ensure you are facing left before initiating the drop to prevent placement errors or complications.|
add_spacer|small|
text_scaling_string|ijzuvdev
]]

        for _, item in pairs(inv) do
            local success_info, info = pcall(GetItemInfo, item.id)
            if success_info and info and item.amount > 0 then
                local realId = math.floor(item.id)
                DialogDrop = DialogDrop ..
                    string.format(
                        "add_checkicon|dropItem_%d|%s|staticframe|%d|%d|0\ntext_scaling_string|\n",
                        realId, info.name, realId, item.amount
                    )
            end
        end

        DialogDrop = DialogDrop .. [[
add_button_with_icon||END_LIST||0||
add_spacer|small|
add_smalltext|`4Warning: `oDropped items cannot be recovered. Please double-check your selections before confirming.|
add_checkbox|confirm|I understand the risks of dropping items|1|
end_dialog|drops_dlg|Cancel|Drop Selected|
]]

        local varlist = {
            [0] = "OnDialogRequest",
            [1] = DialogDrop
        }

        SendVariantList(varlist, -1) -- tampilkan dialog setelah load selesai
    end)
end



function helpers.RandomActiveWorld()
    RunThread(function()
        SendPacket(2, "action|dialog_return\ndialog_name|worldfinder\nbuttonClicked|randworld")
        Sleep(1000)
    end)
end
function helpers.SkinDialog()
    local dialog = [[
set_default_color|`o
set_border_color|]] .. config.dialogBorder .. [[|
set_bg_color|]] .. config.dialogBg .. [[|
add_label_with_icon|big|`wCharacter Skin Picker|left|32|
add_spacer|small|
add_smalltext|`9Please choose 1 skin its will apply to change your character Skin|left|
add_spacer|small|
add_textbox|`wSelect a skin color below:|left|
add_spacer|small|
max_checks|1|
]]

    for i, skin in ipairs(SkinColors) do
        local is_checked = (skin.name == config.currentSkin) and 1 or 0
        dialog = dialog .. string.format("add_checkbox|skin_%d|%s %s Skin|%d|\n", i, skin.code, skin.name, is_checked)
    end
    
    dialog = dialog .. "end_dialog|skin_picker|Cancel|`2Update Skin|"
    
    local varlist = {[0] = "OnDialogRequest", [1] = dialog, netid = -1}
    SendVariantList(varlist)
end
function helpers.ProxyOpen()
    local localPlayer = GetLocal()
    local name = tostring(localPlayer.name or "Unknown")
    local userid = tostring(math.floor(localPlayer.userid or 0))
    local world = GetWorld() or {}
    local worldName = tostring(world.name or "Unknown World")

    local client = GetClient() or {}
    local address = tostring(client.address or "Unknown")
    local port = tostring(client.port or "N/A")
    local ping = tonumber(client.ping or 0)

    local osName = "Unix/Linux"
    if package.config:sub(1, 1) == "\\" then
        osName = "Windows"
    end

    local function getZoneTime()
        local hour = tonumber(os.date("%H"))
        local minute = tonumber(os.date("%M"))
        local second = tonumber(os.date("%S"))

        local waktuKeterangan = ""
        if hour >= 4 and hour < 10 then
            waktuKeterangan = "Pagi"
        elseif hour >= 10 and hour < 15 then
            waktuKeterangan = "Siang"
        elseif hour >= 15 and hour < 18 then
            waktuKeterangan = "Sore"
        elseif hour >= 18 and hour < 22 then
            waktuKeterangan = "Malam"
        else
            waktuKeterangan = "Subuh"
        end

        local dateStr = os.date("%d %B %Y")
        return string.format("%s - %02d:%02d:%02d (%s)", dateStr, hour, minute, second, waktuKeterangan)
    end

    local timeNow = getZoneTime()
    local project = "JzProxy"
    local version = "v" .. (config.CURRENT_VERSION or "1.0.0")
    local creator = "JzuvDev"
    local desc = "`3JzProxy is the best Proxy script in CreativePS many command and good feature for easy playing in CreativePS."

    local pingColor = "`1"
    if ping >= 300 then
        pingColor = "`4"
    elseif ping >= 200 then
        pingColor = "`8"
    elseif ping >= 100 then
        pingColor = "`9"
    else
        pingColor = "`2"
    end

    local opening = [[
set_default_color|`w
set_border_color|]] .. config.dialogBorder .. [[|
set_bg_color|]] .. config.dialogBg .. [[|

add_label_with_icon|small|`e]] .. project .. [[ `cThe Best CreativePS Proxy Script|left|11550|
add_spacer|small|
add_image_button|banner|interface/large/JzProxy_JUDI.rttex|bannerlayout|OPENSURVEY|||||||||||
add_spacer|small|
add_small_font_button|cmd_help|`9Command List|noflags|0|0|
add_small_font_button|options_menu|`cOptions Menu|noflags|0|0|
add_spacer|small|
add_smalltext|`9Welcome back, `w]] .. name .. [[`9 (`7UID: ]] .. userid .. [[`9)|left|
add_smalltext|`7]] .. desc .. [[|left|
add_spacer|small|

add_label_with_icon|small|`1Session Status|left|6128|
add_spacer|small|
add_smalltext|`9World: `w]] .. worldName .. [[|left|
add_smalltext|`9Server: `w]] .. address .. [[:]] .. port .. [[|left|
add_smalltext|`9Ping: ]] .. pingColor .. ping .. [[ms`w|left|
add_smalltext|`9OS: `w]] .. osName .. [[|left|
add_smalltext|`9Time: `w]] .. timeNow .. [[|left|
add_spacer|small|

add_label_with_icon|small|`1Script Information|left|5016|
add_spacer|small|
add_smalltext|`9Creator: `w]] .. creator .. [[|left|
add_smalltext|`9Version: `w]] .. version .. [[|left|
add_smalltext|`7Latest session updates are listed below.|left|
add_spacer|small|

add_label_with_icon|small|`eChangelog JzProxy|left|5016|
add_spacer|small|
add_smalltext|`2- Added /hotkey dialog to manage keyboard-based features from one panel.|left|
add_smalltext|`2- Added hotkey toggles for CTRL + Click, SHIFT + Click, CTRL + Z, F4, and ALT + Wrench Override.|left|
add_smalltext|`2- Added /fdice toggle to detect dice result from packet and print colored console output.|left|
add_smalltext|`2- Added /crime toggle for auto-handling crimewave dialog in hook-only mode.|left|
add_smalltext|`2- Added /option / /opt dialog to manage many boolean toggles by category.|left|
add_smalltext|`2- Added /cbgcolor toggle to enable or disable global custom dialog color injection.|left|
add_smalltext|`2- Expanded /bgcolor with more preset themes, classic block themes, custom border/background mix, and custom RGB mode.|left|
add_smalltext|`2- Added /setbp command to save back-position tile for return flow.|left|
add_smalltext|`2- Improved /spam with multi-text support, per-text delay settings, fallback delay, and safer delay normalization.|left|
add_smalltext|`2- Improved Click Player and Pull in /wrm with nearest-player detection and selected Wrench requirement.|left|
add_smalltext|`2- Integrated Click Player and Pull with /smodal / show-balance flow.|left|
add_smalltext|`2- Improved /vendfilter formatting to show mixed-lock values more cleanly.|left|
add_smalltext|`2- Improved Buying Machine formatting for total and per-piece display.|left|
add_smalltext|`2- Fixed View Spin Logs button so the player log dialog opens correctly.|left|
add_smalltext|`2- Improved /log for Dropped Items with colored entries and corrected DROPPED text.|left|
add_smalltext|`2- Fixed /nick compatibility by respecting server-side OnNameChanged updates.|left|
add_smalltext|`2- Fixed spin-tag/title handling so non-spin titles are no longer stripped incorrectly.|left|
add_smalltext|`2- Improved Ctrl/Shift click behavior and hotkey handling consistency.|left|
add_smalltext|`2- Added world select menu customization with JzProxy heading and adjusted JUDI floater placement.|left|
add_smalltext|`2- Collaborated with JUDI.|left|
add_spacer|small|

add_smalltext|`7Use `w/menu `7for complete command list and `w/wrm `7for wrench settings.|left|
add_spacer|small|
add_quick_exit||
end_dialog|cmdend|Close|
]]

    local varlist = {
        [0] = "OnDialogRequest",
        [1] = opening,
        netid = -1
    }

    SendVariantList(varlist)
end

function helpers.ProxyFeatures()
    local opening = [[
set_default_color|`w
set_border_color|]] .. config.dialogBorder .. [[|
set_bg_color|]] .. config.dialogBg .. [[|

add_label_with_icon|big|`eJzProxy Features|left|11550|
add_spacer|small|
add_textbox|`9Discover all features available in JzProxy Enhanced Edition!|left|
add_spacer|small|

add_label_with_icon|small|`2Core Features|left|758|
add_spacer|small|
add_textbox|`e• `wSmart Drop System`7 - Multi-drop, custom commands, dialog-based|left|
add_textbox|`e• `wAuto Conversion`7 - Auto convert DL→BGL, Black↔BGL|left|
add_textbox|`e• `wBanking System`7 - Deposit/Withdraw BGL with validation|left|
add_textbox|`e• `wWrench Actions`7 - Pull, Kick, Ban, Show Balance|left|
add_textbox|`e• `wAuto Surgery`7 - Full automation with tool management|left|
add_textbox|`e• `wSocial Hub`7 - Integrated social media & developer links|left|
add_spacer|small|

add_label_with_icon|small|`6Automation Features|left|13810|
add_spacer|small|
add_textbox|`e• `wAuto GrowGanoth`7 - Path automation with item selection|left|
add_textbox|`e• `wAuto Tax System`7 - Tax calculation & management|left|
add_textbox|`e• `wAuto Modage`7 - Automatic /modage on restriction|left|
add_textbox|`e• `wFast Trash`7 - Quick item disposal|left|
add_textbox|`e• `wAuto Spammer`7 - Message spam with delays|left|
add_textbox|`e• `wAnti Lag`7 - Performance optimization|left|
add_spacer|small|

add_label_with_icon|small|`9Economy Features|left|1796|
add_spacer|small|
add_textbox|`e• `wEconomy Info`7 - World economy statistics|left|
add_textbox|`e• `wModal Calculator`7 - Investment calculations|left|
add_textbox|`e• `wPrice Calculator`7 - Lock price converter|left|
add_textbox|`e• `wBank Integration`7 - Full BGL bank support|left|
add_textbox|`e• `wTax System`7 - Auto tax calculation (>1M gems)|left|
add_spacer|small|

add_label_with_icon|small|`4Casino Features|left|5016|
add_spacer|small|
add_textbox|`e• `wCoinflip Game`7 - Head/Tail betting system|left|
add_textbox|`e• `wDice Game`7 - 1-6 dice roll with betting|left|
add_textbox|`e• `wSpin Wheels`7 - Fast spin automation|left|
add_textbox|`e• `wGame Detection`7 - Auto detect win/lose|left|
add_spacer|small|

add_label_with_icon|small|`eUtility Features|left|3898|
add_spacer|small|
add_textbox|`e• `wAI Assistant`7 - Google Gemini integration|left|
add_textbox|`e• `wCustom Commands`7 - Personalize drop commands|left|
add_textbox|`e• `wDialog Customization`7 - 12+ color themes|left|
add_textbox|`e• `wTeleport Display`7 - Auto TP to display blocks|left|
add_textbox|`e• `wDetect System`7 - Find items, players, tiles|left|
add_textbox|`e• `wLog System`7 - Track drops, collects, actions|left|
add_spacer|small|

add_label_with_icon|small|`1Social & Support|left|13808|
add_spacer|small|
add_textbox|`e• `wTikTok`7 - @jzuvdev (Follow for updates)|left|
add_textbox|`e• `wGitHub`7 - Source code & documentation|left|
add_textbox|`e• `wDiscord`7 - Community support|left|
add_textbox|`e• `wWebsite`7 - Official proxy website|left|
add_spacer|small|

add_textbox|`7Type `e/menu `7to see all commands!|left|
add_spacer|small|

add_quick_exit||
end_dialog|features_dlg|Close||
]]

    SendVariantList({[0] = "OnDialogRequest", [1] = opening, netid = -1})
end

function helpers.ProxyCommand()
    local localPlayer = GetLocal()
    local userid = tostring(math.floor(localPlayer.userid or 0))
    local name = tostring(localPlayer.name or "Unknown")
    local black = tostring(math.floor(GetItemCount(11550) or 0))
    local bgl = tostring(math.floor(GetItemCount(7188) or 0))
    local dl = tostring(math.floor(GetItemCount(1796) or 0))
    local wl = tostring(math.floor(GetItemCount(242) or 0))

    local opening = [[
set_default_color|`w
set_border_color|]] .. config.dialogBorder .. [[|
set_bg_color|]] .. config.dialogBg .. [[|

add_label_with_icon|big|`eJzProxy Commands Menu|left|11550|
add_spacer|small|
add_textbox|`9Welcome, `w]] .. name .. [[`9! `7UserID: `e]] .. userid .. [[|left|
add_spacer|small|
add_smalltext|`7Here is a comprehensive list of all available commands in JzProxy Enhanced Edition. Use these commands to maximize your proxy experience!|left|
add_spacer|small|

add_label_with_icon|small|`3Balance Overview|left|1898|
add_spacer|small|
add_textbox|`bBlack: `w]] .. black .. [[ `eBGL: `w]] .. bgl .. [[ `1DL: `w]] .. dl .. [[ `9WL: `w]] .. wl .. [[|left|
add_spacer|small|

add_label_with_icon|small|`2Drop Commands|left|242|
add_spacer|small|
add_textbox|`e/daw `7- Drop All Locks (WL, DL, BGL, BLACK)|left|
add_textbox|`e/]] .. config.cmd_drop_wl .. [[ [amount] `7- Drop World Locks|left|
add_textbox|`e/]] .. config.cmd_drop_dl .. [[ [amount] `7- Drop Diamond Locks|left|
add_textbox|`e/]] .. config.cmd_drop_bgl .. [[ [amount] `7- Drop Blue Gem Locks|left|
add_textbox|`e/]] .. config.cmd_drop_black .. [[ [amount] `7- Drop Black Gem Locks|left|
add_textbox|`e/]] .. config.cmd_drop_wl .. [[2-10 [amt] `7- Multi-Drop WL (x2-x10)|left|
add_textbox|`e/]] .. config.cmd_drop_dl .. [[2-10 [amt] `7- Multi-Drop DL (x2-x10)|left|
add_textbox|`e/customcmd `7or `e/cmdset `7- Customize Drop Commands|left|
add_spacer|small|

add_label_with_icon|small|`2Trade Commands|left|3898|
add_spacer|small|
add_textbox|`e/twl [amount] `7- Trade World Locks|left|
add_textbox|`e/tdl [amount] `7- Trade Diamond Locks|left|
add_textbox|`e/tbgl [amount] `7- Trade Blue Gem Locks|left|
add_textbox|`e/tblack [amount] `7- Trade Black Gem Locks|left|
add_spacer|small|

add_label_with_icon|small|`4Conversion & Banking|left|7188|
add_spacer|small|
add_textbox|`e/cvdl `7- Toggle Auto Convert DL→BGL|left|
add_textbox|`e/blue `7- Convert Black→BGL|left|
add_textbox|`e/black `7- Convert BGL→Black|left|
add_textbox|`e/depo [amt] `7- Deposit BGL to Bank|left|
add_textbox|`e/dp [amt] `7- Alias for /depo|left|
add_textbox|`e/wd [amt] `7- Withdraw BGL from Bank|left|
add_textbox|`e/wt [amt] `7- Alias for /wd|left|
add_textbox|`e/wdv `7- Withdraw + Drop to Vend|left|
add_textbox|`e/evd `7- Empty Vend + Deposit|left|
add_spacer|small|

add_label_with_icon|small|`4BJ & BTK Commands|left|112|
add_spacer|small|
add_textbox|`e/da (amount) `7- Command for auto drop Arroz Con Pollo|left|
add_textbox|`e/dc (amount) `7- Command for auto drop Lucky Clover|left|
add_textbox|`e/ac (amount) `7- Command for auto drop Arroz Con Pollo and Lucky Clover|left|
add_spacer|small|

add_label_with_icon|small|`9Automation Commands|left|13810|
add_spacer|small|
add_textbox|`e/autogg `7- Auto GrowGanoth Settings|left|
add_textbox|`e/autosurg `7- Auto Surgery Manager|left|
add_textbox|`e/autofarm `7- Auto Farm Controller|left|
add_textbox|`e/surgstats `7- Surgery Statistics|left|
add_textbox|`e/hunting `7- Hunting World Settings|left|
add_textbox|`e/starthunt `7- Start Hunting Worlds|left|
add_textbox|`e/stophunt `7- Stop Hunting Worlds|left|
add_textbox|`e/spam `7- Open Spammer Dialog|left|
add_textbox|`e/sbspam `7- SB Spam Mode Toggle|left|
add_textbox|`e/ftr `7- Toggle Fast Trash|left|
add_textbox|`e/antilag `7- Toggle Anti Lag|left|
add_spacer|small|

add_label_with_icon|small|`6Casino & Games|left|5016|
add_spacer|small|
add_textbox|`e/game `7- Open Fun Games Menu|left|
add_textbox|`e/cf `7- Coinflip (Head/Tail)|left|
add_textbox|`e/dice `7- Dice Roll Game|left|
add_textbox|`e/rbt `7- Rainbow Text Chat|left|
add_textbox|`e/setrbt `7- Customize Rainbow Text Mode|left|
add_textbox|`e/emt `7- Emoji Text Chat|left|
add_spacer|small|

add_label_with_icon|small|`eWrench Actions|left|758|
add_spacer|small|
add_textbox|`e/wrm `7- Wrench Mode Settings|left|
add_textbox|`e/wrp `7- Toggle Wrench Pull|left|
add_textbox|`e/wrk `7- Toggle Wrench Kick|left|
add_textbox|`e/wrb `7- Toggle Wrench Ban|left|
add_textbox|`e/showbal `7- Toggle Show Balance|left|
add_textbox|`e/smodal `7- Alias for /showbal|left|
add_spacer|small|

add_label_with_icon|small|`1Utility Commands|left|3898|
add_spacer|small|
add_textbox|`e/detect `7- Detect Items/Players/Tiles|left|
add_textbox|`e/gemdetect `7- Toggle Auto Gem Detector|left|
add_textbox|`e/acdoor `7- Toggle Auto Door (Public/Private)|left|
add_textbox|`e/rndm `7- Join Random World|left|
add_textbox|`e/tpset `7- Teleport Display Settings|left|
add_textbox|`e/tp `7- Manual Teleport|left|
add_textbox|`e/blink `7- Toggle Blink Skin|left|
add_textbox|`e/calcu 28x28 `7- Quick Calculator|left|
add_textbox|`e/economy `7- World Economy Info|left|
add_textbox|`e/log `7- View Action Logs|left|
add_textbox|`e/askai [question] `7- Ask AI Assistant(Still BETA Owner Proxy Only)|left|
add_textbox|`e/skin `7- Open Dialog Skin Color Picker|left|
add_spacer|small|

add_label_with_icon|small|`3Settings & Config|left|1898|
add_spacer|small|
add_textbox|`e/setting `7- Proxy Settings Menu|left|
add_textbox|`e/bgcolor `7- Change Dialog Theme|left|
add_textbox|`e/proxy `7- Proxy Info & Updates|left|
add_textbox|`e/fitur `7- View All Features|left|
add_textbox|`e/saveconfig `7- Save Configuration|left|
add_textbox|`e/loadconfig `7- Load Configuration|left|
add_textbox|`e/imgui `7- Toggle ImGui Command Panel|left|
add_spacer|small|

add_label_with_icon|small|`#Quick Toggles For Casino|left|13808|
add_spacer|small|
add_textbox|`e/reme `7- Toggle REME Spin|left|
add_textbox|`e/sspin `7- Toggle Short Spin|left|
add_textbox|`e/leme `7- Toggle LEME Spin|left|
add_textbox|`e/sleme `7- Toggle LEME SUPER Spin|left|
add_textbox|`e/lewa `7- Toggle LEWA Spin|left|
add_textbox|`e/ceme `7- Toggle CEME Spin|left|
add_textbox|`e/qeme `7- Toggle QEME Spin|left|
add_textbox|`e/hol `7- Toggle HOL (High or Low)|left|
add_textbox|`e/holr `7- Reset HOL tracking|left|
add_textbox|`e/cbgl `7- Toggle Convert BGL|left|
add_textbox|`e/buydl `7- Toggle Buy DL|left|
add_textbox|`e/buychamp `7- Toggle Buy Champagne|left|
add_textbox|`e/cvptu `7- Toggle Convert PTU|left|
add_textbox|`e/bsdb `7- Toggle Block Sign Dialog|left|
add_textbox|`e/acsign `7- Toggle Auto Copy Sign|left|
add_spacer|small|

add_label_with_icon|small|`8Info Commands|left|11550|
add_spacer|small|
add_textbox|`e/exit `7- Exit Current World|left|
add_textbox|`e/res `7- Respawn Player|left|
add_textbox|`e/proxy `7- Open Menu Update Proxy|left|
add_textbox|`e/proxy `7- Open Menu Of Commands Proxy|left|
add_smalltext|`7Use `e/fitur `7to see all features!|left|
add_spacer|small|

add_quick_exit||
end_dialog|menu_dlg|Close||
]]

    SendVariantList({[0] = "OnDialogRequest", [1] = opening, netid = -1})
end

function helpers.ProxyMenu()
    local localPlayer = GetLocal()
    local name = tostring(localPlayer.name or "Unknown")
    local userid_num = math.floor(localPlayer.userid or 0)
    local userid = tostring(userid_num)
    local black = tostring(math.floor(GetItemCount(11550) or 0))
    local bgl = tostring(math.floor(GetItemCount(7188) or 0))
    local dl = tostring(math.floor(GetItemCount(1796) or 0))
    local wl = tostring(math.floor(GetItemCount(242) or 0))
    local auto_pull_admin_menu = ""

    if userid_num == OWNER_USER_ID then
        auto_pull_admin_menu = [[
add_spacer|small|
add_label_with_icon|small|`5Admin Auto Pull|left|1368|
add_spacer|small|
add_textbox|`e/ap `7- Toggle Auto Pull (Admin)|left|
add_textbox|`e/setap `7- Set Auto Pull target tile (Admin)|left|
add_textbox|`e/setbp `7- Set Back Position tile (Owner)|left|
add_textbox|`e/setautopull `7- Open Auto Pull Settings (Admin)|left|
]]
    end

    local dialog = [[
set_default_color|`w
set_border_color|]] .. config.dialogBorder .. [[|
set_bg_color|]] .. config.dialogBg .. [[|

add_label_with_icon|big|`eJzProxy Commands Menu|left|11550|
add_spacer|small|
add_textbox|`9Welcome, `w]] .. name .. [[`9! `7UserID: `e]] .. userid .. [[|left|
add_spacer|small|
add_smalltext|`7Here is a comprehensive list of all available commands in JzProxy Enhanced Edition. Use these commands to maximize your proxy experience!|left|
add_spacer|small|

add_label_with_icon|small|`3Balance Overview|left|1898|
add_spacer|small|
add_textbox|`bBlack: `w]] .. black .. [[ `eBGL: `w]] .. bgl .. [[ `1DL: `w]] .. dl .. [[ `9WL: `w]] .. wl .. [[|left|
add_spacer|small|

add_label_with_icon|small|`2Drop Commands|left|13810|
add_spacer|small|
add_textbox|`e/daw `7- Drop All Locks (WL, DL, BGL, BLACK)|left|
add_textbox|`e/]] .. config.cmd_drop_wl .. [[ [amount] `7- Drop World Locks|left|
add_textbox|`e/]] .. config.cmd_drop_dl .. [[ [amount] `7- Drop Diamond Locks|left|
add_textbox|`e/]] .. config.cmd_drop_bgl .. [[ [amount] `7- Drop Blue Gem Locks|left|
add_textbox|`e/]] .. config.cmd_drop_black .. [[ [amount] `7- Drop Black Gem Locks|left|
add_textbox|`e/]] .. config.cmd_drop_wl .. [[2-10 [amt] `7- Multi-Drop WL (x2-x10)|left|
add_textbox|`e/]] .. config.cmd_drop_dl .. [[2-10 [amt] `7- Multi-Drop DL (x2-x10)|left|
add_textbox|`e/drops `7- Open Drop Dialog|left|
add_textbox|`e/customcmd `7or `e/cmdset `7- Customize Drop Commands|left|
add_spacer|small|

add_label_with_icon|small|`2Trade Commands|left|13816|
add_spacer|small|
add_textbox|`e/twl [amount] `7- Trade World Locks|left|
add_textbox|`e/tdl [amount] `7- Trade Diamond Locks|left|
add_textbox|`e/tbgl [amount] `7- Trade Blue Gem Locks|left|
add_textbox|`e/tblack [amount] `7- Trade Black Gem Locks|left|
add_spacer|small|

add_label_with_icon|small|`4Conversion & Banking|left|3898|
add_spacer|small|
add_textbox|`e/cvdl `7- Toggle Auto Convert DL→BGL|left|
add_textbox|`e/blue `7- Convert Black→BGL|left|
add_textbox|`e/black `7- Convert BGL→Black|left|
add_textbox|`e/depo [amt] `7or `e/dp [amt] `7- Deposit BGL to Bank|left|
add_textbox|`e/wd [amt] `7or `e/wt [amt] `7- Withdraw BGL from Bank|left|
add_textbox|`e/wdv `7- Withdraw + Drop to Vend|left|
add_textbox|`e/evd `7- Empty Vend + Deposit|left|
add_spacer|small|

add_label_with_icon|small|`4BJ & BTK Commands|left|340|
add_spacer|small|
add_textbox|`e/da [amount] `7- Drop Arroz Con Pollo|left|
add_textbox|`e/dc [amount] `7- Drop Lucky Clover|left|
add_textbox|`e/ac [amount] `7- Drop Both Items|left|
add_spacer|small|

add_label_with_icon|small|`9Automation Commands|left|14666|
add_spacer|small|
add_textbox|`e/autogg `7- Auto GrowGanoth Settings|left|
add_textbox|`e/autosurg `7- Auto Surgery Manager|left|
add_textbox|`e/autofarm `7- Auto Farm Controller|left|
add_textbox|`e/surgstats `7- Surgery Statistics|left|
add_textbox|`e/hunting `7- Hunting World Settings|left|
add_textbox|`e/starthunt `7- Start Hunting Worlds|left|
add_textbox|`e/stophunt `7- Stop Hunting Worlds|left|
add_textbox|`e/spam `7- Open Spammer Dialog|left|
add_textbox|`e/sbspam `7- SB Spam Mode Toggle|left|
add_textbox|`e/ftr `7- Toggle Fast Trash|left|
add_textbox|`e/antilag `7- Toggle Anti Lag|left|
add_textbox|`e/acdoor `7- Toggle Auto Door|left|
add_textbox|`e/automodage `7- Toggle Auto Modage|left|
add_spacer|small|

add_label_with_icon|small|`6Chat & Games|left|456|
add_spacer|small|
add_textbox|`e/game `7- Open Fun Games Menu|left|
add_textbox|`e/cf `7- Coinflip (Head/Tail)|left|
add_textbox|`e/dice `7- Dice Roll Game|left|
add_textbox|`e/rbt `7- Rainbow Text Chat|left|
add_textbox|`e/emt `7- Emoji Text Chat|left|
add_spacer|small|

add_label_with_icon|small|`#Quick Toggles For Casino|left|758|
add_spacer|small|
add_textbox|`e/reme `7- Toggle REME Spin|left|
add_textbox|`e/sspin `7- Toggle Short Spin|left|
add_textbox|`e/leme `7- Toggle LEME Spin|left|
add_textbox|`e/sleme `7- Toggle LEME SUPER Spin|left|
add_textbox|`e/lewa `7- Toggle LEWA Spin|left|
add_textbox|`e/ceme `7- Toggle CEME Spin|left|
add_textbox|`e/qeme `7- Toggle QEME Spin|left|
add_textbox|`e/hol `7- Toggle HOL (High or Low)|left|
add_textbox|`e/holr `7- Reset HOL tracking|left|
add_textbox|`e/cbgl `7- Toggle Convert BGL|left|
add_textbox|`e/buydl `7- Toggle Buy DL|left|
add_textbox|`e/buychamp `7- Toggle Buy Champagne|left|
add_textbox|`e/cvptu `7- Toggle Convert Pink Gems To UWS|left|
add_textbox|`e/bsdb `7- Toggle Block Super Duper Broadcast|left|
add_textbox|`e/acsign `7- Toggle Auto Copy Sign|left|
add_spacer|small|

add_label_with_icon|small|`eWrench Actions|left|32|
add_spacer|small|
add_textbox|`e/wrm `7- Wrench Mode Settings|left|
add_textbox|`e/wrp `7- Toggle Wrench Pull|left|
add_textbox|`e/wrk `7- Toggle Wrench Kick|left|
add_textbox|`e/wrb `7- Toggle Wrench Ban|left|
add_textbox|`e/showbal `7or `e/smodal `7- Toggle Show Balance|left|
add_spacer|small|

add_label_with_icon|small|`1Utility Commands|left|32|
add_spacer|small|
add_textbox|`e/detect `7- Detect Items/Players/Tiles|left|
add_textbox|`e/gemdetect `7- Toggle Auto Gem Detector|left|
add_textbox|`e/tpset `7- Teleport Display Settings|left|
add_textbox|`e/tp `7- Manual Teleport|left|
]] .. auto_pull_admin_menu .. [[
add_textbox|`e/mf `7or `e/modfly `7- Toggle ModFly|left|
add_textbox|`e/rndm `7- Join Random World|left|
add_textbox|`e/calcu 28x28 `7- Quick Calculator|left|
add_textbox|`e/economy `7- World Economy Info|left|
add_textbox|`e/cmp `7- Use Champagne from inventory|left|
add_textbox|`e/g `7- Toggle Ghost Mode|left|
add_textbox|`e/blink `7- Toggle Blink Skin|left|
add_textbox|`e/blockspam `7- Toggle Block Spammer Slave|left|
add_textbox|`e/slave `7- Toggle Anti Spammer Slave|left|
add_textbox|`e/tdb `7- Toggle Fast Take Display Block|left|
add_textbox|`e/vendfilter `7- Toggle Vending Cost Filter|left|
add_textbox|`e/log `7- View Action Logs|left|
add_textbox|`e/skin `7- Open Dialog Skin Color Picker|left|
add_spacer|small|

add_label_with_icon|small|`3Settings & Config|left|550|
add_spacer|small|
add_textbox|`e/setting `7- Proxy Settings Menu|left|
add_textbox|`e/bgcolor `7- Change Dialog Theme|left|
add_textbox|`e/proxy `7- Proxy Info & Updates|left|
add_textbox|`e/fitur `7or `e/feature `7- View All Features|left|
add_textbox|`e/saveconfig `7- Save Configuration|left|
add_textbox|`e/loadconfig `7- Load Configuration|left|
add_textbox|`e/imgui `7- Toggle ImGui Command Panel|left|
add_spacer|small|

add_label_with_icon|small|`8Info Commands|left|5016|
add_spacer|small|
add_textbox|`e/exit `7- Exit Current World|left|
add_textbox|`e/res `7- Respawn Player|left|
add_textbox|`e/relog `7or `e/rl `7- Fast relog to current world|left|
add_textbox|`e/menu `7- Open This Menu|left|
add_textbox|`e/askai [question] `7- Ask AI Assistant (Beta)|left|
add_spacer|small|

add_label_with_icon|small|`8For PC/Windows Users HotKey|left|16050|
add_spacer|small|
add_textbox|`eHOLD CTRL + CLICK TILE `7- Teleport and Back To Last Position|left|
add_textbox|`eHOLD SHIFT + CLICK TILE `7- Teleport Taget Tile Position|left|
add_textbox|`ePRESS F4 `7- Fast Respawning Shortcut|left|

add_quick_exit||
end_dialog|menu_dlg|Close||
]]
    SendVariantList({[0] = "OnDialogRequest", [1] = dialog, netid = -1})
end

local imgui_state = {
    visible = false,
    hook_ready = false,
    size_initialized = false,
    active_tab = tostring(config.imgui_last_tab or "command"),
    active_style_section = tostring(config.imgui_last_tab or "command"),
    chat_preview_text = "Rainbow Text Preview",
    command_filter = "",
    last_error_text = "",
    last_error_ms = 0,
    last_tab_error = "",
    last_tab_error_ms = 0
}

local function imgui_utf8_from_codepoint(raw_codepoint)
    local codepoint = math.floor(tonumber(raw_codepoint) or -1)
    if codepoint < 0 then
        return ""
    end
    if codepoint <= 0x7F then
        return string.char(codepoint)
    end
    if codepoint <= 0x7FF then
        local b1 = 0xC0 + math.floor(codepoint / 0x40)
        local b2 = 0x80 + (codepoint % 0x40)
        return string.char(b1, b2)
    end
    if codepoint <= 0xFFFF then
        local b1 = 0xE0 + math.floor(codepoint / 0x1000)
        local b2 = 0x80 + (math.floor(codepoint / 0x40) % 0x40)
        local b3 = 0x80 + (codepoint % 0x40)
        return string.char(b1, b2, b3)
    end
    if codepoint <= 0x10FFFF then
        local b1 = 0xF0 + math.floor(codepoint / 0x40000)
        local b2 = 0x80 + (math.floor(codepoint / 0x1000) % 0x40)
        local b3 = 0x80 + (math.floor(codepoint / 0x40) % 0x40)
        local b4 = 0x80 + (codepoint % 0x40)
        return string.char(b1, b2, b3, b4)
    end
    return ""
end

local ICONFONT_FA = {
    command = 0xF03A,  -- ICON_FA_LIST
    wrench = 0xF0AD,   -- ICON_FA_WRENCH
    utility = 0xF552,  -- ICON_FA_TOOLBOX
    teleport = 0xF3C5, -- ICON_FA_MAP_MARKED_ALT
    casino = 0xF522,   -- ICON_FA_DICE
    chat = 0xF086,     -- ICON_FA_COMMENTS
    balance = 0xF555   -- ICON_FA_WALLET
}

local IMGUI_TABS = {
    {id = "command", label = "Command", short = "CMD", emoji = "\240\159\147\156", iconfa = ICONFONT_FA.command, color = {0.98, 0.84, 0.34}},
    {id = "wrench", label = "Wrench", short = "WRN", emoji = "\240\159\148\167", iconfa = ICONFONT_FA.wrench, color = {0.39, 0.83, 1.00}},
    {id = "utility", label = "Utility", short = "UTL", emoji = "\240\159\167\169", iconfa = ICONFONT_FA.utility, color = {0.40, 0.94, 0.66}},
    {id = "teleport", label = "Teleport", short = "TP", emoji = "\240\159\155\176\239\184\143", iconfa = ICONFONT_FA.teleport, color = {0.55, 0.74, 1.00}},
    {id = "casino", label = "Casino", short = "CSN", emoji = "\240\159\142\176", iconfa = ICONFONT_FA.casino, color = {0.99, 0.63, 0.31}},
    {id = "chat", label = "Customize Chat", short = "CHT", emoji = "\240\159\146\172", iconfa = ICONFONT_FA.chat, color = {0.84, 0.58, 1.00}},
    {id = "balance", label = "Balance", short = "BAL", emoji = "\240\159\146\176", iconfa = ICONFONT_FA.balance, color = {0.92, 0.92, 0.92}},
    {id = "auto_pull", label = "Auto Pull", short = "AP", emoji = "\240\159\170\157", iconfa = ICONFONT_FA.wrench, color = {0.82, 0.57, 0.95}},
    {id = "settings", label = "Settings", short = "SET", emoji = "\226\154\153\239\184\143", iconfa = ICONFONT_FA.command, color = {0.65, 0.80, 1.00}},
}

local function imgui_clamp01(v)
    local n = tonumber(v) or 0
    if n < 0 then return 0 end
    if n > 1 then return 1 end
    return n
end

local function imgui_color_rgba(r, g, b, a)
    return {
        imgui_clamp01(r),
        imgui_clamp01(g),
        imgui_clamp01(b),
        imgui_clamp01(a == nil and 1.0 or a)
    }
end

local function imgui_mix_color(c, factor, alpha)
    local f = tonumber(factor) or 1.0
    return imgui_color_rgba(
        (c[1] or 1.0) * f,
        (c[2] or 1.0) * f,
        (c[3] or 1.0) * f,
        alpha or (c[4] or 1.0)
    )
end

local function imgui_build_section_style(accent)
    local base = imgui_color_rgba(accent[1], accent[2], accent[3], 1.0)
    local text = imgui_mix_color(base, 1.0, 1.0)
    local text_muted = imgui_mix_color(base, 0.78, 0.95)
    return {
        accent = base,
        text = text,
        text_muted = text_muted,
        header = imgui_mix_color(base, 0.26, 0.92),
        header_hover = imgui_mix_color(base, 0.38, 0.98),
        header_active = imgui_mix_color(base, 0.52, 1.0),
        frame_bg = imgui_mix_color(base, 0.20, 0.95),
        frame_hover = imgui_mix_color(base, 0.30, 1.0),
        frame_active = imgui_mix_color(base, 0.44, 1.0),
        check_mark = imgui_mix_color(base, 1.0, 1.0),
        button = imgui_mix_color(base, 0.46, 0.96),
        button_hover = imgui_mix_color(base, 0.64, 1.0),
        button_active = imgui_mix_color(base, 0.82, 1.0),
        button_text = imgui_color_rgba(0.96, 0.98, 1.0, 1.0),
        tab = imgui_mix_color(base, 0.30, 0.95),
        tab_hover = imgui_mix_color(base, 0.46, 1.0),
        tab_active = imgui_mix_color(base, 0.62, 1.0),
        tab_unfocus = imgui_mix_color(base, 0.22, 0.82),
        tab_unfocus_active = imgui_mix_color(base, 0.34, 0.9),
    }
end

local UI_THEME = {
    vibrant_neon = {
        sidebar_bg = imgui_color_rgba(0.08, 0.10, 0.14, 0.92),
        sidebar_title = imgui_color_rgba(0.42, 0.86, 1.00, 1.0),
        sidebar_subtitle = imgui_color_rgba(0.66, 0.78, 0.92, 1.0),
        compact_title = imgui_color_rgba(0.75, 0.88, 1.00, 1.0),
        sections = {
            default = imgui_build_section_style({0.66, 0.74, 0.90}),
            command = imgui_build_section_style({0.98, 0.84, 0.34}),
            wrench = imgui_build_section_style({0.39, 0.83, 1.00}),
            utility = imgui_build_section_style({0.40, 0.94, 0.66}),
            teleport = imgui_build_section_style({0.55, 0.74, 1.00}),
            casino = imgui_build_section_style({0.99, 0.63, 0.31}),
            chat = imgui_build_section_style({0.84, 0.58, 1.00}),
            balance = imgui_build_section_style({0.92, 0.92, 0.92}),
            auto_pull = imgui_build_section_style({0.82, 0.57, 0.95}),
            settings = imgui_build_section_style({0.65, 0.80, 1.00}),
        }
    }
}

local function imgui_get_theme()
    local key = tostring(config.ui_theme_variant or "vibrant_neon")
    return UI_THEME[key] or UI_THEME.vibrant_neon
end

local function imgui_get_section_style(section_id)
    local theme = imgui_get_theme()
    local sections = theme.sections or {}
    return sections[section_id] or sections.default
end

local function imgui_push_style_colors(style_map)
    if not (ImGui and ImGui.PushStyleColor and type(ImVec4) == "function") then
        return 0
    end
    local pushed = 0
    for _, pair in ipairs(style_map or {}) do
        local enum_name = pair[1]
        local rgba = pair[2]
        local enum_val = ImGui[enum_name]
        if enum_val ~= nil and type(rgba) == "table" then
            ImGui.PushStyleColor(enum_val, ImVec4(
                imgui_clamp01(rgba[1] or 1.0),
                imgui_clamp01(rgba[2] or 1.0),
                imgui_clamp01(rgba[3] or 1.0),
                imgui_clamp01(rgba[4] or 1.0)
            ))
            pushed = pushed + 1
        end
    end
    return pushed
end

local function imgui_pop_style_colors(count)
    if not (ImGui and ImGui.PopStyleColor) then
        return
    end
    local total = math.floor(tonumber(count) or 0)
    for _ = 1, total do
        ImGui.PopStyleColor()
    end
end

local function imgui_get_icon_mode()
    local mode = tostring(config.ui_icon_mode or "hybrid")
    if mode ~= "hybrid"
        and mode ~= "emoji_only"
        and mode ~= "text_only"
        and mode ~= "iconfontcpp"
        and mode ~= "iconfont_hybrid" then
        mode = "hybrid"
    end
    return mode
end

local function imgui_get_iconfont_symbol(tab)
    if type(tab) ~= "table" then
        return ""
    end
    return imgui_utf8_from_codepoint(tab.iconfa)
end

local function imgui_build_tab_label(tab, selected)
    local mode = imgui_get_icon_mode()
    local short = tostring(tab.short or tab.id or "TAB")
    local label = tostring(tab.label or short)
    local emoji = tostring(tab.emoji or "")
    local iconfont = imgui_get_iconfont_symbol(tab)
    local prefix = selected and "> " or "- "

    if config.imgui_safe_fallback ~= false then
        return prefix .. "[" .. short .. "] " .. label
    end

    if mode == "emoji_only" then
        if emoji ~= "" then
            return prefix .. emoji .. " " .. label
        end
        return prefix .. "[" .. short .. "] " .. label
    end
    if mode == "text_only" then
        return prefix .. "[" .. short .. "] " .. label
    end
    if mode == "iconfontcpp" then
        if iconfont ~= "" then
            return prefix .. iconfont .. " " .. label
        end
        return prefix .. "[" .. short .. "] " .. label
    end
    if mode == "iconfont_hybrid" then
        if iconfont ~= "" then
            return prefix .. "[" .. short .. "] " .. iconfont .. " " .. label
        end
        if emoji ~= "" then
            return prefix .. "[" .. short .. "] " .. emoji .. " " .. label
        end
        return prefix .. "[" .. short .. "] " .. label
    end
    if emoji ~= "" then
        return prefix .. "[" .. short .. "] " .. emoji .. " " .. label
    end
    return prefix .. "[" .. short .. "] " .. label
end

local function imgui_set_style_section(section_id)
    imgui_state.active_style_section = section_id or "default"
end

local function is_imgui_supported()
    return type(ImGui) == "table"
        and type(ImGui.Begin) == "function"
        and type(ImGui.End) == "function"
        and type(ImGui.Text) == "function"
end

local function is_owner_userid(userid)
    return math.floor(tonumber(userid) or 0) == OWNER_USER_ID
end

local function imgui_checkbox(label, value, on_change)
    if not (ImGui and ImGui.Checkbox) then
        return
    end
    local style = imgui_get_section_style(imgui_state.active_style_section)
    local pushed = imgui_push_style_colors({
        {"Col_FrameBg", style.frame_bg},
        {"Col_FrameBgHovered", style.frame_hover},
        {"Col_FrameBgActive", style.frame_active},
        {"Col_CheckMark", style.check_mark},
        {"Col_Text", style.text}
    })
    local ok, changed, new_value = pcall(ImGui.Checkbox, label, value and true or false)
    imgui_pop_style_colors(pushed)
    if ok and changed and on_change then
        on_change(new_value and true or false)
    end
end

local function imgui_radio(label, active, on_select)
    if not (ImGui and ImGui.RadioButton) then
        return
    end
    local style = imgui_get_section_style(imgui_state.active_style_section)
    local pushed = imgui_push_style_colors({
        {"Col_FrameBg", style.frame_bg},
        {"Col_FrameBgHovered", style.frame_hover},
        {"Col_FrameBgActive", style.frame_active},
        {"Col_CheckMark", style.check_mark},
        {"Col_Text", style.text}
    })
    local ok, clicked = pcall(ImGui.RadioButton, label, active and true or false)
    imgui_pop_style_colors(pushed)
    if ok and clicked and on_select then
        on_select()
    end
end

local function imgui_button(label)
    if not (ImGui and ImGui.Button) then
        return false
    end
    local style = imgui_get_section_style(imgui_state.active_style_section)
    local pushed = imgui_push_style_colors({
        {"Col_Button", style.button},
        {"Col_ButtonHovered", style.button_hover},
        {"Col_ButtonActive", style.button_active},
        {"Col_Text", style.button_text}
    })
    local ok, clicked = pcall(ImGui.Button, label)
    imgui_pop_style_colors(pushed)
    return ok and clicked or false
end

local function imgui_input_text(label, value, max_len, on_change)
    if not (ImGui and ImGui.InputText) then
        return
    end

    local style = imgui_get_section_style(imgui_state.active_style_section)
    local pushed = imgui_push_style_colors({
        {"Col_FrameBg", style.frame_bg},
        {"Col_FrameBgHovered", style.frame_hover},
        {"Col_FrameBgActive", style.frame_active},
        {"Col_Text", style.text}
    })
    local base_value = tostring(value or "")
    local ok, changed, new_value = pcall(ImGui.InputText, label, base_value, max_len or 120)
    if not ok then
        ok, changed, new_value = pcall(ImGui.InputText, label, base_value)
    end
    imgui_pop_style_colors(pushed)
    if ok and changed and on_change then
        on_change(tostring(new_value or ""))
    end
end

local function imgui_input_int(label, value, min_value, max_value, on_change)
    local number = math.floor(tonumber(value) or 0)
    local function clamp(v)
        local out = math.floor(tonumber(v) or number)
        if out < min_value then out = min_value end
        if out > max_value then out = max_value end
        return out
    end

    if ImGui and ImGui.InputInt then
        local style = imgui_get_section_style(imgui_state.active_style_section)
        local pushed = imgui_push_style_colors({
            {"Col_FrameBg", style.frame_bg},
            {"Col_FrameBgHovered", style.frame_hover},
            {"Col_FrameBgActive", style.frame_active},
            {"Col_Text", style.text}
        })
        local ok, changed, new_value = pcall(ImGui.InputInt, label, number, 1, 100)
        if not ok then
            ok, changed, new_value = pcall(ImGui.InputInt, label, number)
        end
        imgui_pop_style_colors(pushed)
        if ok and changed and on_change then
            on_change(clamp(new_value))
        end
        if ok then
            return
        end
    end

    imgui_input_text(label, tostring(number), 8, function(raw)
        if on_change then
            on_change(clamp(raw))
        end
    end)
end

local function imgui_text(text)
    if ImGui and ImGui.Text then
        pcall(ImGui.Text, tostring(text or ""))
    end
end

local function imgui_text_colored(text, r, g, b, a)
    if ImGui and ImGui.TextColored and type(ImVec4) == "function" then
        local ok = pcall(ImGui.TextColored, ImVec4(r, g, b, a or 1.0), tostring(text or ""))
        if ok then
            return
        end
        imgui_text(text)
    else
        imgui_text(text)
    end
end

function helpers.SetImguiActiveTab(tab_id)
    local next_tab = tostring(tab_id or "command")
    if next_tab == "" then
        next_tab = "command"
    end
    imgui_state.active_tab = next_tab
    imgui_state.active_style_section = next_tab
    config.imgui_last_tab = next_tab
    auto_save_config()
end

function helpers.RenderImguiGrowtopiaText(raw_text, default_rgba)
    local text = tostring(raw_text or "")
    if text == "" then
        imgui_text("")
        return
    end

    local default_color = default_rgba or {0.95, 0.95, 0.95, 1.0}
    local active_color = {
        tonumber(default_color[1]) or 0.95,
        tonumber(default_color[2]) or 0.95,
        tonumber(default_color[3]) or 0.95,
        tonumber(default_color[4]) or 1.0
    }
    local first_segment = true
    local index = 1

    while index <= #text do
        local code_start, code_end, code_char = text:find("`(.)", index)
        local segment_end = code_start and (code_start - 1) or #text
        local segment = text:sub(index, segment_end)

        if segment ~= "" then
            if not first_segment and ImGui and ImGui.SameLine then
                local same_line_ok = pcall(ImGui.SameLine, 0, 0)
                if not same_line_ok then
                    pcall(ImGui.SameLine)
                end
            end
            imgui_text_colored(segment, active_color[1], active_color[2], active_color[3], active_color[4])
            first_segment = false
        end

        if not code_start then
            break
        end

        local target_code = "`" .. tostring(code_char or "")
        for _, skin in ipairs(SkinColors) do
            if skin.code == target_code then
                active_color = {
                    (tonumber(skin.r) or 255) / 255,
                    (tonumber(skin.g) or 255) / 255,
                    (tonumber(skin.b) or 255) / 255,
                    (tonumber(skin.a) or 255) / 255
                }
                break
            end
        end

        index = code_end + 1
    end

    if first_segment then
        imgui_text(stripColors(text))
    end
end

local function imgui_command_header(title, r, g, b)
    if ImGui and ImGui.Separator then
        pcall(ImGui.Separator)
    end
    imgui_text_colored(title, r, g, b, 1.0)
end

local function imgui_command_entry(cmd, desc)
    imgui_text_colored(tostring(cmd or ""), 0.95, 0.88, 0.33, 1.0)
    if ImGui and ImGui.SameLine then
        pcall(ImGui.SameLine)
    end
    imgui_text_colored("- " .. tostring(desc or ""), 0.78, 0.78, 0.78, 1.0)
end

local function imgui_sidebar_item(tab)
    local selected = (imgui_state.active_tab == tab.id)
    local style = imgui_get_section_style(tab.id)
    local display_label = imgui_build_tab_label(tab, selected)
    local text_col = selected and style.text or style.text_muted

    if ImGui and ImGui.Selectable then
        local pushed = imgui_push_style_colors({
            {"Col_Text", text_col},
            {"Col_Header", style.header},
            {"Col_HeaderHovered", style.header_hover},
            {"Col_HeaderActive", style.header_active}
        })
        local ok, clicked = pcall(ImGui.Selectable, display_label .. "##imgui_tab_" .. tab.id, selected)
        imgui_pop_style_colors(pushed)
        if ok and clicked then
            helpers.SetImguiActiveTab(tab.id)
        end
    else
        imgui_radio(display_label .. "##imgui_tab_" .. tab.id, selected, function()
            helpers.SetImguiActiveTab(tab.id)
        end)
    end
end

local function imgui_current_wrench_mode()
    if config.pull then return "pull" end
    if config.kick then return "kick" end
    if config.ban then return "ban" end
    return "off"
end

local function imgui_set_wrench_mode(mode)
    config.pull = (mode == "pull")
    config.kick = (mode == "kick")
    config.ban = (mode == "ban")
    auto_save_config()
end

local function imgui_current_spin_mode()
    if config.reme then return "reme" end
    if config.leme then return "leme" end
    if config.lemesuper then return "sleme" end
    if config.ceme then return "ceme" end
    if config.qeme then return "qeme" end
    if config.lewa then return "lewa" end
    if config.hol then return "hol" end
    return "off"
end

local function imgui_set_spin_mode(mode)
    config.reme = (mode == "reme")
    config.leme = (mode == "leme")
    config.lemesuper = (mode == "sleme")
    config.ceme = (mode == "ceme")
    config.qeme = (mode == "qeme")
    config.lewa = (mode == "lewa")
    config.hol = (mode == "hol")
    auto_save_config()
end

local function imgui_set_economy_mode(mode, enabled)
    if mode == "cbgl" then
        config.cbgl = enabled
        if enabled then
            config.buydl = false
            config.buychamp = false
        end
    elseif mode == "buydl" then
        config.buydl = enabled
        if enabled then
            config.cbgl = false
            config.buychamp = false
        end
    elseif mode == "buychamp" then
        config.buychamp = enabled
        if enabled then
            config.cbgl = false
            config.buydl = false
        end
    end
    auto_save_config()
end

local function imgui_apply_anti_lag(enabled)
    config.antiLagEnabled = enabled and true or false
    ChangeValue("[C] No render particle", config.antiLagEnabled)
    ChangeValue("[C] No render shadow", config.antiLagEnabled)
    config.antiSpammerSlave = config.antiLagEnabled
    if config.antiLagEnabled then
        helpers.OnTextOverlay("`2Anti-Lag Enabled")
    else
        helpers.OnTextOverlay("`4Anti-Lag Disabled")
    end
    auto_save_config()
end

local function imgui_apply_auto_modage(enabled)
    config.automodage = enabled and true or false
    if config.automodage then
        helpers.OnTextOverlay("`2Auto Modage: `aON")
        RunThread(function()
            while config.automodage do
                SendPacket(2, "action|input\n|text|/modage 9999\n")
                Sleep(1000)
            end
        end)
    else
        helpers.OnTextOverlay("`4Auto Modage: `cOFF")
    end
    auto_save_config()
end

local function imgui_apply_blink(enabled)
    if enabled then
        helpers.start_blink_skin()
    else
        helpers.stop_blink_skin()
    end
end

local function imgui_clean_spin_log(entry)
    local raw = entry
    if type(entry) == "table" then
        raw = entry.spin or ""
    end
    raw = tostring(raw or "")
    raw = raw:gsub("add_label_with_icon_button|small|", "")
    raw = raw:gsub("add_label_with_icon|small|", "")
    raw = raw:gsub("|left|758|%d+|", "")
    raw = raw:gsub("|left|758||", "")
    raw = raw:gsub("[\r\n]", " ")
    raw = raw:gsub("`.", "")
    raw = raw:gsub("%s+", " ")
    raw = raw:gsub("^%s+", ""):gsub("%s+$", "")
    if raw == "" then
        raw = "(empty log)"
    end
    return raw
end

local function imgui_draw_command_tab(can_auto_pull)
    local cmd_wl = "/" .. tostring(config.cmd_drop_wl or "w")
    local cmd_dl = "/" .. tostring(config.cmd_drop_dl or "d")
    local cmd_bgl = "/" .. tostring(config.cmd_drop_bgl or "b")
    local cmd_black = "/" .. tostring(config.cmd_drop_black or "bb")

    imgui_input_text("Search Commands##imgui_command_filter", imgui_state.command_filter, 80, function(v)
        imgui_state.command_filter = tostring(v or "")
    end)

    local filter = tostring(imgui_state.command_filter or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    imgui_text_colored("Quick access: panel search mirrors /menu and highlights the most used commands.", 0.72, 0.78, 0.86, 1.0)

    if imgui_button("Open Menu Dialog##imgui_cmd_menu") then
        helpers.ProxyMenu()
    end
    if ImGui and ImGui.SameLine then pcall(ImGui.SameLine) end
    if imgui_button("Drop Dialog##imgui_cmd_drop") then
        helpers.DropDialog()
    end
    if ImGui and ImGui.SameLine then pcall(ImGui.SameLine) end
    if imgui_button("Wrench Dialog##imgui_cmd_wrm") then
        helpers.WrenchModeDialog()
    end
    if ImGui and ImGui.SameLine then pcall(ImGui.SameLine) end
    if imgui_button("Settings Dialog##imgui_cmd_setting") then
        helpers.ShowSettings()
    end
    if can_auto_pull then
        if ImGui and ImGui.SameLine then pcall(ImGui.SameLine) end
        if imgui_button("Auto Pull Dialog##imgui_cmd_apdlg") then
            helpers.ShowAutoPullDialog()
        end
    end

    local sections = {
        {
            title = "Drop Commands",
            color = {0.35, 0.95, 0.45},
            items = {
                {cmd = "/daw", desc = "Drop all locks (WL, DL, BGL, BLACK)"},
                {cmd = cmd_wl .. " [amount]", desc = "Drop World Locks"},
                {cmd = cmd_dl .. " [amount]", desc = "Drop Diamond Locks"},
                {cmd = cmd_bgl .. " [amount]", desc = "Drop Blue Gem Locks"},
                {cmd = cmd_black .. " [amount]", desc = "Drop Black Gem Locks"},
                {cmd = cmd_wl .. "2-10 [amt]", desc = "Multi-drop WL (x2-x10)"},
                {cmd = cmd_dl .. "2-10 [amt]", desc = "Multi-drop DL (x2-x10)"},
                {cmd = "/drops", desc = "Open drop dialog"},
                {cmd = "/customcmd or /cmdset", desc = "Customize drop commands"}
            }
        },
        {
            title = "Trade Commands",
            color = {0.35, 0.95, 0.45},
            items = {
                {cmd = "/twl [amount]", desc = "Trade World Locks"},
                {cmd = "/tdl [amount]", desc = "Trade Diamond Locks"},
                {cmd = "/tbgl [amount]", desc = "Trade Blue Gem Locks"},
                {cmd = "/tblack [amount]", desc = "Trade Black Gem Locks"}
            }
        },
        {
            title = "Conversion & Banking",
            color = {0.95, 0.46, 0.30},
            items = {
                {cmd = "/cvdl", desc = "Toggle auto convert DL to BGL"},
                {cmd = "/blue", desc = "Convert Black to BGL"},
                {cmd = "/black", desc = "Convert BGL to Black"},
                {cmd = "/depo [amt] or /dp [amt]", desc = "Deposit BGL to bank"},
                {cmd = "/wd [amt] or /wt [amt]", desc = "Withdraw BGL from bank"},
                {cmd = "/wdv", desc = "Withdraw and drop to vend"},
                {cmd = "/evd", desc = "Empty vend and deposit"}
            }
        },
        {
            title = "Automation Commands",
            color = {0.45, 0.75, 1.00},
            items = {
                {cmd = "/autogg", desc = "Auto GrowGanoth settings"},
                {cmd = "/autosurg", desc = "Auto surgery manager"},
                {cmd = "/autofarm", desc = "Auto farm controller"},
                {cmd = "/surgstats", desc = "Surgery statistics"},
                {cmd = "/hunting", desc = "Hunting world settings"},
                {cmd = "/starthunt", desc = "Start hunting worlds"},
                {cmd = "/stophunt", desc = "Stop hunting worlds"},
                {cmd = "/spam", desc = "Open spammer dialog"},
                {cmd = "/sbspam", desc = "SB spam mode toggle"},
                {cmd = "/ftr", desc = "Toggle fast trash"},
                {cmd = "/antilag", desc = "Toggle anti lag"},
                {cmd = "/acdoor", desc = "Toggle auto door"},
                {cmd = "/automodage", desc = "Toggle auto modage"}
            }
        },
        {
            title = "Casino & Games",
            color = {0.96, 0.73, 0.28},
            items = {
                {cmd = "/game", desc = "Open fun games menu"},
                {cmd = "/cf", desc = "Coinflip"},
                {cmd = "/dice", desc = "Dice roll game"},
                {cmd = "/rbt", desc = "Toggle rainbow text chat"},
                {cmd = "/emt", desc = "Toggle emoji text chat"},
                {cmd = "/reme", desc = "Toggle REME spin"},
                {cmd = "/sspin", desc = "Toggle short spin"},
                {cmd = "/leme", desc = "Toggle LEME spin"},
                {cmd = "/sleme", desc = "Toggle LEME SUPER spin"},
                {cmd = "/lewa", desc = "Toggle LEWA spin"},
                {cmd = "/ceme", desc = "Toggle CEME spin"},
                {cmd = "/qeme", desc = "Toggle QEME spin"},
                {cmd = "/hol", desc = "Toggle HOL"},
                {cmd = "/holr", desc = "Reset HOL tracking"},
                {cmd = "/cbgl", desc = "Toggle convert BGL"},
                {cmd = "/buydl", desc = "Toggle buy DL"},
                {cmd = "/buychamp", desc = "Toggle buy champagne"},
                {cmd = "/cvptu", desc = "Toggle convert pink gems to UWS"},
                {cmd = "/bsdb", desc = "Toggle block super duper broadcast"},
                {cmd = "/acsign", desc = "Toggle auto copy sign"}
            }
        },
        {
            title = "Wrench Commands",
            color = {0.98, 0.90, 0.35},
            items = {
                {cmd = "/wrm", desc = "Open wrench mode settings"},
                {cmd = "/wrp", desc = "Toggle wrench pull"},
                {cmd = "/wrk", desc = "Toggle wrench kick"},
                {cmd = "/wrb", desc = "Toggle wrench ban"},
                {cmd = "/showbal or /smodal", desc = "Toggle show balance"}
            }
        },
        {
            title = "Utility Commands",
            color = {0.40, 0.86, 0.98},
            items = {
                {cmd = "/detect", desc = "Detect items, players, and tiles"},
                {cmd = "/gemdetect", desc = "Toggle auto gem detector"},
                {cmd = "/tpset", desc = "Teleport display settings"},
                {cmd = "/tp", desc = "Manual teleport"},
                {cmd = "/mf or /modfly", desc = "Toggle modfly"},
                {cmd = "/rndm", desc = "Join random world"},
                {cmd = "/calcu 28x28", desc = "Quick calculator in chat"},
                {cmd = "/economy", desc = "World economy info"},
                {cmd = "/cmp", desc = "Use champagne from inventory"},
                {cmd = "/g", desc = "Toggle ghost mode"},
                {cmd = "/blink", desc = "Toggle blink skin"},
                {cmd = "/blockspam", desc = "Toggle block spammer slave"},
                {cmd = "/slave", desc = "Toggle anti spammer slave"},
                {cmd = "/tdb", desc = "Toggle fast take display block"},
                {cmd = "/vendfilter", desc = "Toggle vending cost filter"},
                {cmd = "/log", desc = "View action logs"},
                {cmd = "/skin", desc = "Open skin dialog"}
            }
        },
        {
            title = "Settings & Info",
            color = {0.65, 0.80, 1.00},
            items = {
                {cmd = "/setting", desc = "Open settings overview"},
                {cmd = "/bgcolor", desc = "Change dialog theme"},
                {cmd = "/proxy", desc = "Proxy info and updates"},
                {cmd = "/fitur or /feature", desc = "View all features"},
                {cmd = "/saveconfig", desc = "Save configuration"},
                {cmd = "/loadconfig", desc = "Load configuration"},
                {cmd = "/imgui", desc = "Toggle ImGui panel"},
                {cmd = "/exit", desc = "Exit current world"},
                {cmd = "/res", desc = "Respawn player"},
                {cmd = "/relog or /rl", desc = "Fast relog to current world"},
                {cmd = "/menu", desc = "Open main menu"},
                {cmd = "/askai [question]", desc = "Ask AI assistant"}
            }
        }
    }

    if can_auto_pull then
        table.insert(sections, {
            title = "Admin Auto Pull",
            color = {0.82, 0.57, 0.95},
            items = {
                {cmd = "/ap", desc = "Toggle auto pull admin mode"},
                {cmd = "/setap", desc = "Set auto pull tile"},
                {cmd = "/setautopull", desc = "Open auto pull settings"}
            }
        })
    end

    local function matches_filter(section_title, entry)
        if filter == "" then
            return true
        end
        local haystack = (section_title .. " " .. tostring(entry.cmd or "") .. " " .. tostring(entry.desc or "")):lower()
        return haystack:find(filter, 1, true) ~= nil
    end

    local section_count = 0
    for _, section in ipairs(sections) do
        local rendered = 0
        for _, entry in ipairs(section.items) do
            if matches_filter(section.title, entry) then
                if rendered == 0 then
                    imgui_command_header(section.title, section.color[1], section.color[2], section.color[3])
                end
                imgui_command_entry(entry.cmd, entry.desc)
                rendered = rendered + 1
            end
        end
        if rendered > 0 then
            section_count = section_count + 1
        end
    end

    if section_count == 0 then
        imgui_text_colored("No commands matched your search.", 0.90, 0.52, 0.52, 1.0)
    end
end

local function imgui_draw_wrench_tab()
    imgui_text_colored("Wrench Mode", 0.92, 0.92, 0.92, 1.0)
    local wrench_mode = imgui_current_wrench_mode()
    imgui_radio("OFF##wrench_mode", wrench_mode == "off", function() imgui_set_wrench_mode("off") end)
    if ImGui and ImGui.SameLine then pcall(ImGui.SameLine) end
    imgui_radio("PULL##wrench_mode", wrench_mode == "pull", function() imgui_set_wrench_mode("pull") end)
    if ImGui and ImGui.SameLine then pcall(ImGui.SameLine) end
    imgui_radio("KICK##wrench_mode", wrench_mode == "kick", function() imgui_set_wrench_mode("kick") end)
    if ImGui and ImGui.SameLine then pcall(ImGui.SameLine) end
    imgui_radio("BAN##wrench_mode", wrench_mode == "ban", function() imgui_set_wrench_mode("ban") end)
    if ImGui and ImGui.Separator then ImGui.Separator() end

    imgui_checkbox("Show Balance##wr_showbal", config.showbal, function(v)
        config.showbal = v
        auto_save_config()
    end)
    imgui_checkbox("Show Balance Via Chat##wr_showbal_chat", config.showbal_use_chat, function(v)
        config.showbal_use_chat = v
        auto_save_config()
    end)
    imgui_checkbox("Vend Filter##wr_vendfilter", config.vendfilter, function(v)
        config.vendfilter = v
        auto_save_config()
    end)
    imgui_checkbox("Donation Box Icon Filter##wr_dboxfilter", config.dboxfilter, function(v)
        config.dboxfilter = v
        auto_save_config()
    end)
    imgui_checkbox("Fast Take Display Block##wr_fastdb", config.fastdb, function(v)
        config.fastdb = v
        config.fastdbl = v
        auto_save_config()
    end)
    imgui_checkbox("Auto Close/Open Door##wr_auto_door", config.autoToggleDoor, function(v)
        config.autoToggleDoor = v
        auto_save_config()
    end)

    if ImGui and ImGui.Separator then ImGui.Separator() end
    imgui_text_colored("Action Messages", 0.92, 0.92, 0.92, 1.0)
    imgui_input_text("Pull Message##wr_msg_pull", config.wrench_msg_pull, 120, function(v)
        config.wrench_msg_pull = sanitize_wrench_message_input(v)
        auto_save_config()
    end)
    imgui_input_text("Kick Message##wr_msg_kick", config.wrench_msg_kick, 120, function(v)
        config.wrench_msg_kick = sanitize_wrench_message_input(v)
        auto_save_config()
    end)
    imgui_input_text("Ban Message##wr_msg_ban", config.wrench_msg_ban, 120, function(v)
        config.wrench_msg_ban = sanitize_wrench_message_input(v)
        auto_save_config()
    end)
    imgui_input_text("Show Balance Message##wr_msg_showbal", config.wrench_msg_showbal, 120, function(v)
        config.wrench_msg_showbal = sanitize_wrench_message_input(v)
        auto_save_config()
    end)
    imgui_text_colored("Placeholders: {name} | {action} | {world} | {time}", 0.64, 0.70, 0.78, 1.0)

    if ImGui and ImGui.Separator then ImGui.Separator() end
    if imgui_button("Open Full Wrench Dialog##wr_open_dialog") then
        helpers.WrenchModeDialog()
    end
end

local function imgui_draw_utility_tab()
    local ok_local, local_player = pcall(GetLocal)
    local current_userid = math.floor((ok_local and local_player and local_player.userid) or 0)
    local can_open_detect = is_owner_userid(current_userid)

    imgui_checkbox("Anti Spammer Slave##ut_anti_slave", config.antiSpammerSlave, function(v)
        config.antiSpammerSlave = v
        auto_save_config()
    end)
    imgui_checkbox("Block Spammer Slave##ut_block_slave", config.block_spammer_slave, function(v)
        config.block_spammer_slave = v
        auto_save_config()
    end)
    imgui_checkbox("Auto Gems Detect##ut_gem_detect", config.autoGemDetect, function(v)
        config.autoGemDetect = v
        auto_save_config()
    end)
    imgui_checkbox("Anti Lag##ut_antilag", config.antiLagEnabled, function(v)
        imgui_apply_anti_lag(v)
    end)
    imgui_checkbox("Blink SKIN##ut_blink_skin", config.blink_skin, function(v)
        imgui_apply_blink(v)
    end)
    imgui_checkbox("Auto Modage##ut_auto_modage", config.automodage, function(v)
        imgui_apply_auto_modage(v)
    end)
    imgui_checkbox("Fast Trash##ut_fast_trash", config.fasttrash, function(v)
        config.fasttrash = v
        auto_save_config()
    end)

    if ImGui and ImGui.Separator then ImGui.Separator() end
    if imgui_button("Open Drop Dialog##ut_open_drop") then
        helpers.DropDialog()
    end
    if can_open_detect then
        if ImGui and ImGui.SameLine then pcall(ImGui.SameLine) end
        if imgui_button("Open Detector##ut_open_detect") then
            helpers.ShowFloatingItemsDialog()
        end
    end
    if ImGui and ImGui.SameLine then pcall(ImGui.SameLine) end
    if imgui_button("Open Logs##ut_open_logs") then
        helpers.MenuLogs()
    end
    if ImGui and ImGui.SameLine then pcall(ImGui.SameLine) end
    if imgui_button("Skin Picker##ut_open_skin") then
        helpers.SkinDialog()
    end
    imgui_text_colored("Dialogs stay on their original flow; ImGui is the fast control layer.", 0.65, 0.65, 0.65, 1.0)
end

local function imgui_draw_teleport_tab()
    imgui_text_colored("Windows", 0.90, 0.90, 0.90, 1.0)
    imgui_checkbox("Teleport and Back (CTRL + CLICK)##tp_ctrl", config.tp_ctrl_click_enabled, function(v)
        config.tp_ctrl_click_enabled = v
        auto_save_config()
    end)
    imgui_checkbox("Teleport Tile (SHIFT + CLICK)##tp_shift", config.tp_shift_click_enabled, function(v)
        config.tp_shift_click_enabled = v
        auto_save_config()
    end)

    if ImGui and ImGui.Separator then ImGui.Separator() end
    imgui_text_colored("Android", 0.90, 0.90, 0.90, 1.0)
    imgui_radio("Teleport To Display Only##tp_mode_display", config.tpdisplay_mode == "display_only", function()
        config.tpdisplay_mode = "display_only"
        auto_save_config()
    end)
    imgui_radio("Teleport To All Position##tp_mode_all", config.tpdisplay_mode == "all_position", function()
        config.tpdisplay_mode = "all_position"
        auto_save_config()
    end)
    imgui_checkbox("Auto Back After Teleport##tp_back", config.tpdisplay_return, function(v)
        config.tpdisplay_return = v
        auto_save_config()
    end)
    imgui_input_int("Input Delay BACK (100-60000ms)##tp_delay", config.tpdisplay_delay, 100, 60000, function(v)
        config.tpdisplay_delay = v
        auto_save_config()
    end)

    if ImGui and ImGui.Separator then ImGui.Separator() end
    imgui_text_colored("Notification", 0.90, 0.90, 0.90, 1.0)
    imgui_checkbox("Show Teleport Overlay##tp_overlay_go", config.tpdisplay_show_travel_text, function(v)
        config.tpdisplay_show_travel_text = v
        auto_save_config()
    end)
    imgui_checkbox("Show Back Overlay##tp_overlay_back", config.tpdisplay_show_return_text, function(v)
        config.tpdisplay_show_return_text = v
        auto_save_config()
    end)
    imgui_checkbox("Show Back Message##tp_overlay_msg", config.tpdisplay_show_return_chat, function(v)
        config.tpdisplay_show_return_chat = v
        auto_save_config()
    end)
end

local function imgui_draw_casino_tab()
    imgui_text_colored("Spin Mode", 0.90, 0.90, 0.90, 1.0)
    local spin_mode = imgui_current_spin_mode()
    imgui_radio("REME SPIN##cs_reme", spin_mode == "reme", function() imgui_set_spin_mode("reme") end)
    imgui_radio("LEME SPIN##cs_leme", spin_mode == "leme", function() imgui_set_spin_mode("leme") end)
    imgui_radio("LEME SUPER SPIN##cs_sleme", spin_mode == "sleme", function() imgui_set_spin_mode("sleme") end)
    imgui_radio("CEME SPIN##cs_ceme", spin_mode == "ceme", function() imgui_set_spin_mode("ceme") end)
    imgui_radio("QEME SPIN##cs_qeme", spin_mode == "qeme", function() imgui_set_spin_mode("qeme") end)
    imgui_radio("LEWA SPIN##cs_lewa", spin_mode == "lewa", function() imgui_set_spin_mode("lewa") end)
    imgui_radio("HOL SPIN##cs_hol", spin_mode == "hol", function() imgui_set_spin_mode("hol") end)
    imgui_checkbox("Short SPIN##cs_short_spin", config.sspin, function(v)
        config.sspin = v
        auto_save_config()
    end)

    if ImGui and ImGui.Separator then ImGui.Separator() end
    imgui_text_colored("Automation Telephone", 0.90, 0.90, 0.90, 1.0)
    imgui_radio("Auto Convert BGL##cs_cbgl", config.cbgl, function()
        imgui_set_economy_mode("cbgl", true)
    end)
    imgui_radio("Auto Buy Diamond Lock##cs_buydl", config.buydl, function()
        imgui_set_economy_mode("buydl", true)
    end)
    imgui_radio("Auto Buy Champagne##cs_buychamp", config.buychamp, function()
        imgui_set_economy_mode("buychamp", true)
    end)

    if ImGui and ImGui.Separator then ImGui.Separator() end
    imgui_text_colored("Logs Casino", 0.90, 0.90, 0.90, 1.0)
    imgui_text("LOGS SPIN: " .. tostring(#(config.tablelogspin or {})))

    local draw_logs = function()
        local logs = config.tablelogspin or {}
        if #logs == 0 then
            imgui_text_colored("No spin logs yet.", 0.60, 0.60, 0.60, 1.0)
            return
        end
        for i = #logs, 1, -1 do
            imgui_text(imgui_clean_spin_log(logs[i]))
        end
    end

    if ImGui and ImGui.BeginChild and ImGui.EndChild and type(ImVec2) == "function" then
        ImGui.BeginChild("casino_logs_child", ImVec2(0, 180), true)
        draw_logs()
        ImGui.EndChild()
    else
        draw_logs()
    end

    if imgui_button("Clear Logs##cs_clear_logs") then
        config.tablelogspin = {}
        auto_save_config()
        helpers.OnTextOverlay("`2Spin logs cleared.")
    end
end

local function imgui_draw_chat_tab()
    imgui_checkbox("Enable Rainbow Text##chat_rbt", config.rainbow_text, function(v)
        config.rainbow_text = v
        auto_save_config()
    end)
    imgui_checkbox("Enable Emoji Text##chat_emoji", config.emoji_text, function(v)
        config.emoji_text = v
        auto_save_config()
    end)

    if ImGui and ImGui.Separator then ImGui.Separator() end
    imgui_text_colored("Sidebar Icon Mode", 0.90, 0.90, 0.90, 1.0)
    imgui_checkbox("Safe Glyph Fallback##chat_safe_fallback", config.imgui_safe_fallback, function(v)
        config.imgui_safe_fallback = v and true or false
        auto_save_config()
    end)

    local icon_mode = imgui_get_icon_mode()
    imgui_radio("Hybrid Emoji + Text##chat_icon_mode_hybrid", icon_mode == "hybrid", function()
        config.ui_icon_mode = "hybrid"
        auto_save_config()
    end)
    imgui_radio("Emoji Only##chat_icon_mode_emoji", icon_mode == "emoji_only", function()
        config.ui_icon_mode = "emoji_only"
        auto_save_config()
    end)
    imgui_radio("Text Only##chat_icon_mode_text", icon_mode == "text_only", function()
        config.ui_icon_mode = "text_only"
        auto_save_config()
    end)
    imgui_radio("IconFontCpp Only##chat_icon_mode_iconfont_only", icon_mode == "iconfontcpp", function()
        config.ui_icon_mode = "iconfontcpp"
        auto_save_config()
    end)
    imgui_radio("IconFontCpp Hybrid##chat_icon_mode_iconfont_hybrid", icon_mode == "iconfont_hybrid", function()
        config.ui_icon_mode = "iconfont_hybrid"
        auto_save_config()
    end)

    if icon_mode == "iconfontcpp" or icon_mode == "iconfont_hybrid" then
        imgui_text_colored("Requires merged icon font in ImGui atlas (example: Font Awesome solid).", 0.88, 0.76, 0.45, 1.0)
    end
    if config.imgui_safe_fallback ~= false then
        imgui_text_colored("Safe fallback is ON: tabs use text badges to avoid missing glyph warnings and '?' icons.", 0.68, 0.86, 0.96, 1.0)
    end

    if ImGui and ImGui.Separator then ImGui.Separator() end
    imgui_text_colored("Setting Rainbow Text", 0.90, 0.90, 0.90, 1.0)

    local rbt_mode = normalize_rbt_mode(config.rbt_mode)
    imgui_radio("Single Color##chat_rbt_single", rbt_mode == "single", function()
        config.rbt_mode = "single"
        auto_save_config()
    end)
    imgui_radio("Rainbow Cycle Color##chat_rbt_rainbow", rbt_mode == "rainbow", function()
        config.rbt_mode = "rainbow"
        auto_save_config()
    end)
    imgui_radio("Smooth Gradient Color##chat_rbt_smooth", rbt_mode == "smooth", function()
        config.rbt_mode = "smooth"
        auto_save_config()
    end)
    imgui_radio("Custom Multi Color##chat_rbt_custom", rbt_mode == "custom", function()
        config.rbt_mode = "custom"
        auto_save_config()
    end)

    if rbt_mode == "single" then
        imgui_input_text("Input Single Color##chat_single_color", config.rbt_single_color, 8, function(v)
            local normalized = normalize_rbt_code(v)
            if normalized then
                config.rbt_single_color = normalized
                auto_save_config()
            end
        end)
    end

    if rbt_mode == "custom" then
        imgui_input_text("Input Customize Color##chat_custom_color", config.rbt_custom_colors, 120, function(v)
            local parsed = parse_rbt_color_list(v or "")
            if #parsed > 0 then
                config.rbt_custom_colors = list_to_rbt_string(parsed)
                auto_save_config()
            end
        end)
    end

    if rbt_mode == "smooth" then
        imgui_input_int("Input Smooth Speed (1-10)##chat_smooth_speed", config.rbt_smooth_speed, 1, 10, function(v)
            config.rbt_smooth_speed = v
            auto_save_config()
        end)
        imgui_input_int("Input Smooth Span (1-10)##chat_smooth_span", config.rbt_smooth_span, 1, 10, function(v)
            config.rbt_smooth_span = v
            auto_save_config()
        end)
    end

    if ImGui and ImGui.Separator then ImGui.Separator() end
    imgui_input_text("Live Preview Text##chat_preview_input", imgui_state.chat_preview_text, 120, function(v)
        imgui_state.chat_preview_text = v
    end)

    local preview_text = tostring(imgui_state.chat_preview_text or "")
    if preview_text == "" then
        preview_text = "Rainbow Text Preview"
    end
    local old_offset = rbt_runtime_offset
    local preview_colored = apply_rbt_to_text(preview_text, true)
    rbt_runtime_offset = old_offset
    imgui_text_colored("Preview", 0.90, 0.90, 0.90, 1.0)
    helpers.RenderImguiGrowtopiaText(preview_colored, {0.95, 0.95, 0.95, 1.0})
    imgui_text_colored("Tip: input format example `e or e, custom list: `4,`9,`2", 0.62, 0.62, 0.62, 1.0)
    if ImGui and ImGui.Separator then ImGui.Separator() end
    if imgui_button("Open Full Rainbow Dialog##chat_open_rbt_dialog") then
        helpers.SetRbtDialog()
    end
end

local function imgui_draw_balance_tab(wl, dl, bgl, black)
    local ok_world, world = pcall(GetWorld)
    local world_name = ok_world and world and stripColors(tostring(world.name or "UNKNOWN")) or "UNKNOWN"
    imgui_text_colored("World Lock: " .. tostring(wl), 0.98, 0.88, 0.20, 1.0)
    imgui_text_colored("Diamond Lock: " .. tostring(dl), 0.56, 0.86, 1.00, 1.0)
    imgui_text_colored("Blue Gem Lock: " .. tostring(bgl), 0.20, 0.37, 0.92, 1.0)
    imgui_text_colored("Black Gem Lock: " .. tostring(black), 0.35, 0.35, 0.35, 1.0)
    if ImGui and ImGui.Separator then ImGui.Separator() end
    imgui_text("Current World: " .. world_name)
    imgui_text("Bank Balance: " .. tostring(config.bank_balance or 0))
    imgui_text("Last Deposit: " .. tostring(config.last_deposit or 0))
    imgui_text("Last Withdraw: " .. tostring(config.last_withdraw or 0))
    imgui_text("Spin Logs: " .. tostring(#(config.tablelogspin or {})) .. " | Command Logs: " .. tostring(#(config.tablelogcommand or {})))
end

function helpers.ImguiDrawAutoPullTab(user_id)
    local numeric_userid = math.floor(tonumber(user_id) or 0)
    if not helpers.IsAutoPullAdminUser(numeric_userid) then
        imgui_text_colored("Auto Pull controls are restricted for this user.", 0.95, 0.48, 0.48, 1.0)
        imgui_text_colored("Use the normal dialogs or log in with an allowed admin userid.", 0.72, 0.72, 0.72, 1.0)
        return
    end

    local target_text = "Not Set"
    if config.auto_pull.target_pos then
        target_text = "(" .. tostring(config.auto_pull.target_pos.x) .. ", " .. tostring(config.auto_pull.target_pos.y) .. ")"
    end

    local blacklist_count = 0
    local seen_blacklist = {}
    for key, value in pairs(config.auto_pull.blacklist or {}) do
        local normalized = tostring(key)
        if value and not seen_blacklist[normalized] then
            seen_blacklist[normalized] = true
            blacklist_count = blacklist_count + 1
        end
    end

    imgui_text_colored("Target Tile: " .. target_text, 0.92, 0.92, 0.92, 1.0)
    imgui_text("Blacklist Entries: " .. tostring(blacklist_count))
    imgui_text("Message Template: " .. (config.wrench_msg_pull ~= "" and stripColors(config.wrench_msg_pull or "") or "(empty)"))

    imgui_checkbox("Enable Auto Pull##ap_enabled", config.auto_pull.enabled, function(v)
        config.auto_pull.enabled = v and true or false
        if config.auto_pull.enabled then
            helpers.SendNotification("`2Auto Pull: `aENABLED")
            helpers.OnConsoleMessage("`2[Auto Pull] Enabled")
            StartAutoPullThread()
        else
            helpers.SendNotification("`4Auto Pull: `cDISABLED")
            helpers.OnConsoleMessage("`4[Auto Pull] Disabled")
            clear_auto_pull_pending()
            auto_pull_state.pulled_users = {}
            auto_pull_state.thread_running = false
        end
        auto_save_config()
    end)
    imgui_input_int("Delay (150-60000ms)##ap_delay", config.auto_pull.delay, 150, 60000, function(v)
        config.auto_pull.delay = v
        auto_save_config()
    end)
    imgui_input_int("Minimum Modal (WL value)##ap_modal", config.auto_pull.min_modal, 0, 1000000000, function(v)
        config.auto_pull.min_modal = v
        auto_save_config()
    end)
    imgui_checkbox("Pull Once Until Leave Tile##ap_once", config.auto_pull.pull_once_until_leave, function(v)
        config.auto_pull.pull_once_until_leave = v and true or false
        auto_save_config()
    end)
    imgui_checkbox("Move After Pull##ap_post_move", config.auto_pull.post_pull_move, function(v)
        config.auto_pull.post_pull_move = v and true or false
        auto_save_config()
    end)
    imgui_checkbox("Send Message After Pull##ap_post_msg", config.auto_pull.post_pull_message, function(v)
        config.auto_pull.post_pull_message = v and true or false
        auto_save_config()
    end)
    imgui_checkbox("Send POST After Pull##ap_post_http", config.auto_pull.post_pull_post, function(v)
        config.auto_pull.post_pull_post = v and true or false
        auto_save_config()
    end)

    if ImGui and ImGui.Separator then ImGui.Separator() end
    local direction = helpers.NormalizeAutoPullDirection(config.auto_pull.direction)
    imgui_text_colored("Direction", 0.92, 0.92, 0.92, 1.0)
    imgui_radio("Right##ap_dir_right", direction == "right", function()
        config.auto_pull.direction = "right"
        auto_save_config()
    end)
    if ImGui and ImGui.SameLine then pcall(ImGui.SameLine) end
    imgui_radio("Left##ap_dir_left", direction == "left", function()
        config.auto_pull.direction = "left"
        auto_save_config()
    end)

    if ImGui and ImGui.Separator then ImGui.Separator() end
    if imgui_button("Pick Target Tile##ap_pick_target") then
        auto_pull_state.setting_position = true
        operation_flags.setting_back_position = false
        helpers.SendNotification("`eTouch a tile to set Auto Pull position...")
        helpers.OnConsoleMessage("`e[Auto Pull] Waiting for tile touch...")
    end
    if ImGui and ImGui.SameLine then pcall(ImGui.SameLine) end
    if imgui_button("Open Full Dialog##ap_open_dialog") then
        helpers.ShowAutoPullDialog()
    end
    if ImGui and ImGui.SameLine then pcall(ImGui.SameLine) end
    if imgui_button("Remove Blacklist##ap_remove_blacklist") then
        helpers.ShowRemoveBlacklistDialog()
    end
end

function helpers.ImguiDrawSettingsTab()
    imgui_text_colored("Panel Settings", 0.92, 0.92, 0.92, 1.0)
    imgui_checkbox("Safe Glyph Fallback##st_safe_glyph", config.imgui_safe_fallback, function(v)
        config.imgui_safe_fallback = v and true or false
        auto_save_config()
    end)
    imgui_text("Current Tab Memory: " .. tostring(config.imgui_last_tab or "command"))
    imgui_text("Icon Mode: " .. tostring(config.ui_icon_mode or "hybrid"))
    imgui_text("Theme Variant: " .. tostring(config.ui_theme_variant or "vibrant_neon"))

    if ImGui and ImGui.Separator then ImGui.Separator() end
    imgui_text_colored("Dialogs & Pages", 0.92, 0.92, 0.92, 1.0)
    if imgui_button("Open Settings Dialog##st_open_settings") then
        helpers.ShowSettings()
    end
    if ImGui and ImGui.SameLine then pcall(ImGui.SameLine) end
    if imgui_button("Change Dialog Color##st_open_bgcolor") then
        helpers.ChangeDialogColor()
    end
    if ImGui and ImGui.SameLine then pcall(ImGui.SameLine) end
    if imgui_button("Open Features##st_open_features") then
        helpers.ProxyFeatures()
    end
    if ImGui and ImGui.SameLine then pcall(ImGui.SameLine) end
    if imgui_button("Proxy Info##st_open_proxy") then
        helpers.ProxyOpen()
    end

    if ImGui and ImGui.Separator then ImGui.Separator() end
    imgui_text_colored("Config Actions", 0.92, 0.92, 0.92, 1.0)
    if imgui_button("Save Config##st_save_config") then
        RunThread(function()
            helpers.SaveConfig(configPath)
        end)
    end
    if ImGui and ImGui.SameLine then pcall(ImGui.SameLine) end
    if imgui_button("Load Config##st_load_config") then
        RunThread(function()
            helpers.LoadConfig(configPath)
        end)
    end
    if ImGui and ImGui.SameLine then pcall(ImGui.SameLine) end
    if imgui_button("Open Logs##st_open_logs") then
        helpers.MenuLogs()
    end

    if ImGui and ImGui.Separator then ImGui.Separator() end
    imgui_text_colored("Notes", 0.92, 0.92, 0.92, 1.0)
    imgui_text_colored("Safe fallback keeps sidebar labels readable on builds without merged icon fonts.", 0.70, 0.78, 0.88, 1.0)
    imgui_text_colored("For full icon font mode, the runtime still needs a merged atlas with the required glyphs.", 0.70, 0.78, 0.88, 1.0)
end

local function imgui_draw_active_tab(is_owner, user_id, wl, dl, bgl, black)
    local can_auto_pull = helpers.IsAutoPullAdminUser(user_id)
    if imgui_state.active_tab == "command" then
        imgui_set_style_section("command")
        imgui_draw_command_tab(can_auto_pull)
    elseif imgui_state.active_tab == "wrench" then
        imgui_set_style_section("wrench")
        imgui_draw_wrench_tab()
    elseif imgui_state.active_tab == "utility" then
        imgui_set_style_section("utility")
        imgui_draw_utility_tab()
    elseif imgui_state.active_tab == "teleport" then
        imgui_set_style_section("teleport")
        imgui_draw_teleport_tab()
    elseif imgui_state.active_tab == "casino" then
        imgui_set_style_section("casino")
        imgui_draw_casino_tab()
    elseif imgui_state.active_tab == "chat" then
        imgui_set_style_section("chat")
        imgui_draw_chat_tab()
    elseif imgui_state.active_tab == "balance" then
        imgui_set_style_section("balance")
        imgui_draw_balance_tab(wl, dl, bgl, black)
    elseif imgui_state.active_tab == "auto_pull" then
        imgui_set_style_section("auto_pull")
        helpers.ImguiDrawAutoPullTab(user_id)
    elseif imgui_state.active_tab == "settings" then
        imgui_set_style_section("settings")
        helpers.ImguiDrawSettingsTab()
    else
        helpers.SetImguiActiveTab("command")
        imgui_set_style_section("command")
        imgui_draw_command_tab(can_auto_pull)
    end
end

local function draw_exproxy_imgui_menu()
    if not imgui_state.visible or not is_imgui_supported() then
        return false
    end

    local ok, err = pcall(function()
        if ImGui.SetNextWindowSizeConstraints and type(ImVec2) == "function" then
            pcall(ImGui.SetNextWindowSizeConstraints, ImVec2(760, 500), ImVec2(4000, 4000))
        end

        if ImGui.SetNextWindowSize and type(ImVec2) == "function" then
            if ImGui.Cond and ImGui.Cond.FirstUseEver then
                pcall(ImGui.SetNextWindowSize, ImVec2(900, 620), ImGui.Cond.FirstUseEver)
            elseif not imgui_state.size_initialized then
                pcall(ImGui.SetNextWindowSize, ImVec2(900, 620))
                imgui_state.size_initialized = true
            end
        end

        local window_visible = true
        local begin_ok = ImGui.Begin("ExProxy Control Panel")
        if type(begin_ok) == "boolean" then
            window_visible = begin_ok
        end

        if window_visible then
            local ok_local, localPlayer = pcall(GetLocal)
            if not ok_local then
                localPlayer = nil
            end
            local user_name = stripColors(tostring((localPlayer and localPlayer.name) or "Unknown"))
            local user_id = math.floor((localPlayer and localPlayer.userid) or 0)
            local is_owner = is_owner_userid(user_id)
            local can_auto_pull = helpers.IsAutoPullAdminUser(user_id)
            local ok_world, world = pcall(GetWorld)
            local world_name = ok_world and world and stripColors(tostring(world.name or "UNKNOWN")) or "UNKNOWN"
            local wrench_mode = string.upper(imgui_current_wrench_mode())

            local wl = math.floor(GetItemCount(ITEM_IDS.WORLD_LOCK) or 0)
            local dl = math.floor(GetItemCount(ITEM_IDS.DIAMOND_LOCK) or 0)
            local bgl = math.floor(GetItemCount(ITEM_IDS.BLUE_GEM_LOCK) or 0)
            local black = math.floor(GetItemCount(ITEM_IDS.BLACK_GEM_LOCK) or 0)

            if not can_auto_pull and imgui_state.active_tab == "auto_pull" then
                helpers.SetImguiActiveTab("command")
            end

            imgui_text_colored("ExProxy Control Panel", 0.82, 0.90, 1.00, 1.0)
            imgui_text("User: " .. user_name .. " | UID: " .. tostring(user_id))
            imgui_text("World: " .. world_name .. " | Wrench: " .. wrench_mode .. " | Auto Pull: " .. (config.auto_pull.enabled and "ON" or "OFF"))
            imgui_text("Resize freely. Dialogs remain the primary safe flow for complex actions.")
            if imgui_state.last_tab_error ~= "" then
                local now_ms = math.floor(os.clock() * 1000)
                if (now_ms - (imgui_state.last_tab_error_ms or 0)) <= 12000 then
                    imgui_text_colored("Last content warning: " .. tostring(imgui_state.last_tab_error), 0.95, 0.58, 0.42, 1.0)
                end
            end
            if ImGui and ImGui.Separator then
                pcall(ImGui.Separator)
            end

            local has_child_layout = ImGui and ImGui.BeginChild and ImGui.EndChild and type(ImVec2) == "function"
            local use_split_layout = has_child_layout
            local sidebar_width = 220
            local ui_theme = imgui_get_theme()
            local visible_tabs = {}
            for _, tab in ipairs(IMGUI_TABS) do
                if tab.id ~= "auto_pull" or can_auto_pull then
                    table.insert(visible_tabs, tab)
                end
            end

            if ImGui.GetWindowSize then
                local ok_wsize, wsize = pcall(ImGui.GetWindowSize)
                if wsize and wsize.x and wsize.x < 860 then
                    use_split_layout = false
                end
            end

            if use_split_layout and ImGui.GetContentRegionAvail then
                local ok_avail, avail = pcall(ImGui.GetContentRegionAvail)
                if avail and avail.x then
                    sidebar_width = math.floor(avail.x * 0.26)
                    if sidebar_width < 180 then sidebar_width = 180 end
                    if sidebar_width > 240 then sidebar_width = 240 end
                end
            end

            local layout_drawn = false
            if use_split_layout then
                local split_ok, split_err = pcall(function()
                    local sidebar_style_pushed = imgui_push_style_colors({
                        {"Col_ChildBg", ui_theme.sidebar_bg},
                        {"Col_Border", imgui_mix_color(ui_theme.sidebar_subtitle, 0.55, 0.62)},
                        {"Col_Separator", imgui_mix_color(ui_theme.sidebar_subtitle, 0.8, 0.82)}
                    })

                    ImGui.BeginChild("exproxy_sidebar", ImVec2(sidebar_width, 0), true)
                    imgui_text_colored("ExProxy", ui_theme.sidebar_title[1], ui_theme.sidebar_title[2], ui_theme.sidebar_title[3], ui_theme.sidebar_title[4])
                    imgui_text_colored("Navigation", ui_theme.sidebar_subtitle[1], ui_theme.sidebar_subtitle[2], ui_theme.sidebar_subtitle[3], ui_theme.sidebar_subtitle[4])
                    if ImGui.Separator then pcall(ImGui.Separator) end
                    for _, tab in ipairs(visible_tabs) do
                        imgui_sidebar_item(tab)
                    end
                    ImGui.EndChild()

                    imgui_pop_style_colors(sidebar_style_pushed)

                    if ImGui.SameLine then
                        pcall(ImGui.SameLine)
                    end

                    ImGui.BeginChild("exproxy_content", ImVec2(0, 0), true)
                    local tab_ok, tab_err = pcall(imgui_draw_active_tab, is_owner, user_id, wl, dl, bgl, black)
                    if not tab_ok then
                        imgui_state.last_tab_error = tostring(tab_err)
                        imgui_state.last_tab_error_ms = math.floor(os.clock() * 1000)
                        imgui_text_colored("Content error. Switched to safe render mode for this frame.", 0.95, 0.48, 0.48, 1.0)
                    end
                    ImGui.EndChild()
                end)

                if split_ok then
                    layout_drawn = true
                else
                    imgui_state.last_tab_error = "Layout fallback: " .. tostring(split_err)
                    imgui_state.last_tab_error_ms = math.floor(os.clock() * 1000)
                end
            end

            if not layout_drawn then
                imgui_text_colored("Compact mode: window too small for split layout.", 0.85, 0.70, 0.35, 1.0)
                imgui_text_colored("Tabs", ui_theme.compact_title[1], ui_theme.compact_title[2], ui_theme.compact_title[3], ui_theme.compact_title[4])
                for _, tab in ipairs(visible_tabs) do
                    imgui_sidebar_item(tab)
                end
                if ImGui and ImGui.Separator then
                    pcall(ImGui.Separator)
                end
                local tab_ok, tab_err = pcall(imgui_draw_active_tab, is_owner, user_id, wl, dl, bgl, black)
                if not tab_ok then
                    imgui_state.last_tab_error = tostring(tab_err)
                    imgui_state.last_tab_error_ms = math.floor(os.clock() * 1000)
                    imgui_text_colored("Content error: " .. tostring(tab_err), 0.95, 0.48, 0.48, 1.0)
                end
            end
        end

        ImGui.End()
    end)

    if not ok then
        imgui_state.visible = false
        local now_ms = math.floor(os.clock() * 1000)
        local err_text = tostring(err)
        if imgui_state.last_error_text ~= err_text or (now_ms - (imgui_state.last_error_ms or 0)) > 3000 then
            imgui_state.last_error_text = err_text
            imgui_state.last_error_ms = now_ms
            helpers.OnConsoleMessage("`4[ImGui] Draw error: `w" .. err_text)
            helpers.OnTextOverlay("`4ImGui panel disabled (draw error).")
        end
    end

    return false
end

-- Dialog for customizing drop commands
function helpers.ShowCustomCommandDialog()
    local dialog = [[
set_default_color|`o
set_border_color|]] .. config.dialogBorder .. [[|
set_bg_color|]] .. config.dialogBg .. [[|

add_label_with_icon|big|`eCustomize Drop Commands|left|242|
add_spacer|small|
add_textbox|`7Customize your drop command shortcuts below:|left|
add_smalltext|`9After saving, commands will update immediately|left|
add_spacer|small|

add_label_with_icon|small|`9World Lock Command|left|242|
add_text_input|cmd_wl|/|]] .. config.cmd_drop_wl .. [[|10|
add_smalltext|`7Example: /]] .. config.cmd_drop_wl .. [[ 100 = Drop 100 WL|left|
add_spacer|small|

add_label_with_icon|small|`1Diamond Lock Command|left|1796|
add_text_input|cmd_dl|/|]] .. config.cmd_drop_dl .. [[|10|
add_smalltext|`7Example: /]] .. config.cmd_drop_dl .. [[ 100 = Drop 100 DL|left|
add_spacer|small|

add_label_with_icon|small|`eBlue Gem Lock Command|left|7188|
add_text_input|cmd_bgl|/|]] .. config.cmd_drop_bgl .. [[|10|
add_smalltext|`7Example: /]] .. config.cmd_drop_bgl .. [[ 100 = Drop 100 BGL|left|
add_spacer|small|

add_label_with_icon|small|`bBlack Gem Lock Command|left|11550|
add_text_input|cmd_black|/|]] .. config.cmd_drop_black .. [[|10|
add_smalltext|`7Example: /]] .. config.cmd_drop_black .. [[ 5 = Drop 5 Black|left|
add_spacer|small|

add_textbox|`9Note: Commands are case-sensitive and should be short (1-10 chars)|left|
add_spacer|small|

end_dialog|custom_cmd|Cancel|Save Commands|
]]
    
    SendVariantList({[0] = "OnDialogRequest", [1] = dialog, netid = -1})
end

local function ShowSettings()
    local settingsDialog = [[
set_default_color|`o
set_border_color|]] .. config.dialogBorder .. [[|
set_bg_color|]] .. config.dialogBg .. [[|

add_label_with_icon|big|`eJzProxy Settings Overview|left|6016|
add_spacer|small|
add_textbox|`7View all current configuration values and their status|left|
add_spacer|small|

add_label_with_icon|small|`2Toggle Features (Boolean)|left|758|
add_spacer|small|
]]

    -- Boolean configs (Main Features)
    local booleanConfigs = {
        {key = "notif", label = "Notifications"},
        {key = "acrime", label = "Auto Crime"},
        {key = "pull", label = "Auto Pull"},
        {key = "kick", label = "Auto Kick"},
        {key = "ban", label = "Auto Ban"},
        {key = "showbal", label = "Show Balance"},
        {key = "antiSpammerSlave", label = "Anti Spammer Slave"},
        {key = "antiLagEnabled", label = "Anti Lag"},
        {key = "fasttrash", label = "Fast Trash"},
        {key = "cvptu", label = "Convert Tax to UWS"},
        {key = "fastdb", label = "Fast DB"},
        {key = "buydl", label = "Buy DL"},
        {key = "buychamp", label = "Buy Champagne"},
        {key = "autoJoinDetect", label = "Auto Join Detect"},
        {key = "autoGemDetect", label = "Auto Gem Detector"},
        {key = "autoToggleDoor", label = "Auto Toggle Door"},
        {key = "copy_sign_mode", label = "Copy Sign Mode"},
        {key = "auto_copy_sign", label = "Auto Copy Sign"},
        {key = "bsdb", label = "Block SDB"},
        {key = "tpdisplay", label = "TP Display"},
        {key = "blink_skin", label = "Blink Skin"},
        {key = "rainbow_text", label = "Rainbow Text"},
        {key = "emoji_text", label = "Emoji Text"},
        {key = "wdvend", label = "WD Vend"},
        {key = "emptyvend", label = "Empty Vend"},
        {key = "autocvdl", label = "Convert DL When Collecting"},
    }

    for _, item in ipairs(booleanConfigs) do
        local value = config[item.key]
        if type(value) == "boolean" then
            local status = value and "`2ON" or "`4OFF"
            settingsDialog = settingsDialog .. string.format(
                "add_smalltext|`w%s: %s`o|left|\n",
                item.label, status
            )
        end
    end

    settingsDialog = settingsDialog .. [[
add_spacer|small|

add_label_with_icon|small|`eGame Modes|left|11550|
add_spacer|small|
]]

    -- Game mode configs
    local gameModes = {
        {key = "reme", label = "Reme Mode"},
        {key = "leme", label = "Leme Mode"},
        {key = "lemesuper", label = "Leme Super Mode"},
        {key = "qeme", label = "Qeme Mode"},
        {key = "ceme", label = "Ceme Mode"},
        {key = "lewa", label = "Lewa Mode"},
        {key = "cbgl", label = "Convert BGL"}
    }

    for _, item in ipairs(gameModes) do
        local value = config[item.key]
        if type(value) == "boolean" then
            local status = value and "`2ON" or "`4OFF"
            settingsDialog = settingsDialog .. string.format(
                "add_smalltext|`w%s: %s`o|left|\n",
                item.label, status
            )
        end
    end

    settingsDialog = settingsDialog .. [[
add_spacer|small|

add_label_with_icon|small|`6Broadcast Settings|left|2480|
add_spacer|small|
]]

    -- Broadcast configs
    settingsDialog = settingsDialog .. string.format("add_smalltext|`wBroadcast Active: %s`o|left|\n", 
        config.broadcast and "`2ON" or "`4OFF")
    settingsDialog = settingsDialog .. string.format("add_smalltext|`wOnce Broadcast: %s`o|left|\n", 
        config.once_broadcast and "`2ON" or "`4OFF")
    settingsDialog = settingsDialog .. string.format("add_smalltext|`wSpam Broadcast: %s`o|left|\n", 
        config.spam_broadcast_mode and "`2ON" or "`4OFF")
    settingsDialog = settingsDialog .. string.format("add_smalltext|`wWatermark Mode: %s`o|left|\n", 
        config.watermark_mode and "`2ON" or "`4OFF")
    
    local displayText = config.textsb or "Not Set"
    if #displayText > 40 then
        displayText = string.sub(displayText, 1, 40) .. "..."
    end
    settingsDialog = settingsDialog .. string.format("add_smalltext|`wBroadcast Text: `e%s`o|left|\n", displayText)
    
    settingsDialog = settingsDialog .. string.format("add_smalltext|`wWatermark: `e%s`o|left|\n", 
        config.watermark_text or "Not Set")
    settingsDialog = settingsDialog .. string.format("add_smalltext|`wBroadcast Amount: `6%s`o|left|\n", 
        tostring(config.broadcast_amount or 20))

    settingsDialog = settingsDialog .. [[
add_spacer|small|

add_label_with_icon|small|`9Other Configurations|left|13808|
add_spacer|small|
]]

    -- Other important configs
    settingsDialog = settingsDialog .. string.format("add_smalltext|`wVersion: `e%s`o|left|\n", 
        config.CURRENT_VERSION or "Unknown")
    
    local displaySpam = config.spammsg or "Not Set"
    if #displaySpam > 40 then
        displaySpam = string.sub(displaySpam, 1, 40) .. "..."
    end
    settingsDialog = settingsDialog .. string.format("add_smalltext|`wSpam Message: `e%s`o|left|\n", displaySpam)
    
    settingsDialog = settingsDialog .. string.format("add_smalltext|`wSpam Delay: `6%s ms`o|left|\n", 
        tostring(config.spamdelay or 0))
    settingsDialog = settingsDialog .. string.format("add_smalltext|`wSpam Delay T1/T2/T3: `6%s / %s / %s ms`o|left|\n",
        tostring(config.spamdelay1 or config.spamdelay or 0),
        tostring(config.spamdelay2 or config.spamdelay or 0),
        tostring(config.spamdelay3 or config.spamdelay or 0))
    settingsDialog = settingsDialog .. string.format("add_smalltext|`wBank Balance: `6%s`o|left|\n", 
        tostring(config.bank_balance or 0))
    settingsDialog = settingsDialog .. string.format("add_smalltext|`wLast Deposit: `6%s`o|left|\n", 
        tostring(config.last_deposit or 0))
    settingsDialog = settingsDialog .. string.format("add_smalltext|`wLast Withdraw: `6%s`o|left|\n", 
        tostring(config.last_withdraw or 0))

    settingsDialog = settingsDialog .. [[
add_spacer|small|

add_label_with_icon|small|`eCustom Drop Commands|left|242|
add_spacer|small|
add_smalltext|`wWorld Lock: `9/]] .. config.cmd_drop_wl .. [[`o|left|
add_smalltext|`wDiamond Lock: `9/]] .. config.cmd_drop_dl .. [[`o|left|
add_smalltext|`wBlue Gem Lock: `9/]] .. config.cmd_drop_bgl .. [[`o|left|
add_smalltext|`wBlack Gem Lock: `9/]] .. config.cmd_drop_black .. [[`o|left|
add_spacer|small|
add_small_font_button|customize_commands|`2Customize Commands|noflags|0|0|
add_spacer|small|

add_label_with_icon|small|`4Logs Status|left|242|
add_spacer|small|
add_smalltext|`wLog Spin: ]] .. (config.logspin and "`2ON" or "`4OFF") .. [[`o|left|
add_smalltext|`wLog Command: ]] .. (config.logcommand and "`2ON" or "`4OFF") .. [[`o|left|
add_smalltext|`wLog Drop Enable: ]] .. (config.logdrop_enable and "`2ON" or "`4OFF") .. [[`o|left|
add_smalltext|`wSpin Logs Count: `2]] .. #config.tablelogspin .. [[`o|left|
add_smalltext|`wCommand Logs Count: `2]] .. #config.tablelogcommand .. [[`o|left|
add_spacer|small|

add_quick_exit||
end_dialog|settings_dialog|Close||
]]

    local varlist = {
        [0] = "OnDialogRequest",
        [1] = settingsDialog,
        netid = -1
    }
    SendVariantList(varlist)
end
helpers.ShowSettings = ShowSettings

function helpers.MenuLogs()
    local logm = [[
set_default_color|`o
set_border_color|]] .. config.dialogBorder .. [[|
set_bg_color|]] .. config.dialogBg .. [[|

add_label_with_icon|big|`3Logs Panel|left|1436|
add_spacer|small|

add_label_with_icon|small|`9Spin Logs|left|758|
add_small_font_button|spin_logs|`eRoulette Wheel Logs|noflags|0|0|
add_smalltext|`7Check all roulette wheel results and history.|
add_spacer|small|

add_textbox|`7Here you can review all actions recorded by the proxy.|
add_label_with_icon|small|`6Collection Logs|left|13808|
add_small_font_button|coll|`wCollected Items|noflags|0|0|
add_smalltext|`7View collected gems, packs, and more.|
add_spacer|small|

add_label_with_icon|small|`2Drop Logs|left|13810|
add_small_font_button|drop_logs|`aDropped Items|noflags|0|0|
add_smalltext|`7See items you’ve dropped recently.|
add_spacer|small|

add_label_with_icon|small|`4Reset Options|left|16294|
add_spacer|small|
]] .. (log_backup.undo_available and (300 - (os.time() - log_backup.backup_time) > 0 and "add_button|undo_reset|`2Undo Last Reset (`e" .. math.floor(300 - (os.time() - log_backup.backup_time)) .. "s`2)|noflags|0|0|\nadd_smalltext|`9Restore logs from last reset operation.|left|\nadd_spacer|small|\n" or "") or "") .. [[
add_button|selective_reset|`eSelective Reset|noflags|0|0|
add_smalltext|`9Choose which logs to reset (recommended).|left|
add_spacer|small|

add_button|resetall|`4Reset All Logs|noflags|0|0|
add_smalltext|`4Delete all logs permanently (with backup).|left|
add_spacer|small|

add_quick_exit||
end_dialog|ah|Cancel||
]]
    local varlist = {[0] = "OnDialogRequest", [1] = logm, netid = -1}
    SendVariantList(varlist)
end

-- ============ NEW: SELECTIVE LOG MANAGEMENT ============

function helpers.SelectiveResetDialog()
    local spin_count = #(config.tablelogspin or {})
    local drop_lines = config.logdrop and #config.logdrop > 0 and select(2, config.logdrop:gsub('\n', '\n')) + 1 or 0
    local collect_lines = config.logcollect and #config.logcollect > 0 and select(2, config.logcollect:gsub('\n', '\n')) + 1 or 0
    local command_count = #(config.tablelogcommand or {})
    
    local dialog = [[
set_default_color|`o
set_border_color|]] .. config.dialogBorder .. [[|
set_bg_color|]] .. config.dialogBg .. [[|

text_scaling_string|jjjjjjjjjjjjjjjjjjjjjjjjjjjj|

add_label_with_icon|big|`eSelective Log Reset|left|16294|
add_spacer|small|

add_textbox|`7Select which logs you want to reset. Unchecked logs will be preserved.|
add_spacer|small|

add_label_with_icon|small|`2Select Logs to Reset|left|1436|
add_spacer|small|

add_checkbox|reset_spin|`9Spin Logs (`2]] .. spin_count .. [[ entries`9)|0|
add_smalltext|`7Roulette wheel history and results.|left|
add_spacer|small|

add_checkbox|reset_drop|`4Drop Logs (`2]] .. drop_lines .. [[ lines`4)|0|
add_smalltext|`7Items you've dropped recently.|left|
add_spacer|small|

add_checkbox|reset_collect|`6Collect Logs (`2]] .. collect_lines .. [[ lines`6)|0|
add_smalltext|`7Items you've collected.|left|
add_spacer|small|

add_checkbox|reset_command|`eCommand Logs (`2]] .. command_count .. [[ entries`e)|0|
add_smalltext|`7Command execution history.|left|
add_spacer|small|

add_checkbox|create_backup|`2Create Backup Before Reset|1|
add_smalltext|`9Allows undo within 5 minutes (recommended).|left|
add_spacer|small|

add_textbox|`4Warning: `wThis action will delete selected logs!|
add_spacer|small|

text_scaling_string|jjjjjjjjjjjjjjjjjjjjjjjjjjjj|

add_quick_exit||
end_dialog|selective_reset_dlg|Cancel|`4Reset Selected|
]]

    SendVariantList({[0] = "OnDialogRequest", [1] = dialog, netid = -1})
end

function helpers.BackupLogs()
    log_backup.spin_logs = {}
    for i, v in ipairs(config.tablelogspin or {}) do
        log_backup.spin_logs[i] = {spin = v.spin}
    end
    
    log_backup.drop_logs = config.logdrop or ""
    log_backup.collect_logs = config.logcollect or ""
    
    log_backup.command_logs = {}
    for i, v in ipairs(config.tablelogcommand or {}) do
        log_backup.command_logs[i] = v
    end
    
    log_backup.backup_time = os.time()
    log_backup.undo_available = true
    
    helpers.OnConsoleMessage("`2[Logs] `wBackup created successfully!")
end

function helpers.RestoreLogs()
    if not log_backup.undo_available then
        helpers.OnTextOverlay("`4No backup available to restore!")
        return
    end
    
    local time_since_backup = os.time() - log_backup.backup_time
    if time_since_backup > 300 then -- 5 menit
        helpers.OnTextOverlay("`4Backup expired! (>5 minutes)")
        log_backup.undo_available = false
        return
    end
    
    -- Restore logs
    config.tablelogspin = {}
    for i, v in ipairs(log_backup.spin_logs or {}) do
        config.tablelogspin[i] = {spin = v.spin}
    end
    
    config.logdrop = log_backup.drop_logs or ""
    config.logcollect = log_backup.collect_logs or ""
    
    config.tablelogcommand = {}
    for i, v in ipairs(log_backup.command_logs or {}) do
        config.tablelogcommand[i] = v
    end
    
    log_backup.undo_available = false
    
    helpers.OnConsoleMessage("`2[Logs] `wLogs restored successfully!")
    helpers.OnTextOverlay("`2Logs restored from backup!")
end

function helpers.MenuDropLogs()
    local dropLogDialog = [[
set_default_color|`o
set_border_color|]] .. config.dialogBorder .. [[|
set_bg_color|]] .. config.dialogBg .. [[|

add_label_with_icon|big|`3Drop Logs Panel|left|13810|
add_spacer|small|
add_textbox|`7Here you can review all items you’ve dropped recently.|

add_label_with_icon|small|`2Drop Logs|left|13810|
add_textbox|`w]] .. (config.logdrop or "`7No drop logs available.") .. [[`|

add_spacer|small|
add_quick_exit||
end_dialog|drop_logs|Close|
]]

    local varlist = {
        [0] = "OnDialogRequest",
        [1] = dropLogDialog,
        netid = -1
    }

    SendVariantList(varlist)
end

function helpers.MenuDropLogs()
    local dropLogContent = config.logdrop or ""
    if dropLogContent == "" then
        dropLogContent = "add_smalltext|`7No drop logs available.|left|\n"
    else
        local converted = {}
        for line in dropLogContent:gmatch("[^\n]+") do
            if line ~= "" then
                if line:find("^add_", 1, false) then
                    table.insert(converted, line)
                else
                    table.insert(converted, "add_smalltext|`w" .. line .. "|left|")
                end
            end
        end
        if #converted > 0 then
            dropLogContent = table.concat(converted, "\n") .. "\n"
        else
            dropLogContent = "add_smalltext|`7No drop logs available.|left|\n"
        end
    end

    local dropLogDialog = [[
set_default_color|`o
set_border_color|]] .. config.dialogBorder .. [[|
set_bg_color|]] .. config.dialogBg .. [[|

add_label_with_icon|big|`3Drop Logs Panel|left|13810|
add_spacer|small|
add_smalltext|`9This panel shows all items you have `4dropped`9 in this session.|left|
add_smalltext|`4Warning: `wDrop logs are temporary and may be trimmed after many entries.|left|
add_spacer|small|
add_button|resetd|`4Reset Logs|noflags|0|0|
add_smalltext|`8(Reset will clear all dropped logs permanently)|left|
add_spacer|small|

add_label_with_icon|small|`2Drop Logs|left|13810|
]] .. dropLogContent .. [[

add_spacer|small|
add_quick_exit||
end_dialog|drop_logs|Close|
]]

    local varlist = {
        [0] = "OnDialogRequest",
        [1] = dropLogDialog,
        netid = -1
    }

    SendVariantList(varlist)
end

function helpers.CollectLog()
    local DialogCollect = [[
set_default_color|`o
set_border_color|]] .. config.dialogBorder .. [[|
set_bg_color|]] .. config.dialogBg .. [[|

add_label_with_icon|big|`2Collected Logs`` |left|1436|
add_spacer|small|
add_smalltext|`9This panel shows all items you have `2collected`9 in this session.|
add_smalltext|`4Warning: `wCollected logs are temporary and will reset when you leave the world.|
add_spacer|small|
add_button|resetc|`4Reset Logs|noflags|0|
add_smalltext|`8(Reset will clear all collected logs permanently)|
add_spacer|small|
]] .. config.logcollect .. [[
add_spacer|small|
add_quick_exit||
end_dialog|logcollect|Close||
]]
    local varlist = {[0] = "OnDialogRequest", [1] = DialogCollect, netid = -1}
    SendVariantList(varlist)
end

function helpers.SpinLog()
    local dialogSpin = {}

    local function getTimeWithZone()
        local hour = tonumber(os.date("%H"))
        local minute = os.date("%M")
        local second = os.date("%S")
        local dateStr = os.date("%Y-%m-%d")

        local zone = "WIB" -- default zone
        if hour >= 8 and hour < 10 then
            zone = "WITA" -- contoh kondisi untuk WITA
        end

        return string.format("%s %02d:%02d:%02d %s", dateStr, hour, minute, second, zone)
    end

    for _, spin in pairs(config.tablelogspin) do
        local logTime = getTimeWithZone()
        table.insert(dialogSpin, "`7[" .. logTime .. "] `w" .. spin.spin)
    end

    local varlist = {
        [0] = "OnDialogRequest",
        [1] = [[
set_default_color|`o
set_border_color|]] .. config.dialogBorder .. [[|
set_bg_color|]] .. config.dialogBg .. [[|

add_label_with_icon|big|`3Roulette Logs|left|1436|
add_spacer|small|
add_textbox|`7This panel shows all recorded spins with timestamps.|
add_textbox|`9Use this to `etrack results`9 and analyze the game.|

add_label_with_icon|small|`4Warning|left|3732|
add_button|resets|`4Reset Logs|noflags|0|
add_smalltext|`cThis will `4delete all spin logs permanently!`c|
add_smalltext|`9Note: Logs will `2auto-reset `9when you leave the world.|
add_spacer|small|

add_label_with_icon|small|`qHow To Use|left|758|
add_smalltext|`7Click on the Wheel Button to filter logs for a specific player.|
add_smalltext|`9Logs are displayed below in real-time:|
add_spacer|small|

]] .. table.concat(dialogSpin) .. [[

add_spacer|small|
add_quick_exit||
end_dialog|logah|Close||
        ]],
        netid = -1
    }
    SendVariantList(varlist)
end
local function formatGems(num)
    local formatted = tostring(num)
    while true do
        formatted, k = formatted:gsub("^(-?%d+)(%d%d%d)", "%1.%2")
        if k == 0 then break end
    end
    return formatted
end

function helpers.JzBroadcast()
    local startBtn = ""
    local stopBtn = ""
    local statusColor = "`4"
    local statusText = "Idle"
    
    if not config.broadcast then
        startBtn = "add_button|broadcast_start|`2Start Broadcast|noflags|0|0|\n"
    end
    
    if config.broadcast then
        stopBtn = "add_button|broadcast_stop|`4Stop Broadcast|noflags|0|0|\n"
        statusColor = "`2"
        statusText = "Running"
    end
    
    -- Ambil informasi pemain
    local localPlayer = GetLocal()
    local world = GetWorld()
    local growid = stripColors(tostring(localPlayer.name or "Unknown"))
    local worldName = tostring(world.name or "Unknown")
    local gems = formatGems(GetPlayerInfo().gems or 0)
    
    -- Auto copy sign status
    local autoCopyStatus = (config.textsb and config.textsb ~= "") and "`4OFF (Text Exists)" or "`2ON (Auto Copy)"
    
    local broadcastDialog = [[
set_default_color|`o
set_border_color|]] .. config.dialogBorder .. [[|
set_bg_color|]] .. config.dialogBg .. [[|

text_scaling_string|jjjjjjjjjjjjjjjjjjjjjjjjjjjj|

add_label_with_icon|big|`6Super Broadcast Manager|left|2480|
add_spacer|small|

add_textbox|`7Welcome to the easy-to-use broadcast manager! This tool helps you automate your SB with advanced features.|
add_spacer|small|

add_label_with_icon|small|`9Your Information|left|758|
add_spacer|small|
add_textbox|`7GrowID: `w]] .. growid .. [[|
add_textbox|`7World: `w]] .. worldName .. [[|
add_textbox|`7Gems: `e]] .. gems .. [[|
add_textbox|`7Status: ]] .. statusColor .. statusText .. [[`o|
add_textbox|`7Broadcast Count: `2]] .. config.broadcast_counter .. [[`o|
add_spacer|small|

add_label_with_icon|small|`2Broadcast Text|left|242|
add_spacer|small|
add_text_input|textsb|Enter your SB text:|]] .. (config.textsb or "") .. [[|150|4|
add_smalltext|`9Tip: Leave empty to auto-copy from any sign you wrench!|
add_spacer|small|

add_label_with_icon|small|`eMode Settings|left|5260|
add_spacer|small|
add_textbox|`7Choose how you want to broadcast:|
add_spacer|small|

add_checkbox|once_broadcast|`9Once Only Mode|]] .. ((config.once_broadcast and "1") or "0") .. [[|
add_smalltext|`7Send broadcast only one time then stop|
add_spacer|small|

add_checkbox|spam_broadcast_mode|`6Scheduled Spam Mode|]] .. ((config.spam_broadcast_mode and "1") or "0") .. [[|
add_smalltext|`7Spam multiple times within 1 hour period|
add_spacer|small|

add_text_input|broadcast_amount|Spam Amount:|]] .. (config.broadcast_amount or 20) .. [[|5|
add_smalltext|`9How many times to broadcast in 1 hour (1-100)|
add_spacer|small|

add_text_input|broadcast_delay|Send Delay (ms):|]] .. (config.broadcast_delay or 250) .. [[|5|
add_smalltext|`9Wait time before sending SB (250-1000ms recommended)|
add_spacer|small|

add_label_with_icon|small|`#Extra Features|left|13808|
add_spacer|small|

add_checkbox|watermark_mode|`9Add Watermark|]] .. ((config.watermark_mode and "1") or "0") .. [[|
add_text_input|watermark_text|Watermark:|]] .. (config.watermark_text or "`6[ `eJz`qSB`6 ]") .. [[|80|
add_smalltext|`7Adds custom text at the end of broadcast|
add_spacer|small|

add_checkbox|auto_copy_sign|`eAuto Copy Sign|]] .. ((config.auto_copy_sign and "1") or "0") .. [[|
add_smalltext|`7]] .. autoCopyStatus .. [[ - Automatically copy text when wrench sign|
add_spacer|small|

add_label_with_icon|small|`1Webhook Monitoring|left|16238|
add_spacer|small|
add_textbox|`7Track your broadcasts in Discord with real-time notifications!|
add_spacer|small|

add_checkbox|webhook_enable|`2Enable Webhook|]] .. ((config.broadcast_webhook_enable and "1") or "0") .. [[|
add_smalltext|`9Turn ON to receive notifications in Discord|
add_spacer|small|

add_text_box_input|webhook_url|Discord Webhook URL:|]] .. (config.broadcast_webhook_url or "") .. [[|500|8|
add_smalltext|`7Paste your Discord webhook URL here|
add_smalltext|`9How to get webhook: Server Settings -> Integrations -> Create Webhook|
add_spacer|small|

add_label_with_icon|small|`4Statistics|left|1436|
add_spacer|small|
add_textbox|`7Total Broadcasts Sent: `2]] .. config.broadcast_counter .. [[`o|
add_smalltext|`9This counter tracks all broadcasts in current session|
add_button|reset_counter|`4Reset Counter|noflags|0|0|
add_spacer|small|

text_scaling_string|jjjjjjjjjjjjjjjjjjjjjjjjjjjj|

]] .. startBtn .. stopBtn .. [[
add_spacer|small|

add_textbox|`4Important Notes:|
add_smalltext|`7• Once & Spam modes cannot be enabled together|
add_smalltext|`7• Auto copy works only when broadcast text is empty|
add_smalltext|`7• Webhook requires valid Discord webhook URL|
add_smalltext|`7• System will auto-say "SB X/Total (megaphone)" after each broadcast|
add_spacer|small|

end_dialog|broadcast_dlg|`4Close|`2Save Settings|
]]
    
    local varlist = {
        [0] = "OnDialogRequest",
        [1] = broadcastDialog,
        netid = -1
    }
    SendVariantList(varlist)
end

function helpers.Spammer()
    local startBtn = ""
    local stopBtn = ""

    if not config.spam then
        startBtn = "add_inner_image_label_button|spam_start|`2Start Spam|game/custom_tiles3.rttex|1.6|16|9|32|\n"
    end

    if config.spam then
        stopBtn = "add_inner_image_label_button|spam_stop|`4Stop Spam|game/custom_tiles3.rttex|1.6|18|4|32|\n"
    end

    local spamDialog = [[
set_default_color|`o
set_border_color|]] .. config.dialogBorder .. [[|
set_bg_color|]] .. config.dialogBg .. [[|
add_label_with_icon|big|`6JzProxy Text Spammer````|left|16432|
add_label|small|Enter the text you want to spam:|left|
max_check|1
add_label_with_icon|small|`cSpam Text 1|left|16432|
add_text_input|spam_text_1|Text 1:|]] .. (config.spamText1 or "") .. [[|100|
add_checkbox|use_spam_1|Use Text 1|]] .. (config.useSpam1 and 1 or 0) .. [[|
add_text_input|spamdelay_1|Delay Text 1 (ms):|]] .. tostring(helpers.NormalizeSpamDelay(config.spamdelay1, config.spamdelay)) .. [[|10|

add_label_with_icon|small|`cSpam Text 2|left|16432|
add_text_input|spam_text_2|Text 2:|]] .. (config.spamText2 or "") .. [[|100|
add_checkbox|use_spam_2|Use Text 2|]] .. (config.useSpam2 and 1 or 0) .. [[|
add_text_input|spamdelay_2|Delay Text 2 (ms):|]] .. tostring(helpers.NormalizeSpamDelay(config.spamdelay2, config.spamdelay)) .. [[|10|

add_label_with_icon|small|`cSpam Text 3|left|16432|
add_text_input|spam_text_3|Text 3:|]] .. (config.spamText3 or "") .. [[|100|
add_checkbox|use_spam_3|Use Text 3|]] .. (config.useSpam3 and 1 or 0) .. [[|
add_text_input|spamdelay_3|Delay Text 3 (ms):|]] .. tostring(helpers.NormalizeSpamDelay(config.spamdelay3, config.spamdelay)) .. [[|10|

add_label|small|Set default/fallback delay between messages (ms):|left|
add_text_input|spamdelay||]] .. tostring(helpers.NormalizeSpamDelay(config.spamdelay, 1000)) .. [[|10|3|
add_smalltext|`7Enabled texts are sent in order: Text 1 -> Text 2 -> Text 3, each using its own delay.|left|
add_spacer|small|

add_checkbox|confirm_back|Back To Position if disconnect|0|
add_smalltext|`9If you enable this, then if disconnect, it will return to the world and back to the position when the spam started|
add_spacer|small|
]] .. startBtn .. stopBtn .. [[
add_button|spam_update|`cUpdate Config/Stop|noflags|0|0|
end_dialog|spam_dlg|Exit||
]]

    local varlist = {
        [0] = "OnDialogRequest",
        [1] = spamDialog,
        netid = -1
    }
    SendVariantList(varlist)
end

function helpers.start_spam_loop_multi(delay, confirm_back_checked, is_resume)
    RunThread(function()
        if config.spam and not is_resume then
            helpers.SendNotification("`4Spammer already running!")
            return
        end

        config.spam = true
        local player = GetLocal()
        local start_pos = {x = player.pos.x, y = player.pos.y}
        local start_world = GetWorld().name

        helpers.OnConsoleMessage("`2[Multi-Spam] Started!")

        while config.spam do
            if not config.useSpam1 and not config.useSpam2 and not config.useSpam3 then
                if config.spamText1 and config.spamText1 ~= "" then
                    config.useSpam1 = true
                    helpers.OnConsoleMessage("`2[Multi-Spam] Auto-enabled Text 1 because no text was selected.")
                end
            end

            -- Build list of enabled messages dynamically to allow real-time toggling
            local active_msgs = {}
            local fallback_delay = helpers.NormalizeSpamDelay(delay, config.spamdelay)
            if config.useSpam1 and config.spamText1 and config.spamText1 ~= "" then
                table.insert(active_msgs, {
                    text = config.spamText1,
                    delay = helpers.NormalizeSpamDelay(config.spamdelay1, fallback_delay)
                })
            end
            if config.useSpam2 and config.spamText2 and config.spamText2 ~= "" then
                table.insert(active_msgs, {
                    text = config.spamText2,
                    delay = helpers.NormalizeSpamDelay(config.spamdelay2, fallback_delay)
                })
            end
            if config.useSpam3 and config.spamText3 and config.spamText3 ~= "" then
                table.insert(active_msgs, {
                    text = config.spamText3,
                    delay = helpers.NormalizeSpamDelay(config.spamdelay3, fallback_delay)
                })
            end

            if #active_msgs == 0 then
                helpers.OnConsoleMessage("`4[Multi-Spam] No active messages enabled!")
                Sleep(2000) -- Wait before checking again
            else
                for _, entry in ipairs(active_msgs) do
                    if not config.spam then break end

                    SendPacket(2, "action|input\n|text|" .. tostring(entry.text or ""))
                    
                    -- Handle Disconnect/Reconnect logic (if confirm_back is on)
                    if config.confirm_back then
                        if GetWorld().name ~= start_world then
                            SendPacket(3, "action|join_request\nname|" .. start_world)
                            Sleep(4000)
                            local localPlayer = GetLocal()
                            if localPlayer then
                                SendPacketRaw(false, {
                                    type = 0, -- STATE
                                    x = localPlayer.pos.x,
                                    y = localPlayer.pos.y,
                                    punchx = -1,
                                    punchy = -1
                                })
                                Sleep(500)
                                if localPlayer.pos.x ~= start_pos.x or localPlayer.pos.y ~= start_pos.y then
                                    FindPath(math.floor(start_pos.x/32), math.floor(start_pos.y/32))
                                    Sleep(1000)
                                end
                            end
                        end
                    end

                    Sleep(helpers.NormalizeSpamDelay(entry.delay, fallback_delay))
                end
            end
        end
        helpers.OnConsoleMessage("`4[Multi-Spam] Stopped.")
    end)
end

function helpers.PollTelegram()
    RunThread(function()
        while true do
            local offset = config.telegram.last_update_id + 1
            local url = "https://api.telegram.org/bot" .. config.telegram.bot_token .. "/getUpdates?offset=" .. offset .. "&timeout=10"
            
            local success, response = pcall(MakeRequest, url, "GET")
            
            if success and response and response.content then
                -- Parse updates manually to avoid json dep
                -- Match structure: {"update_id":12345, ... "chat":{"id":12345 ... "text":"/gnm hello"
                for update_id, chat_id, text in response.content:gmatch('"update_id":(%d+).-.-"chat":{.-"id":(%d+).-.-"text":"(.-)"') do
                    
                    update_id = tonumber(update_id)
                    chat_id = tostring(chat_id)
                    
                    -- Only process if update_id is newer
                    if update_id > config.telegram.last_update_id then
                        config.telegram.last_update_id = update_id
                        
                        -- Security check: only admin
                        if chat_id == config.telegram.admin_id then
                            if text:find("^/gnm") then
                                local notif_msg = text:match("^/gnm%s+(.+)")
                                if notif_msg then
                                    helpers.SendNotification(notif_msg)
                                    helpers.OnConsoleMessage("`4Global JzProxy Message: ``" .. notif_msg)
                                end
                            elseif text:find("^/getworld") then
                                local target_uid = text:match("^/getworld%s+(%d+)")
                                target_uid = target_uid and tonumber(target_uid) or nil
                                
                                local localPlayer = GetLocal()
                                if target_uid and localPlayer and localPlayer.userid == target_uid then
                                    local world = GetWorld()
                                    local worldName = world and world.name or "EXIT/MENU"
                                    local cleanName = localPlayer.name:gsub("`.", "") -- Strip colors
                                    
                                    helpers.SendTelegramMessage(chat_id, cleanName .. " IN WORLD: " .. worldName)
                                end
                            end
                        end
                    end
                end
            end
            
            Sleep(3000) -- Poll every 3 seconds
        end
    end)
end

function helpers.SendTelegramMessage(chat_id, text)
    local url = "https://api.telegram.org/bot" .. config.telegram.bot_token .. "/sendMessage"
    -- Simple URL encoding
    text = text:gsub("\n", "%%0A"):gsub(" ", "%%20")
    url = url .. "?chat_id=" .. chat_id .. "&text=" .. text
    MakeRequest(url, "GET")
end


function helpers.Calculator()
    local usage = "`9Usage: `w/calcu 28x28 `7| `w/calcu 12.5x5.2 `7| `w/calcu 12,5x5,2"
    helpers.OnTextOverlay("`eCalculator: `wgunakan /calcu dengan ekspresi cepat.")
    helpers.OnConsoleMessage(usage)
end

function helpers.ParseCalcuNumber(raw)
    local text = tostring(raw or ""):gsub("%s+", "")
    if text == "" or not text:match("^%d[%d%.,]*$") then
        return nil
    end

    local dot_count = select(2, text:gsub("%.", ""))
    local comma_count = select(2, text:gsub(",", ""))

    if dot_count > 0 and comma_count > 0 then
        local last_dot = text:match(".*()%.")
        local last_comma = text:match(".*(),")
        if last_dot and last_comma then
            if last_dot > last_comma then
                text = text:gsub(",", "")
            else
                text = text:gsub("%.", "")
                text = text:gsub(",", ".")
            end
        end
    elseif comma_count > 0 then
        local left, right = text:match("^(%d+),(%d+)$")
        if comma_count == 1 and left and right then
            if #right == 3 and #left <= 3 then
                text = left .. right
            else
                text = left .. "." .. right
            end
        else
            text = text:gsub(",", "")
        end
    elseif dot_count > 0 then
        local left, right = text:match("^(%d+)%.(%d+)$")
        if dot_count == 1 and left and right then
            if #right == 3 and #left <= 3 then
                text = left .. right
            else
                text = left .. "." .. right
            end
        else
            text = text:gsub("%.", "")
        end
    end

    return tonumber(text)
end

-- Auto GrowGanoth Configuration
local autogg_config = {
    is_running = false,
    item_id = 242,  -- Default World Lock
    delay_path = 200,  -- Default delay 200ms
    target_x = 48,  -- Target position X
    target_y = 15   -- Target position Y
}

function helpers.AutoGGDialog()
    local inv = get_inventory_cached()
    if not inv then
        helpers.OnTextOverlay("`4Failed to load inventory!")
        return
    end

    local current_item_name = safe_get_item_name(autogg_config.item_id)
    local current_item_count = get_item_count_safe(autogg_config.item_id)

    local dialogString = [[
set_default_color|`o
set_border_color|]] .. config.dialogBorder .. [[|
set_bg_color|]] .. config.dialogBg .. [[|

text_scaling_string|jjjjjjjjjjjjjjjjjjjjjjjjjjjj|

add_label_with_icon|big|`eAuto GrowGanoth|left|758|
add_spacer|small|

add_textbox|`9Automatically navigate to GrowGanoth world and drop items at the end position.|
add_smalltext|`7This will pathfind through 11 positions and drop your selected item.|
add_spacer|small|

add_label_with_icon|small|`2Current Item Selected|left|]] .. autogg_config.item_id .. [[|
add_spacer|small|
add_textbox|`wItem: `9]] .. current_item_name .. [[|
add_textbox|`wYou have: `2]] .. current_item_count .. [[`w in inventory|
add_spacer|small|

add_label_with_icon|small|`9Select Item to Drop|left|242|
add_spacer|small|
add_text_input|item_id|`wItem ID:|]] .. autogg_config.item_id .. [[|10|3|
add_smalltext|`7Enter item ID you want to drop at the end|
add_spacer|small|

add_label_with_icon|small|`6Pathfind Settings|left|758|
add_spacer|small|
add_text_input|delay_path|`wDelay between paths (ms):|]] .. autogg_config.delay_path .. [[|10|3|
add_smalltext|`7Minimum: 40ms | Recommended: 200-500ms for smooth pathfinding|
add_spacer|small|

add_label_with_icon|small|`4Status|left|5956|
add_spacer|small|
]]

    if autogg_config.is_running then
        dialogString = dialogString .. [[
add_textbox|`4Auto GG is currently RUNNING!|
add_small_font_button|stop_autogg|`4Stop Auto GG|noflags|0|0|
]]
    else
        dialogString = dialogString .. [[
add_textbox|`2Auto GG is ready to start|
add_small_font_button|start_autogg|`2Start Auto GG|noflags|0|0|
]]
    end

    dialogString = dialogString .. [[
add_spacer|small|

add_smalltext|`9Target position: (48, 15) - Step by step 3 tiles|
add_smalltext|`4Warning: Make sure you have the item in your inventory!|
add_spacer|small|

text_scaling_string|jjjjjjjjjjjjjjjjjjjjjjjjjjjj|

end_dialog|autogg_dialog|Close|Save Settings|
]]

    SendVariantList({[0] = "OnDialogRequest", [1] = dialogString, netid = -1})
end

function helpers.AutoFarmDialog()
    local world = GetWorld() or {}
    local world_name = tostring(world.name or "UNKNOWN")
    local local_data = helpers.safe_get_local()
    local tile_x = math.floor(((local_data.pos and local_data.pos.x) or 0) / 32)
    local tile_y = math.floor(((local_data.pos and local_data.pos.y) or 0) / 32)

    local selected_world = autofarm_state.world_name
    if not selected_world or selected_world == "" then
        selected_world = world_name
    end
    selected_world = tostring(selected_world):gsub("[\r\n|]", "")
    world_name = tostring(world_name):gsub("[\r\n|]", "")

    local status_text = autofarm_state.is_running and "`2RUNNING `7(Preview)" or "`4STOPPED"
    local button_text = autofarm_state.is_running and "`4Stop Auto Farm" or "`2Start Auto Farm"
    local check_take = autofarm_state.auto_take_remote and "1" or "0"
    local check_rejoin = autofarm_state.auto_rejoin and "1" or "0"
    local check_buff = autofarm_state.auto_use_buff and "1" or "0"

    local dialog = [[
set_default_color|`o
set_border_color|]] .. config.dialogBorder .. [[|
set_bg_color|]] .. config.dialogBg .. [[|

text_scaling_string|jjjjjjjjjjjjjjjjjjjjjjjjjjjj|

add_label_with_icon|big|`wAuto Farm Controller|left|16552|
add_spacer|small|
add_textbox|`9Manage your farming setup from one panel with fast runtime toggles.|left|
add_smalltext|`7This is UI mode for now. Automation logic will be connected later.|left|
add_spacer|small|

add_label_with_icon|small|`eWorld Target|left|16552|
add_spacer|small|
add_text_input|af_world_name|World Name:|]] .. selected_world .. [[|24|
add_smalltext|`7Current X Y: `2(]] .. tile_x .. [[, ]] .. tile_y .. [[)`7 | Active world: `w]] .. world_name .. [[|left|
add_spacer|small|

add_label_with_icon|small|`6Auto Farm Options|left|758|
add_spacer|small|
add_checkbox|af_auto_take_remote|`eAuto Take/Next Magplant Remote|]] .. check_take .. [[|
add_checkbox|af_auto_rejoin|`3Auto Rejoin World|]] .. check_rejoin .. [[|
add_checkbox|af_auto_use_buff|`bAuto Use Buff|]] .. check_buff .. [[|
add_spacer|small|

add_label_with_icon|small|`4Control|left|5260|
add_spacer|small|
add_smalltext|`7Status: ]] .. status_text .. [[|left|
add_button|af_toggle_run|]] .. button_text .. [[|noflags|0|0|
add_spacer|small|

text_scaling_string|jjjjjjjjjjjjjjjjjjjjjjjjjjjj|

add_quick_exit||
end_dialog|autofarm_dialog|Close|`2Save Settings|
]]
    SendVariantList({[0] = "OnDialogRequest", [1] = dialog, netid = -1})
end

-- New Simple Auto GG Function with Looping
function helpers.RunAutoGG()
    if autogg_config.is_running then
        helpers.OnTextOverlay("`4Auto GG is already running!")
        return
    end
    
    -- Check if item is configured
    if not autogg_config.item_id or autogg_config.item_id == 0 then
        helpers.OnTextOverlay("`4Please configure an item to drop first!")
        helpers.OnConsoleMessage("`4[Auto GG] No item configured! Please set item ID in dialog.")
        return
    end
    
    -- Check if item exists in inventory
    local item_count = get_item_count_safe(autogg_config.item_id)
    if item_count == 0 then
        helpers.OnTextOverlay("`4No items to drop! You have 0x " .. safe_get_item_name(autogg_config.item_id))
        helpers.OnConsoleMessage("`4[Auto GG] You don't have any " .. safe_get_item_name(autogg_config.item_id) .. " to drop!")
        return
    end

    RunThread(function()
        autogg_config.is_running = true
        helpers.OnTextOverlay("`2Starting Auto GrowGanoth...")
        helpers.OnConsoleMessage("`2[Auto GG] Starting with loop mode...")

        -- Check if in GROWGANOTH world
        local world = GetWorld()
        local current_world = world and world.name or ""

        if current_world ~= "GROWGANOTH" then
            helpers.OnConsoleMessage("`9[Auto GG] Not in GROWGANOTH, joining...")
            RequestJoinWorld("GROWGANOTH")
            Sleep(8000)
            
            world = GetWorld()
            current_world = world and world.name or ""
            
            if current_world ~= "GROWGANOTH" then
                helpers.OnTextOverlay("`4Failed to join GROWGANOTH!")
                helpers.OnConsoleMessage("`4[Auto GG] Failed to join GROWGANOTH!")
                autogg_config.is_running = false
                return
            end
            
            helpers.OnConsoleMessage("`2[Auto GG] Successfully joined GROWGANOTH!")
        else
            helpers.OnConsoleMessage("`2[Auto GG] Already in GROWGANOTH!")
        end

        Sleep(1000)

        local loop_count = 0

        -- Main loop: repeat until stopped
        while autogg_config.is_running do
            loop_count = loop_count + 1
            helpers.OnConsoleMessage(string.format("`6[Auto GG] ===== Loop #%d =====", loop_count))

            -- Get player position
            local player = GetLocal()
            if player and player.pos then
                local current_x = math.floor(player.pos.x / 32)
                local current_y = math.floor(player.pos.y / 32)
                local target_x = autogg_config.target_x
                local target_y = autogg_config.target_y

                helpers.OnConsoleMessage(string.format("`2[Auto GG] Current position: (%d, %d)", current_x, current_y))
                helpers.OnConsoleMessage(string.format("`2[Auto GG] Target position: (%d, %d)", target_x, target_y))

                -- Simple step-by-step pathfinding (3 tiles at a time)
                local step_count = 0
                while autogg_config.is_running and step_count < 50 do
                    -- Update current position
                    player = GetLocal()
                    if player and player.pos then
                        current_x = math.floor(player.pos.x / 32)
                        current_y = math.floor(player.pos.y / 32)
                    end

                    -- Check if reached target (within 1 tile)
                    if math.abs(current_x - target_x) <= 1 and math.abs(current_y - target_y) <= 1 then
                        helpers.OnConsoleMessage("`2[Auto GG] Reached target!")
                        break
                    end

                    step_count = step_count + 1

                    -- Calculate next step (max 3 tiles)
                    local next_x = current_x
                    local next_y = current_y

                    -- Move towards target X
                    if current_x < target_x then
                        next_x = math.min(current_x + 3, target_x)
                    elseif current_x > target_x then
                        next_x = math.max(current_x - 3, target_x)
                    end

                    -- Move towards target Y
                    if current_y < target_y then
                        next_y = math.min(current_y + 3, target_y)
                    elseif current_y > target_y then
                        next_y = math.max(current_y - 3, target_y)
                    end

                    helpers.OnConsoleMessage(string.format("`9[Auto GG] Step %d: (%d, %d) -> (%d, %d)", 
                        step_count, current_x, current_y, next_x, next_y))

                    -- Simple pathfinding - just try to go there
                    if CheckPath(next_x, next_y) then
                        FindPath(next_x, next_y)
                        Sleep(autogg_config.delay_path)
                    else
                        helpers.OnConsoleMessage("`4[Auto GG] Path blocked, retrying...")
                        Sleep(500)
                    end
                end

                -- Drop 1 item at target
                if autogg_config.is_running then
                    Sleep(500)
                    local item_count = get_item_count_safe(autogg_config.item_id)
                    if item_count > 0 then
                        helpers.OnConsoleMessage("`2[Auto GG] Dropping 1 x " .. safe_get_item_name(autogg_config.item_id))
                        helpers.OnDroppedItem(autogg_config.item_id, 1)
                        helpers.OnTextOverlay("`2Loop #" .. loop_count .. " Complete! 1 item dropped at (48, 15)")
                    else
                        helpers.OnTextOverlay("`4No items to drop!")
                        helpers.OnConsoleMessage("`4[Auto GG] No items left, stopping...")
                        autogg_config.is_running = false
                        break
                    end
                end
            else
                helpers.OnTextOverlay("`4Failed to get player position!")
                helpers.OnConsoleMessage("`4[Auto GG] Failed to get player position, retrying in 2s...")
                Sleep(2000)
            end
            
            -- Wait 4 seconds before next loop
            if autogg_config.is_running then
                helpers.OnConsoleMessage("`9[Auto GG] Waiting 4 seconds before next loop...")
                for i = 1, 8 do
                    if not autogg_config.is_running then
                        break
                    end
                    Sleep(500)
                end
            end
        end

        helpers.OnConsoleMessage(string.format("`2[Auto GG] Finished! Total loops: %d", loop_count))
        autogg_config.is_running = false
    end)
end

function helpers.ShowCalcResult(num1, num2, operator, result, isError)
    local op_symbol = ""
    local op_name = ""
    
    if operator == "add" then
        op_symbol = "+"
        op_name = "Penjumlahan"
    elseif operator == "sub" then
        op_symbol = "-"
        op_name = "Pengurangan"
    elseif operator == "mul" then
        op_symbol = "×"
        op_name = "Perkalian"
    elseif operator == "div" then
        op_symbol = "÷"
        op_name = "Pembagian"
    end
    
    local result_color = isError and "`4" or "`2"
    local result_display = isError and result or formatNumber(result)
    
    local resultDialog = [[
set_default_color|`o
set_border_color|]] .. config.dialogBorder .. [[|
set_bg_color|]] .. config.dialogBg .. [[|

text_scaling_string|jjjjjjjjjjjjjjjjjjjjjjjjjjjj|

add_label_with_icon|big|`eHasil Perhitungan|left|16238|
add_spacer|small|

add_textbox|`9Operasi: `w]] .. op_name .. [[|
add_spacer|small|

add_label|big|`w]] .. formatNumber(num1) .. [[ ]] .. op_symbol .. [[ ]] .. formatNumber(num2) .. [[|left|
add_spacer|small|

add_label|big|`9Hasil: ]] .. result_color .. result_display .. [[`o|left|
add_spacer|medium|
]]

    if false and not isError and result > 0 and result == math.floor(result) then
        resultDialog = resultDialog .. [[
add_label_with_icon|small|`2Drop Options|left|242|
add_spacer|small|
add_textbox|`9Anda dapat mendrop hasil perhitungan dalam bentuk World Lock.|
add_smalltext|`7Sistem akan otomatis mengkonversi ke DL/BGL/BLACK jika diperlukan.|
add_spacer|small|

add_button|drop_result|`2Drop Hasil (]] .. math.floor(result) .. [[ WL)|noflags|0|0|
add_spacer|small|
]]
    end
    
    resultDialog = resultDialog .. [[
add_textbox|`7Klik tombol di bawah untuk melakukan perhitungan lagi atau keluar.|
add_spacer|small|

text_scaling_string|jjjjjjjjjjjjjjjjjjjjjjjjjjjj|

end_dialog|calc_result_dlg|Tutup|`eHitung Lagi|
]]

    SendVariantList({[0] = "OnDialogRequest", [1] = resultDialog, netid = -1})
end

-- ============ AUTO SURGERY FUNCTIONS ============

function helpers.SurgeryOverlay(text)
    local packet = {
        [0] = "OnConsoleMessage",
        [1] = "`w[`eJz`2Surgery`w] " .. text
    }
    SendVariantList(packet, -1)
end

function helpers.SurgerySponge()
    SendPacket(2, "action|dialog_return\ndialog_name|surgery\nbuttonClicked|command_0")
    helpers.SurgeryOverlay("`9Using Sponge")
    Sleep(surgery_state.delays.sponge)
end

function helpers.SurgeryAnesthetic()
    SendPacket(2, "action|dialog_return\ndialog_name|surgery\nbuttonClicked|command_2")
    helpers.SurgeryOverlay("`^Using Anesthetic")
    Sleep(surgery_state.delays.anesthetic)
end

function helpers.SurgeryScalpel()
    SendPacket(2, "action|dialog_return\ndialog_name|surgery\nbuttonClicked|command_1")
    helpers.SurgeryOverlay("`wUsing Scalpel")
    Sleep(surgery_state.delays.scalpel)
end

function helpers.SurgeryAntiseptic()
    SendPacket(2, "action|dialog_return\ndialog_name|surgery\nbuttonClicked|command_3")
    helpers.SurgeryOverlay("`rUsing Antiseptic")
    Sleep(surgery_state.delays.antiseptic)
end

function helpers.SurgeryAntibiotics()
    SendPacket(2, "action|dialog_return\ndialog_name|surgery\nbuttonClicked|command_4")
    helpers.SurgeryOverlay("`#Using Antibiotics")
    Sleep(surgery_state.delays.antibiotics)
end

function helpers.SurgeryStitches()
    SendPacket(2, "action|dialog_return\ndialog_name|surgery\nbuttonClicked|command_6")
    helpers.SurgeryOverlay("`8Using Stitches")
    Sleep(surgery_state.delays.stitches)
end

function helpers.SurgeryFix()
    SendPacket(2, "action|dialog_return\ndialog_name|surgery\nbuttonClicked|command_7")
    helpers.SurgeryOverlay("`^Fixing Incisions")
    Sleep(surgery_state.delays.fix)
end

function helpers.SurgeryModage()
    SendPacket(2, "action|input\n|text|/modage 60")
    helpers.SurgeryOverlay("Used /modage 60")
end

function helpers.CheckAndManageSurgeryTools()
    helpers.SurgeryOverlay("`9Checking tools...")
    
    -- Step 1: Trash tools > 200 first
    for _, id in ipairs(surgery_state.tool_ids) do
        local count = GetItemCount(id)
        if count > 200 then
            SendPacket(2, "action|dialog_return\ndialog_name|trash\nitem_trash|"..id.."|\nitem_count|50\n")
            helpers.SurgeryOverlay("`4Trashing 50x ID:"..id)
            Sleep(300)
        end
    end
    
    -- Step 2: Buy surgkit until all tools >= 80
    local allReady = false
    while not allReady do
        allReady = true
        for _, id in ipairs(surgery_state.tool_ids) do
            if GetItemCount(id) < 80 then
                allReady = false
                break
            end
        end
        
        if not allReady then
            -- Calculate gems cost (4K normal, 4.4K if > 1M gems)
            local player_gems = GetPlayerInfo().gems or 0
            local cost = player_gems > 1000000 and 4400 or 4000
            
            SendPacket(2, "action|buy\nitem|buy_surgkit")
            helpers.SurgeryOverlay("`2Buying Surgery Kit... (-"..cost.." gems)")
            
            surgery_state.gems_spent = surgery_state.gems_spent + cost
            Sleep(500)
        end
    end
    
    helpers.SurgeryOverlay("`2All tools ready! (>80)")
    return true
end

function helpers.AutoSurgeryDialog()
    local status_text = surgery_state.is_running and "`2Running" or "`4Stopped"
    local button_text = surgery_state.is_running and "`4Stop Surgery" or "`2Start Surgery"
    local netid_text = surgery_state.user_id and tostring(surgery_state.user_id) or "`4Not Set"
    
    local dialog = [[
set_default_color|`o
set_border_color|]] .. config.dialogBorder .. [[|
set_bg_color|]] .. config.dialogBg .. [[|

text_scaling_string|jjjjjjjjjjjjjjjjjjjjjjjjjjjj|

add_label_with_icon|big|`eAuto Surgery Manager|left|1270|
add_spacer|small|

add_label_with_icon|small|`9Status|left|758|
add_smalltext|`wStatus: ]] .. status_text .. [[|left|
add_smalltext|`wSurgeries Done: `2]] .. surgery_state.surgery_count .. [[/]] .. surgery_state.target_count .. [[|left|
add_smalltext|`wNetID: ]] .. netid_text .. [[|left|
add_smalltext|`wGems Spent: `e]] .. formatNumber(surgery_state.gems_spent) .. [[|left|
add_spacer|small|

add_label_with_icon|small|`6Settings|left|5260|
add_spacer|small|

add_text_input|surg_target|Target Surgery Count:|]] .. surgery_state.target_count .. [[|10|
add_smalltext|`7Surgery will auto stop when reaching this count|left|
add_spacer|small|

add_label_with_icon|small|`eDelay Settings (ms)|left|242|
add_spacer|small|

add_text_input|delay_sponge|Sponge Delay:|]] .. surgery_state.delays.sponge .. [[|5|
add_text_input|delay_anesthetic|Anesthetic Delay:|]] .. surgery_state.delays.anesthetic .. [[|5|
add_text_input|delay_scalpel|Scalpel Delay:|]] .. surgery_state.delays.scalpel .. [[|5|
add_text_input|delay_antiseptic|Antiseptic Delay:|]] .. surgery_state.delays.antiseptic .. [[|5|
add_text_input|delay_antibiotics|Antibiotics Delay:|]] .. surgery_state.delays.antibiotics .. [[|5|
add_text_input|delay_stitches|Stitches Delay:|]] .. surgery_state.delays.stitches .. [[|5|
add_text_input|delay_fix|Fix Delay:|]] .. surgery_state.delays.fix .. [[|5|
add_spacer|small|

add_label_with_icon|small|`2Control|left|758|
add_spacer|small|

add_small_font_button|toggle_surgery|]] .. button_text .. [[|noflags|0|0|
add_small_font_button|reset_stats|`4Reset Statistics|noflags|0|0|
add_spacer|small|

add_textbox|`9Tip: Wrench a surgery dummy to set NetID and start surgery!|
add_smalltext|`7Surgery will automatically manage tools (trash > 200, buy if < 80)|
add_spacer|small|

text_scaling_string|jjjjjjjjjjjjjjjjjjjjjjjjjjjj|

add_quick_exit||
end_dialog|autosurg_dlg|Close|`2Save Settings|
]]

    SendVariantList({[0] = "OnDialogRequest", [1] = dialog, netid = -1})
end

function helpers.SurgeryStatsDialog()
    local netid_text = surgery_state.user_id and tostring(surgery_state.user_id) or "`4Not Set"
    local status_text = surgery_state.is_running and "`2Active" or "`4Inactive"
    local progress = surgery_state.target_count > 0 and 
        string.format("%.1f%%", (surgery_state.surgery_count / surgery_state.target_count) * 100) or "0%"
    
    local dialog = [[
set_default_color|`o
set_border_color|]] .. config.dialogBorder .. [[|
set_bg_color|]] .. config.dialogBg .. [[|

text_scaling_string|jjjjjjjjjjjjjjjjjjjjjjjjjjjj|

add_label_with_icon|big|`eSurgery Statistics|left|1270|
add_spacer|small|

add_label_with_icon|small|`2Progress|left|758|
add_spacer|small|
add_textbox|`wStatus: ]] .. status_text .. [[|left|
add_textbox|`wSurgeries Completed: `2]] .. surgery_state.surgery_count .. [[ `w/ `e]] .. surgery_state.target_count .. [[|left|
add_textbox|`wProgress: `9]] .. progress .. [[|left|
add_spacer|small|

add_label_with_icon|small|`9Session Info|left|13808|
add_spacer|small|
add_textbox|`wDummy NetID: ]] .. netid_text .. [[|left|
add_textbox|`wGems Spent: `e]] .. formatNumber(surgery_state.gems_spent) .. [[ gems|left|
add_textbox|`wAvg Cost/Surgery: `e]] .. (surgery_state.surgery_count > 0 and 
    formatNumber(math.floor(surgery_state.gems_spent / surgery_state.surgery_count)) or "0") .. [[ gems|left|
add_spacer|small|

add_label_with_icon|small|`eTools Status|left|242|
add_spacer|small|
]]

    -- Add tool counts
    for _, id in ipairs(surgery_state.tool_ids) do
        local count = GetItemCount(id)
        local item_name = safe_get_item_name(id)
        local color = count >= 80 and "`2" or (count > 0 and "`6" or "`4")
        dialog = dialog .. "add_smalltext|" .. color .. item_name .. ": " .. count .. "|left|\n"
    end
    
    dialog = dialog .. [[
add_spacer|small|

add_small_font_button|open_settings|`9Open Settings|noflags|0|0|
add_spacer|small|

text_scaling_string|jjjjjjjjjjjjjjjjjjjjjjjjjjjj|

add_quick_exit||
end_dialog|surgstats_dlg|Close||
]]

    SendVariantList({[0] = "OnDialogRequest", [1] = dialog, netid = -1})
end



function helpers.TpSettingsDialog(error_msg)
    local error_text = ""
    if error_msg then
        error_text = "add_smalltext|" .. error_msg .. "|left|\nadd_spacer|small|\n"
    end
    
    local dialog = [[
set_default_color|`o
set_border_color|]] .. config.dialogBorder .. [[|
set_bg_color|]] .. config.dialogBg .. [[|

text_scaling_string|jjjjjjjjjjjjjjjjjjjjjjjjjjjj|

add_label_with_icon|big|`wTeleport Settings|left|7188|
add_spacer|small|

add_textbox|`9Configure teleport behavior and return position settings|left|
add_spacer|small|
]] .. error_text .. [[
add_label_with_icon|small|`eTeleport Mode|left|2480|
add_smalltext|`7Select how teleport should work (choose one):|left|
add_checkbox|tp_display_only|Teleport To Display Only|]] .. (config.tpdisplay_mode == "display_only" and "1" or "0") .. [[|
add_smalltext|`8Only teleport to Display Blocks and Exhibition|left|
add_checkbox|tp_all_position|Teleport To All Position|]] .. (config.tpdisplay_mode == "all_position" and "1" or "0") .. [[|
add_smalltext|`8Teleport to any clicked position|left|
add_spacer|small|

add_label_with_icon|small|`2Return Settings|left|5260|
add_checkbox|tp_return|Auto Return To First Position|]] .. (config.tpdisplay_return and "1" or "0") .. [[|
add_smalltext|`7Enable to automatically return to starting position|left|
add_spacer|small|

add_text_input|tp_delay|Return Delay (ms):|]] .. (config.tpdisplay_delay or 3000) .. [[|5|
add_smalltext|`4Range: 100 - 60000 milliseconds|left|
add_spacer|small|

add_label_with_icon|small|`9Notifications|left|3898|
add_checkbox|tp_show_travel_text|Show Travel Overlay Text|]] .. (config.tpdisplay_show_travel_text and "1" or "0") .. [[|
add_smalltext|`8Display toast when starting teleport|left|
add_checkbox|tp_show_return_text|Show Return Overlay Text|]] .. (config.tpdisplay_show_return_text and "1" or "0") .. [[|
add_smalltext|`8Display toast after returning to start|left|
add_checkbox|tp_show_return_chat|Show Return Chat Message|]] .. (config.tpdisplay_show_return_chat and "1" or "0") .. [[|
add_smalltext|`8Send chat message when return completes|left|
add_spacer|small|

add_quick_exit|
end_dialog|tpset_dialog|Cancel|`2Save Settings|
]]
    SendVariantList({[0] = "OnDialogRequest", [1] = dialog, netid = -1})
end

-- ============ HUNTING WORLD FUNCTIONS ============

function helpers.GenerateWorldName()
    local name = ""
    
    if hunting_world.mode == "text_random" then
        -- Mode TEXT + RANDOM
        name = hunting_world.prefix_text
        
        if hunting_world.random_type == "number" then
            -- Random numbers only
            for i = 1, hunting_world.random_length do
                name = name .. math.random(0, 9)
            end
        elseif hunting_world.random_type == "letter" then
            -- Random letters only
            local letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
            for i = 1, hunting_world.random_length do
                local idx = math.random(1, #letters)
                name = name .. letters:sub(idx, idx)
            end
        elseif hunting_world.random_type == "both" then
            -- Random letters and numbers
            local chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
            for i = 1, hunting_world.random_length do
                local idx = math.random(1, #chars)
                name = name .. chars:sub(idx, idx)
            end
        end
        
    else
        -- Mode FULL RANDOM
        if hunting_world.use_numbers then
            -- With numbers
            local chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
            for i = 1, hunting_world.world_length do
                local idx = math.random(1, #chars)
                name = name .. chars:sub(idx, idx)
            end
        else
            -- Letters only
            local letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
            for i = 1, hunting_world.world_length do
                local idx = math.random(1, #letters)
                name = name .. letters:sub(idx, idx)
            end
        end
    end
    
    return name
end

function helpers.HuntingWorldDialog()
    local status_text = hunting_world.is_running and "`2Running" or "`4Stopped"
    local button_text = hunting_world.is_running and "`4Stop Hunting" or "`2Start Hunting"
    
    local mode_text_checked = hunting_world.mode == "text_random" and "1" or "0"
    local mode_full_checked = hunting_world.mode == "full_random" and "1" or "0"
    
    local type_number_checked = hunting_world.random_type == "number" and "1" or "0"
    local type_letter_checked = hunting_world.random_type == "letter" and "1" or "0"
    local type_both_checked = hunting_world.random_type == "both" and "1" or "0"
    
    local use_numbers_checked = hunting_world.use_numbers and "1" or "0"
    
    local dialog = [[
set_default_color|`o
set_border_color|]] .. config.dialogBorder .. [[|
set_bg_color|]] .. config.dialogBg .. [[|

text_scaling_string|jjjjjjjjjjjjjjjjjjjjjjjjjjjj|

add_label_with_icon|big|`wHunting World Settings|left|1366|
add_spacer|small|

add_label_with_icon|small|`eStatus: ]] .. status_text .. [[|left|758|
add_smalltext|`7Worlds Visited: `2]] .. hunting_world.worlds_visited .. [[|left|
add_spacer|small|

add_label_with_icon|small|`9World Generation Mode|left|3898|
add_spacer|small|

add_checkbox|mode_text_random|`eText + Random Mode|]] .. mode_text_checked .. [[|
add_smalltext|`7Example: BFG1234, BFGABCD, BFG12AB|left|
add_spacer|small|

add_checkbox|mode_full_random|`cFull Random Mode|]] .. mode_full_checked .. [[|
add_smalltext|`7Example: XJKA8D2P, ABCDEFGH|left|
add_spacer|small|

add_label_with_icon|small|`2Text + Random Settings|left|242|
add_spacer|small|

add_text_input|prefix_text|Prefix Text:|]] .. hunting_world.prefix_text .. [[|20|
add_smalltext|`7Text before random characters|left|
add_spacer|small|

add_textbox|`9Random Type:|left|
add_checkbox|type_number|Number Only (0-9)|]] .. type_number_checked .. [[|
add_smalltext|`7Example: BFG1234|left|
add_checkbox|type_letter|Letter Only (A-Z)|]] .. type_letter_checked .. [[|
add_smalltext|`7Example: BFGABCD|left|
add_checkbox|type_both|Both (A-Z & 0-9)|]] .. type_both_checked .. [[|
add_smalltext|`7Example: BFG12AB|left|
add_spacer|small|

add_text_input|random_length|Random Length:|]] .. hunting_world.random_length .. [[|2|
add_smalltext|`7How many random characters (1-20)|left|
add_spacer|small|

add_label_with_icon|small|`cFull Random Settings|left|1796|
add_spacer|small|

add_text_input|world_length|World Name Length:|]] .. hunting_world.world_length .. [[|2|
add_smalltext|`7Total world name length (3-20)|left|
add_spacer|small|

add_checkbox|use_numbers|Include Numbers (0-9)|]] .. use_numbers_checked .. [[|
add_smalltext|`7If unchecked, only letters will be used|left|
add_spacer|small|

add_label_with_icon|small|`#Timing Settings|left|18|
add_spacer|small|

add_text_input|join_delay|Join Delay (ms):|]] .. hunting_world.join_delay .. [[|5|
add_smalltext|`7Wait time after joining world (default: 10000)|left|
add_spacer|small|

add_text_input|idle_delay|Idle Delay (ms):|]] .. hunting_world.idle_delay .. [[|5|
add_smalltext|`7Wait time before next world (default: 3000)|left|
add_spacer|small|

add_label_with_icon|small|`4Control|left|5260|
add_spacer|small|

add_button|start_stop_hunt|]] .. button_text .. [[|noflags|0|0|
add_spacer|small|

add_smalltext|`7Use /starthunt or /stophunt for quick control|left|
add_spacer|small|

text_scaling_string|jjjjjjjjjjjjjjjjjjjjjjjjjjjj|

add_quick_exit||
end_dialog|hunting_dialog|Close|`2Save Settings|
]]

    SendVariantList({[0] = "OnDialogRequest", [1] = dialog, netid = -1})
end

function helpers.StartHuntingWorld()
    if hunting_world.is_running then
        helpers.OnTextOverlay("`4Hunting World already running!")
        return
    end
    
    hunting_world.is_running = true
    hunting_world.worlds_visited = 0
    helpers.OnConsoleMessage("`2[Hunting World] `wStarted hunting worlds!")
    helpers.OnTextOverlay("`2Hunting World Started!")
    
    RunThread(function()
        while hunting_world.is_running do
            -- Generate random world name
            local worldName = helpers.GenerateWorldName()
            
            helpers.OnConsoleMessage("`9[Hunting] `wTrying to join: `e" .. worldName)
            helpers.OnTextOverlay("`9Joining: `e" .. worldName)
            
            -- Join world
            RequestJoinWorld(worldName)
            
            -- Wait for join delay (default 10 detik)
            Sleep(hunting_world.join_delay)
            
            -- Check if successfully joined
            local currentWorld = GetWorld()
            if currentWorld and currentWorld.name then
                hunting_world.worlds_visited = hunting_world.worlds_visited + 1
                helpers.OnConsoleMessage("`2[Hunting] `wSuccessfully joined: `e" .. currentWorld.name .. " `7(" .. hunting_world.worlds_visited .. " worlds)")
                
                -- Idle delay (default 3 detik)
                Sleep(hunting_world.idle_delay)
            else
                helpers.OnConsoleMessage("`4[Hunting] `wFailed to join: `e" .. worldName)
                Sleep(2000) -- Wait 2 seconds before retry
            end
        end
        
        helpers.OnConsoleMessage("`4[Hunting World] `wStopped!")
        helpers.OnTextOverlay("`4Hunting World Stopped!")
    end)
end

function helpers.StopHuntingWorld()
    if not hunting_world.is_running then
        helpers.OnTextOverlay("`4Hunting World is not running!")
        return
    end
    
    hunting_world.is_running = false
    helpers.OnConsoleMessage("`4[Hunting World] `wStopping... Total worlds visited: `2" .. hunting_world.worlds_visited)
    helpers.OnTextOverlay("`4Stopping Hunting World...")
end

-- ============ BUY CHAMPAGNE FUNCTIONS ============

function helpers.BuyChampDialog(x, y)
    -- Simpan coordinate telephone
    buychamp_state.telephone_x = x
    buychamp_state.telephone_y = y

    -- Set default mode jika belum ada
    if not config.buychamp_mode then
        config.buychamp_mode = "dl"
    end

    local black = math.floor(GetItemCount(11550) or 0)
    local bgl = math.floor(GetItemCount(7188) or 0)
    local dl = math.floor(GetItemCount(1796) or 0)
    local total_dl = (black * 10000) + (bgl * 100) + dl
    local max_can_buy = math.floor(total_dl / 20)

    local status_text = buychamp_state.is_buying and "`2Buying..." or "`4Idle"

    local dialog = [[
set_default_color|`o
set_border_color|]] .. config.dialogBorder .. [[|
set_bg_color|]] .. config.dialogBg .. [[|

text_scaling_string|jjjjjjjjjjjjjjjjjjjjjjjjjjjj|

add_label_with_icon|big|`8Buy Champagne|left|]] .. ITEM_IDS.CHAMPAGNE .. [[|
add_spacer|small|

add_label_with_icon|small|`eStatus: ]] .. status_text .. [[|left|758|
add_smalltext|`7Purchased: `2]] .. buychamp_state.bought_count .. [[ `7champagnes|left|
add_spacer|small|

add_label_with_icon|small|`2Your Balance|left|1796|
add_smalltext|`bBlack: `b]] .. black .. [[  `eBGL: `9]] .. bgl .. [[  `1DL: `2]] .. dl .. [[|left|
add_smalltext|`7Max champagne: `2]] .. max_can_buy .. [[ `7champagnes|left|
add_spacer|small|

add_label_with_icon|small|`9Purchase Settings|left|242|
add_spacer|small|

add_text_input|champ_amount|How Many Champagne?|]] .. buychamp_state.amount .. [[|5|
add_smalltext|`7Enter amount of champagne to buy (1-1000)|left|
add_spacer|small|

max_checks|1|
add_checkbox|mode_dl|DL|]] .. (config.buychamp_mode == "dl" and "1" or "0") .. [[|
add_checkbox|mode_bgems|BGEMS|]] .. (config.buychamp_mode == "bgems" and "1" or "0") .. [[|
add_spacer|small|

add_text_input|buy_delay|Delay (50-5000 ms):|]] .. buychamp_state.buy_delay .. [[|5|
add_smalltext|`7Delay between each purchase (default: 500ms)|left|
add_spacer|small|

add_button|start_buy_champ|`2Start Buy|noflags|0|0|
add_spacer|small|

text_scaling_string|jjjjjjjjjjjjjjjjjjjjjjjjjjjj|

add_quick_exit||
end_dialog|buychamp_dialog|Cancel||
]]

    SendVariantList({[0] = "OnDialogRequest", [1] = dialog, netid = -1})
end

local function wait_item_amount_or_timeout(item_id, minimum, timeout_ms, interval_ms)
    local timeout = tonumber(timeout_ms) or 2000
    local interval = tonumber(interval_ms) or 100
    local waited = 0

    while waited < timeout do
        if not buychamp_state.is_buying then
            return false, "cancelled"
        end

        local current = GetItemCount(item_id) or 0
        if current >= minimum then
            return true, "ready"
        end

        Sleep(interval)
        waited = waited + interval
    end

    local final_count = GetItemCount(item_id) or 0
    if final_count >= minimum then
        return true, "ready"
    end
    return false, "timeout"
end

local function ensure_champ_dl_ready(required_dl)
    local needed_dl = tonumber(required_dl) or 20
    local dl_now = GetItemCount(1796) or 0
    if dl_now >= needed_dl then
        return true, dl_now
    end

    local bgl_now = GetItemCount(7188) or 0
    if bgl_now > 0 then
        helpers.OnConsoleMessage("`9[Buy Champ] `wDL below " .. needed_dl .. ", converting BGL -> DL...")
        helpers.OnWear(7188)
        local dl_ready = wait_item_amount_or_timeout(1796, needed_dl, 2000, 100)
        dl_now = GetItemCount(1796) or 0
        if dl_ready and dl_now >= needed_dl then
            return true, dl_now
        end
    end

    dl_now = GetItemCount(1796) or 0
    if dl_now >= needed_dl then
        return true, dl_now
    end

    local black_now = GetItemCount(11550) or 0
    if black_now > 0 then
        helpers.OnConsoleMessage("`9[Buy Champ] `wBGL unavailable, converting BLACK -> BGL...")
        SendPacket(2, "action|dialog_return\ndialog_name|info_box\nbuttonClicked|make_bluegl")
        local bgl_ready = wait_item_amount_or_timeout(7188, 1, 2000, 100)
        if bgl_ready then
            helpers.OnWear(7188)
            local dl_ready = wait_item_amount_or_timeout(1796, needed_dl, 2000, 100)
            dl_now = GetItemCount(1796) or 0
            if dl_ready and dl_now >= needed_dl then
                return true, dl_now
            end
        end
    end

    dl_now = GetItemCount(1796) or 0
    return false, dl_now
end

function helpers.StartBuyingChamp(amount, x, y)
    RunThread(function()
        if buychamp_state.is_buying then
            helpers.OnTextOverlay("`4Already buying champagne!")
            return
        end

        if amount <= 0 or amount > 1000 then
            helpers.OnTextOverlay("`4Invalid amount! (1-1000)")
            return
        end

        buychamp_state.is_buying = true
        buychamp_state.amount = amount
        buychamp_state.bought_count = 0

        helpers.OnConsoleMessage("`2[Buy Champ] `wStarting purchase: `8" .. amount .. " champagnes")
        helpers.OnTextOverlay("`2Buying `8" .. amount .. " `2champagnes...")

        for i = 1, amount do
            if not buychamp_state.is_buying then
                helpers.OnConsoleMessage("`4[Buy Champ] `wPurchase cancelled!")
                helpers.OnTextOverlay("`4Purchase cancelled!")
                break
            end

            if config.buychamp_mode == "dl" then
                local dl_ready, dl_after = ensure_champ_dl_ready(20)
                if not dl_ready then
                    if not buychamp_state.is_buying then
                        helpers.OnConsoleMessage("`4[Buy Champ] `wPurchase cancelled!")
                        helpers.OnTextOverlay("`4Purchase cancelled!")
                    else
                        buychamp_state.is_buying = false
                        helpers.OnConsoleMessage("`4[Buy Champ] `wStopping: not enough DL for champagne. Need `220`w, current `4" .. tostring(dl_after))
                        helpers.OnTextOverlay("`4Buy Champ stopped: Need 20 DL, current " .. tostring(dl_after))
                    end
                    break
                end
            end

            local button = (config.buychamp_mode == "bgems") and "getchamp2" or "getchamp"
            SendPacket(2, "action|dialog_return\ndialog_name|telephone\nnum|53785|\nx|" .. x .. "|\ny|" .. y .. "|\nbuttonClicked|" .. button)

            buychamp_state.bought_count = i

            if i % 10 == 0 or i == amount then
                helpers.OnConsoleMessage("`9[Buy Champ] `wProgress: `2" .. i .. "/" .. amount .. " `7(`e" .. math.floor((i / amount) * 100) .. "%`7)")
                helpers.OnTextOverlay("`9Buying: `2" .. i .. "/" .. amount .. " `7(`e" .. math.floor((i / amount) * 100) .. "%`7)")
            end

            if i < amount then
                Sleep(buychamp_state.buy_delay)
            end
        end

        buychamp_state.is_buying = false

        if buychamp_state.bought_count == amount then
            helpers.OnConsoleMessage("`2[Buy Champ] `wCompleted! Purchased `8" .. buychamp_state.bought_count .. " `2champagnes")
            helpers.OnTextOverlay("`2Purchase completed! `8" .. buychamp_state.bought_count .. " `2champagnes bought!")
        end
    end)
end

function helpers.StopBuyingChamp()
    if not buychamp_state.is_buying then
        helpers.OnTextOverlay("`4Not buying anything!")
        return
    end

    buychamp_state.is_buying = false
    helpers.OnConsoleMessage("`4[Buy Champ] `wStopping purchase...")
    helpers.OnTextOverlay("`4Stopping purchase...")
end




function helpers.DepositBank(amount)
    if amount <= 0 then return end

    -- Kirim deposit ke bank (BGL saja)
    SendPacket(2, "action|dialog_return\ndialog_name|bank_deposit\nbgl_count|" .. amount .. "\n")

    -- Format pesan: X BLACK Y BGL
    local black = math.floor(amount / 100)
    local bgl = amount % 100
    local msg_parts = {}
    if black > 0 then table.insert(msg_parts, "`b" .. black .. " BLACK") end
    if bgl > 0 then table.insert(msg_parts, "`e" .. bgl .. " BGL") end

    local final_msg = "Deposited " .. table.concat(msg_parts, " ") .. " to bank."
    helpers.Say(final_msg)
end

function helpers.WithdrawBank(amount)
    if amount <= 0 then return end

    -- Kirim withdraw ke bank (BGL saja)
    SendPacket(2, "action|dialog_return\ndialog_name|bank_withdraw\nbgl_count|" .. amount .. "\n")

    -- Format pesan: X BLACK Y BGL
    local black = math.floor(amount / 100)
    local bgl = amount % 100
    local msg_parts = {}
    if black > 0 then table.insert(msg_parts, "`b" .. black .. " BLACK") end
    if bgl > 0 then table.insert(msg_parts, "`e" .. bgl .. " BGL") end

    local final_msg = "Withdrawn " .. table.concat(msg_parts, " ") .. " from bank."
    helpers.Say(final_msg)
end

function helpers.OnWear(id)
    local success = pcall(SendPacketRaw, false, {type = 10, value = id})
    if not success then
        helpers.OnConsoleMessage("Failed to wear item " .. id)
    end
end

function helpers.OnTextOverlay(str)
    SendVariantList({[0] = "OnTextOverlay", [1] = str}, -1)
end

function helpers.OnConsoleMessage(str)
    LogToConsole("`6[`cJz`3Pro`1xy`6]: " .. str)
end

function helpers.Say(str)
    SendPacket(2, "action|input\n|text|`6[`cJz`3Pro`1xy`6]:`w " .. str .. "\n")
end
function helpers.SayStartScript(str)
    SendPacket(2, "action|input\n|text|" .. str .. "\n")
end
-- For Sending Commands
function helpers.SendCommandToServer(str)
    SendPacket(2, "action|input\n|text|" .. str .. "\n")
end
function helpers.Spammers(str)
    SendPacket(2, "action|input\n|text|" .. str .. "\n")
end

-- Shared spam starter used by dialog and auto-start
local function start_spam_loop(msg, delay, confirm_back_flag)
    if spam_thread_running then
        helpers.OnConsoleMessage("`4Spammer already running, skip start")
        return
    end

    if not msg or msg == "" then
        helpers.OnConsoleMessage("`4Please set a spam message first!")
        config.spam = false
        return
    end

    delay = tonumber(delay) or 1000
    if delay < 1000 then delay = 1000 end

    config.spam = true
    config.spammsg = msg
    config.spamdelay = delay
    config.confirm_back = confirm_back_flag and true or false

    helpers.OnTextOverlay("`2Started `wSpammer")
    LogToConsole("`6Spammer Started")

    RunThread(function()
        spam_thread_running = true
        -- Simpan posisi dan dunia saat start
        local world = GetWorld()
        if not world or not world.name then
            helpers.OnConsoleMessage("`4Not in a world or world data unavailable!")
            config.spam = false
            spam_thread_running = false
            return
        end
        local savedWorld = world.name

        local localData = GetLocal()
        if not localData or not localData.pos then
            helpers.OnConsoleMessage("`4Local player data unavailable!")
            config.spam = false
            spam_thread_running = false
            return
        end
        local savedPx = localData.pos.x
        local savedPy = localData.pos.y
        local savedTileX = math.floor(savedPx / 32)
        local savedTileY = math.floor(savedPy / 32)

        LogToConsole("`9Position saved: World `w" .. savedWorld .. "`9 at (`w" .. savedTileX .. ", " .. savedTileY .. "`9)")

        while config.spam do
            helpers.Spammers(config.spammsg)
            Sleep(config.spamdelay)

            if config.confirm_back then
                local currentWorldObj = GetWorld()
                -- Gabungkan kondisi: data hilang ATAU nama dunia tidak cocok
                if not currentWorldObj or currentWorldObj.name ~= savedWorld then
                    LogToConsole("`eDisconnected or in wrong world. Rejoining `w" .. savedWorld .. "`e...")
                    SendPacket(3, "action|join_request\nname|" .. savedWorld .. "\ninvitedWorld|0")
                    Sleep(6000)  -- Tunggu 6 detik hingga join world selesai
                end

                -- Setelah menunggu (atau jika sudah di dunia yang benar), periksa posisi
                localData = GetLocal()
                if localData and localData.pos then
                    local currentPx = localData.pos.x
                    local currentPy = localData.pos.y

                    -- Cek jika posisi tidak sesuai (dengan toleransi 1 tile / 32 pixel)
                    if math.abs(currentPx - savedPx) > 32 or math.abs(currentPy - savedPy) > 32 then
                        LogToConsole("`aPosition mismatch. Returning to saved position...")
                        -- Gunakan MoveToTile yang baru dengan GhostMode = true
                        helpers.MoveToTile(savedTileX, savedTileY, false)
                    end
                else
                    -- Jika setelah 6 detik data local masih tidak ada, mungkin ada masalah lain
                    LogToConsole("`4Warning: Could not get local player data after rejoining.")
                end
            end
        end
        spam_thread_running = false
    end)
end
helpers.start_spam_loop = start_spam_loop

function helpers.OnDroppedItem(id, amount)
    SendPacket(2, "action|dialog_return\ndialog_name|drop\nitem_drop|" .. id .. "|\nitem_count|" .. amount)
end

function helpers.OnDroppedItem(id, amount)
    local item_info = GetItemInfo(id)
    local item_name = (item_info and item_info.name and item_info.name ~= "" and item_info.name) or ("Item ID " .. tostring(id))
    local item_color = "`w"

    if id == ITEM_IDS.WORLD_LOCK then
        item_color = "`9"
    elseif id == ITEM_IDS.DIAMOND_LOCK then
        item_color = "`1"
    elseif id == ITEM_IDS.BLUE_GEM_LOCK then
        item_color = "`e"
    elseif id == ITEM_IDS.BLACK_GEM_LOCK then
        item_color = "`b"
    elseif item_info and tonumber(item_info.rarity or 0) >= 5 then
        item_color = "`6"
    end

    if type(config.logdrop) ~= "string" then
        config.logdrop = ""
    end

    local drop_entry = "add_label_with_icon|small|`w[`7" .. os.date("%H:%M") .. "`w] `9You've Dropped `2"
        .. tostring(amount) .. " " .. item_color .. item_name .. "|left|" .. tostring(id) .. "|"

    if config.logdrop == "" then
        config.logdrop = drop_entry
    else
        config.logdrop = config.logdrop .. "\n" .. drop_entry
    end

    SendPacket(2, "action|dialog_return\ndialog_name|drop\nitem_drop|" .. id .. "|\nitem_count|" .. amount)
end

function helpers.OnInventoryDrp(id, amount)
    SendPacket(2, "action|dialog_return\ndialog_name|drop\nitem_drop|" .. id .. "|\nitem_count|" .. amount .. "\n")
end

function helpers.OnWarning(str)
    SendVariantList({[0] = "OnAddNotification", [1] = "interface/atomic_button.rttex", [2] = str, [3] = "audio/ogg/suspended.ogg"}, -1)
end

function helpers.SendNotification(text)
    SendVariantList({
        [0] = "OnAddNotification",
        [1] = "interface/large/JzProxyNotifs.rttex",
        [2] = text,
        [3] = "audio/sungate.wav",
        [4] = 0
    }, -1)
end

function helpers.OnQuickGamble(str)
    SendPacket(2, "action|dialog_return\ndialog_name|quickgamble\nbuttonClicked|" .. str .. "\n")
end

function helpers.isReme(number)
    number = tonumber(number)
    if not number then return "", "" end

    local num1 = math.floor(number / 10)
    local num2 = number % 10
    local sum = num1 + num2
    local result = tostring(sum):sub(-1)

    if number == 19 or number == 28 or number == 0 then
        return "`2" .. result, "`b[`2 X3 `b]"
    elseif number == 29 or number == 10 or number == 1 then
        return "`4" .. result, "`b[`4 LOSE `b]"
    else
        return "`c" .. result, ""
    end
end

function helpers.isHOL(number, playerKey)
    number = tonumber(number)
    if not number or not playerKey then return "", "" end
    
    -- If single spin is 0, instant LOSE (no need to wait for 3 spins)
    if number == 0 then
        config.holSpins[playerKey] = {} -- Reset tracking
        return "`40", "`b[`4 LOSE `b]"
    end
    
    -- Initialize table for this player if not exists
    if not config.holSpins[playerKey] then
        config.holSpins[playerKey] = {}
    end
    
    local spins = config.holSpins[playerKey]
    
    -- Track last 3 spins for this specific player
    table.insert(spins, number)
    if #spins > 3 then
        table.remove(spins, 1)
    end
    
    -- Calculate total if we have 3 spins
    if #spins == 3 then
        local total = spins[1] + spins[2] + spins[3]
        
        -- Reset after showing result
        config.holSpins[playerKey] = {}
        
        if total == 55 or total > 99 then
            return "`4" .. total, "`b[`4 LOSE `b]"
        elseif total >= 56 and total <= 99 then
            return "`2" .. total, "`b[`2 HIGH `b]"
        elseif total >= 1 and total <= 54 then
            return "`4" .. total, "`b[`4 LOW `b]"
        end
    end
    
    -- Show current progress
    return "`c" .. number, "`w[" .. #spins .. "/3]"
end

function helpers.isLeme(number)
    number = tonumber(number)
    if not number then return "", "" end

    local num1 = math.floor(number / 10)
    local num2 = number % 10
    local sum = num1 + num2
    local result = tostring(sum):sub(-1)

    if number == 19 or number == 28 or number == 0 then
        return "`20", "`b[`2 X4 `b]"
    elseif number == 1 or number == 29 or number == 10 then
        return "`2" .. result, "`b[`2 X3 `b]"
    elseif number == 11 or number == 2 or number == 20 or number == 9 or number == 27 or number == 36 or number == 18 then
        return "`4" .. result, "`b[`4 LOSE `b]"
    else
        return "`c" .. result, ""
    end
end

function helpers.isCeme(number)
    number = tonumber(number)
    if not number then return "", "" end

    local num1 = math.floor(number / 10)
    local num2 = number % 10
    local sum = num1 + num2
    local result = tostring(sum):sub(-1)

    if number == 19 or number == 28 or number == 0 then
        return "`20", "`b[`2 X4 `b]"
    elseif number == 1 or number == 29 or number == 10 or number == 2 or number == 11 or number == 20 then
        return "`2" .. result, "`b[`2 X3 `b]"
    elseif number == 21 or number == 12 or number == 3 or number == 30 then
        return "`4" .. result, "`b[`2 HOSTER WIN `b]"
    elseif number == 9 or number == 27 or number == 36 or number == 18 then
        return "`4" .. result, "`b[`4 LOSE `b]"
    else
        return "`c" .. result, ""
    end
end

function helpers.isLemeSuper(number)
    number = tonumber(number)
    if not number then return "", "" end

    local num1 = math.floor(number / 10)
    local num2 = number % 10
    local sum = num1 + num2
    local result = tostring(sum):sub(-1)

    if number == 19 or number == 28 then
        return "`20", "`b[`2 X5 `b]"
    elseif number == 1 or number == 29 or number == 10 then
        return "`2" .. result, "`b[`2 X3 `b]"
    elseif number == 11 or number == 2 or number == 20 or number == 9 or number == 27 or number == 36 or number == 18 or number == 3 or number == 12 or number == 30 or number == 21 or number == 0 then
        return "`4" .. result, "`b[`4 LOSE `b]"
    else
        return "`c" .. result, ""
    end
end

function helpers.isQeme(number)
    number = tonumber(number)
    if not number then return "", "" end

    local result = (number >= 10) and tostring(number):sub(-1) or tostring(number)

    if number == 0 then
        return "`4" .. result, "`b[`4 LOSE `b]"
    elseif number == 10 or number == 20 or number == 30 then
        return "`2" .. result, "`b[`2 X3 `b]"
    else
        return "`c" .. result, ""
    end
end

function helpers.isLewa(number)
    number = tonumber(number)
    if not number then return "", "" end

    local result = (number >= 10) and tostring(number):sub(-1) or tostring(number)

    if number == 0 then
        return "`4" .. result, "`b[`4 LOSE `b]"
    elseif number == 9 or number == 19 or number == 29 then
        return "`2" .. result, "`b[`2 X3 `b]"
    elseif number == 10 or number == 20 or number == 30 then
        return "`2" .. result, "`b[`2 X4 `b]"
    else
        return "`c" .. result, ""
    end
end

-- Tambahin ini di atas fungsi getGame, atau di bagian helpers
local function parseEmojiString(emojiStr)
    local emojis = {}
    for emoji in emojiStr:gmatch("%(([^)]+)%)") do
        emojis[emoji] = "(" .. emoji .. ")"  -- Simpan sebagai key-value buat lookup cepet
    end
    return emojis
end

local EmojiString = '(wl)(yes)(no)(love)(oops)(shy)(wink)(tongue)(agree)(sleep)(punch)(music)(build)(megaphone)(sigh)(mad)(wow)(dance)(bheart)(heart)(grow)(gems)(kiss)(gtoken)(lol)(smile)(cool)(cry)(vend)(bunny)(cactus)(pine)(peace)(terror)(troll)(evil)(fireworks)(football)(alien)(party)(pizza)(clap)(song)(ghost)(nuke)(halo)(turkey)(gift)(cake)(heartarrow)(lucky)(shamrock)(grin)(ill)(eyes)(weary)(moyai)(plead)'
local emojis = parseEmojiString(EmojiString)

local winEmoji = emojis["lol"] or "(lol)"  -- Ganti ke "(heart)" kalau mau
local loseEmoji = emojis["cry"] or "(cry)"  -- Ganti ke "(no)" kalau mau
local x3Emoji = emojis["troll"] or "(troll)"      -- Ganti ke "(smile)" kalau mau
local x4Emoji = emojis["wink"] or "(wink)"      -- Ganti ke "(smile)" kalau mau
local x5Emoji = emojis["cool"] or "(cool)"      -- Ganti ke "(smile)" kalau mau
function helpers.getGame(num, netid)
    local number = tonumber(num)
    if not number then return "" end

    local function coloredLabel(lbl)
        local colors = { "`8", "`9", "`2", "`4" }
        local parts = {}
        for i = 1, #lbl do
            parts[#parts + 1] = (colors[i] or "`5") .. lbl:sub(i, i)
        end
        return table.concat(parts)
    end

    local modes = {
        { key = "reme", label = "REME", func = helpers.isReme },
        { key = "leme", label = "LEME", func = helpers.isLeme },
        { key = "qeme", label = "QEME", func = helpers.isQeme },
        { key = "lewa", label = "LEWA", func = helpers.isLewa },
        { key = "ceme", label = "CEME", func = helpers.isCeme },
        { key = "lemesuper", label = "LEME SUPER", func = helpers.isLemeSuper },
        { key = "hol", label = "HOL", func = helpers.isHOL },
    }

    local active
    for _, m in ipairs(modes) do
        if config[m.key] then
            active = m
            break
        end
    end
    if not active then return "" end

    -- Call function dengan atau tanpa playerKey (hanya HOL yang butuh playerKey)
    local result, status
    if active.key == "hol" and netid then
        result, status = active.func(number, "player_" .. netid)
    else
        result, status = active.func(number)
    end
    
    if status and status ~= "" then
        if status:find("WIN") then
            status = status .. " " .. winEmoji  -- Win: tambah (yes)
        elseif status:find("X3") then
            status = status .. " " .. x3Emoji  -- X3: tambah (smile)
        elseif status:find("X4") then
            status = status .. " " .. x4Emoji  -- X4: tambah (smile)
        elseif status:find("X5") then
            status = status .. " " .. x5Emoji  -- X5: tambah (sm
        elseif status:find("LOSE") then
            status = status .. " " .. loseEmoji  -- Lose: tambah (cry)
        end
    end
    
    return string.format("`b[%s: %s`b] %s", coloredLabel(active.label), result, status or "")
end


function helpers.convert_hours_to_time(hours)
    if not hours or hours <= 0 then return "0 minutes" end
    local total_minutes = math.floor(hours * 60)
    local years = math.floor(total_minutes / (365 * 24 * 60))
    total_minutes = total_minutes % (365 * 24 * 60)
    local days = math.floor(total_minutes / (24 * 60))
    total_minutes = total_minutes % (24 * 60)
    local hrs = math.floor(total_minutes / 60)
    local minutes = total_minutes % 60
    local parts = {}
    if years > 0 then table.insert(parts, years .. " year" .. (years > 1 and "s" or "")) end
    if days > 0 then table.insert(parts, days .. " day" .. (days > 1 and "s" or "")) end
    if hrs > 0 then table.insert(parts, hrs .. " hour" .. (hrs > 1 and "s" or "")) end
    if minutes > 0 then table.insert(parts, minutes .. " minute" .. (minutes > 1 and "s" or "")) end
    if #parts == 0 then return "0 minutes" end
    return table.concat(parts, ", ")
end

function helpers.get_time_difference(from_date)
    if not from_date or from_date == "" then return "N/A", 0 end
    local current_date = os.time()
    local pattern = "(%d+)-(%d+)-(%d+) (%d+):(%d+):(%d+)"
    local year, month, day, hour, min, sec = from_date:match(pattern)
    if not (year and month and day and hour and min and sec) then return "N/A", 0 end

    local from_time = os.time{
        year = tonumber(year),
        month = tonumber(month),
        day = tonumber(day),
        hour = tonumber(hour),
        min = tonumber(min),
        sec = tonumber(sec)
    }

    local diff_seconds = os.difftime(current_date, from_time)
    if diff_seconds < 0 then return "N/A", 0 end

    local diff_hours = math.floor(diff_seconds / 3600)
    local diff_days = math.floor(diff_seconds / (24 * 3600))
    local diff_years = math.floor(diff_days / 365)

    local result = {}
    if diff_years > 0 then
        table.insert(result, diff_years .. " year" .. (diff_years > 1 and "s" or ""))
    end
    if diff_days % 365 > 0 then
        table.insert(result, (diff_days % 365) .. " days")
    end
    if diff_hours % 24 > 0 then
        table.insert(result, (diff_hours % 24) .. " hours")
    end

    return table.concat(result, " "), diff_hours
end

function helpers.GetPlayerName(netid)
    local success, players = pcall(GetPlayerList)
    if success then
        for _, player in pairs(players) do
            if player.netid == netid then
                return stripColors(player.name or "Unknown")
            end
        end
    end
    return "Unknown"
end

-- ============ NEW FEATURES ============

-- Sign Scanner: Scan all signs in world
function helpers.ScanAllSigns()
    local tiles = get_tiles_cached()
    if not tiles then
        helpers.OnTextOverlay("`4Error: Unable to access world tiles!")
        return
    end
    
    local signs = {}
    for _, tile in pairs(tiles) do
        if tile.fg == ITEM_IDS.SIGN and tile.extra and tile.extra.label then
            table.insert(signs, {
                x = tile.x,
                y = tile.y,
                text = tile.extra.label
            })
        end
    end
    
    if #signs == 0 then
        helpers.OnTextOverlay("`4No signs found in this world!")
        return
    end
    
    -- Build dialog
    local dialog = [[
set_default_color|`o
set_border_color|]] .. config.dialogBorder .. [[|
set_bg_color|]] .. config.dialogBg .. [[|
add_label_with_icon|big|`eSign Scanner Results|left|]] .. ITEM_IDS.SIGN .. [[|
add_spacer|small|
add_textbox|`9Found ]] .. #signs .. [[ signs in this world:|
add_spacer|small|
]]
    
    for i, sign in ipairs(signs) do
        if i <= 20 then -- Limit to 20 signs to prevent dialog overflow
            dialog = dialog .. string.format(
                "add_smalltext|`w[%d, %d] `7%s|\n",
                sign.x, sign.y, sign.text:gsub("|", "¦")
            )
        end
    end
    
    if #signs > 20 then
        dialog = dialog .. "add_smalltext|`4... and " .. (#signs - 20) .. " more signs|\n"
    end
    
    dialog = dialog .. [[
add_spacer|small|
add_quick_exit||
end_dialog|sign_scanner|Close||
]]
    
    SendVariantList({[0] = "OnDialogRequest", [1] = dialog, netid = -1})
    helpers.OnConsoleMessage("`9Sign Scanner: Found " .. #signs .. " signs")
end

-- Auto Pickup: Automatically collect floating items
function helpers.AutoPickupFloatingItems()
    if operation_flags.is_collecting then
        helpers.OnTextOverlay("`4Auto pickup already running!")
        return
    end
    
    operation_flags.is_collecting = true
    
    RunThread(function()
        local success, world = pcall(GetWorld)
        if not success or not world then
            helpers.OnConsoleMessage("`4Error: Not in a world!")
            operation_flags.is_collecting = false
            return
        end
        
        local targetItems = {
            [ITEM_IDS.WORLD_LOCK] = true,
            [ITEM_IDS.DIAMOND_LOCK] = true,
            [ITEM_IDS.BLUE_GEM_LOCK] = true,
            [ITEM_IDS.BLACK_GEM_LOCK] = true
        }
        
        local success2, objects = pcall(GetObjectList)
        if not success2 or not objects then
            helpers.OnConsoleMessage("`4Error: Unable to get object list!")
            operation_flags.is_collecting = false
            return
        end
        
        local collected = 0
        for _, obj in pairs(objects) do
            if targetItems[obj.id] then
                local tileX = math.floor(obj.pos.x / 32)
                local tileY = math.floor(obj.pos.y / 32)
                
                FindPath(tileX, tileY)
                Sleep(DELAYS.SAFE_DELAY)
                collected = collected + 1
            end
        end
        
        operation_flags.is_collecting = false
        helpers.OnTextOverlay("`2Auto pickup completed: " .. collected .. " items")
    end)
end

-- Broadcast Spam Detector
local last_broadcast_time = 0
local broadcast_spam_count = 0

function helpers.CheckBroadcastSpam()
    local current_time = os.time()
    
    if current_time - last_broadcast_time < 5 then
        broadcast_spam_count = broadcast_spam_count + 1
        if broadcast_spam_count >= 3 then
            if config.broadcast then
                config.broadcast = false
                helpers.OnConsoleMessage("`4Broadcast paused: Spam detected!")
                helpers.OnTextOverlay("`4Broadcast auto-paused due to spam detection")
                return true
            end
        end
    else
        broadcast_spam_count = 0
    end
    
    last_broadcast_time = current_time
    return false
end

-- Safe Respawn: Auto exit if in dangerous world
config.dangerous_worlds = {"MEMEK", "MOMOK", "KONTOL", "CIBEY"} -- Configurable

function helpers.SafeRespawn()
    local success, world = pcall(GetWorld)
    if not success or not world then return end
    
    local worldName = world.name:upper()
    for _, dangerous in ipairs(config.dangerous_worlds) do
        if worldName:find(dangerous) then
            helpers.OnConsoleMessage("`4Dangerous world detected! Exiting...")
            Sleep(DELAYS.SHORT_DELAY)
            SendPacket(3, "action|join_request\nname|exit")
            return true
        end
    end
    return false
end

-- Casino Analyzer: Simple pattern detection
config.spin_history = {}
config.spin_stats = {}

function helpers.AnalyzeCasinoPattern(number)
    table.insert(config.spin_history, number)
    
    -- Keep only last 50 spins
    if #config.spin_history > 50 then
        table.remove(config.spin_history, 1)
    end
    
    -- Count frequency
    config.spin_stats[number] = (config.spin_stats[number] or 0) + 1
    
    -- Simple "hot" number detection (appeared 3+ times in last 20 spins)
    if #config.spin_history >= 20 then
        local recent_count = 0
        for i = #config.spin_history - 19, #config.spin_history do
            if config.spin_history[i] == number then
                recent_count = recent_count + 1
            end
        end
        
        if recent_count >= 3 then
            helpers.OnConsoleMessage("`2[Casino] Hot number detected: " .. number .. " (appeared " .. recent_count .. " times recently)")
        end
    end
end

function helpers.ShowCasinoStats()
    local dialog = [[
set_default_color|`o
set_border_color|]] .. config.dialogBorder .. [[|
set_bg_color|]] .. config.dialogBg .. [[|
add_label_with_icon|big|`eCasino Pattern Analyzer|left|758|
add_spacer|small|
add_textbox|`7Analysis based on last ]] .. #config.spin_history .. [[ spins:|
add_spacer|small|
]]
    
    -- Sort by frequency
    local sorted = {}
    for num, count in pairs(config.spin_stats) do
        table.insert(sorted, {number = num, count = count})
    end
    table.sort(sorted, function(a, b) return a.count > b.count end)
    
    -- Top 10 numbers
    dialog = dialog .. "add_label|small|`2Top 10 Hot Numbers:|left|\n"
    for i = 1, math.min(10, #sorted) do
        local percent = (sorted[i].count / #config.spin_history) * 100
        dialog = dialog .. string.format(
            "add_smalltext|`w%d. Number `e%d `w- `2%d times `7(%.1f%%)|\n",
            i, sorted[i].number, sorted[i].count, percent
        )
    end
    
    -- Last 10 spins
    dialog = dialog .. [[
add_spacer|small|
add_label|small|`9Last 10 Spins:|left|
]]
    local start = math.max(1, #config.spin_history - 9)
    for i = start, #config.spin_history do
        dialog = dialog .. "add_smalltext|`w" .. config.spin_history[i] .. "|\n"
    end
    
    dialog = dialog .. [[
add_spacer|small|
add_smalltext|`7Note: This is for entertainment only. Casino games are random!|
add_quick_exit||
end_dialog|casino_stats|Close||
]]
    
    SendVariantList({[0] = "OnDialogRequest", [1] = dialog, netid = -1})
end

function helpers.ShowSpinLogsDialog(netid_str)
    local netid = tostring(netid_str)
    config.playerSpins = config.playerSpins or {}
    
    -- Get player info
    local player = GetPlayer(tonumber(netid_str))
    local playerName = player and player.name or "Unknown Player"
    local cleanName = playerName:gsub("`.", ""):gsub("`", "")
    
    -- Get spin logs for this player
    local playerData = config.playerSpins[netid]
    
    local dialog = "set_default_color|`o\n"
    dialog = dialog .. "set_border_color|" .. config.dialogBorder .. "|\n"
    dialog = dialog .. "set_bg_color|" .. config.dialogBg .. "|\n"
    dialog = dialog .. "add_label_with_icon|big|`cSpin Logs - " .. cleanName .. "``|left|758|\n"
    dialog = dialog .. "add_spacer|small|\n"
    
    if playerData and playerData.logs and #playerData.logs > 0 then
        dialog = dialog .. "add_label|small|`c " .. #playerData.logs .. " Spins:|left|\n"
        
        -- Use stored log entries
        for i = 1, #playerData.logs do
            dialog = dialog .. playerData.logs[i]
        end
    else
        dialog = dialog .. "add_smalltext|`4No spin logs found for this player.|\n"
    end
    
    dialog = dialog .. [[
add_spacer|small|
add_quick_exit||
end_dialog|spin_logs_dialog|Close||
]]
    
    SendVariantList({[0] = "OnDialogRequest", [1] = dialog, netid = -1})
end

-- =========================================================
-- Slash Command Map (Exact token parser + dispatcher)
-- =========================================================
local COMMAND_DEFS = {}
local COMMAND_MAP = {}
local COMMAND_ALIAS_TO_CANONICAL = {}

local function normalize_command_name(raw)
    local value = tostring(raw or ""):lower()
    value = value:gsub("^%s*/", "")
    value = value:gsub("^%s+", ""):gsub("%s+$", "")
    return value
end

local function register_command(def)
    if type(def) ~= "table" then
        return
    end
    local name = normalize_command_name(def.name)
    if name == "" then
        return
    end

    def.name = name
    def.aliases = def.aliases or {}
    COMMAND_MAP[name] = def
    table.insert(COMMAND_DEFS, def)

    for _, alias in ipairs(def.aliases) do
        local alias_name = normalize_command_name(alias)
        if alias_name ~= "" and alias_name ~= name then
            COMMAND_ALIAS_TO_CANONICAL[alias_name] = name
        end
    end
end

local function resolve_registered_command(token)
    local cmd = normalize_command_name(token)
    if cmd == "" then
        return nil, nil
    end
    if COMMAND_MAP[cmd] then
        return cmd, COMMAND_MAP[cmd]
    end
    local canonical = COMMAND_ALIAS_TO_CANONICAL[cmd]
    if canonical and COMMAND_MAP[canonical] then
        return canonical, COMMAND_MAP[canonical]
    end
    return nil, nil
end

local function get_local_userid_safe()
    local ok, local_player = pcall(GetLocal)
    if ok and local_player then
        return math.floor(tonumber(local_player.userid) or 0)
    end
    return 0
end

local function parse_positive_integer(raw)
    if type(raw) ~= "string" then
        raw = tostring(raw or "")
    end
    local value = raw:match("^%s*(%d+)%s*$")
    local number = tonumber(value)
    if number and number > 0 then
        return math.floor(number)
    end
    return nil
end

local function extract_chat_text_from_packet(packet)
    if type(packet) ~= "string" then
        return nil
    end
    if packet:find("action|input", 1, true) then
        local text = packet:match("|text|([^\n]*)")
        if type(text) ~= "string" then
            return nil
        end
        text = text:gsub("\r", "")
        text = text:gsub("^%s+", ""):gsub("%s+$", "")
        return text
    end

    local raw = packet:gsub("\r", "")
    raw = raw:gsub("^%s+", ""):gsub("%s+$", "")
    if raw:sub(1, 1) == "/" then
        return raw
    end
    return nil
end

local function parse_slash_command_packet(packet)
    local text = extract_chat_text_from_packet(packet)
    if not text or text == "" then
        return nil
    end
    if text:sub(1, 1) ~= "/" then
        return nil
    end

    local body = text:sub(2)
    local token, args = body:match("^([^%s]+)%s*(.-)$")
    if not token or token == "" then
        return nil
    end

    return {
        text = text,
        token = normalize_command_name(token),
        args = tostring(args or ""),
        packet = packet
    }
end

local function append_drop_log_message(msg)
    local clean = stripColors(tostring(msg or "")):gsub("%([^)]+%)", ""):gsub("^%s+", ""):gsub("%s+$", "")
    if clean == "" then
        return
    end
    if type(config.logdrop) ~= "string" or config.logdrop == "" then
        config.logdrop = clean
    else
        config.logdrop = config.logdrop .. "\n" .. clean
    end
end

function helpers.IsAutoPullAdminUser(userid)
    local id = math.floor(tonumber(userid) or 0)
    for _, allowedId in ipairs(autoPullUserIds or {}) do
        if id == math.floor(tonumber(allowedId) or 0) then
            return true
        end
    end

    return false
end

function helpers.GetAutoPullAdminCount()
    local count = 0
    for _, allowedId in ipairs(autoPullUserIds or {}) do
        if tonumber(allowedId) then
            count = count + 1
        end
    end
    return count
end

local function is_owner_user(userid)
    return math.floor(tonumber(userid) or 0) == OWNER_USER_ID
end

function helpers.InvokeRegisteredCommand(command_name)
    local canonical, def = resolve_registered_command(command_name)
    if not canonical or not def or type(def.handler) ~= "function" then
        return false, "command_not_found"
    end

    local ok, handled = pcall(def.handler, {
        token = "/" .. canonical,
        args = "",
        text = "/" .. canonical,
        command = canonical
    })
    if not ok then
        return false, handled
    end

    return true, handled
end

function helpers.GetOptionToggleDefs(userid)
    local numeric_userid = math.floor(tonumber(userid) or get_local_userid_safe() or 0)

    return {
        {
            id = "opt_imgui",
            category = "Settings",
            label = "`9ImGui Panel `8(/imgui)",
            get = function() return imgui_state.visible and true or false end,
            apply = function(desired, current)
                if desired ~= current then
                    if desired and not is_imgui_supported() then
                        helpers.OnConsoleMessage("`4[Option] ImGui is not available in this runtime.")
                        return false, "imgui_unavailable"
                    end
                    return helpers.InvokeRegisteredCommand("imgui")
                end
                return true
            end
        },
        {
            id = "opt_eventbutton",
            category = "Settings",
            label = "`6Hide Event Button `8(/eventbutton) `7(relog)",
            get = function() return config.event_button_hide and true or false end,
            apply = function(desired)
                config.event_button_hide = desired and true or false
                return true
            end
        },
        {
            id = "opt_rbt",
            category = "Chat",
            label = "`9Rainbow Text `8(/rbt)",
            get = function() return config.rainbow_text and true or false end,
            apply = function(desired)
                config.rainbow_text = desired and true or false
                return true
            end
        },
        {
            id = "opt_emt",
            category = "Chat",
            label = "`9Emoji Text `8(/emt)",
            get = function() return config.emoji_text and true or false end,
            apply = function(desired)
                config.emoji_text = desired and true or false
                return true
            end
        },
        {
            id = "opt_fdice",
            category = "Utility",
            label = "`9Fast Dice Detector `8(/fdice)",
            get = function() return config.fdice and true or false end,
            apply = function(desired)
                config.fdice = desired and true or false
                return true
            end
        },
        {
            id = "opt_blockspam",
            category = "Utility",
            label = "`4Block Spammer Slave `8(/blockspam)",
            get = function() return config.block_spammer_slave and true or false end,
            apply = function(desired)
                config.block_spammer_slave = desired and true or false
                return true
            end
        },
        {
            id = "opt_slave",
            category = "Utility",
            label = "`4Anti Spammer Slave `8(/slave)",
            get = function() return config.antiSpammerSlave and true or false end,
            apply = function(desired)
                config.antiSpammerSlave = desired and true or false
                config.block_spammer_slave = desired and true or false
                return true
            end
        },
        {
            id = "opt_blink",
            category = "Utility",
            label = "`eBlink Skin `8(/blink)",
            get = function() return config.blink_skin and true or false end,
            apply = function(desired)
                if desired then
                    helpers.start_blink_skin()
                else
                    helpers.stop_blink_skin()
                end
                return true
            end
        },
        {
            id = "opt_tdb",
            category = "Utility",
            label = "`2Fast Take Display Block `8(/tdb)",
            get = function() return config.fastdb and true or false end,
            apply = function(desired)
                config.fastdb = desired and true or false
                config.fastdbl = config.fastdb
                return true
            end
        },
        {
            id = "opt_vendfilter",
            category = "Utility",
            label = "`eVend Filter `8(/vendfilter)",
            get = function() return config.vendfilter and true or false end,
            apply = function(desired)
                config.vendfilter = desired and true or false
                return true
            end
        },
        {
            id = "opt_dboxfilter",
            category = "Utility",
            label = "`eDonation Box Filter `8(/dboxfilter)",
            get = function() return config.dboxfilter and true or false end,
            apply = function(desired)
                config.dboxfilter = desired and true or false
                return true
            end
        },
        {
            id = "opt_gemdetect",
            category = "Utility",
            label = "`2Gem Detector `8(/gemdetect)",
            get = function() return config.autoGemDetect and true or false end,
            apply = function(desired)
                config.autoGemDetect = desired and true or false
                return true
            end
        },
        {
            id = "opt_acdoor",
            category = "Utility",
            label = "`2Auto Door `8(/acdoor)",
            get = function() return config.autoToggleDoor and true or false end,
            apply = function(desired)
                config.autoToggleDoor = desired and true or false
                return true
            end
        },
        {
            id = "opt_mf",
            category = "Utility",
            label = "`2ModFly `8(/mf)",
            get = function()
                local ok, value = pcall(GetValue, "[C] Modfly")
                return ok and value and true or false
            end,
            apply = function(desired)
                ChangeValue("[C] Modfly", desired and true or false)
                return true
            end
        },
        {
            id = "opt_tp",
            category = "Teleport",
            label = "`eTeleport Display `8(/tp)",
            get = function() return config.tpdisplay and true or false end,
            apply = function(desired)
                config.tpdisplay = desired and true or false
                return true
            end
        },
        {
            id = "opt_wrp",
            category = "Wrench",
            label = "`2Wrench Pull `8(/wrp)",
            exclusive_group = "wrench_mode",
            get = function() return config.pull and true or false end
        },
        {
            id = "opt_wrk",
            category = "Wrench",
            label = "`4Wrench Kick `8(/wrk)",
            exclusive_group = "wrench_mode",
            get = function() return config.kick and true or false end
        },
        {
            id = "opt_wrb",
            category = "Wrench",
            label = "`4Wrench Ban `8(/wrb)",
            exclusive_group = "wrench_mode",
            get = function() return config.ban and true or false end
        },
        {
            id = "opt_showbal",
            category = "Wrench",
            label = "`9Show Balance `8(/showbal)",
            get = function() return config.showbal and true or false end,
            apply = function(desired)
                config.showbal = desired and true or false
                return true
            end
        },
        {
            id = "opt_sspin",
            category = "Casino",
            label = "`6Short Spin `8(/sspin)",
            get = function() return config.sspin and true or false end,
            apply = function(desired)
                config.sspin = desired and true or false
                return true
            end
        },
        {
            id = "opt_bsdb",
            category = "Casino",
            label = "`4Block SDB `8(/bsdb)",
            get = function() return config.bsdb and true or false end,
            apply = function(desired)
                config.bsdb = desired and true or false
                return true
            end
        },
        {
            id = "opt_acsign",
            category = "Casino",
            label = "`2Auto Copy Sign `8(/acsign)",
            get = function() return config.auto_copy_sign and true or false end,
            apply = function(desired)
                config.auto_copy_sign = desired and true or false
                return true
            end
        },
        {
            id = "opt_hol",
            category = "Casino",
            label = "`eHOL Spin Mode `8(/hol)",
            get = function() return config.hol and true or false end,
            apply = function(desired)
                if desired then
                    config.reme = false
                    config.leme = false
                    config.lemesuper = false
                    config.ceme = false
                    config.qeme = false
                    config.lewa = false
                    config.hol = true
                    config.holSpins = {}
                else
                    config.hol = false
                end
                return true
            end
        },
        {
            id = "opt_cbgl",
            category = "Casino",
            label = "`eAuto Convert BGL `8(/cbgl)",
            exclusive_group = "casino_auto",
            get = function() return config.cbgl and true or false end
        },
        {
            id = "opt_buydl",
            category = "Casino",
            label = "`1Auto Buy DL `8(/buydl)",
            exclusive_group = "casino_auto",
            get = function() return config.buydl and true or false end
        },
        {
            id = "opt_buychamp",
            category = "Casino",
            label = "`6Auto Buy Champagne `8(/buychamp)",
            exclusive_group = "casino_auto",
            get = function() return config.buychamp and true or false end
        },
        {
            id = "opt_automodage",
            category = "Automation",
            label = "`2Auto Modage `8(/automodage)",
            get = function() return config.automodage and true or false end,
            apply = function(desired, current)
                if desired ~= current then
                    return helpers.InvokeRegisteredCommand("automodage")
                end
                return true
            end
        },
        {
            id = "opt_acrime",
            category = "Automation",
            label = "`4Auto Crime `8(/crime)",
            get = function() return config.acrime and true or false end,
            apply = function(desired)
                config.acrime = desired and true or false
                if config.acrime then
                    helpers.crime_state.stop_requested = false
                    helpers.ResetCrimeState(true)
                else
                    helpers.crime_state.stop_requested = true
                    helpers.ResetCrimeState(true)
                end
                return true
            end
        },
        {
            id = "opt_antilag",
            category = "Automation",
            label = "`2Anti Lag `8(/antilag)",
            get = function() return config.antiLagEnabled and true or false end,
            apply = function(desired)
                config.antiLagEnabled = desired and true or false
                ChangeValue("[C] No render particle", config.antiLagEnabled)
                ChangeValue("[C] No render shadow", config.antiLagEnabled)
                config.antiSpammerSlave = config.antiLagEnabled
                return true
            end
        },
        {
            id = "opt_ftr",
            category = "Automation",
            label = "`2Fast Trash `8(/ftr)",
            get = function() return config.fasttrash and true or false end,
            apply = function(desired)
                config.fasttrash = desired and true or false
                return true
            end
        },
        {
            id = "opt_wdv",
            category = "Conversion",
            label = "`2Auto Withdraw Vend `8(/wdv)",
            get = function() return config.wdvend and true or false end,
            apply = function(desired)
                config.wdvend = desired and true or false
                return true
            end
        },
        {
            id = "opt_evd",
            category = "Conversion",
            label = "`2Auto Empty Vend `8(/evd)",
            get = function() return config.emptyvend and true or false end,
            apply = function(desired)
                config.emptyvend = desired and true or false
                return true
            end
        },
        {
            id = "opt_cvdl",
            category = "Conversion",
            label = "`eAuto Convert DL to BGL `8(/cvdl)",
            get = function() return config.autocvdl and true or false end,
            apply = function(desired)
                config.autocvdl = desired and true or false
                return true
            end
        },
        {
            id = "opt_cvptu",
            category = "Conversion",
            label = "`3Convert Tax to UWS `8(/cvptu)",
            get = function() return config.cvptu and true or false end,
            apply = function(desired, current)
                if desired ~= current then
                    return helpers.InvokeRegisteredCommand("cvptu")
                end
                return true
            end
        },
        {
            id = "opt_ap",
            category = "Admin",
            label = "`2Auto Pull `8(/ap)",
            visible = function(current_userid)
                return helpers.IsAutoPullAdminUser(current_userid)
            end,
            get = function() return config.auto_pull.enabled and true or false end,
            apply = function(desired)
                config.auto_pull.enabled = desired and true or false
                if config.auto_pull.enabled then
                    StartAutoPullThread()
                else
                    clear_auto_pull_pending()
                    auto_pull_state.pulled_users = {}
                    auto_pull_state.thread_running = false
                end
                return true
            end
        }
    }
end

function helpers.ShowOptionDialog(userid)
    local numeric_userid = math.floor(tonumber(userid) or get_local_userid_safe() or 0)
    local defs = helpers.GetOptionToggleDefs(numeric_userid)
    local grouped = {}
    local category_order = {"Settings", "Chat", "Utility", "Teleport", "Wrench", "Casino", "Automation", "Conversion", "Admin"}
    local category_meta = {
        Settings = {title = "`eSettings Toggles", icon = 6016},
        Chat = {title = "`9Chat Toggles", icon = 1366},
        Utility = {title = "`2Utility Toggles", icon = 3898},
        Teleport = {title = "`eTeleport Toggles", icon = 2480},
        Wrench = {title = "`6Wrench Toggles", icon = 758},
        Casino = {title = "`8Casino Toggles", icon = 456},
        Automation = {title = "`3Automation Toggles", icon = 13810},
        Conversion = {title = "`1Conversion Toggles", icon = 1796},
        Admin = {title = "`4Admin Toggles", icon = 1368}
    }

    for _, def in ipairs(defs) do
        local visible = true
        if type(def.visible) == "function" then
            visible = def.visible(numeric_userid) and true or false
        end
        if visible then
            grouped[def.category] = grouped[def.category] or {}
            table.insert(grouped[def.category], def)
        end
    end

    local lines = {
        "set_default_color|`o",
        "set_border_color|" .. tostring(config.dialogBorder or "100,100,100,255") .. "|",
        "set_bg_color|" .. tostring(config.dialogBg or "45,45,45,200") .. "|",
        "add_label_with_icon|big|`eExProxy Toggle Options|left|758|",
        "add_spacer|small|",
        "add_textbox|`7Manage your main toggle commands from one dialog.|left|",
        "add_smalltext|`9Single-select is enforced for Wrench Mode and Casino Auto Buy.|left|",
        "add_smalltext|`8Some advanced toggles can affect shared state, such as /slave and /antilag.|left|",
        "add_spacer|small|"
    }

    for _, category in ipairs(category_order) do
        local items = grouped[category]
        if items and #items > 0 then
            local meta = category_meta[category] or {title = "`w" .. tostring(category), icon = 242}
            table.insert(lines, "add_label_with_icon|small|" .. meta.title .. "|left|" .. tostring(meta.icon) .. "|")
            table.insert(lines, "add_spacer|small|")

            local active_exclusive_group = nil
            for idx, def in ipairs(items) do
                if def.exclusive_group ~= active_exclusive_group then
                    if active_exclusive_group then
                        table.insert(lines, "max_checks|9999|")
                    end
                    if def.exclusive_group then
                        table.insert(lines, "max_checks|1|")
                    end
                    active_exclusive_group = def.exclusive_group
                end

                local checked = false
                local ok_get, current_value = pcall(def.get)
                if ok_get and current_value then
                    checked = true
                end
                table.insert(lines, string.format("add_checkbox|%s|%s|%d|", def.id, def.label, checked and 1 or 0))

                local next_def = items[idx + 1]
                if active_exclusive_group and (not next_def or next_def.exclusive_group ~= active_exclusive_group) then
                    table.insert(lines, "max_checks|9999|")
                    active_exclusive_group = nil
                end
            end

            table.insert(lines, "add_spacer|small|")
        end
    end

    table.insert(lines, "add_quick_exit||")
    table.insert(lines, "end_dialog|option_dialog|Close|Save|")
    SendVariantList({[0] = "OnDialogRequest", [1] = table.concat(lines, "\n"), netid = -1})
end

function helpers.ApplyOptionDialogSelections(str)
    local numeric_userid = math.floor(tonumber(get_local_userid_safe()) or 0)
    local defs = helpers.GetOptionToggleDefs(numeric_userid)
    local desired = {}
    local change_count = 0
    local error_count = 0

    for _, def in ipairs(defs) do
        local visible = true
        if type(def.visible) == "function" then
            visible = def.visible(numeric_userid) and true or false
        end
        if visible then
            desired[def.id] = str:find(def.id .. "|1", 1, true) ~= nil
        end
    end

    local current_wrench = nil
    if config.pull then
        current_wrench = "pull"
    elseif config.kick then
        current_wrench = "kick"
    elseif config.ban then
        current_wrench = "ban"
    end

    local desired_wrench = nil
    if desired.opt_wrp then
        desired_wrench = "pull"
    elseif desired.opt_wrk then
        desired_wrench = "kick"
    elseif desired.opt_wrb then
        desired_wrench = "ban"
    end

    if desired_wrench ~= current_wrench then
        config.pull = (desired_wrench == "pull")
        config.kick = (desired_wrench == "kick")
        config.ban = (desired_wrench == "ban")
        change_count = change_count + 1
    end

    local current_casino_auto = nil
    if config.cbgl then
        current_casino_auto = "cbgl"
    elseif config.buydl then
        current_casino_auto = "buydl"
    elseif config.buychamp then
        current_casino_auto = "buychamp"
    end

    local desired_casino_auto = nil
    if desired.opt_cbgl then
        desired_casino_auto = "cbgl"
    elseif desired.opt_buydl then
        desired_casino_auto = "buydl"
    elseif desired.opt_buychamp then
        desired_casino_auto = "buychamp"
    end

    if desired_casino_auto ~= current_casino_auto then
        config.cbgl = (desired_casino_auto == "cbgl")
        config.buydl = (desired_casino_auto == "buydl")
        config.buychamp = (desired_casino_auto == "buychamp")
        change_count = change_count + 1
    end

    for _, def in ipairs(defs) do
        local visible = true
        if type(def.visible) == "function" then
            visible = def.visible(numeric_userid) and true or false
        end
        if visible and not def.exclusive_group and type(def.apply) == "function" then
            local ok_get, current_value = pcall(def.get)
            current_value = ok_get and (current_value and true or false) or false
            local desired_value = desired[def.id] and true or false
            if desired_value ~= current_value then
                local ok_apply, apply_result, apply_err = pcall(def.apply, desired_value, current_value, numeric_userid)
                if ok_apply and apply_result ~= false then
                    change_count = change_count + 1
                else
                    error_count = error_count + 1
                    helpers.OnConsoleMessage("`4[Option] Failed to apply " .. tostring(def.id) .. ": `w" .. tostring(apply_err or apply_result))
                end
            end
        end
    end

    auto_save_config(true)
    helpers.OnTextOverlay("`2Option dialog applied: `w" .. tostring(change_count) .. " `2change(s)")
    helpers.OnConsoleMessage("`2[Option] Applied `w" .. tostring(change_count) .. " `2toggle change(s).")
    if error_count > 0 then
        helpers.OnConsoleMessage("`4[Option] Errors: `w" .. tostring(error_count))
    end
end

local function get_dynamic_drop_command_names()
    local function normalize_or_default(raw, fallback)
        local value = tostring(raw or fallback or ""):lower()
        value = value:gsub("[%s%p]", "")
        if value == "" then
            value = tostring(fallback or "")
        end
        return value
    end

    local wl_cmd = normalize_or_default(config.cmd_drop_wl, "w")
    local dl_cmd = normalize_or_default(config.cmd_drop_dl, "d")
    local bgl_cmd = normalize_or_default(config.cmd_drop_bgl, "b")
    local black_cmd = normalize_or_default(config.cmd_drop_black, "bb")
    return wl_cmd, dl_cmd, bgl_cmd, black_cmd
end

local function execute_drop_world_lock(count)
    RunThread(function()
        local dl = math.floor(count / 100)
        local wl = count % 100
        local bgl = math.floor(dl / 100)
        dl = dl % 100

        if bgl > 0 and GetItemCount(ITEM_IDS.BLUE_GEM_LOCK) < bgl then
            helpers.Say("`6Not enough BGL, crafting...`0")
            SendPacket(2, "action|dialog_return\ndialog_name|info_box\nbuttonClicked|make_bluegl")
            Sleep(100)
        end

        if bgl > 0 then
            if GetItemCount(ITEM_IDS.BLUE_GEM_LOCK) >= bgl then
                helpers.OnDroppedItem(ITEM_IDS.BLUE_GEM_LOCK, bgl)
                Sleep(100)
            else
                helpers.Say("`4Not enough BGL to drop!`0")
                return
            end
        end

        if dl > 0 and GetItemCount(ITEM_IDS.DIAMOND_LOCK) < dl then
            helpers.OnWear(ITEM_IDS.BLUE_GEM_LOCK)
            Sleep(100)
        end

        if dl > 0 then
            if GetItemCount(ITEM_IDS.DIAMOND_LOCK) >= dl then
                helpers.OnDroppedItem(ITEM_IDS.DIAMOND_LOCK, dl)
                Sleep(100)
            else
                helpers.Say("`4Not enough DL to drop!`0")
                return
            end
        end

        if wl > 0 and GetItemCount(ITEM_IDS.WORLD_LOCK) < wl then
            helpers.OnWear(ITEM_IDS.DIAMOND_LOCK)
            local wait_time = 0
            while GetItemCount(ITEM_IDS.WORLD_LOCK) < wl and wait_time < 2000 do
                Sleep(100)
                wait_time = wait_time + 100
            end
        end

        if wl > 0 then
            if GetItemCount(ITEM_IDS.WORLD_LOCK) >= wl then
                helpers.OnDroppedItem(ITEM_IDS.WORLD_LOCK, wl)
            else
                helpers.Say("`4Not enough WL to drop!`0")
                return
            end
        end

        local msg = "`2DROPPED: "
        if bgl > 0 then msg = msg .. "`w" .. bgl .. " `eBGL " end
        if dl > 0 then msg = msg .. "`w" .. dl .. " `1DL " end
        if wl > 0 then msg = msg .. "`w" .. wl .. " `9WL (wl)" end
        helpers.Say(msg)
    end)
end

local function execute_drop_diamond_lock(count)
    RunThread(function()
        local bgl = math.floor(count / 100)
        local dl = count % 100

        if bgl > 0 and GetItemCount(ITEM_IDS.BLUE_GEM_LOCK) < bgl then
            SendPacket(2, "action|dialog_return\ndialog_name|info_box\nbuttonClicked|make_bluegl")
            Sleep(100)
        end

        if bgl > 0 then
            if GetItemCount(ITEM_IDS.BLUE_GEM_LOCK) >= bgl then
                helpers.OnDroppedItem(ITEM_IDS.BLUE_GEM_LOCK, bgl)
                Sleep(100)
            else
                helpers.Say("`4Not enough BGL to drop!`0")
                return
            end
        end

        if dl > 0 then
            if GetItemCount(ITEM_IDS.DIAMOND_LOCK) < dl then
                helpers.OnWear(ITEM_IDS.BLUE_GEM_LOCK)
                local wait_time = 0
                while GetItemCount(ITEM_IDS.DIAMOND_LOCK) < dl and wait_time < 2000 do
                    Sleep(100)
                    wait_time = wait_time + 100
                end
            end

            if GetItemCount(ITEM_IDS.DIAMOND_LOCK) >= dl then
                helpers.OnDroppedItem(ITEM_IDS.DIAMOND_LOCK, dl)
            else
                helpers.Say("`4Still not enough DL to drop!`0")
                return
            end
        end

        local msg = "`2DROPPED: "
        if bgl > 0 then msg = msg .. "`w" .. bgl .. " `eBGL " end
        if dl > 0 then msg = msg .. "`w" .. dl .. " `1DL (wl)" end
        helpers.Say(msg)
    end)
end

local function execute_drop_black_lock(count)
    RunThread(function()
        if GetItemCount(ITEM_IDS.BLACK_GEM_LOCK) < count then
            SendPacket(2, "action|dialog_return\ndialog_name|info_box\nbuttonClicked|make_bgl")
            Sleep(100)
        end

        if GetItemCount(ITEM_IDS.BLACK_GEM_LOCK) >= count then
            helpers.OnDroppedItem(ITEM_IDS.BLACK_GEM_LOCK, count)
        else
            helpers.Say("`4Not enough BLACK to drop!`0")
            return
        end

        local msg = "`2DROPPED: `w" .. count .. " `bBLACK"
        helpers.Say(msg)
    end)
end

local function execute_drop_bgl_lock(count)
    RunThread(function()
        local black_needed = math.floor(count / 100)
        local bgl_needed = count % 100

        local have_black = GetItemCount(ITEM_IDS.BLACK_GEM_LOCK)
        local have_bgl = GetItemCount(ITEM_IDS.BLUE_GEM_LOCK)

        if black_needed > have_black then
            local bgl_to_convert = (black_needed - have_black) * 100
            if have_bgl >= bgl_to_convert then
                SendPacket(2, "action|dialog_return\ndialog_name|info_box\nbuttonClicked|make_bgl")
                Sleep(1000)
                have_black = GetItemCount(ITEM_IDS.BLACK_GEM_LOCK)
            end
        end

        if bgl_needed > have_bgl and have_black > black_needed then
            SendPacket(2, "action|dialog_return\ndialog_name|info_box\nbuttonClicked|make_bluegl")
            Sleep(1000)
            have_bgl = GetItemCount(ITEM_IDS.BLUE_GEM_LOCK)
        end

        if have_black < black_needed or have_bgl < bgl_needed then
            helpers.Say("`4Not enough BLACK/BGL to drop!`0")
            return
        end

        if black_needed > 0 then
            helpers.OnDroppedItem(ITEM_IDS.BLACK_GEM_LOCK, black_needed)
            Sleep(100)
        end
        if bgl_needed > 0 then
            helpers.OnDroppedItem(ITEM_IDS.BLUE_GEM_LOCK, bgl_needed)
            Sleep(100)
        end

        local msg = "`2DROPPED: "
        if black_needed > 0 then msg = msg .. "`w" .. black_needed .. " `bBLACK " end
        if bgl_needed > 0 then msg = msg .. "`w" .. bgl_needed .. " `eBGL " end
        msg = msg .. "(wl)"
        helpers.Say(msg)
    end)
end

local function execute_drop_all_locks()
    RunThread(function()
        local black_count = GetItemCount(ITEM_IDS.BLACK_GEM_LOCK)
        local bgl_count = GetItemCount(ITEM_IDS.BLUE_GEM_LOCK)
        local dl_count = GetItemCount(ITEM_IDS.DIAMOND_LOCK)
        local wl_count = GetItemCount(ITEM_IDS.WORLD_LOCK)

        if black_count == 0 and bgl_count == 0 and dl_count == 0 and wl_count == 0 then
            helpers.Say("`4No locks to drop!")
            helpers.OnTextOverlay("`4No locks found in inventory!")
            return
        end

        local msg = "`2DROP ALL: "
        if black_count > 0 then
            helpers.OnDroppedItem(ITEM_IDS.BLACK_GEM_LOCK, black_count)
            msg = msg .. "`w" .. black_count .. " `bBLACK "
            Sleep(150)
        end
        if bgl_count > 0 then
            helpers.OnDroppedItem(ITEM_IDS.BLUE_GEM_LOCK, bgl_count)
            msg = msg .. "`w" .. bgl_count .. " `eBGL "
            Sleep(150)
        end
        if dl_count > 0 then
            helpers.OnDroppedItem(ITEM_IDS.DIAMOND_LOCK, dl_count)
            msg = msg .. "`w" .. dl_count .. " `1DL "
            Sleep(150)
        end
        if wl_count > 0 then
            helpers.OnDroppedItem(ITEM_IDS.WORLD_LOCK, wl_count)
            msg = msg .. "`w" .. wl_count .. " `9WL (wl)"
        end

        helpers.Say(msg)
        helpers.OnTextOverlay(msg)
    end)
end

local function execute_trade_command(item_id, amount, usage, item_label, color_code)
    if not amount then
        helpers.OnConsoleMessage("`4Usage: " .. usage)
        return true
    end

    RunThread(function()
        if not config.is_trading then
            helpers.OnTextOverlay("`4Error: Not in a trade!")
            helpers.OnConsoleMessage("`4Error: You must be in a trade to use " .. usage .. ".")
            return
        end

        if amount > 250 then
            helpers.OnTextOverlay("`4Max trade amount is 250!")
            helpers.OnConsoleMessage("`4Error: You cannot trade more than 250 at once.")
            return
        end

        local current_count = GetItemCount(item_id)
        if current_count < amount then
            helpers.OnTextOverlay("`4Not enough " .. item_label .. "!")
            helpers.OnConsoleMessage("`4Error: You only have " .. current_count .. " " .. item_label .. ", but tried to trade " .. amount .. ".")
            return
        end

        local packet = "action|dialog_return\n"
            .. "dialog_name|trade\n"
            .. "item_trade|" .. item_id .. "|\n"
            .. "item_count|" .. amount
        SendPacket(2, packet)
        helpers.OnConsoleMessage("`2Added `w" .. amount .. " `" .. color_code .. item_label .. " `2to trade.")
    end)
    return true
end

local LOGGABLE_COMMANDS = {
    blue = true, black = true, exit = true, res = true, saveconfig = true, loadconfig = true, wrp = true
}

local function log_command_execution(canonical_cmd, raw_text)
    if not config.logcommand then
        return
    end

    local wl_cmd, dl_cmd, bgl_cmd, black_cmd = get_dynamic_drop_command_names()
    local cmd = normalize_command_name(canonical_cmd)
    local should_log = LOGGABLE_COMMANDS[cmd]
        or cmd == wl_cmd
        or cmd == dl_cmd
        or cmd == bgl_cmd
        or cmd == black_cmd

    if not should_log then
        return
    end

    local clean_cmd = tostring(raw_text or "")
    clean_cmd = clean_cmd:gsub("action|input%s*|text|", "")
    clean_cmd = clean_cmd:gsub("^%s+", ""):gsub("%s+$", "")

    table.insert(config.tablelogcommand, {command = clean_cmd})
    if type(trim_logs) == "function" then
        trim_logs()
    end
end

local function add_command(def)
    register_command(def)
end

local function try_handle_dynamic_drop_command(parsed)
    local wl_cmd, dl_cmd, bgl_cmd, black_cmd = get_dynamic_drop_command_names()
    local token = normalize_command_name(parsed.token)
    local amount = parse_positive_integer(parsed.args)

    if token == wl_cmd then
        if not amount then
            helpers.Say("`5Invalid amount!`0")
            return true, wl_cmd
        end
        execute_drop_world_lock(amount)
        return true, wl_cmd
    elseif token == dl_cmd then
        if not amount then
            helpers.Say("`5Invalid amount!`0")
            return true, dl_cmd
        end
        execute_drop_diamond_lock(amount)
        return true, dl_cmd
    elseif token == bgl_cmd then
        if not amount then
            -- Allow plain "/b" to pass through to server command.
            return false, nil
        end
        execute_drop_bgl_lock(amount)
        return true, bgl_cmd
    elseif token == black_cmd then
        if not amount then
            helpers.Say("`5Invalid amount!`0")
            return true, black_cmd
        end
        execute_drop_black_lock(amount)
        return true, black_cmd
    end

    local cmd_type, multiplier_str = token:match("^(%a+)(%d+)$")
    local multiplier = tonumber(multiplier_str)
    if cmd_type and multiplier then
        if multiplier < 2 or multiplier > 10 then
            helpers.OnTextOverlay("`4Invalid multiplier! Use 2-10 only.")
            helpers.Say("`4Multiplier must be between 2-10!")
            return true, token
        end

        if not amount then
            helpers.Say("`5Invalid amount!`0")
            return true, token
        end

        local total = amount * multiplier
        if cmd_type == wl_cmd then
            execute_drop_world_lock(total)
            return true, token
        elseif cmd_type == dl_cmd then
            execute_drop_diamond_lock(total)
            return true, token
        elseif cmd_type == bgl_cmd then
            execute_drop_bgl_lock(total)
            return true, token
        elseif cmd_type == black_cmd then
            execute_drop_black_lock(total)
            return true, token
        end
    end

    return false, nil
end

local function build_command_entry_text(def)
    local usage = tostring(def.usage or ("/" .. def.name))
    local aliases = def.aliases or {}
    if #aliases == 0 then
        return usage
    end
    local alias_parts = {}
    for _, alias in ipairs(aliases) do
        table.insert(alias_parts, "/" .. normalize_command_name(alias))
    end
    return usage .. " (alias: " .. table.concat(alias_parts, ", ") .. ")"
end

function helpers.BeginAutoHostPositionCapture(target_key, label_text)
    operation_flags.setting_autohost_target = target_key
    helpers.SendNotification("`eTouch a tile to set " .. label_text .. "...")
    helpers.OnConsoleMessage("`e[AutoHost] Waiting for tile touch for " .. label_text .. "...")
    return true
end

local function is_command_visible_for_user(def, userid)
    if def.ai_visible == false then
        return false
    end
    if type(def.visible_predicate) == "function" then
        return def.visible_predicate(userid) and true or false
    end
    return true
end

function helpers.GetCommandSummaryForAI(userid)
    local id = math.floor(tonumber(userid) or get_local_userid_safe())
    local parts = {}
    for _, def in ipairs(COMMAND_DEFS) do
        if is_command_visible_for_user(def, id) then
            table.insert(parts, build_command_entry_text(def))
        end
    end
    local wl_cmd, dl_cmd, bgl_cmd, black_cmd = get_dynamic_drop_command_names()
    table.insert(parts, "/" .. wl_cmd .. " [amount] (dynamic WL drop)")
    table.insert(parts, "/" .. dl_cmd .. " [amount] (dynamic DL drop)")
    table.insert(parts, "/" .. bgl_cmd .. " [amount] (dynamic BGL drop)")
    table.insert(parts, "/" .. black_cmd .. " [amount] (dynamic BLACK drop)")
    table.insert(parts, "/" .. wl_cmd .. "2-10 [amount] (dynamic multiplier drop)")
    table.insert(parts, "/" .. dl_cmd .. "2-10 [amount] (dynamic multiplier drop)")
    return table.concat(parts, ", ")
end

-- Register command map entries (single source for slash commands)
add_command({
    name = "proxy",
    category = "settings",
    usage = "/proxy",
    description = "Open proxy info menu",
    handler = function()
        helpers.ProxyOpen()
        return true
    end
})

add_command({
    name = "menu",
    category = "info",
    usage = "/menu",
    description = "Open command menu",
    handler = function()
        helpers.ProxyMenu()
        return true
    end
})

add_command({
    name = "imgui",
    category = "settings",
    usage = "/imgui",
    description = "Toggle ImGui panel",
    handler = function()
        if not is_imgui_supported() then
            helpers.OnTextOverlay("`4ImGui is not available on this build.")
            helpers.OnConsoleMessage("`4[ImGui] Not available in current runtime.")
            return true
        end
        if not imgui_state.hook_ready then
            local rehook_ok, rehook_err = pcall(AddHook, "OnDraw", "exproxy_imgui_menu", draw_exproxy_imgui_menu)
            if rehook_ok then
                imgui_state.hook_ready = true
            else
                local err_str = string.lower(tostring(rehook_err or ""))
                if err_str:find("already") or err_str:find("exist") then
                    imgui_state.hook_ready = true
                end
            end
            if not imgui_state.hook_ready then
                helpers.OnTextOverlay("`4ImGui hook is unavailable in this runtime.")
                helpers.OnConsoleMessage("`4[ImGui] OnDraw hook is not active.")
                return true
            end
        end
        imgui_state.visible = not imgui_state.visible
        if imgui_state.visible then
            imgui_state.active_tab = tostring(config.imgui_last_tab or imgui_state.active_tab or "command")
        end
        helpers.OnTextOverlay(imgui_state.visible and "`2ExProxy ImGui: ON" or "`4ExProxy ImGui: OFF")
        return true
    end
})

add_command({
    name = "game",
    category = "casino",
    usage = "/game",
    description = "Open fun games menu",
    handler = function()
        helpers.FunGame()
        return true
    end
})

add_command({
    name = "autogg",
    category = "automation",
    usage = "/autogg",
    description = "Open Auto GrowGanoth dialog",
    handler = function()
        helpers.AutoGGDialog()
        return true
    end
})

add_command({
    name = "autosurg",
    category = "automation",
    usage = "/autosurg",
    description = "Open Auto Surgery dialog",
    handler = function()
        helpers.AutoSurgeryDialog()
        return true
    end
})

add_command({
    name = "autofarm",
    category = "automation",
    usage = "/autofarm",
    description = "Open Auto Farm dialog",
    handler = function()
        helpers.AutoFarmDialog()
        return true
    end
})

add_command({
    name = "surgstats",
    category = "automation",
    usage = "/surgstats",
    description = "Open surgery statistics dialog",
    handler = function()
        helpers.SurgeryStatsDialog()
        return true
    end
})

add_command({
    name = "hunting",
    category = "automation",
    usage = "/hunting",
    description = "Open hunting world settings",
    handler = function()
        helpers.HuntingWorldDialog()
        return true
    end
})

add_command({
    name = "starthunt",
    category = "automation",
    usage = "/starthunt",
    description = "Start hunting world",
    handler = function()
        helpers.StartHuntingWorld()
        return true
    end
})

add_command({
    name = "stophunt",
    category = "automation",
    usage = "/stophunt",
    description = "Stop hunting world",
    handler = function()
        helpers.StopHuntingWorld()
        return true
    end
})

add_command({
    name = "g",
    category = "utility",
    usage = "/g",
    description = "Toggle ghost mode",
    handler = function()
        RunThread(function()
            helpers.SendCommandToServer("/ghost")
            Sleep(200)
            local status = ghost_state.is_enabled and "`2ENABLED" or "`4DISABLED"
            helpers.OnConsoleMessage("`2[Ghost] `9Toggling ghost mode... Current status: " .. status)
        end)
        return true
    end
})

add_command({
    name = "da",
    category = "drop",
    usage = "/da [amount]",
    description = "Drop Arroz Con Pollo",
    handler = function(ctx)
        local amount = parse_positive_integer(ctx.args)
        if not amount then
            helpers.Say("`5Invalid amount!`0")
            return true
        end
        RunThread(function()
            local item_id = 4604
            if GetItemCount(item_id) >= amount then
                helpers.OnDroppedItem(item_id, amount)
                Sleep(100)
                helpers.Say("`2DROPPED: `w" .. amount .. " `eArroz Con Polo (gems)")
            else
                helpers.Say("`4Not enough Arroz Con Polo! You have: " .. GetItemCount(item_id))
            end
        end)
        return true
    end
})

add_command({
    name = "dc",
    category = "drop",
    usage = "/dc [amount]",
    description = "Drop Lucky Clover",
    handler = function(ctx)
        local amount = parse_positive_integer(ctx.args)
        if not amount then
            helpers.Say("`5Invalid amount!`0")
            return true
        end
        RunThread(function()
            local item_id = 528
            if GetItemCount(item_id) >= amount then
                helpers.OnDroppedItem(item_id, amount)
                Sleep(100)
                helpers.Say("`2DROPPED: `w" .. amount .. " `2Lucky Clover (shamrock)")
            else
                helpers.Say("`4Not enough Lucky Clover! You have: " .. GetItemCount(item_id))
            end
        end)
        return true
    end
})

add_command({
    name = "ac",
    category = "drop",
    usage = "/ac [amount]",
    description = "Drop Arroz + Clover",
    handler = function(ctx)
        local amount = parse_positive_integer(ctx.args)
        if not amount then
            helpers.Say("`5Invalid amount!`0")
            return true
        end
        RunThread(function()
            local arroz_id = 4604
            local clover_id = 528
            if GetItemCount(arroz_id) < amount then
                helpers.Say("`4Not enough Arroz Con Polo! You have: " .. GetItemCount(arroz_id))
                return
            end
            helpers.OnDroppedItem(arroz_id, amount)
            Sleep(500)
            if GetItemCount(clover_id) < amount then
                helpers.Say("`4Not enough Lucky Clover! You have: " .. GetItemCount(clover_id))
                return
            end
            helpers.OnDroppedItem(clover_id, amount)
            helpers.Say("`2DROPPED: `w" .. amount .. " `eArroz Con Polo (gems) `w" .. amount .. " `2Lucky Clover (shamrock)")
        end)
        return true
    end
})

add_command({
    name = "detect",
    category = "utility",
    usage = "/detect",
    description = "Open floating detector dialog",
    visible_predicate = function(userid) return is_owner_user(userid) end,
    owner_check = function(userid) return is_owner_user(userid) end,
    handler = function()
        helpers.ShowFloatingItemsDialog()
        return true
    end
})

add_command({
    name = "askai",
    category = "utility",
    usage = "/askai [question]",
    description = "Open AI dialog",
    handler = function()
        helpers.AskAiDialog()
        return true
    end
})

add_command({
    name = "option",
    aliases = {"opt"},
    category = "settings",
    usage = "/option",
    description = "Open toggle options dialog",
    handler = function()
        helpers.ShowOptionDialog()
        return true
    end
})

add_command({
    name = "fdice",
    category = "utility",
    usage = "/fdice",
    description = "Toggle fast dice packet detector",
    handler = function()
        config.fdice = not config.fdice
        helpers.OnTextOverlay(config.fdice and "`2FDice: `aON" or "`4FDice: `cOFF")
        helpers.OnConsoleMessage(config.fdice and "`2[FDice] Enabled" or "`4[FDice] Disabled")
        auto_save_config()
        return true
    end
})

add_command({
    name = "showoc",
    category = "utility",
    usage = "/showoc",
    description = "Toggle Show Open Close Entrance/Door markers",
    handler = function()
        config.showoc = not config.showoc
        auto_save_config()

        if config.showoc then
            helpers.showoc_state.stop_requested = false
            helpers.OnTextOverlay("`2ShowOC: `aON")
            helpers.OnConsoleMessage("`2[ShowOC] `wEnabled. Scanning current world...")
            helpers.RefreshShowOCAsync()
            helpers.StartShowOCWatcher()
        else
            helpers.showoc_state.stop_requested = true
            helpers.RestoreShowOCMarkers()
            helpers.OnTextOverlay("`4ShowOC: `cOFF")
            helpers.OnConsoleMessage("`4[ShowOC] `wDisabled and restored original tile flags.")
        end

        return true
    end
})

add_command({
    name = "crime",
    category = "utility",
    usage = "/crime",
    description = "Toggle auto crime dialog handler",
    handler = function()
        config.acrime = not config.acrime
        if config.acrime then
            helpers.crime_state.stop_requested = false
            helpers.ResetCrimeState(true)
            helpers.OnTextOverlay("`2Auto Crime: `aON")
            helpers.OnConsoleMessage("`2[Crime] Auto crime handler enabled.")
            helpers.OnConsoleMessage("`9[Crime] Waiting for `wcrimewave `9dialog...")
        else
            helpers.crime_state.stop_requested = true
            helpers.ResetCrimeState(true)
            helpers.OnTextOverlay("`4Auto Crime: `cOFF")
            helpers.OnConsoleMessage("`4[Crime] Auto crime handler disabled.")
        end
        auto_save_config()
        return true
    end
})

add_command({
    name = "bgcolor",
    category = "settings",
    usage = "/bgcolor",
    description = "Open dialog color menu",
    handler = function()
        helpers.ChangeDialogColor()
        return true
    end
})

add_command({
    name = "cbgcolor",
    category = "settings",
    usage = "/cbgcolor",
    description = "Toggle custom dialog color injection",
    handler = function()
        config.cbgcolor = not config.cbgcolor
        auto_save_config()
        helpers.OnTextOverlay(config.cbgcolor and "`2Custom BGColor: `aON" or "`4Custom BGColor: `cOFF")
        helpers.OnConsoleMessage(config.cbgcolor and "`2[BGColor] `wCustom dialog color injection enabled." or "`4[BGColor] `wCustom dialog color injection disabled.")
        return true
    end
})

add_command({
    name = "hotkey",
    category = "settings",
    usage = "/hotkey",
    description = "Open hotkey toggle dialog",
    handler = function()
        helpers.HotkeyDialog()
        return true
    end
})

add_command({
    name = "fitur",
    category = "settings",
    usage = "/fitur",
    aliases = {"feature"},
    description = "Open features overview",
    handler = function()
        helpers.ProxyFeatures()
        return true
    end
})

add_command({
    name = "setting",
    category = "settings",
    usage = "/setting",
    description = "Open settings overview",
    handler = function()
        helpers.ShowSettings()
        return true
    end
})

add_command({
    name = "customcmd",
    category = "drop",
    usage = "/customcmd",
    aliases = {"cmdset"},
    description = "Customize dynamic drop commands",
    handler = function()
        helpers.CustomCommandDialog()
        return true
    end
})

add_command({
    name = "wrm",
    category = "wrench",
    usage = "/wrm",
    description = "Open wrench mode dialog",
    handler = function()
        helpers.WrenchModeDialog()
        return true
    end
})

add_command({
    name = "calcu",
    category = "utility",
    usage = "/calcu <expr>",
    description = "Quick calculator in chat",
    handler = function(ctx)
        local expr = tostring((ctx and ctx.args) or "")
        expr = expr:gsub("^%s+", ""):gsub("%s+$", "")

        if expr == "" then
            helpers.Calculator()
            return true
        end

        local left_raw, operator_raw, right_raw = expr:match("^([%d%.,%s]+)([%+%-%*/xX])([%d%.,%s]+)$")
        if not left_raw or not operator_raw or not right_raw then
            helpers.OnTextOverlay("`4Format /calcu tidak valid!")
            helpers.OnConsoleMessage("`4Usage: `w/calcu 28x28 `7| `w/calcu 12.5x5.2 `7| `w/calcu 12,5x5,2")
            return true
        end

        local num1 = helpers.ParseCalcuNumber(left_raw)
        local num2 = helpers.ParseCalcuNumber(right_raw)
        if not num1 or not num2 then
            helpers.OnTextOverlay("`4Error: Angka tidak valid!")
            helpers.OnConsoleMessage("`4Calculator accepts decimal or thousands separators with `w. `4or `w,")
            return true
        end

        local operator = operator_raw
        local result = 0

        if operator_raw == "+" then
            result = num1 + num2
        elseif operator_raw == "-" then
            result = num1 - num2
        elseif operator_raw == "/" then
            operator = "/"
            if num2 == 0 then
                helpers.OnTextOverlay("`4Tidak bisa dibagi dengan nol!")
                helpers.OnConsoleMessage("`4Calculator division by zero is not allowed.")
                return true
            end
            result = num1 / num2
        else
            operator = "x"
            result = num1 * num2
        end

        helpers.Say("`e[Calcu] `w" .. formatNumber(num1) .. " " .. operator .. " " .. formatNumber(num2) .. " `7= `2" .. formatNumber(result))
        return true
    end
})

add_command({
    name = "sspin",
    category = "casino",
    usage = "/sspin",
    description = "Toggle short spin output",
    handler = function()
        config.sspin = not config.sspin
        local status = config.sspin and "`2ON" or "`4OFF"
        helpers.OnTextOverlay("`2Short Spin: " .. status)
        helpers.OnConsoleMessage("`2Short Spin toggled " .. status)
        return true
    end
})

add_command({
    name = "skin",
    category = "utility",
    usage = "/skin",
    description = "Open skin picker dialog",
    handler = function()
        helpers.SkinDialog()
        return true
    end
})

add_command({
    name = "drops",
    category = "drop",
    usage = "/drops",
    description = "Open drop dialog",
    handler = function()
        helpers.DropDialog()
        return true
    end
})

add_command({
    name = "spam",
    category = "automation",
    usage = "/spam",
    description = "Open spam dialog",
    handler = function()
        helpers.Spammer()
        return true
    end
})

add_command({
    name = "sbspam",
    category = "automation",
    usage = "/sbspam",
    description = "Open broadcast manager",
    handler = function()
        helpers.JzBroadcast()
        return true
    end
})

add_command({
    name = "eventbutton",
    category = "settings",
    usage = "/eventbutton",
    description = "Toggle event button visibility",
    ai_visible = false,
    visible_predicate = function() return false end,
    handler = function()
        config.event_button_hide = not config.event_button_hide
        auto_save_config()
        if config.event_button_hide then
            helpers.OnTextOverlay("`4Event Button Hidden: ON (Relog to apply)")
            helpers.OnConsoleMessage("`6[EventButton] `wON - please relog to apply changes.")
        else
            helpers.OnTextOverlay("`2Event Button Hidden: OFF (Relog to apply)")
            helpers.OnConsoleMessage("`6[EventButton] `wOFF - please relog to restore.")
        end
        return true
    end
})

add_command({
    name = "setrbt",
    category = "chat",
    usage = "/setrbt",
    description = "Open rainbow text settings dialog",
    handler = function()
        helpers.SetRbtDialog()
        return true
    end
})

add_command({
    name = "rbt",
    category = "chat",
    usage = "/rbt",
    description = "Toggle rainbow text",
    handler = function()
        config.rainbow_text = not config.rainbow_text
        local mode_text = normalize_rbt_mode(config.rbt_mode)
        if config.rainbow_text then
            helpers.OnTextOverlay("`2Enabled `9Rainbow Text `7(mode: `e" .. mode_text .. "`7)")
        else
            helpers.OnTextOverlay("`4Disabled `9Rainbow Text")
        end
        return true
    end
})

add_command({
    name = "emt",
    category = "chat",
    usage = "/emt",
    description = "Toggle emoji text",
    handler = function()
        config.emoji_text = not config.emoji_text
        helpers.OnTextOverlay(config.emoji_text and "`2Enabled `9Emoji Text" or "`4Disabled `9Emoji Text")
        return true
    end
})

add_command({
    name = "blockspam",
    category = "utility",
    usage = "/blockspam",
    description = "Toggle block spammer slave",
    handler = function()
        config.block_spammer_slave = not config.block_spammer_slave
        auto_save_config()
        helpers.OnTextOverlay(config.block_spammer_slave and "`4Block Spammer Slave: ON" or "`2Block Spammer Slave: OFF")
        helpers.OnConsoleMessage(config.block_spammer_slave and "`4[BlockSpam] Enabled" or "`2[BlockSpam] Disabled")
        return true
    end
})

add_command({
    name = "blink",
    category = "utility",
    usage = "/blink",
    description = "Toggle blink skin",
    handler = function()
        if config.blink_skin then
            helpers.stop_blink_skin()
        else
            helpers.start_blink_skin()
        end
        return true
    end
})

add_command({
    name = "wrp",
    category = "wrench",
    usage = "/wrp",
    description = "Toggle wrench pull",
    handler = function()
        config.pull = not config.pull
        config.kick = false
        config.ban = false
        helpers.OnTextOverlay(config.pull and "`2Enabled Wrench Pull" or "`4Disabled Wrench Pull")
        helpers.Say(config.pull and "`2Enabled Wrench Pull" or "`4Disabled Wrench Pull")
        auto_save_config()
        return true
    end
})

add_command({
    name = "wrk",
    category = "wrench",
    usage = "/wrk",
    description = "Toggle wrench kick",
    handler = function()
        config.kick = not config.kick
        config.pull = false
        config.ban = false
        helpers.OnTextOverlay(config.kick and "`2Enabled Wrench Kick" or "`4Disabled Wrench Kick")
        helpers.Say(config.kick and "`2Enabled Wrench Kick" or "`4Disabled Wrench Kick")
        auto_save_config()
        return true
    end
})

add_command({
    name = "showbal",
    category = "wrench",
    usage = "/showbal",
    aliases = {"smodal"},
    description = "Toggle show player balance",
    handler = function()
        config.showbal = not config.showbal
        helpers.OnTextOverlay(config.showbal and "`2Enabled Show Modal Player" or "`4Disabled Show Modal Player")
        helpers.Say(config.showbal and "`2Enabled Show Modal Player" or "`4Disabled Show Modal Player")
        auto_save_config()
        return true
    end
})

add_command({
    name = "wrb",
    category = "wrench",
    usage = "/wrb",
    description = "Toggle wrench ban",
    handler = function()
        config.ban = not config.ban
        config.pull = false
        config.kick = false
        helpers.OnTextOverlay(config.ban and "`2Enabled Wrench Ban" or "`4Disabled Wrench Ban")
        helpers.Say(config.ban and "`2Enabled Wrench Ban" or "`4Disabled Wrench Ban")
        auto_save_config()
        return true
    end
})

add_command({
    name = "slave",
    category = "utility",
    usage = "/slave",
    description = "Toggle anti spammer slave",
    handler = function()
        config.antiSpammerSlave = not config.antiSpammerSlave
        config.block_spammer_slave = config.antiSpammerSlave
        auto_save_config()
        local msg = config.antiSpammerSlave and "`2Enabled Anti Spammer Slave" or "`4Disabled Anti Spammer Slave"
        helpers.OnTextOverlay(msg .. " `9(Re-enter world to apply)")
        helpers.Say(msg .. " `9Re-enter world to apply")
        return true
    end
})

add_command({
    name = "tdb",
    category = "utility",
    usage = "/tdb",
    description = "Toggle fast take display block",
    handler = function()
        config.fastdb = not config.fastdb
        config.fastdbl = config.fastdb
        helpers.OnTextOverlay(config.fastdb and "`2Enabled Fast Take Display Block" or "`4Disabled Fast Take Display Block")
        helpers.Say(config.fastdb and "`2Enabled Fast Take Display Block" or "`4Disabled Fast Take Display Block")
        return true
    end
})

add_command({
    name = "vendfilter",
    category = "utility",
    usage = "/vendfilter",
    description = "Toggle vending filter",
    handler = function()
        config.vendfilter = not config.vendfilter
        auto_save_config()
        helpers.OnTextOverlay(config.vendfilter and "`2Vending Filter: `aON" or "`4Vending Filter: `cOFF")
        helpers.OnConsoleMessage(config.vendfilter and "`2[VendFilter] Enabled" or "`4[VendFilter] Disabled")
        return true
    end
})

add_command({
    name = "dboxfilter",
    category = "utility",
    usage = "/dboxfilter",
    description = "Toggle donation box icon filter",
    handler = function()
        config.dboxfilter = not config.dboxfilter
        auto_save_config()
        helpers.OnTextOverlay(config.dboxfilter and "`2Donation Box Filter: `aON" or "`4Donation Box Filter: `cOFF")
        helpers.OnConsoleMessage(config.dboxfilter and "`2[DBoxFilter] Enabled" or "`4[DBoxFilter] Disabled")
        return true
    end
})

add_command({
    name = "bsdb",
    category = "casino",
    usage = "/bsdb",
    description = "Toggle block SDB",
    handler = function()
        config.bsdb = not config.bsdb
        helpers.OnTextOverlay(config.bsdb and "`2Enabled Block SDB" or "`4Disabled Block SDB")
        return true
    end
})

add_command({
    name = "acsign",
    category = "casino",
    usage = "/acsign",
    description = "Toggle auto copy sign",
    handler = function()
        config.auto_copy_sign = not config.auto_copy_sign
        helpers.OnTextOverlay(config.auto_copy_sign and "`2Enabled Auto Copy Sign" or "`4Disabled Auto Copy Sign")
        return true
    end
})

add_command({
    name = "autohost",
    category = "casino",
    usage = "/autohost",
    description = "Open Auto HOST panel",
    handler = function()
        helpers.ShowAutoHostDialog()
        return true
    end
})

add_command({
    name = "p1",
    category = "casino",
    usage = "/p1",
    description = "Set Auto HOST player 1 tile",
    handler = function()
        return helpers.BeginAutoHostPositionCapture("p1", "Player 1 Position")
    end
})

add_command({
    name = "p2",
    category = "casino",
    usage = "/p2",
    description = "Set Auto HOST player 2 tile",
    handler = function()
        return helpers.BeginAutoHostPositionCapture("p2", "Player 2 Position")
    end
})

add_command({
    name = "p3",
    category = "casino",
    usage = "/p3",
    description = "Set Auto HOST player 3 tile",
    handler = function()
        return helpers.BeginAutoHostPositionCapture("p3", "Player 3 Position")
    end
})

add_command({
    name = "p4",
    category = "casino",
    usage = "/p4",
    description = "Set Auto HOST player 4 tile",
    handler = function()
        return helpers.BeginAutoHostPositionCapture("p4", "Player 4 Position")
    end
})

add_command({
    name = "hp",
    category = "casino",
    usage = "/hp",
    description = "Set Auto HOST host position",
    handler = function()
        return helpers.BeginAutoHostPositionCapture("hp", "Host Position")
    end
})

add_command({
    name = "tax",
    category = "casino",
    usage = "/tax [percent]",
    description = "Set Auto HOST tax percent",
    handler = function(ctx)
        local raw = tostring((ctx and ctx.args) or ""):gsub(",", ".")
        local percent = tonumber(raw)
        if percent == nil then
            helpers.OnConsoleMessage("`4Usage: /tax <percent>")
            helpers.OnTextOverlay("`4Usage: /tax <percent>")
            return true
        end

        if percent < 0 then percent = 0 end
        if percent > 100 then percent = 100 end

        config.autohost.tax_percent = percent
        auto_save_config()
        helpers.OnTextOverlay("`2Auto HOST Tax: `w" .. helpers.AutoHostFormatPercent(percent) .. "`2%")
        helpers.OnConsoleMessage("`2[AutoHost] Tax set to `w" .. helpers.AutoHostFormatPercent(percent) .. "`2%.")
        return true
    end
})

add_command({
    name = "take",
    category = "casino",
    usage = "/take",
    description = "Take Auto HOST bets from active slots",
    handler = function()
        return helpers.ExecuteAutoHostTake()
    end
})

add_command({
    name = "w1",
    category = "casino",
    usage = "/w1",
    description = "Pay Auto HOST winner at player 1 slot",
    handler = function()
        return helpers.ExecuteAutoHostWinner(1)
    end
})

add_command({
    name = "w2",
    category = "casino",
    usage = "/w2",
    description = "Pay Auto HOST winner at player 2 slot",
    handler = function()
        return helpers.ExecuteAutoHostWinner(2)
    end
})

add_command({
    name = "w3",
    category = "casino",
    usage = "/w3",
    description = "Pay Auto HOST winner at player 3 slot",
    handler = function()
        return helpers.ExecuteAutoHostWinner(3)
    end
})

add_command({
    name = "w4",
    category = "casino",
    usage = "/w4",
    description = "Pay Auto HOST winner at player 4 slot",
    handler = function()
        return helpers.ExecuteAutoHostWinner(4)
    end
})

add_command({
    name = "gemdetect",
    category = "utility",
    usage = "/gemdetect",
    description = "Toggle gem detector",
    handler = function()
        config.autoGemDetect = not config.autoGemDetect
        helpers.OnTextOverlay(config.autoGemDetect and "`2Enabled Gem Detector" or "`4Disabled Gem Detector")
        helpers.Say(config.autoGemDetect and "`2Gem Detector: `aON" or "`4Gem Detector: `cOFF")
        auto_save_config()
        return true
    end
})

add_command({
    name = "acdoor",
    category = "utility",
    usage = "/acdoor",
    description = "Toggle auto door",
    handler = function()
        config.autoToggleDoor = not config.autoToggleDoor
        helpers.OnTextOverlay(config.autoToggleDoor and "`2Auto Toggle Door: ON" or "`4Auto Toggle Door: OFF")
        helpers.Say(config.autoToggleDoor and "`2AC Door: `aON" or "`4AC Door: `cOFF")
        auto_save_config()
        return true
    end
})

add_command({
    name = "automodage",
    category = "automation",
    usage = "/automodage",
    description = "Toggle auto modage",
    handler = function()
        config.automodage = not config.automodage
        if config.automodage then
            helpers.OnTextOverlay("`2Auto Modage: `aON")
            helpers.Say("`2Auto Modage: `aON")
            RunThread(function()
                while config.automodage do
                    SendPacket(2, "action|input\n|text|/modage 9999\n")
                    Sleep(1000)
                end
            end)
        else
            helpers.OnTextOverlay("`4Auto Modage: `cOFF")
            helpers.Say("`4Auto Modage: `cOFF")
        end
        return true
    end
})

add_command({
    name = "antilag",
    category = "automation",
    usage = "/antilag",
    description = "Toggle anti lag mode",
    handler = function()
        config.antiLagEnabled = not config.antiLagEnabled
        ChangeValue("[C] No render particle", config.antiLagEnabled)
        ChangeValue("[C] No render shadow", config.antiLagEnabled)
        config.antiSpammerSlave = config.antiLagEnabled
        if config.antiLagEnabled then
            helpers.OnTextOverlay("`2Anti-Lag Enabled")
            helpers.Say("`2Anti-Lag Mode: `2ON")
        else
            helpers.OnTextOverlay("`4Anti-Lag Disabled")
            helpers.Say("`4Anti-Lag Mode: `cOFF")
        end
        return true
    end
})

local function set_spin_mode(mode)
    config.reme = (mode == "reme")
    config.leme = (mode == "leme")
    config.lemesuper = (mode == "sleme")
    config.ceme = (mode == "ceme")
    config.qeme = (mode == "qeme")
    config.lewa = (mode == "lewa")
    config.hol = (mode == "hol")
end

add_command({
    name = "reme",
    category = "casino",
    usage = "/reme",
    description = "Toggle REME spin mode",
    handler = function()
        local enabled = not config.reme
        if enabled then
            set_spin_mode("reme")
        else
            config.reme = false
        end
        helpers.OnTextOverlay(config.reme and "`2Enabled Reme" or "`4Disabled Reme")
        helpers.Say(config.reme and "`2Enabled Reme Spin" or "`4Disabled Reme Spin")
        return true
    end
})

add_command({
    name = "leme",
    category = "casino",
    usage = "/leme",
    description = "Toggle LEME spin mode",
    handler = function()
        local enabled = not config.leme
        if enabled then
            set_spin_mode("leme")
        else
            config.leme = false
        end
        helpers.OnTextOverlay(config.leme and "`2Enabled Leme" or "`4Disabled Leme")
        helpers.Say(config.leme and "`2Enabled Leme Spin" or "`4Disabled Leme Spin")
        return true
    end
})

add_command({
    name = "sleme",
    category = "casino",
    usage = "/sleme",
    description = "Toggle LEME SUPER spin mode",
    handler = function()
        local enabled = not config.lemesuper
        if enabled then
            set_spin_mode("sleme")
        else
            config.lemesuper = false
        end
        helpers.OnTextOverlay(config.lemesuper and "`2Enabled Leme Super" or "`4Disabled Leme Super")
        helpers.Say(config.lemesuper and "`2Enabled Leme Super Spin" or "`4Disabled Leme Super Spin")
        return true
    end
})

add_command({
    name = "ceme",
    category = "casino",
    usage = "/ceme",
    description = "Toggle CEME spin mode",
    handler = function()
        local enabled = not config.ceme
        if enabled then
            set_spin_mode("ceme")
        else
            config.ceme = false
        end
        helpers.OnTextOverlay(config.ceme and "`2Enabled Ceme" or "`4Disabled Ceme")
        helpers.Say(config.ceme and "`2Enabled Ceme Spin" or "`4Disabled Ceme Spin")
        return true
    end
})

add_command({
    name = "qeme",
    category = "casino",
    usage = "/qeme",
    description = "Toggle QEME spin mode",
    handler = function()
        local enabled = not config.qeme
        if enabled then
            set_spin_mode("qeme")
        else
            config.qeme = false
        end
        helpers.OnTextOverlay(config.qeme and "`2Enabled Qeme" or "`4Disabled Qeme")
        helpers.Say(config.qeme and "`2Enabled Qeme Spin" or "`4Disabled Qeme Spin")
        return true
    end
})

add_command({
    name = "lewa",
    category = "casino",
    usage = "/lewa",
    description = "Toggle LEWA spin mode",
    handler = function()
        local enabled = not config.lewa
        if enabled then
            set_spin_mode("lewa")
        else
            config.lewa = false
        end
        helpers.OnTextOverlay(config.lewa and "`2Enabled Lewa" or "`4Disabled Lewa")
        helpers.Say(config.lewa and "`2Enabled Lewa Spin" or "`4Disabled Lewa Spin")
        return true
    end
})

add_command({
    name = "holr",
    category = "casino",
    usage = "/holr",
    description = "Reset HOL tracker",
    handler = function()
        config.holSpins = {}
        helpers.OnTextOverlay("`2HOL Tracking Reset!")
        helpers.Say("`2HOL Tracking has been reset for all players")
        return true
    end
})

add_command({
    name = "hol",
    category = "casino",
    usage = "/hol",
    description = "Toggle HOL spin mode",
    handler = function()
        local enabled = not config.hol
        if enabled then
            set_spin_mode("hol")
            config.holSpins = {}
        else
            config.hol = false
        end
        helpers.OnTextOverlay(config.hol and "`2Enabled HOL (High or Low)" or "`4Disabled HOL")
        helpers.Say(config.hol and "`2Enabled HOL Spin (High or Low)" or "`4Disabled HOL Spin")
        return true
    end
})

add_command({
    name = "ap",
    category = "admin",
    usage = "/ap",
    description = "Toggle auto pull admin mode",
    visible_predicate = function(userid) return helpers.IsAutoPullAdminUser(userid) end,
    owner_check = function(userid) return helpers.IsAutoPullAdminUser(userid) end,
    handler = function()
        config.auto_pull.enabled = not config.auto_pull.enabled
        if config.auto_pull.enabled then
            helpers.SendNotification("`2Auto Pull: `aENABLED")
            helpers.OnConsoleMessage("`2[Auto Pull] Enabled")
            StartAutoPullThread()
        else
            helpers.SendNotification("`4Auto Pull: `cDISABLED")
            helpers.OnConsoleMessage("`4[Auto Pull] Disabled")
            clear_auto_pull_pending()
            auto_pull_state.pulled_users = {}
            auto_pull_state.thread_running = false
        end
        return true
    end
})

add_command({
    name = "setap",
    category = "admin",
    usage = "/setap",
    description = "Set auto pull tile",
    visible_predicate = function(userid) return helpers.IsAutoPullAdminUser(userid) end,
    owner_check = function(userid) return helpers.IsAutoPullAdminUser(userid) end,
    handler = function()
        auto_pull_state.setting_position = true
        operation_flags.setting_back_position = false
        helpers.SendNotification("`eTouch a tile to set Auto Pull position...")
        helpers.OnConsoleMessage("`e[Auto Pull] Waiting for tile touch...")
        return true
    end
})

add_command({
    name = "setbp",
    category = "admin",
    usage = "/setbp",
    description = "Set back position tile",
    visible_predicate = function(userid) return is_owner_user(userid) end,
    owner_check = function(userid) return is_owner_user(userid) end,
    handler = function()
        operation_flags.setting_back_position = true
        auto_pull_state.setting_position = false
        helpers.SendNotification("`eTouch a tile to set Back Position...")
        helpers.OnConsoleMessage("`e[Back Position] Waiting for tile touch...")
        return true
    end
})

add_command({
    name = "setautopull",
    category = "admin",
    usage = "/setautopull",
    description = "Open auto pull settings",
    visible_predicate = function(userid) return helpers.IsAutoPullAdminUser(userid) end,
    owner_check = function(userid) return helpers.IsAutoPullAdminUser(userid) end,
    handler = function()
        helpers.ShowAutoPullDialog()
        return true
    end
})

add_command({
    name = "reloadscript",
    category = "utility",
    usage = "/reloadscript",
    description = "Reload remote user and Auto Pull whitelists",
    visible_predicate = function() return false end,
    handler = function()
        local result = helpers.ReloadRemoteWhitelistData()
        local all_ok = result.allow_ok and result.autopull_ok

        if result.allow_ok then
            helpers.OnConsoleMessage("`2[ReloadScript] `wUser whitelist reloaded: `9" .. tostring(result.allow_count))
        else
            helpers.OnConsoleMessage("`4[ReloadScript] `wUser whitelist reload failed. Keeping previous data. `8(" .. tostring(result.allow_error) .. ")")
        end

        if result.autopull_ok then
            helpers.OnConsoleMessage("`2[ReloadScript] `wAuto Pull whitelist reloaded: `9" .. tostring(result.autopull_count))
        else
            helpers.OnConsoleMessage("`4[ReloadScript] `wAuto Pull whitelist reload failed. Keeping previous data. `8(" .. tostring(result.autopull_error) .. ")")
        end

        if all_ok then
            helpers.OnTextOverlay("`2Whitelist reload complete")
        else
            helpers.OnTextOverlay("`6Whitelist reload partial")
        end

        return true
    end
})

add_command({
    name = "tpset",
    category = "teleport",
    usage = "/tpset",
    description = "Open teleport settings",
    handler = function()
        helpers.TpSettingsDialog()
        return true
    end
})

add_command({
    name = "tp",
    category = "teleport",
    usage = "/tp",
    description = "Toggle teleport display",
    handler = function()
        config.tpdisplay = not config.tpdisplay
        helpers.OnTextOverlay(config.tpdisplay and "`2Enabled Teleport" or "`4Disabled Teleport")
        return true
    end
})

add_command({
    name = "mf",
    aliases = {"modfly"},
    category = "utility",
    usage = "/mf",
    description = "Toggle modfly",
    handler = function()
        local current_state = GetValue("[C] Modfly")
        local new_state = not current_state
        ChangeValue("[C] Modfly", new_state)
        helpers.OnTextOverlay(new_state and "`2ModFly Enabled" or "`4ModFly Disabled")
        return true
    end
})

add_command({
    name = "wdv",
    category = "conversion",
    usage = "/wdv",
    description = "Toggle auto withdraw vending",
    handler = function()
        config.wdvend = not config.wdvend
        helpers.OnTextOverlay(config.wdvend and "`2Enabled Auto Withdraw Vending" or "`4Disabled Auto Withdraw Vending")
        return true
    end
})

add_command({
    name = "evd",
    category = "conversion",
    usage = "/evd",
    description = "Toggle auto empty vending",
    handler = function()
        config.emptyvend = not config.emptyvend
        helpers.OnTextOverlay(config.emptyvend and "`2Enabled Auto Empty Stock Vending" or "`4Disabled Auto Empty Stock Vending")
        return true
    end
})

add_command({
    name = "rndm",
    category = "utility",
    usage = "/rndm",
    description = "Join random active world",
    handler = function()
        RunThread(function()
            helpers.OnTextOverlay("`2Joining Random World...")
            Sleep(1000)
            helpers.RandomActiveWorld()
        end)
        return true
    end
})

add_command({
    name = "cbgl",
    category = "casino",
    usage = "/cbgl",
    description = "Toggle auto convert BGL",
    handler = function()
        config.cbgl = not config.cbgl
        if config.cbgl then
            config.buydl = false
            config.buychamp = false
        end
        helpers.OnTextOverlay(config.cbgl and "`2Enabled Convert BGL" or "`4Disabled Convert BGL")
        return true
    end
})

add_command({
    name = "cvdl",
    category = "conversion",
    usage = "/cvdl",
    description = "Toggle auto convert DL to BGL",
    handler = function()
        config.autocvdl = not config.autocvdl
        helpers.OnTextOverlay(config.autocvdl and "`2Enabled Auto Convert DL to BGL" or "`4Disabled Auto Convert DL to BGL")
        return true
    end
})

add_command({
    name = "cmp",
    category = "conversion",
    usage = "/cmp",
    description = "Use champagne from inventory",
    handler = function()
        local item_id = GetItemByName('Champagne').id
        local count = GetItemCount(item_id)
        if count > 0 then
            local player = helpers.safe_get_local()
            local tile_x = math.floor(player.pos.x / 32)
            local tile_y = math.floor(player.pos.y / 32)
            helpers.OnTextOverlay("`2Used 1 Champagne...")
            placeBait(item_id, tile_x, tile_y)
        else
            helpers.OnTextOverlay("`4No Champagne in inventory!")
            helpers.OnConsoleMessage("`4You don't have Champagne!")
        end
        return true
    end
})

add_command({
    name = "buydl",
    category = "casino",
    usage = "/buydl",
    description = "Toggle auto buy DL",
    handler = function()
        config.buydl = not config.buydl
        if config.buydl then
            config.cbgl = false
            config.buychamp = false
        end
        helpers.OnTextOverlay(config.buydl and "`2Enabled Buy DL" or "`4Disabled Buy DL")
        return true
    end
})

add_command({
    name = "buychamp",
    category = "casino",
    usage = "/buychamp",
    description = "Toggle auto buy champagne",
    handler = function()
        config.buychamp = not config.buychamp
        if config.buychamp then
            config.cbgl = false
            config.buydl = false
        end
        helpers.OnTextOverlay(config.buychamp and "`2Enabled Buy Champagne" or "`4Disabled Buy Champagne")
        return true
    end
})

add_command({
    name = "ftr",
    category = "automation",
    usage = "/ftr",
    description = "Toggle fast trash",
    handler = function()
        config.fasttrash = not config.fasttrash
        helpers.OnTextOverlay(config.fasttrash and "`2Enabled Fast Trash" or "`4Disable Fast Trash")
        return true
    end
})

add_command({
    name = "cvptu",
    category = "conversion",
    usage = "/cvptu",
    description = "Toggle convert tax to UWS",
    handler = function()
        config.cvptu = not config.cvptu
        helpers.OnTextOverlay(config.cvptu and "`2Enabled Convert Tax To UWS" or "`4Disabled Convert Tax To UWS")
        if config.cvptu then
            RunThread(function()
                while config.cvptu do
                    local tel, prin = helpers.findTelePrinces()
                    if tel and prin then
                        helpers.TaxToPink(tel.x, tel.y)
                        Sleep(250)
                        helpers.PinkToUWS(prin.x, prin.y)
                        helpers.OnConsoleMessage("`2Successfully `6converted `cTax `3to `1UWS!`")
                    else
                        helpers.OnConsoleMessage("`4Convert Tax to UWS failed! Make sure both Telephone and Princess are nearby!``")
                    end
                    Sleep(100)
                end
            end)
        end
        return true
    end
})

add_command({
    name = "log",
    category = "utility",
    usage = "/log",
    description = "Open logs dialog",
    handler = function()
        helpers.MenuLogs()
        return true
    end
})

add_command({
    name = "daw",
    category = "drop",
    usage = "/daw",
    description = "Drop all lock types",
    handler = function()
        execute_drop_all_locks()
        return true
    end
})

add_command({
    name = "blue",
    category = "conversion",
    usage = "/blue",
    description = "Convert BLACK to BGL",
    handler = function()
        RunThread(function()
            local black_count = GetItemCount(ITEM_IDS.BLACK_GEM_LOCK)
            if black_count < 1 then
                helpers.OnConsoleMessage("`4Not enough BLACK to make BGL! Need at least 1 BLACK.`0")
                helpers.OnTextOverlay("`4Not enough BLACK to make BGL! Need at least 1 BLACK.`0")
                return
            end
            SendPacket(2, "action|dialog_return\ndialog_name|info_box\nbuttonClicked|make_bluegl")
            helpers.Say("`2Success Make `9100 `eCreativePS Blue Gem Lock")
        end)
        return true
    end
})

add_command({
    name = "black",
    category = "conversion",
    usage = "/black",
    description = "Convert BGL to BLACK",
    handler = function()
        RunThread(function()
            local bgl_count = GetItemCount(ITEM_IDS.BLUE_GEM_LOCK)
            if bgl_count < 100 then
                helpers.OnConsoleMessage("`4Not enough BGL to make BLACK! Need at least 100 BGL.`0")
                helpers.OnTextOverlay("`4Not enough BGL to make BLACK! Need at least 100 BGL.`0")
                return
            end
            SendPacket(2, "action|dialog_return\ndialog_name|info_box\nbuttonClicked|make_bgl")
            helpers.Say("`2Success Make `91 `bCreativePS Black Gem Lock")
        end)
        return true
    end
})

add_command({
    name = "depo",
    aliases = {"dp"},
    category = "conversion",
    usage = "/depo [amount]",
    description = "Deposit BGL to bank",
    handler = function(ctx)
        local amount = parse_positive_integer(ctx.args)
        if amount and amount > 0 then
            RunThread(function()
                local bgl_count = GetItemCount(ITEM_IDS.BLUE_GEM_LOCK)
                local black_count = GetItemCount(ITEM_IDS.BLACK_GEM_LOCK)
                local total_bgl = black_count * 100 + bgl_count
                if amount > total_bgl then
                    helpers.OnConsoleMessage("`4You don't have enough BGL! Available: " .. total_bgl)
                    return
                end
                helpers.DepositBank(amount)
            end)
        else
            RunThread(function()
                local bgl_count = GetItemCount(ITEM_IDS.BLUE_GEM_LOCK)
                local black_count = GetItemCount(ITEM_IDS.BLACK_GEM_LOCK)
                local total_bgl = black_count * 100 + bgl_count
                if total_bgl > 0 then
                    helpers.DepositBank(total_bgl)
                    helpers.OnConsoleMessage("`2Deposited all " .. total_bgl .. " BGL to bank!")
                else
                    helpers.OnConsoleMessage("`4No BGL to deposit!")
                end
            end)
        end
        return true
    end
})

add_command({
    name = "economy",
    category = "utility",
    usage = "/economy",
    description = "Open global economy report",
    handler = function()
        SendPacket(2, "action|dialog_return\ndialog_name|blockchain\nbuttonClicked|locksupply")
        return true
    end
})

add_command({
    name = "wd",
    aliases = {"wt"},
    category = "conversion",
    usage = "/wd [amount]",
    description = "Withdraw BGL from bank",
    handler = function(ctx)
        local amount = parse_positive_integer(ctx.args)
        if amount and amount > 0 then
            RunThread(function()
                helpers.WithdrawBank(amount)
            end)
        else
            helpers.OnConsoleMessage("`4Invalid withdraw amount!")
        end
        return true
    end
})

add_command({
    name = "cf",
    category = "casino",
    usage = "/cf",
    description = "Open coinflip quick gamble",
    handler = function()
        RunThread(function()
            helpers.OnQuickGamble("coinflip")
            Sleep(1000)
            helpers.OnTextOverlay("`2Open Coin Flip Dialog")
        end)
        return true
    end
})

add_command({
    name = "dice",
    category = "casino",
    usage = "/dice",
    description = "Open dice quick gamble",
    handler = function()
        RunThread(function()
            helpers.OnQuickGamble("dice")
            Sleep(1000)
            helpers.OnTextOverlay("`2Open Dice Roll Dialog")
        end)
        return true
    end
})

add_command({
    name = "exit",
    category = "info",
    usage = "/exit",
    description = "Exit current world",
    handler = function()
        RunThread(function()
            helpers.Say("`2Keluar dulu babayyy`0")
            Sleep(500)
            SendPacket(3, "action|join_request\nname|exit")
        end)
        return true
    end
})

add_command({
    name = "res",
    category = "info",
    usage = "/res",
    description = "Respawn player",
    handler = function()
        RunThread(function()
            SendPacket(2, "action|respawn")
        end)
        return true
    end
})

add_command({
    name = "relog",
    aliases = {"rl"},
    category = "info",
    usage = "/relog",
    description = "Relog to current world",
    handler = function()
        RunThread(function()
            local world_name = getworldname()
            if not world_name then
                helpers.OnTextOverlay("`4Unable to relog (world not found).")
                return
            end
            SendPacket(3, "action|join_request\nname|" .. world_name .. "\ninvitedWorld|0")
        end)
        return true
    end
})

add_command({
    name = "saveconfig",
    category = "settings",
    usage = "/saveconfig",
    description = "Save config to disk",
    handler = function()
        RunThread(function()
            helpers.SaveConfig(configPath)
        end)
        return true
    end
})

add_command({
    name = "loadconfig",
    category = "settings",
    usage = "/loadconfig",
    description = "Load config from disk",
    handler = function()
        RunThread(function()
            helpers.LoadConfig(configPath)
        end)
        return true
    end
})

add_command({
    name = "twl",
    category = "trade",
    usage = "/twl [amount]",
    description = "Trade world locks",
    handler = function(ctx)
        return execute_trade_command(ITEM_IDS.WORLD_LOCK, parse_positive_integer(ctx.args), "/twl <amount>", "World Locks", "2")
    end
})

add_command({
    name = "tdl",
    category = "trade",
    usage = "/tdl [amount]",
    description = "Trade diamond locks",
    handler = function(ctx)
        return execute_trade_command(ITEM_IDS.DIAMOND_LOCK, parse_positive_integer(ctx.args), "/tdl <amount>", "Diamond Locks", "1")
    end
})

add_command({
    name = "tbgl",
    category = "trade",
    usage = "/tbgl [amount]",
    description = "Trade blue gem locks",
    handler = function(ctx)
        return execute_trade_command(ITEM_IDS.BLUE_GEM_LOCK, parse_positive_integer(ctx.args), "/tbgl <amount>", "Blue Gem Locks", "e")
    end
})

add_command({
    name = "tblack",
    category = "trade",
    usage = "/tblack [amount]",
    description = "Trade black gem locks",
    handler = function(ctx)
        return execute_trade_command(ITEM_IDS.BLACK_GEM_LOCK, parse_positive_integer(ctx.args), "/tblack <amount>", "Black Gem Locks", "b")
    end
})

local MENU_CATEGORY_ORDER = {
    "drop",
    "trade",
    "conversion",
    "automation",
    "casino",
    "wrench",
    "utility",
    "chat",
    "teleport",
    "settings",
    "info",
    "admin"
}

local MENU_CATEGORY_META = {
    drop = {title = "`2Drop Commands", icon = 13810},
    trade = {title = "`2Trade Commands", icon = 13816},
    conversion = {title = "`4Conversion & Banking", icon = 3898},
    automation = {title = "`9Automation Commands", icon = 340},
    casino = {title = "`6Casino & Games", icon = 758},
    wrench = {title = "`eWrench Actions", icon = 758},
    utility = {title = "`1Utility Commands", icon = 32},
    chat = {title = "`cCustomize Chat", icon = 32},
    teleport = {title = "`5Teleport Commands", icon = 18},
    settings = {title = "`3Settings & Config", icon = 32},
    info = {title = "`8Info Commands", icon = 11550},
    admin = {title = "`5Admin Commands", icon = 1368}
}

local function menu_clean_text(raw)
    local text = tostring(raw or "")
    text = text:gsub("[\r\n|]", " ")
    text = text:gsub("%s+", " ")
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    return text
end

local function is_command_visible_for_menu(def, userid)
    if type(def) ~= "table" then
        return false
    end
    if def.menu_visible == false then
        return false
    end
    return is_command_visible_for_user(def, userid)
end

local function build_menu_line(entry)
    local usage = menu_clean_text(entry.usage or ("/" .. tostring(entry.name or "")))
    local description = menu_clean_text(entry.description or "")
    local alias_parts = {}
    for _, alias in ipairs(entry.aliases or {}) do
        table.insert(alias_parts, "/" .. normalize_command_name(alias))
    end

    local line = "`e" .. usage
    if description ~= "" then
        line = line .. " `7- " .. description
    end
    if #alias_parts > 0 then
        line = line .. " `8(alias: " .. table.concat(alias_parts, ", ") .. ")"
    end
    return line
end

local function append_menu_section(lines, meta, entries)
    if type(entries) ~= "table" or #entries == 0 then
        return
    end

    table.insert(lines, "add_label_with_icon|small|" .. meta.title .. "|left|" .. tostring(meta.icon or 242) .. "|")
    table.insert(lines, "add_spacer|small|")

    for _, entry in ipairs(entries) do
        table.insert(lines, "add_textbox|" .. build_menu_line(entry) .. "|left|")
    end

    table.insert(lines, "add_spacer|small|")
end

local function build_proxy_menu_dialog()
    local player = GetLocal() or {}
    local userid_num = math.floor(tonumber(player.userid) or 0)
    local name = menu_clean_text(player.name or "Unknown")
    local black = tostring(math.floor(GetItemCount(ITEM_IDS.BLACK_GEM_LOCK) or 0))
    local bgl = tostring(math.floor(GetItemCount(ITEM_IDS.BLUE_GEM_LOCK) or 0))
    local dl = tostring(math.floor(GetItemCount(ITEM_IDS.DIAMOND_LOCK) or 0))
    local wl = tostring(math.floor(GetItemCount(ITEM_IDS.WORLD_LOCK) or 0))

    local grouped = {}
    for _, category in ipairs(MENU_CATEGORY_ORDER) do
        grouped[category] = {}
    end

    for _, def in ipairs(COMMAND_DEFS) do
        if is_command_visible_for_menu(def, userid_num) then
            local category = normalize_command_name(def.category or "utility")
            if not grouped[category] then
                grouped[category] = {}
            end
            table.insert(grouped[category], def)
        end
    end

    local wl_cmd, dl_cmd, bgl_cmd, black_cmd = get_dynamic_drop_command_names()
    if not grouped.drop then
        grouped.drop = {}
    end
    table.insert(grouped.drop, {
        usage = "/" .. wl_cmd .. " [amount]",
        description = "Drop World Locks"
    })
    table.insert(grouped.drop, {
        usage = "/" .. dl_cmd .. " [amount]",
        description = "Drop Diamond Locks"
    })
    table.insert(grouped.drop, {
        usage = "/" .. bgl_cmd .. " [amount]",
        description = "Drop Blue Gem Locks"
    })
    table.insert(grouped.drop, {
        usage = "/" .. black_cmd .. " [amount]",
        description = "Drop Black Gem Locks"
    })
    table.insert(grouped.drop, {
        usage = "/" .. wl_cmd .. "2-10 [amount]",
        description = "Multi-Drop World Locks"
    })
    table.insert(grouped.drop, {
        usage = "/" .. dl_cmd .. "2-10 [amount]",
        description = "Multi-Drop Diamond Locks"
    })
    table.insert(grouped.drop, {
        usage = "/" .. bgl_cmd .. "2-10 [amount]",
        description = "Multi-Drop Blue Gem Locks"
    })
    table.insert(grouped.drop, {
        usage = "/" .. black_cmd .. "2-10 [amount]",
        description = "Multi-Drop Black Gem Locks"
    })

    local lines = {
        "set_default_color|`w",
        "set_border_color|" .. tostring(config.dialogBorder or "100,100,100,255") .. "|",
        "set_bg_color|" .. tostring(config.dialogBg or "45,45,45,200") .. "|",
        "",
        "add_label_with_icon|big|`eJzProxy Commands Menu|left|11550|",
        "add_spacer|small|",
        "add_textbox|`9Welcome, `w" .. name .. "`9! `7UserID: `e" .. tostring(userid_num) .. "|left|",
        "add_spacer|small|",
        "add_smalltext|`7This menu is auto-generated from command map. Any command update will be shown here automatically.|left|",
        "add_spacer|small|",
        "add_label_with_icon|small|`3Balance Overview|left|1898|",
        "add_spacer|small|",
        "add_textbox|`bBlack: `w" .. black .. " `eBGL: `w" .. bgl .. " `1DL: `w" .. dl .. " `9WL: `w" .. wl .. "|left|",
        "add_spacer|small|"
    }

    local rendered_categories = {}
    for _, category in ipairs(MENU_CATEGORY_ORDER) do
        local entries = grouped[category]
        local meta = MENU_CATEGORY_META[category]
        if meta and entries and #entries > 0 then
            append_menu_section(lines, meta, entries)
            rendered_categories[category] = true
        end
    end

    local extra_categories = {}
    for category, entries in pairs(grouped) do
        if not rendered_categories[category] and entries and #entries > 0 then
            table.insert(extra_categories, category)
        end
    end
    table.sort(extra_categories)
    for _, category in ipairs(extra_categories) do
        local label = tostring(category):gsub("^%l", string.upper)
        append_menu_section(lines, {
            title = "`7" .. label .. " Commands",
            icon = 11550
        }, grouped[category])
    end

    table.insert(lines, "add_label_with_icon|small|`8For PC/Windows Users HotKey|left|16050|")
    table.insert(lines, "add_spacer|small|")
    table.insert(lines, "add_textbox|`eHOLD CTRL + CLICK TILE `7- Teleport and Back To Last Position|left|")
    table.insert(lines, "add_textbox|`eHOLD SHIFT + CLICK TILE `7- Teleport Target Tile Position|left|")
    table.insert(lines, "add_textbox|`ePRESS F4 `7- Fast Respawning Shortcut|left|")
    table.insert(lines, "add_spacer|small|")
    table.insert(lines, "add_quick_exit||")
    table.insert(lines, "end_dialog|menu_dlg|Close||")

    return table.concat(lines, "\n")
end

local function open_proxy_menu_dialog()
    local dialog = build_proxy_menu_dialog()
    SendVariantList({[0] = "OnDialogRequest", [1] = dialog, netid = -1})
end

helpers.ProxyMenu = open_proxy_menu_dialog
helpers.ProxyCommand = open_proxy_menu_dialog

local function dispatch_slash_command_map(packet)
    local parsed = parse_slash_command_packet(packet)
    if not parsed then
        return nil
    end

    local canonical, def = resolve_registered_command(parsed.token)
    local userid = get_local_userid_safe()

    if def then
        if type(def.owner_check) == "function" and not def.owner_check(userid) then
            helpers.OnConsoleMessage("`4Access Denied. This command is restricted.`0")
            return true
        end

        local ok, handled = pcall(def.handler, parsed)
        if not ok then
            helpers.OnConsoleMessage("`4[CommandMap] Error in /" .. canonical .. ": `w" .. tostring(handled))
            helpers.OnTextOverlay("`4Command error: /" .. canonical)
            return true
        end

        if handled == nil or handled == true then
            log_command_execution(canonical, parsed.text)
            return true
        end
        return handled
    end

    local handled_dynamic, dynamic_cmd = try_handle_dynamic_drop_command(parsed)
    if handled_dynamic then
        log_command_execution(dynamic_cmd or parsed.token, parsed.text)
        return true
    end

    -- For any slash command not in map, pass it to server as-is and skip legacy substring router.
    return false
end

function HandleSendPacket(type, packet)
    
    local str = packet
    local slash_dispatch = dispatch_slash_command_map(str)
    if slash_dispatch ~= nil then
        return slash_dispatch
    end
    -- Handle Remove Blacklist Dialog Actions
    if str:find("action|dialog_return") and str:find("dialog_name|remove_blacklist_dialog") then
        -- Process removals
        local removed_count = 0
        local removal_occured = false
        
        for id_to_remove in str:gmatch("blacklist_remove_(%d+)|1") do
            if id_to_remove then
                 config.auto_pull.blacklist[id_to_remove] = nil
                 config.auto_pull.blacklist[tonumber(id_to_remove)] = nil
                 removed_count = removed_count + 1
                 removal_occured = true
            end
        end
        
        if removal_occured then
            auto_save_config(true) -- Immediate save
            helpers.OnTextOverlay("`2Removed " .. removed_count .. " users from blacklist!")
            helpers.ShowRemoveBlacklistDialog() -- Refresh remove dialog 
        else
            -- If no removal, check if "Remove Selected" (right button) or "Cancel" (left button) was clicked
            -- Left button usually sends "buttonClicked|Cancel" or similar if named. 
            -- Here we named it "Cancel".
            -- If buttonClicked is empty or not "remove_blacklist_dialog" (which is the close identifier if we used end_dialog|name|Cancel|Close)
            
            -- If right button "Remove Selected" clicked but nothing checked -> Refresh.
            -- If left button "Cancel" clicked -> Go back to main dialog.
            
            if str:find("buttonClicked|Cancel") then
                 helpers.ShowAutoPullDialog()
            else
                 -- Assumption: Right button clicked or just generic return
                 helpers.ShowRemoveBlacklistDialog()
            end
        end
        return true
    end

    -- Handle auto_pull_dialog save (Generic)
    if str:find("action|dialog_return") and str:find("dialog_name|auto_pull_dialog") then
        local enabled = str:match("auto_pull_enabled|(%d+)")
        local delay = str:match("auto_pull_delay|(%d+)")
        local min_modal_raw = str:match("auto_pull_min_modal|([^|\n]*)")
        local pull_once = str:find("auto_pull_pull_once|1") ~= nil
        local post_pull_move = str:find("auto_pull_post_move|1") ~= nil
        local post_pull_message = str:find("auto_pull_post_message|1") ~= nil
        local post_pull_post = str:find("auto_pull_post_post|1") ~= nil
        local direction = helpers.NormalizeAutoPullDirection(config.auto_pull.direction)
        
        config.auto_pull.enabled = (enabled == "1")
        config.auto_pull.delay = tonumber(delay) or config.auto_pull.delay or 3000
        if config.auto_pull.delay < 150 then config.auto_pull.delay = 150 end
        if config.auto_pull.delay > 60000 then config.auto_pull.delay = 60000 end

        local min_modal_digits = tostring(min_modal_raw or ""):gsub("[^%d]", "")
        local min_modal_value = tonumber(min_modal_digits)
        if min_modal_value == nil then
            min_modal_value = tonumber(config.auto_pull.min_modal) or 0
        end
        min_modal_value = math.floor(min_modal_value)
        if min_modal_value < 0 then min_modal_value = 0 end
        config.auto_pull.min_modal = min_modal_value
        config.auto_pull.pull_once_until_leave = pull_once and true or false
        config.auto_pull.post_pull_move = post_pull_move and true or false
        config.auto_pull.post_pull_message = post_pull_message and true or false
        config.auto_pull.post_pull_post = post_pull_post and true or false
        if str:find("auto_pull_dir_left|1") then
            direction = "left"
        elseif str:find("auto_pull_dir_right|1") then
            direction = "right"
        end
        config.auto_pull.direction = direction
        
        -- Process Blacklist Additions (Checkboxes)
        local added_count = 0
        for id_to_add in str:gmatch("blacklist_add_(%d+)|1") do
            if id_to_add then
                config.auto_pull.blacklist[id_to_add] = true
                -- Add as number too
                config.auto_pull.blacklist[tonumber(id_to_add)] = true
                added_count = added_count + 1
            end
        end
        
        helpers.OnTextOverlay("`2Settings Saved! Added " .. added_count .. " users to blacklist.")
        helpers.OnConsoleMessage("`2[Auto Pull] Settings Updated:")
        helpers.OnConsoleMessage("  `9- Enabled: " .. (config.auto_pull.enabled and "`2YES" or "`4NO"))
        helpers.OnConsoleMessage("  `9- Delay: " .. config.auto_pull.delay .. "ms")
        helpers.OnConsoleMessage("  `9- Minimum Modal: `w" .. config.auto_pull.min_modal .. " `7(WL-value)")
        helpers.OnConsoleMessage("  `9- Pull Once Until Leave: " .. (config.auto_pull.pull_once_until_leave and "`2YES" or "`4NO"))
        helpers.OnConsoleMessage("  `9- Move After Pull: " .. (config.auto_pull.post_pull_move and "`2YES" or "`4NO"))
        helpers.OnConsoleMessage("  `9- Message After Pull: " .. (config.auto_pull.post_pull_message and "`2YES" or "`4NO"))
        helpers.OnConsoleMessage("  `9- POST After Pull: " .. (config.auto_pull.post_pull_post and "`2YES" or "`4NO"))
        helpers.OnConsoleMessage("  `9- Direction: `w" .. config.auto_pull.direction:upper())
        
         local bl_count = 0
        -- Count unique keys (string/number mess workaround)
        local seen = {}
        for k, v in pairs(config.auto_pull.blacklist) do
            if v and not seen[tostring(k)] then
                seen[tostring(k)] = true
                bl_count = bl_count + 1
            end
        end
        helpers.OnConsoleMessage("  `9- Blacklist Count: " .. bl_count)
        
        -- Start/Stop thread based on new setting
        if config.auto_pull.enabled then
             StartAutoPullThread()
        else
             clear_auto_pull_pending()
             auto_pull_state.pulled_users = {}
             auto_pull_state.thread_running = false
        end
        
        -- Check if "Remove Blacklist" button was clicked (it sends dialog return too)
        if str:find("buttonClicked|remove_blacklist") then
             auto_save_config(true) -- Save changes first
             helpers.ShowRemoveBlacklistDialog()
             return true
        end

        auto_save_config(true) -- Immediate save for manual settings
        return true
    end

    if str:find("action|dialog_return") and str:find("dialog_name|custom_cmd_dialog") then
        local cmd_wl = str:match("cmd_wl|([^|\n]+)")
        local cmd_dl = str:match("cmd_dl|([^|\n]+)")
        local cmd_bgl = str:match("cmd_bgl|([^|\n]+)")
        local cmd_black = str:match("cmd_black|([^|\n]+)")
        
        -- Validation: check if commands are not empty
        if not cmd_wl or cmd_wl:match("^%s*$") then cmd_wl = "w" end
        if not cmd_dl or cmd_dl:match("^%s*$") then cmd_dl = "d" end
        if not cmd_bgl or cmd_bgl:match("^%s*$") then cmd_bgl = "b" end
        if not cmd_black or cmd_black:match("^%s*$") then cmd_black = "bb" end
        
        -- Remove spaces and special characters
        cmd_wl = cmd_wl:gsub("[%s%p]", ""):lower()
        cmd_dl = cmd_dl:gsub("[%s%p]", ""):lower()
        cmd_bgl = cmd_bgl:gsub("[%s%p]", ""):lower()
        cmd_black = cmd_black:gsub("[%s%p]", ""):lower()
        
        -- Check for duplicates
        local commands = {cmd_wl, cmd_dl, cmd_bgl, cmd_black}
        local seen = {}
        local has_duplicate = false
        
        for _, cmd in ipairs(commands) do
            if seen[cmd] then
                has_duplicate = true
                break
            end
            seen[cmd] = true
        end
        
        if has_duplicate then
            helpers.OnTextOverlay("`4Error: Commands must be unique!")
            helpers.OnConsoleMessage("`4Error: All commands must be different!")
            return true
        end
        
        -- Save to config
        config.cmd_drop_wl = cmd_wl
        config.cmd_drop_dl = cmd_dl
        config.cmd_drop_bgl = cmd_bgl
        config.cmd_drop_black = cmd_black
        
        -- Auto save config
        auto_save_config()
        
        helpers.OnTextOverlay("`2Custom commands saved successfully!")
        helpers.OnConsoleMessage("`2Custom drop commands updated:")
        helpers.OnConsoleMessage("`9WL: `w/" .. cmd_wl .. " `9| DL: `w/" .. cmd_dl .. " `9| BGL: `w/" .. cmd_bgl .. " `9| BLACK: `w/" .. cmd_black)
        
        return true
    end
    
    
    -- Handle tpset dialog save
    if str:find("action|dialog_return") and str:find("dialog_name|tpset_dialog") then
        local display_only = str:find("tp_display_only|1")
        local all_position = str:find("tp_all_position|1")
        local return_enabled = str:find("tp_return|1")
        local delay_str = str:match("tp_delay|([^|\n]+)")
        local show_travel_text = str:find("tp_show_travel_text|1")
        local show_return_text = str:find("tp_show_return_text|1")
        local show_return_chat = str:find("tp_show_return_chat|1")
        
        -- Validate: check if both modes selected
        if display_only and all_position then
            helpers.OnTextOverlay("`4Please Choose one Mode")
            helpers.OnConsoleMessage("`4Error: Cannot enable both teleport modes!")
            RunDelayed(100, function()
                helpers.TpSettingsDialog("`4Please Choose one Mode")
            end)
            return true
        end
        
        -- Check if no mode selected
        if not display_only and not all_position then
            helpers.OnTextOverlay("`4Please Choose one Mode")
            helpers.OnConsoleMessage("`4Error: You must select a teleport mode!")
            RunDelayed(100, function()
                helpers.TpSettingsDialog("`4Please Choose one Mode")
            end)
            return true
        end
        
        -- Set mode based on what's checked
        if display_only then
            config.tpdisplay_mode = "display_only"
        elseif all_position then
            config.tpdisplay_mode = "all_position"
        end
        
        -- Set return option
        config.tpdisplay_return = return_enabled and true or false
        config.tpdisplay_show_travel_text = show_travel_text and true or false
        config.tpdisplay_show_return_text = show_return_text and true or false
        config.tpdisplay_show_return_chat = show_return_chat and true or false
        
        -- Validate and set delay
        local delay = tonumber(delay_str)
        if delay and delay >= 100 and delay <= 60000 then
            config.tpdisplay_delay = delay
        else
            helpers.OnTextOverlay("`4Invalid delay! Using default 3000ms")
            config.tpdisplay_delay = 3000
        end
        
        -- Save config
        auto_save_config()
        
        -- Notify user
        local mode_str = config.tpdisplay_mode == "display_only" and "Display Only" or "All Position"
        helpers.OnTextOverlay("`2Teleport settings saved!")
        helpers.OnConsoleMessage("`2Teleport Settings Updated:")
        helpers.OnConsoleMessage("`9Mode: `w" .. mode_str)
        helpers.OnConsoleMessage("`9Auto Return: `w" .. (config.tpdisplay_return and "Enabled" or "Disabled"))
        helpers.OnConsoleMessage("`9Delay: `w" .. config.tpdisplay_delay .. "ms")
        helpers.OnConsoleMessage("`9Travel Overlay: `w" .. (config.tpdisplay_show_travel_text and "Shown" or "Hidden"))
        helpers.OnConsoleMessage("`9Return Overlay: `w" .. (config.tpdisplay_show_return_text and "Shown" or "Hidden"))
        helpers.OnConsoleMessage("`9Return Chat: `w" .. (config.tpdisplay_show_return_chat and "Shown" or "Hidden"))
        
        return true
    end

    -- Handle wrench mode dialog save
    if str:find("action|dialog_return") and str:find("dialog_name|wrench_mode_dialog") then
        local showbal = str:find("showbal|1")
        local showbal_use_chat = str:find("showbal_use_chat|1")
        local vendfilter = str:find("vendfilter|1")
        local dboxfilter = str:find("dboxfilter|1")
        local pull = str:find("pull|1")
        local wrench_touch_pull = str:find("wrench_touch_pull|1")
        local kick = str:find("kick|1")
        local ban = str:find("ban|1")
        local msg_pull_input = str:match("wrench_msg_pull|([^|\n]*)")
        local msg_kick_input = str:match("wrench_msg_kick|([^|\n]*)")
        local msg_ban_input = str:match("wrench_msg_ban|([^|\n]*)")
        local msg_showbal_input = str:match("wrench_msg_showbal|([^|\n]*)")
        
        -- Count how many action modes are selected (pull, kick, ban only)
        local action_count = 0
        if pull then action_count = action_count + 1 end
        if kick then action_count = action_count + 1 end
        if ban then action_count = action_count + 1 end
        
        -- Validate: check if more than one action mode is selected
        if action_count > 1 then
            helpers.OnTextOverlay("`4Please Choose one Mode")
            helpers.OnConsoleMessage("`4Error: Cannot enable multiple wrench actions (Pull/Kick/Ban)!")
            RunDelayed(100, function()
                helpers.WrenchModeDialog("`4Please Choose one Mode")
            end)
            return true
        end
        
        -- Update config
        config.showbal = showbal and true or false
        config.showbal_use_chat = showbal_use_chat and true or false
        config.vendfilter = vendfilter and true or false
        config.dboxfilter = dboxfilter and true or false
        config.pull = pull and true or false
        config.wrench_touch_pull = wrench_touch_pull and true or false
        config.kick = kick and true or false
        config.ban = ban and true or false
        config.wrench_msg_pull = sanitize_wrench_message_input(msg_pull_input ~= nil and msg_pull_input or config.wrench_msg_pull)
        config.wrench_msg_kick = sanitize_wrench_message_input(msg_kick_input ~= nil and msg_kick_input or config.wrench_msg_kick)
        config.wrench_msg_ban = sanitize_wrench_message_input(msg_ban_input ~= nil and msg_ban_input or config.wrench_msg_ban)
        config.wrench_msg_showbal = sanitize_wrench_message_input(msg_showbal_input ~= nil and msg_showbal_input or config.wrench_msg_showbal)
        
        -- Auto save config
        auto_save_config()
        
        -- Build status message
        local enabled = {}
        if config.showbal then 
            local output_type = config.showbal_use_chat and "(Chat)" or "(Console)"
            table.insert(enabled, "Show Balance " .. output_type)
        end
        if config.vendfilter then table.insert(enabled, "Vend Filter") end
        if config.dboxfilter then table.insert(enabled, "DBox Filter") end
        if config.pull then table.insert(enabled, "Pull") end
        if config.wrench_touch_pull then table.insert(enabled, "Click Pull") end
        if config.kick then table.insert(enabled, "Kick") end
        if config.ban then table.insert(enabled, "Ban") end
        
        local status_msg = #enabled > 0 and table.concat(enabled, ", ") or "None"
        
        helpers.OnTextOverlay("`2Wrench mode settings saved!")
        helpers.OnConsoleMessage("`2Wrench mode updated:")
        helpers.OnConsoleMessage("`9Enabled: `w" .. status_msg)
        helpers.OnConsoleMessage("`9Custom chat text: `wSaved (`2{name}`w, `2{action}`w, `2{world}`w, `2{time}`w)")
        
        return true
    end

    if str:find("action|dialog_return") and str:find("dialog_name|hotkey_dialog") then
        config.tp_ctrl_click_enabled = str:find("hotkey_ctrl_click|1") and true or false
        config.tp_shift_click_enabled = str:find("hotkey_shift_click|1") and true or false
        config.hotkey_ctrl_z_enabled = str:find("hotkey_ctrl_z|1") and true or false
        config.hotkey_f4_respawn = str:find("hotkey_f4_respawn|1") and true or false
        config.hotkey_alt_wrench = str:find("hotkey_alt_wrench|1") and true or false

        auto_save_config()

        local enabled = {}
        if config.tp_ctrl_click_enabled then table.insert(enabled, "CTRL+Click") end
        if config.tp_shift_click_enabled then table.insert(enabled, "SHIFT+Click") end
        if config.hotkey_ctrl_z_enabled then table.insert(enabled, "CTRL+Z") end
        if config.hotkey_f4_respawn then table.insert(enabled, "F4") end
        if config.hotkey_alt_wrench then table.insert(enabled, "ALT+Wrench") end

        local status_msg = #enabled > 0 and table.concat(enabled, ", ") or "None"
        helpers.OnTextOverlay("`2Hotkey settings saved!")
        helpers.OnConsoleMessage("`2[Hotkey] Enabled: `w" .. status_msg)
        return true
    end
    
    -- Handle Auto Surgery dialog
    if str:find("action|dialog_return") and str:find("dialog_name|autosurg_dlg") then
        if str:find("buttonClicked|toggle_surgery") then
            surgery_state.is_running = not surgery_state.is_running
            helpers.SurgeryOverlay(surgery_state.is_running and "`2Auto Surgery Started!" or "`4Auto Surgery Stopped!")
            helpers.Say(surgery_state.is_running and "`2Auto Surgery Started!" or "`4Auto Surgery Stopped!")
            RunDelayed(100, function()
                helpers.AutoSurgeryDialog()
            end)
            return true
        elseif str:find("buttonClicked|reset_stats") then
            surgery_state.surgery_count = 0
            surgery_state.gems_spent = 0
            helpers.SurgeryOverlay("`2Surgery statistics reset!")
            RunDelayed(100, function()
                helpers.AutoSurgeryDialog()
            end)
            return true
        else
            -- Save settings
            local target = tonumber(str:match("surg_target|([^%s\n]+)"))
            local sponge = tonumber(str:match("delay_sponge|([^%s\n]+)"))
            local anesthetic = tonumber(str:match("delay_anesthetic|([^%s\n]+)"))
            local scalpel = tonumber(str:match("delay_scalpel|([^%s\n]+)"))
            local antiseptic = tonumber(str:match("delay_antiseptic|([^%s\n]+)"))
            local antibiotics = tonumber(str:match("delay_antibiotics|([^%s\n]+)"))
            local stitches = tonumber(str:match("delay_stitches|([^%s\n]+)"))
            local fix = tonumber(str:match("delay_fix|([^%s\n]+)"))
            
            if target and target > 0 then surgery_state.target_count = target end
            if sponge and sponge > 0 then surgery_state.delays.sponge = sponge end
            if anesthetic and anesthetic > 0 then surgery_state.delays.anesthetic = anesthetic end
            if scalpel and scalpel > 0 then surgery_state.delays.scalpel = scalpel end
            if antiseptic and antiseptic > 0 then surgery_state.delays.antiseptic = antiseptic end
            if antibiotics and antibiotics > 0 then surgery_state.delays.antibiotics = antibiotics end
            if stitches and stitches > 0 then surgery_state.delays.stitches = stitches end
            if fix and fix > 0 then surgery_state.delays.fix = fix end
            
            helpers.SurgeryOverlay("`2Surgery settings saved!")
            helpers.Say("`2Surgery settings saved! Target: `w" .. surgery_state.target_count)
            return true
        end
    end
    
    -- Handle Surgery Stats dialog
    if str:find("action|dialog_return") and str:find("dialog_name|surgstats_dlg") then
        if str:find("buttonClicked|open_settings") then
            RunDelayed(100, function()
                helpers.AutoSurgeryDialog()
            end)
            return true
        end
        return true
    end
    
    -- Handle Hunting World dialog
    if str:find("action|dialog_return") and str:find("dialog_name|hunting_dialog") then
        -- Handle start/stop button
        if str:find("buttonClicked|start_stop_hunt") then
            if hunting_world.is_running then
                helpers.StopHuntingWorld()
            else
                helpers.StartHuntingWorld()
            end
            RunDelayed(100, function()
                helpers.HuntingWorldDialog()
            end)
            return true
        else
            -- Save settings
            -- Mode selection
            local mode_text = str:find("mode_text_random|1")
            local mode_full = str:find("mode_full_random|1")
            
            if mode_text then
                hunting_world.mode = "text_random"
            elseif mode_full then
                hunting_world.mode = "full_random"
            end
            
            -- Text + Random settings
            local prefix = str:match("prefix_text|([^|\n]+)")
            if prefix and prefix ~= "" then
                hunting_world.prefix_text = prefix
            end
            
            local type_number = str:find("type_number|1")
            local type_letter = str:find("type_letter|1")
            local type_both = str:find("type_both|1")
            
            if type_number then
                hunting_world.random_type = "number"
            elseif type_letter then
                hunting_world.random_type = "letter"
            elseif type_both then
                hunting_world.random_type = "both"
            end
            
            local random_length = tonumber(str:match("random_length|([^%s\n]+)"))
            if random_length and random_length > 0 and random_length <= 20 then
                hunting_world.random_length = random_length
            end
            
            -- Full Random settings
            local world_length = tonumber(str:match("world_length|([^%s\n]+)"))
            if world_length and world_length >= 3 and world_length <= 20 then
                hunting_world.world_length = world_length
            end
            
            hunting_world.use_numbers = str:find("use_numbers|1") ~= nil
            
            -- Timing settings
            local join_delay = tonumber(str:match("join_delay|([^%s\n]+)"))
            if join_delay and join_delay >= 1000 then
                hunting_world.join_delay = join_delay
            end
            
            local idle_delay = tonumber(str:match("idle_delay|([^%s\n]+)"))
            if idle_delay and idle_delay >= 1000 then
                hunting_world.idle_delay = idle_delay
            end
            
            helpers.OnTextOverlay("`2Hunting World settings saved!")
            helpers.OnConsoleMessage("`2[Hunting] Settings saved successfully!")
            return true
        end
    end

    if str:find("action|dialog_return") and str:find("dialog_name|autofarm_dialog") then
        local world_input = str:match("af_world_name|([^|\n]*)")
        if world_input then
            world_input = world_input:gsub("^%s*(.-)%s*$", "%1")
            world_input = world_input:gsub("[\r\n|]", "")
            if world_input == "" then
                local world = GetWorld()
                autofarm_state.world_name = tostring((world and world.name) or "UNKNOWN")
            else
                autofarm_state.world_name = world_input
            end
        end

        autofarm_state.auto_take_remote = str:find("af_auto_take_remote|1") ~= nil
        autofarm_state.auto_rejoin = str:find("af_auto_rejoin|1") ~= nil
        autofarm_state.auto_use_buff = str:find("af_auto_use_buff|1") ~= nil

        if str:find("buttonClicked|af_toggle_run") then
            autofarm_state.is_running = not autofarm_state.is_running
            local state_text = autofarm_state.is_running and "`2[AutoFarm] UI status: RUNNING (preview mode)" or "`4[AutoFarm] UI status: STOPPED"
            helpers.OnTextOverlay(state_text)
            helpers.OnConsoleMessage(state_text)
            RunDelayed(100, function()
                helpers.AutoFarmDialog()
            end)
            return true
        end

        helpers.OnTextOverlay("`2Auto Farm settings saved (UI mode).")
        helpers.OnConsoleMessage("`2[AutoFarm] Settings updated.")
        return true
    end
    
    -- Handle Buy Champagne dialog
    if str:find("action|dialog_return") and str:find("dialog_name|buychamp_dialog") then
        local mode_dl = str:match("mode_dl|(%d)")
        local mode_bgems = str:match("mode_bgems|(%d)")

        if mode_dl == "1" then
            config.buychamp_mode = "dl"
        elseif mode_bgems == "1" then
            config.buychamp_mode = "bgems"
        end

        if str:find("buttonClicked|start_buy_champ") then
            local amount = tonumber(str:match("champ_amount|([^%s\n]+)"))
            local buy_delay = tonumber(str:match("buy_delay|([^%s\n]+)"))

            if not amount or amount <= 0 or amount > 1000 then
                helpers.OnTextOverlay("`4Invalid amount! Please enter 1-1000")
                RunDelayed(100, function()
                    helpers.BuyChampDialog(buychamp_state.telephone_x, buychamp_state.telephone_y)
                end)
                return true
            end

            if not buy_delay or buy_delay < 50 or buy_delay > 5000 then
                helpers.OnTextOverlay("`4Invalid delay! Use 50-5000ms")
                RunDelayed(100, function()
                    helpers.BuyChampDialog(buychamp_state.telephone_x, buychamp_state.telephone_y)
                end)
                return true
            end

            buychamp_state.buy_delay = buy_delay
            buychamp_state.amount = amount

            local mode_text = (config.buychamp_mode == "bgems") and "BGEMS" or "DL"
            helpers.OnConsoleMessage("`2[Buy Champ] `wMode: " .. mode_text)

            helpers.StartBuyingChamp(amount, buychamp_state.telephone_x, buychamp_state.telephone_y)
            return true
        end
        return true
    end

    -- Handle autogg dialog
    if str:find("action|dialog_return") and str:find("dialog_name|autogg_dialog") then
        local buttonClicked = str:match("buttonClicked|([^|\n]+)")
        
        -- Handle start button
        if buttonClicked == "start_autogg" then
            helpers.RunAutoGG()
            return true
        end
        
        -- Handle stop button
        if buttonClicked == "stop_autogg" then
            autogg_config.is_running = false
            helpers.OnTextOverlay("`4Auto GG stopped!")
            helpers.OnConsoleMessage("`4[Auto GG] Stopped by user")
            return true
        end
        
        -- Handle save settings
        local item_id = str:match("item_id|([^|\n]+)")
        local delay_path = str:match("delay_path|([^|\n]+)")
        
        if item_id then
            local id_num = tonumber(item_id)
            if id_num and id_num > 0 then
                autogg_config.item_id = id_num
                helpers.OnConsoleMessage("`2[Auto GrowGanoth] Item ID set to: " .. id_num)
            end
        end
        
        if delay_path then
            local delay_num = tonumber(delay_path)
            if delay_num and delay_num >= 40 and delay_num <= 5000 then
                autogg_config.delay_path = delay_num
                helpers.OnConsoleMessage("`2[Auto GrowGanoth] Delay set to: " .. delay_num .. "ms")
            else
                helpers.OnTextOverlay("`4Invalid delay! Use 40-5000ms")
            end
        end
        
        helpers.OnTextOverlay("`2Auto GrowGanoth settings saved!")
        return true
    end

    if str:find("action|dialog_return") and str:find("dialog_name|setrbt_dlg") then
        local selected_mode = nil
        if str:find("rbt_mode_single|1") then
            selected_mode = "single"
        elseif str:find("rbt_mode_rainbow|1") then
            selected_mode = "rainbow"
        elseif str:find("rbt_mode_smooth|1") then
            selected_mode = "smooth"
        elseif str:find("rbt_mode_custom|1") then
            selected_mode = "custom"
        end
        selected_mode = normalize_rbt_mode(selected_mode or config.rbt_mode)

        local single_input = str:match("rbt_single_color|([^|\n]*)") or config.rbt_single_color
        local custom_input = str:match("rbt_custom_colors|([^|\n]*)") or config.rbt_custom_colors
        local speed_input = str:match("rbt_smooth_speed|([^|\n]*)")
        local span_input = str:match("rbt_smooth_span|([^|\n]*)")
        local preview_input = str:match("rbt_preview_text|([^|\n]*)") or "Rainbow Text Preview"
        local buttonClicked = str:match("buttonClicked|([^|\n]+)") or ""

        local normalized_single = normalize_rbt_code(single_input) or "`e"
        local parsed_custom = parse_rbt_color_list(custom_input or "")
        if #parsed_custom == 0 then
            parsed_custom = ensure_rbt_palette_table(config.rbt_rainbow_colors, DEFAULT_RBT_CUSTOM_COLORS)
        end
        local normalized_custom = list_to_rbt_string(parsed_custom)
        local smooth_speed = clamp_rbt_number(speed_input or config.rbt_smooth_speed, 1, 10, 1)
        local smooth_span = clamp_rbt_number(span_input or config.rbt_smooth_span, 1, 10, 1)
        local preview_text = (preview_input or ""):match("^%s*(.-)%s*$")
        if preview_text == "" then
            preview_text = "Rainbow Text Preview"
        end

        if buttonClicked == "rbt_preview" then
            local old_mode = config.rbt_mode
            local old_single = config.rbt_single_color
            local old_custom = config.rbt_custom_colors
            local old_speed = config.rbt_smooth_speed
            local old_span = config.rbt_smooth_span
            local old_offset = rbt_runtime_offset

            config.rbt_mode = selected_mode
            config.rbt_single_color = normalized_single
            config.rbt_custom_colors = normalized_custom
            config.rbt_smooth_speed = smooth_speed
            config.rbt_smooth_span = smooth_span

            local preview_colored = apply_rbt_to_text(preview_text, true)

            config.rbt_mode = old_mode
            config.rbt_single_color = old_single
            config.rbt_custom_colors = old_custom
            config.rbt_smooth_speed = old_speed
            config.rbt_smooth_span = old_span
            rbt_runtime_offset = old_offset

            helpers.OnTextOverlay("`9[RBT Preview] " .. preview_colored)
            helpers.OnConsoleMessage("`9[RBT Preview] " .. preview_colored)
            RunDelayed(100, function()
                helpers.SetRbtDialog()
            end)
            return true
        end

        config.rbt_mode = selected_mode
        config.rbt_single_color = normalized_single
        config.rbt_custom_colors = normalized_custom
        config.rbt_smooth_speed = smooth_speed
        config.rbt_smooth_span = smooth_span
        config.rbt_rainbow_colors = ensure_rbt_palette_table(config.rbt_rainbow_colors, DEFAULT_RBT_COLORS)
        auto_save_config()

        helpers.OnTextOverlay("`2RBT settings saved! Mode: `e" .. selected_mode)
        helpers.OnConsoleMessage("`2[RBT] Saved mode=`e" .. selected_mode .. "`2 single=`e" .. normalized_single .. "`2 custom=`e" .. normalized_custom)
        return true
    end
    if str:find("action|friends") then
        helpers.ShowSocialPortal()
        return true
    end

    local proxy_prefix = "`6[`eJz`1Proxy`6]:`w "
    if str:find("action|input\n|text|")
        and not str:find("|text|/")
        and not str:find("|text|%((%w+)%)")
        and not str:find(proxy_prefix, 1, true) then
        local Text = str:match("|text|([^\n]+)")
        if not Text or Text == "" then return true end

        local outputText = apply_rbt_to_text(Text, false)

        local prefix = ""
        if config.emoji_text and GetRandomEmoji then
            prefix = GetRandomEmoji() .. " : "
        end

        SendPacket(2, "action|input\n|text|" .. prefix .. outputText)
        return true
    end
    if str:find("dialog_name|skin_picker") then
        RunThread(function()
            local selectedCount = 0
            local targetSkin = nil

            for i, skin in ipairs(SkinColors) do
                local pattern = "skin_" .. i .. "|1"
                if str:find(pattern) then
                    selectedCount = selectedCount + 1
                    targetSkin = skin
                end
            end

            if selectedCount > 1 then
                helpers.OnTextOverlay("`4Please Choose 1 Skin")
                return
            end

            if targetSkin then
                config.currentSkin = targetSkin.name
                SendPacket(2, "action|dialog_return\ndialog_name|skinpicker\nred|"..targetSkin.r.."\ngreen|"..targetSkin.g.."\nblue|"..targetSkin.b.."\ntransparency|0")
                helpers.Say("Skin changed to " .. targetSkin.code .. targetSkin.name .. "!")
                helpers.OnTextOverlay("`2Skin updated to " .. targetSkin.code .. targetSkin.name)
                auto_save_config()
            end
        end)
        return true 
    end

    if str:find("action|dialog_return") and str:find("dialog_name|bgcolor_mix_dialog") then
        local buttonClicked = (str:match("buttonClicked|([^|]+)") or ""):gsub("^%s*(.-)%s*$", "%1")
        local lowerClicked = buttonClicked:lower()
        if lowerClicked == "back" or lowerClicked == "close" or lowerClicked == "cancel" then
            helpers.ChangeDialogColor()
            return true
        end

        local selected_bg = nil
        local selected_border = nil
        for _, entry in ipairs(helpers.GetDialogColorPalette()) do
            if str:find("bgmix_bg_" .. entry.id .. "|1", 1, true) then
                selected_bg = entry
            end
            if str:find("bgmix_border_" .. entry.id .. "|1", 1, true) then
                selected_border = entry
            end
        end

        if not selected_bg or not selected_border then
            helpers.OnTextOverlay("`4Please select one background and one border color.")
            helpers.OnConsoleMessage("`4[BGColor] Please choose one background color and one border color.")
            RunDelayed(100, function()
                helpers.ShowDialogColorMixDialog("`4Please select one background and one border color.")
            end)
            return true
        end

        config.dialogBg = selected_bg.bg
        config.dialogBorder = selected_border.border
        auto_save_config(true)
        helpers.OnTextOverlay("`2Custom dialog mix applied!")
        helpers.OnConsoleMessage("`2[BGColor] Custom mix applied: `wBG `8= " .. selected_bg.id .. " `9| `wBorder `8= " .. selected_border.id)
        helpers.ChangeDialogColor()
        return true
    end

    if str:find("action|dialog_return") and str:find("dialog_name|bgcolor_rgb_dialog") then
        local buttonClicked = (str:match("buttonClicked|([^|]+)") or ""):gsub("^%s*(.-)%s*$", "%1")
        local lowerClicked = buttonClicked:lower()
        local bg_input = str:match("custom_bg_rgb|([^|\n]*)") or helpers.GetDialogColorRgbOnly(config.dialogBg, "45,45,45")
        local border_input = str:match("custom_border_rgb|([^|\n]*)") or helpers.GetDialogColorRgbOnly(config.dialogBorder, "100,100,100")

        if lowerClicked == "back" or lowerClicked == "close" or lowerClicked == "cancel" then
            helpers.ChangeDialogColor()
            return true
        end

        local bg_rgb = helpers.ParseDialogColorRgbInput(bg_input)
        local border_rgb = helpers.ParseDialogColorRgbInput(border_input)
        if not bg_rgb or not border_rgb then
            helpers.OnTextOverlay("`4Invalid RGB format. Use R,G,B with values 0-255.")
            helpers.OnConsoleMessage("`4[BGColor] Invalid RGB. Example: 35,35,35")
            RunDelayed(100, function()
                helpers.ShowDialogColorRgbDialog("`4Invalid RGB format. Use `wR,G,B `4with values `w0-255`4.", bg_input, border_input)
            end)
            return true
        end

        config.dialogBg = bg_rgb .. ",200"
        config.dialogBorder = border_rgb .. ",255"
        auto_save_config(true)
        helpers.OnTextOverlay("`2Custom RGB dialog colors applied!")
        helpers.OnConsoleMessage("`2[BGColor] Custom RGB applied: `wBG `8= " .. bg_rgb .. " `9| `wBorder `8= " .. border_rgb)
        helpers.ChangeDialogColor()
        return true
    end

    if str:find("dialog_name|changedialogcolor") then
        -- Fallback config kalau gak ada
        if not config then
            config = config or {}
            config.dialogBorder = "100,100,100,255"
            config.dialogBg = "45,45,45,200"
            config.is_trading = false
        end
        
        local buttonClicked = str:match("buttonClicked|([^|]+)") or ""
        buttonClicked = buttonClicked:gsub("^%s*(.-)%s*$", "%1")  -- Trim spasi
        if buttonClicked == "" or buttonClicked:lower() == "close" or buttonClicked:lower() == "cancel" then
            return true
        end
        
        local lowerClicked = buttonClicked:lower()
        if lowerClicked == "open_custom_mix" then
            helpers.ShowDialogColorMixDialog()
            return true
        elseif lowerClicked == "open_custom_rgb" then
            helpers.ShowDialogColorRgbDialog()
            return true
        elseif lowerClicked == "resetdefault" then
            config.dialogBorder = "100,100,100,255"
            config.dialogBg = "45,45,45,200"
        else
            local preset = helpers.GetDialogColorPreset(lowerClicked)
            if preset then
                config.dialogBorder = preset.border
                config.dialogBg = preset.bg
            else
                return true
            end
        end

        auto_save_config(true)
        helpers.OnTextOverlay("`2Dialog color updated to `e" .. buttonClicked .. "`o!")
        helpers.OnConsoleMessage("`9Dialog color updated to `e: " .. buttonClicked .. ".")
        helpers.ChangeDialogColor()
        
        return true
    end

    if str:find("action|dialog_return") and str:find("dialog_name|drops_dlg") then
        if not str:find("confirm|1") then
            helpers.OnConsoleMessage("`4You must confirm before dropping items!")
            return true
        end

        local success, inv = pcall(GetInventory)
        if not success or not inv then
            helpers.OnConsoleMessage("`4Error getting inventory!")
            return true
        end

        config.isDropping = true  -- Start dropping process

        RunThread(function()
            for _, item in pairs(inv) do
                local realId = math.floor(item.id)
                local selected = str:match("dropItem_" .. realId .. "|(%d)")
                if selected == "1" and item.amount > 0 then
                    helpers.OnDroppedItem(realId, item.amount)
                    local success_name, item_name = pcall(safe_get_item_name, realId)
                    local name = success_name and item_name or tostring(realId)
                    helpers.OnConsoleMessage("`9Dropped `2" .. item.amount .. "x " .. name)
                    Sleep(500)
                end
            end
            config.isDropping = false
        end)
        return true
    end

    if str:find("buttonClicked|cmd_help") then
        helpers.ProxyCommand()
        return true
    end
    if str:find("buttonClicked|options_menu") then
        helpers.ShowOptionDialog()
        return true
    end
    if str:find("buttonClicked|autohost_reset_all_pos") then
        helpers.ResetAutoHostPositions()
        helpers.OnTextOverlay("`4Auto HOST positions reset")
        helpers.OnConsoleMessage("`4[AutoHost] All positions reset.")
        RunDelayed(100, function()
            helpers.ShowAutoHostDialog()
        end)
        return true
    end
    if str:find("buttonClicked|cbg_color") or str:find("buttonClicked|dialog_color") then
        helpers.ChangeDialogColor()
        return true
    end
    if str:find("buttonClicked|drop_dialog") then
        helpers.DropDialog()
        return true
    end
    if str:find("buttonClicked|spam_dialog") then
        helpers.Spammer()
        return true
    end
    if str:find("buttonClicked|calculator") then
        helpers.Calculator()
        return true
    end
    if str:find("buttonClicked|fun_games") then
        helpers.FunGame()
        return true
    end
    if str:find("buttonClicked|social_hub") then
        helpers.ShowSocialPortal()
        return true
    end
    if str:find("buttonClicked|view_settings") then
        helpers.ShowSettings()
        return true
    end

    if str:find("action|dialog_return") and str:find("dialog_name|option_dialog") then
        local is_close = str:find("buttonClicked|Close", 1, true) ~= nil or str:find("buttonClicked|Cancel", 1, true) ~= nil
        if not is_close then
            helpers.ApplyOptionDialogSelections(str)
        end
        return true
    end

    -- Protected item IDs for trash confirmation
    local protectedIDs = {
        ITEM_IDS.WORLD_LOCK,
        ITEM_IDS.DIAMOND_LOCK,
        ITEM_IDS.BLUE_GEM_LOCK,
        ITEM_IDS.BLACK_GEM_LOCK
    }

    if str:find("action|trash") and config.fasttrash then
        local itemID = str:match("|itemID|(%d+)")
        if itemID then
            local idNum = tonumber(itemID)
            local itemcount = GetItemCount(idNum)
            local itemName = safe_get_item_name(idNum)
            local isProtected = false
            for _, protectedID in ipairs(protectedIDs) do
                if idNum == protectedID then
                    isProtected = true
                    break
                end
            end
            
            if isProtected then
                pendingTrash = {itemID = itemID, itemcount = itemcount, itemName = itemName, idStr = itemID, countStr = itemcount}
                local confirmMsg = "Are you sure you want to trash " .. itemName .. " (ID: " .. itemID .. ") with amount " .. itemcount .. "?"
                local dialogString = [[
set_default_color|`o
set_border_color|]] .. config.dialogBorder .. [[|
set_bg_color|]] .. config.dialogBg .. [[|
add_label_with_icon|big|`cConfirm Trashing `2]].. itemName ..[[|left|]] .. itemID .. [[|
add_spacer|small|
add_textbox|`3]] .. confirmMsg .. [[|
add_spacer|small|
add_button|yes_trash|`2Yes - Trash It|noflags|0|0|
add_button|no_trash|`4No - Cancel|noflags|0|0|
add_spacer|small|
end_dialog|trash_confirm|||
                ]]

                local varlist = {
                    [0] = "OnDialogRequest",
                    [1] = dialogString,
                    netid = -1
                }
                SendVariantList(varlist)

                helpers.OnConsoleMessage('`cProtected trash attempt intercepted for Item ID: `e' .. itemID .. ' ``(`9' .. itemName .. '``)')
                return true  -- Block original until confirmation
            else
                -- Auto-trash non-protected items
                RunThread(function()
                    Sleep(100)  -- Small delay
                    SendPacket(2, "action|dialog_return\ndialog_name|trash\nitem_trash|" .. itemID .. "|\nitem_count|" .. itemcount)
                    helpers.OnConsoleMessage("`9Trashed `4" .. itemcount .. "x `w" .. itemName)
                    helpers.OnTextOverlay("`9Trashed `4" .. itemcount .. "x `w" .. itemName)
                end)
                helpers.OnConsoleMessage('`eFast trash executed for Item ID: `w' .. itemID)
                return true
            end
        end
    end

    if str:find("action|dialog_return") and str:find("dialog_name|trash_confirm") and config.fasttrash then
        if str:find('buttonClicked|yes_trash') then
            local info = pendingTrash  -- Capture local copy
            if not info then  -- Safety check
                helpers.OnConsoleMessage("`4Error: No pending trash info found.")
                return true
            end
            RunThread(function()
                Sleep(100)  -- Delay
                if info then  -- Double-check di thread
                    SendPacket(2, "action|dialog_return\ndialog_name|trash\nitem_trash|" .. info.itemID .. "|\nitem_count|" .. info.itemcount)
                    helpers.OnConsoleMessage("`9Trashed `4" .. info.itemcount .. "x `w" .. info.itemName)
                    helpers.OnTextOverlay("`9Trashed `4" .. info.itemcount .. "x `w" .. info.itemName)
                else
                    helpers.OnConsoleMessage("`4Failed to trash item - Info unavailable")
                end
                pendingTrash = nil  -- Clear DI SINI, setelah action
            end)
            helpers.OnConsoleMessage('`eFast trash initiated for protected Item ID: `w' .. info.itemID)  -- Ganti "executed" ke "initiated" biar akurat
        elseif str:find('buttonClicked|no_trash') then
            helpers.OnConsoleMessage("`4Trash action cancelled.")
            pendingTrash = nil  -- Clear tetep di sini untuk no_trash (ga ada thread)
        end
        return true
    end
    if str:find("buttonClicked|drop_logs") then
        helpers.MenuDropLogs()
        return true
    end
    if str:find("buttonClicked|coll") then
        helpers.CollectLog()
        return true
    end
    if str:find("buttonClicked|action_logs") then
        helpers.MenuLogs()
        return true
    end
    if str:find("buttonClicked|wrench_mode") then
        helpers.WrenchModeDialog()
        return true
    end
    if str:find("buttonClicked|customize_commands") then
        helpers.CustomCommandDialog()
        return true
    end
    if str:find("buttonClicked|spin_logs") then
        helpers.SpinLog()
        return true
    end
    local target_spin_netid = str:match("buttonClicked|logs_spin_(%d+)")
    if target_spin_netid then
        helpers.ShowSpinLogsDialog(target_spin_netid)
        return true
    end
    
    -- Selective Reset Dialog
    if str:find("buttonClicked|selective_reset") then
        helpers.SelectiveResetDialog()
        return true
    end
    
    -- Undo Last Reset
    if str:find("buttonClicked|undo_reset") then
        helpers.RestoreLogs()
        RunDelayed(100, function()
            helpers.MenuLogs()
        end)
        return true
    end
    
    -- Handle Selective Reset Dialog Return
    if str:find("action|dialog_return") and str:find("dialog_name|selective_reset_dlg") then
        local reset_spin = str:find("reset_spin|1")
        local reset_drop = str:find("reset_drop|1")
        local reset_collect = str:find("reset_collect|1")
        local reset_command = str:find("reset_command|1")
        local create_backup = str:find("create_backup|1")
        
        -- Check if at least one is selected
        if not (reset_spin or reset_drop or reset_collect or reset_command) then
            helpers.OnTextOverlay("`4No logs selected to reset!")
            RunDelayed(100, function()
                helpers.SelectiveResetDialog()
            end)
            return true
        end
        
        -- Create backup if requested
        if create_backup then
            helpers.BackupLogs()
        end
        
        -- Reset selected logs
        local reset_list = {}
        if reset_spin then
            config.tablelogspin = {}
            table.insert(reset_list, "Spin")
        end
        if reset_drop then
            config.logdrop = ""
            table.insert(reset_list, "Drop")
        end
        if reset_collect then
            config.logcollect = ""
            table.insert(reset_list, "Collect")
        end
        if reset_command then
            config.tablelogcommand = {}
            table.insert(reset_list, "Command")
        end
        
        local reset_text = table.concat(reset_list, ", ")
        helpers.OnConsoleMessage("`2[Logs] `wReset completed: `e" .. reset_text .. " `wlogs")
        helpers.OnTextOverlay("`2Logs reset successfully!")
        
        return true
    end
    
    -- Reset All Logs (with backup)
    if str:find("buttonClicked|resetall") then
        -- Create backup first
        helpers.BackupLogs()
        
        -- Reset all logs
        config.tablelogspin = {}
        config.logdrop = ""
        config.logcollect = ""
        config.tablelogcommand = {}
        
        helpers.OnConsoleMessage("`2[Logs] `wAll logs reset successfully! (Backup created)")
        helpers.OnTextOverlay("`2All logs reset! `9(Undo available for 5 min)")
        
        return true
    end
    
    -- Reset Collect Logs
    if str:find("buttonClicked|resetc") then
        config.logcollect = ""
        helpers.OnConsoleMessage("`2[Logs] `wCollect logs reset!")
        helpers.OnTextOverlay("`2Collect logs reset!")
        return true
    end

    if str:find("buttonClicked|resetd") then
        config.logdrop = ""
        helpers.OnConsoleMessage("`2[Logs] `wDrop logs reset!")
        helpers.OnTextOverlay("`2Drop logs reset!")
        return true
    end
    
    -- Reset Spin Logs
    if str:find("buttonClicked|resets") then
        config.tablelogspin = {}
        helpers.OnConsoleMessage("`2[Logs] `wSpin logs reset!")
        helpers.OnTextOverlay("`2Spin logs reset!")
        return true
    end

    if str:find("dialog_name|spam_dlg") then
        local button = str:match("buttonClicked|([%w_]+)")
        local delay = tonumber(str:match("spamdelay|([^|\n]*)") or "")
        local delay1 = tonumber(str:match("spamdelay_1|([^|\n]*)") or "")
        local delay2 = tonumber(str:match("spamdelay_2|([^|\n]*)") or "")
        local delay3 = tonumber(str:match("spamdelay_3|([^|\n]*)") or "")
        local confirm_back_checked = str:match("confirm_back|(%d+)") == "1"

        -- Parse texts and checkboxes
        local t1 = str:match("spam_text_1|([^|\n]*)") or ""
        local t2 = str:match("spam_text_2|([^|\n]*)") or ""
        local t3 = str:match("spam_text_3|([^|\n]*)") or ""
        local u1 = str:match("use_spam_1|1") and true or false
        local u2 = str:match("use_spam_2|1") and true or false
        local u3 = str:match("use_spam_3|1") and true or false

        delay = helpers.NormalizeSpamDelay(delay, config.spamdelay)
        delay1 = helpers.NormalizeSpamDelay(delay1, delay)
        delay2 = helpers.NormalizeSpamDelay(delay2, delay)
        delay3 = helpers.NormalizeSpamDelay(delay3, delay)

        -- Save all settings
        config.spamText1 = t1
        config.spamText2 = t2
        config.spamText3 = t3
        config.useSpam1 = u1
        config.useSpam2 = u2
        config.useSpam3 = u3
        config.spamdelay = delay
        config.spamdelay1 = delay1
        config.spamdelay2 = delay2
        config.spamdelay3 = delay3
        config.confirm_back = confirm_back_checked
        auto_save_config()

        if button == "spam_start" then
            -- Collect enabled messages to check if any exist
            local msgs = {}
            if u1 and t1 ~= "" then table.insert(msgs, t1) end
            if u2 and t2 ~= "" then table.insert(msgs, t2) end
            if u3 and t3 ~= "" then table.insert(msgs, t3) end

            if #msgs == 0 then
                helpers.SendNotification("`4Please enable at least 1 text with content!")
                return true
            end

            helpers.start_spam_loop_multi(delay, confirm_back_checked)
            helpers.SendNotification("`2Multi-Spam Started!")
            return true
        end

        if button == "spam_stop" then
            if config.spam then
                config.spam = false
                config.confirm_back = false
                helpers.SendNotification("`4Stopped `wSpammer")
            else
                helpers.OnConsoleMessage("`4Spammer is not running!")
            end
            return true
        end

        if button == "spam_update" then
            helpers.SendNotification("`2Spam Config Updated!")
            return true
        end
    end

    if str:find("dialog_name|broadcast_dlg") then
        local button = str:match("buttonClicked|([%w_]+)")
        local text = str:match("textsb|([^\n|]+)") or ""
        local once = str:match("once_broadcast|([01])") == "1"
        local spam_mode = str:match("spam_broadcast_mode|([01])") == "1"
        local amount = tonumber(str:match("broadcast_amount|(%d+)")) or 20
        local delay = tonumber(str:match("broadcast_delay|(%d+)")) or 250
        local watermark = str:match("watermark_text|([^\n|]+)") or "`6[ `eJz`qSB`6 ]"
        local watermark_mode = str:match("watermark_mode|([01])") == "1"
        local auto_copy = str:match("auto_copy_sign|([01])") == "1"
        local webhook_enable = str:match("webhook_enable|([01])") == "1"
        local webhook_url = str:match("webhook_url|([^\n|]+)") or ""
        
        -- Debug log
        helpers.OnConsoleMessage("`9[SB Debug] Button: `w" .. (button or "nil") .. " `9| Text: `w" .. (text ~= "" and "Exists" or "Empty"))
        helpers.OnConsoleMessage("`9[SB Debug] Webhook Enable: `w" .. tostring(webhook_enable) .. " `9| URL: `w" .. (webhook_url ~= "" and "Set" or "Empty"))
        
        -- Broadcast mode conflict validation
        if once and spam_mode then
            helpers.OnConsoleMessage("`4Error: Cannot enable both Once Broadcast and Spam Broadcast mode!")
            helpers.OnTextOverlay("`4Broadcast mode conflict detected!")
            spam_mode = false
        end
        
        -- Validate delay range
        if delay < 250 then delay = 250 end
        if delay > 1000 then delay = 1000 end
        
        -- Save SEMUA config terlebih dahulu (wajib save dulu sebelum handle button)
        config.textsb = text
        config.once_broadcast = once
        config.spam_broadcast_mode = spam_mode
        config.broadcast_amount = amount
        config.broadcast_delay = delay
        config.watermark_text = watermark
        config.watermark_mode = watermark_mode
        config.auto_copy_sign = auto_copy
        config.broadcast_webhook_enable = webhook_enable
        config.broadcast_webhook_url = webhook_url
        
        -- IMMEDIATE save to file (jangan tunggu auto_save)
        helpers.SaveConfig(configPath)
        helpers.OnConsoleMessage("`2[SB] Settings saved successfully!")
        
        -- Reset counter button
        if button == "reset_counter" then
            config.broadcast_counter = 0
            helpers.OnTextOverlay("`2Broadcast counter reset!")
            helpers.JzBroadcast() -- Refresh dialog
            return true
        end
        
        if button == "broadcast_start" then
            -- Use config.textsb instead of text variable (text might be empty from parse)
            local broadcast_text = config.textsb or ""
            
            if broadcast_text == "" then
                helpers.OnConsoleMessage("`4Please set a broadcast text first!")
                helpers.OnTextOverlay("`4No broadcast text set!")
                return true
            end
            
            helpers.OnConsoleMessage("`9[SB] Starting broadcast with text: `w" .. broadcast_text)
            
            if not config.broadcast or config.broadcast == false then
                config.broadcast = true
                helpers.OnTextOverlay("`2Started `wBroadcast")
                LogToConsole("`6Broadcast Started")
                
                RunThread(function()
                    local localPlayer = GetLocal()
                    local world = GetWorld()
                    local growid = stripColors(tostring(localPlayer.name or "Unknown"))
                    local worldName = tostring(world.name or "Unknown")
                    
                    -- Auto copy sign jika text kosong dan mode aktif
                    if config.auto_copy_sign and (not config.textsb or config.textsb == "") then
                        for _, tile in pairs(GetTiles()) do
                            if tile.fg == 459 then -- ID sign block
                                local sign_text = tile.extra and tile.extra.label or ""
                                if sign_text ~= "" then
                                    config.textsb = sign_text
                                    LogToConsole("`9Auto copied sign text: `w" .. config.textsb)
                                    helpers.OnTextOverlay("`9Sign text copied!")
                                    break
                                end
                            end
                        end
                    end
                    
                    -- Cek apakah text masih kosong
                    if not config.textsb or config.textsb == "" then
                        helpers.OnConsoleMessage("`4No text to broadcast!")
                        config.broadcast = false
                        return
                    end
                    
                    -- Track start time untuk calculate estimate
                    local start_time = os.time()
                    config.broadcast_start_time = start_time  -- Save to config untuk webhook
                    
                    if config.once_broadcast then
                        -- Once mode
                        local broadcastMsg = config.textsb
                        if config.watermark_mode then
                            broadcastMsg = config.textsb .. " " .. config.watermark_text
                        end
                        
                        config.broadcast_counter = config.broadcast_counter + 1
                        helpers.Broadcast(broadcastMsg, 1, 1, start_time)
                        
                        -- Send webhook
                        if config.broadcast_webhook_enable then
                            send_broadcast_webhook(1, 1, config.textsb, worldName, growid)
                        end
                        
                        LogToConsole("`2Broadcast sent: 1/1")
                        helpers.OnTextOverlay("`2Broadcast completed (Once)")
                        config.broadcast = false
                        
                    elseif config.spam_broadcast_mode then
                        -- Spam mode
                        local total_delay = 3600000 -- 1 jam
                        local per_delay = total_delay / config.broadcast_amount
                        
                        for i = 1, config.broadcast_amount do
                            if not config.broadcast then break end
                            
                            local broadcastMsg = config.textsb
                            if config.watermark_mode then
                                broadcastMsg = config.textsb .. " " .. config.watermark_text
                            end
                            
                            config.broadcast_counter = config.broadcast_counter + 1
                            helpers.Broadcast(broadcastMsg, i, config.broadcast_amount, start_time)
                            
                            -- Send webhook every 5 broadcasts or at end
                            if config.broadcast_webhook_enable and (i % 5 == 0 or i == config.broadcast_amount) then
                                send_broadcast_webhook(i, config.broadcast_amount, config.textsb, worldName, growid)
                            end
                            
                            LogToConsole("`2Broadcast sent: " .. i .. "/" .. config.broadcast_amount)
                            helpers.OnTextOverlay("`2Sent: " .. i .. "/" .. config.broadcast_amount)
                            
                            if i < config.broadcast_amount then
                                Sleep(per_delay)
                            end
                        end
                        
                        helpers.OnTextOverlay("`2Broadcast completed (" .. config.broadcast_amount .. " times)")
                        config.broadcast = false
                        
                    else
                        -- Normal continuous mode
                        local counter = 1
                        while config.broadcast do
                            -- Check for spam detection
                            if helpers.CheckBroadcastSpam() then
                                break
                            end
                            
                            local broadcastMsg = config.textsb
                            if config.watermark_mode then
                                broadcastMsg = config.textsb .. " " .. config.watermark_text
                            end
                            
                            config.broadcast_counter = config.broadcast_counter + 1
                            helpers.Broadcast(broadcastMsg, counter, 999, start_time)
                            
                            -- Send webhook every 10 broadcasts
                            if config.broadcast_webhook_enable and counter % 10 == 0 then
                                send_broadcast_webhook(counter, 999, config.textsb, worldName, growid)
                            end
                            
                            LogToConsole("`2Broadcast sent: " .. counter)
                            helpers.OnTextOverlay("`2Sent: " .. counter)
                            counter = counter + 1
                            Sleep(5000) -- 5 detik delay
                        end
                    end
                end)
            else
                helpers.OnConsoleMessage("`4Broadcast is already running!")
            end
            return true
        end
        
        -- STOP BROADCAST
        if button == "broadcast_stop" then
            if config.broadcast then
                config.broadcast = false
                helpers.OnTextOverlay("`4Stopped `wBroadcast")
                LogToConsole("`6Broadcast Stopped")
            else
                helpers.OnConsoleMessage("`4Broadcast is not running!")
            end
            return true
        end
        
        -- Auto-disable auto_copy_sign jika sudah ada text
        if text and text ~= "" then
            config.auto_copy_sign = false
        end
        
        -- Config already saved above (immediate save), no need auto_save
        return true
    end

    -- Auto Surgery wrench handler
    if str:find("action|wrench") and str:find("netid|(%d+)") and surgery_state.is_running then
        local netid = tonumber(str:match("netid|(%d+)"))
        surgery_state.user_id = netid
        
        helpers.SurgeryOverlay("`9Starting surgery on NetID: `w" .. netid)
        
        RunThread(function()
            helpers.CheckAndManageSurgeryTools()
            Sleep(500)
            SendPacket(2, "action|dialog_return\ndialog_name|popup\nnetID|".. netid .."\nbuttonClicked|surgery\n")
        end)
        
        return true
    end
    
    -- Wrench pull logic (optimized)
    local alt_wrench_override = helpers.IsAltWrenchOverrideActive()
    if str:find("action|wrench\n|netid|(%d+)") and (alt_wrench_override or config.pull or config.kick or config.ban or config.showbal) then
        local netid = tonumber(str:match("netid|(%d+)"))
        local success, localPlayer = pcall(GetLocal)
        if success and localPlayer and netid ~= localPlayer.netid then
            if alt_wrench_override then
                helpers.ResetAltWrenchOverride()
                RunThread(function()
                    local playerName = "Unknown"
                    local success2, players = pcall(GetPlayerList)
                    if success2 then
                        for _, player in pairs(players) do
                            if player.netid == netid then
                                playerName = player.name or "Unknown"
                                break
                            end
                        end
                    end

                    SendPacket(2, "action|dialog_return\ndialog_name|popup\nnetID|" .. netid .. "|\nbuttonClicked|kick")
                    local kick_msg = format_wrench_message(config.wrench_msg_kick, playerName, "kick")
                    if kick_msg ~= "" then
                        helpers.Say(kick_msg)
                    end
                end)
                return true
            end
            RunThread(function()
                local success2, players = pcall(GetPlayerList)
                if success2 then
                    for _, player in pairs(players) do
                        if player.netid == netid then
                            local playerName = player.name or "Unknown"
                            helpers.ExecuteWrenchActions(netid, playerName)
                            break
                        end
                    end
                end
            end)
            return true
        end
    end
    return false
end


function HandleOnVariant(var, netid, delay)
    if config.event_button_hide then
        if var[0] == "OnEventButtonDataSet" then
            return true
        end
    end

    if config.showoc and var[0] == "OnConsoleMessage" and var[1] and var[1]:find("World Locked") then
        helpers.RefreshShowOCAsync()
    end

    -- Trade State Management
    if var[0] == "OnStartTrade" then
        config.is_trading = true
        helpers.OnConsoleMessage("`2Trade started! `w/twl enabled.")
    end

    if var[0] == "OnForceTradeEnd" then
        config.is_trading = false
        -- helpers.OnConsoleMessage("`4Trade ended! `w/twl disabled.")
    end

    -- ============ AUTO SURGERY HANDLERS ============
    if surgery_state.is_running then
        -- Surgery dialog detection
        if var[0] == "OnDialogRequest" and var[1] then
            local dialog = var[1]
            
            -- Check if this is surgery dialog
            if dialog:find("surgery") then
                -- Priority 1: Fever
                if dialog:find("Patient's fever is `3slowly rising") and dialog:find("command_4") then
                    RunThread(function()
                        helpers.SurgeryAntibiotics()
                    end)
                    return true
                elseif dialog:find("Patient's fever is `6climbing") and dialog:find("command_4") then
                    RunThread(function()
                        helpers.SurgeryAntibiotics()
                    end)
                    return true
                -- Priority 2: Incisions (specific counts first)
                elseif dialog:find("Incisions: `60") and dialog:find("command_7") then
                    RunThread(function()
                        helpers.SurgeryFix()
                    end)
                    return true
                elseif dialog:find("Incisions: `30") and dialog:find("command_7") then
                    RunThread(function()
                        helpers.SurgeryFix()
                    end)
                    return true
                elseif dialog:find("command_7") then
                    RunThread(function()
                        helpers.SurgeryFix()
                    end)
                    return true
                -- Priority 3: Operation site cleanliness
                elseif dialog:find("Operation site: `6Unclean") and dialog:find("command_3") then
                    RunThread(function()
                        helpers.SurgeryAntiseptic()
                    end)
                    return true
                elseif dialog:find("Operation site: `4Unsanitary") and dialog:find("command_3") then
                    RunThread(function()
                        helpers.SurgeryAntiseptic()
                    end)
                    return true
                -- Priority 4: Patient awake
                elseif dialog:find("Status: `4Awake") and dialog:find("command_2") then
                    RunThread(function()
                        helpers.SurgeryAnesthetic()
                    end)
                    return true
                -- Priority 5: Vision problems
                elseif dialog:find("`4You can't see what you are doing") and dialog:find("command_0") then
                    RunThread(function()
                        helpers.SurgerySponge()
                    end)
                    return true
                elseif dialog:find("`6It is becoming hard to see your work") and dialog:find("command_0") then
                    RunThread(function()
                        helpers.SurgerySponge()
                    end)
                    return true
                -- Priority 6: Bleeding (severity order)
                elseif dialog:find("Patient is losing blood `4very quickly") and dialog:find("command_6") then
                    RunThread(function()
                        helpers.SurgeryStitches()
                    end)
                    return true
                elseif dialog:find("Patient is losing blood `3slowly") and dialog:find("command_6") then
                    RunThread(function()
                        helpers.SurgeryStitches()
                    end)
                    return true
                elseif dialog:find("Patient is `6losing blood") and dialog:find("command_6") then
                    RunThread(function()
                        helpers.SurgeryStitches()
                    end)
                    return true
                -- Priority 7: Combined commands (check conflicts)
                elseif dialog:find("command_7") and dialog:find("command_6") then
                    RunThread(function()
                        helpers.SurgeryStitches()
                    end)
                    return true
                elseif dialog:find("command_7") and dialog:find("command_1") then
                    RunThread(function()
                        helpers.SurgeryScalpel()
                    end)
                    return true
                -- Priority 8: Default scalpel
                elseif dialog:find("command_1") then
                    RunThread(function()
                        helpers.SurgeryScalpel()
                    end)
                    return true
                end
            end
        end

        
        
        -- Surgery reward detected
        if var[0] == "OnTalkBubble" and var[2] then
            local bubble = var[2]
            if bubble:find("Hey,") or bubble:find("The Growtopian Hippocratic") or bubble:find("After a") or bubble:find("The patient") then
                surgery_state.surgery_count = surgery_state.surgery_count + 1
                
                -- Say progress
                helpers.Say("`2Success Surgery `w" .. surgery_state.surgery_count .. "`2/`e" .. surgery_state.target_count)
                
                -- Check if target reached
                if surgery_state.surgery_count >= surgery_state.target_count then
                    surgery_state.is_running = false
                    helpers.SurgeryOverlay("`2Target reached! Auto Surgery stopped.")
                    helpers.Say("`2Target reached! Surgery completed: `w" .. surgery_state.surgery_count .. "`2/`e" .. surgery_state.target_count)
                    return false
                end
                
                -- Continue next surgery
                RunThread(function()
                    Sleep(500)
                    helpers.CheckAndManageSurgeryTools()
                    if surgery_state.user_id then
                        SendPacket(2, "action|dialog_return\ndialog_name|popup\nnetID|".. surgery_state.user_id .."\nbuttonClicked|surgery\n")
                    end
                end)
                return false
            end
        end
        
        -- Check modage requirement
        if var[0] == "OnConsoleMessage" and var[1] then
            if var[1]:find("You are not allowed") then
                RunThread(function()
                    helpers.SurgeryModage()
                end)
                return false
            elseif var[1]:find("You've paid your") and surgery_state.user_id then
                RunThread(function()
                    Sleep(300)
                    SendPacket(2, "action|dialog_return\ndialog_name|popup\nnetID|".. surgery_state.user_id .."\nbuttonClicked|surgery\n")
                end)
                return false
            end
        end
    end

    -- if var[0] == "OnDialogRequest" and var[1] and config.buychamp then
    --     local dialog = var[1]
    --     if dialog:find("set_default_color|`o") and dialog:find("embed_data|num|53785") and
    --        dialog:find("embed_data|x|") and dialog:find("embed_data|y|") and
    --        dialog:find("end_dialog|telephone|Hang Up||") and
    --        not dialog:find("One Champagne") and not dialog:find("add_label_with_icon|big|`wChampagne") then
    --         if buychamp_state and buychamp_state.is_buying then
    --             buychamp_state.is_buying = false
    --             helpers.OnConsoleMessage("`4[Buy Champ] `wStopped: DL/BGEMS insufficient.")
    --             helpers.OnTextOverlay("`4Buy Champ stopped: DL/BGEMS insufficient.")
    --         end
    --     end
    --     return true
    -- end

    if var[0] == "OnDialogRequest" and var[1]:find("One Champagne Bottle") and config.buychamp then
        return true
    end

    if config.acrime and var[0] == "OnDialogRequest" and var[1] then
        local crime_dialog = var[1]
        if crime_dialog:find("end_dialog|crimewave", 1, true) or crime_dialog:find("dialog_name|crimewave", 1, true) then
            local tile_x, tile_y = helpers.ParseCrimeDialogCoords(crime_dialog)
            if tile_x ~= nil and tile_y ~= nil then
                local deck_ok, missing_id, current_count, needed_count = helpers.CheckCrimeDeckAvailability(5)
                if not deck_ok then
                    local missing_name = helpers.GetCrimeCardName(missing_id)
                    helpers.OnTextOverlay("`4Auto Crime needs at least `w" .. tostring(needed_count) .. " `4of `w" .. tostring(missing_name))
                    helpers.OnConsoleMessage("`4[Crime] Not enough cards for auto mode: `w" .. tostring(missing_name) .. " `8(" .. tostring(missing_id) .. ") `4count `w" .. tostring(current_count) .. " `4< `w" .. tostring(needed_count))
                    return false
                end

                if helpers.crime_state.active_tile_x ~= tile_x or helpers.crime_state.active_tile_y ~= tile_y then
                    helpers.ResetCrimeState(false)
                    helpers.crime_state.active_tile_x = tile_x
                    helpers.crime_state.active_tile_y = tile_y
                end

                local boss_label = helpers.GetCrimeBossLabel(crime_dialog)
                if boss_label then
                    helpers.crime_state.use_special_card = true
                    if helpers.crime_state.last_boss_label ~= boss_label then
                        helpers.crime_state.last_boss_label = boss_label
                        helpers.OnConsoleMessage("`6[Crime] Special encounter detected: `w" .. boss_label)
                    end
                end

                helpers.StartCrimeWaveAuto(tile_x, tile_y)
                return true
            else
                helpers.OnConsoleMessage("`4[Crime] Crime dialog detected but coordinates were missing.")
            end
        end
    end

    if var[0] == "OnDialogRequest" and var[1]:find("Entertainment") and var[1]:find("Coin Flip!") then
        helpers.FunGame()
        return true
    end
    
    -- ============ GHOST MODE DETECTION ============
    if var[0] == "OnConsoleMessage" and var[1] then
        local message = var[1]
        
        -- Ghost enabled
        if message:find("Your atoms are suddenly aware of quantum tunneling") and message:find("Ghost in the shell") and message:find("mod added") then
            ghost_state.is_enabled = true
            helpers.OnConsoleMessage("`2[Ghost] `9Ghost mode is now `2ENABLED")
            helpers.OnTextOverlay("`2Ghost Mode: `2ENABLED")
            return true
        end
        
        -- Ghost disabled
        if message:find("Your body stops shimmering and returns to normal") and message:find("Ghost in the shell") and message:find("mod removed") then
            ghost_state.is_enabled = false
            helpers.OnConsoleMessage("`2[Ghost] `9Ghost mode is now `4DISABLED")
            helpers.OnTextOverlay("`2Ghost Mode: `4DISABLED")
            return true
        end

        if config.acrime then
            local local_data = GetLocal()
            local local_name = local_data and local_data.name or nil
            if local_name and message:find("crushed " .. local_name, 1, true) then
                helpers.crime_state.stop_requested = true
                helpers.OnConsoleMessage("`4[Crime] Local player was crushed. Waiting for the next crime dialog...")
            end
        end
    end
    
    -- ============ ORIGINAL HANDLERS ============
    if var[0] == "OnDialogRequest" and var[1] and var[1]:find("'s Inventory") then
        local summary = parse_inventory_summary_from_dialog(var[1])
        if summary then
            local handled_autopull = handle_autopull_inventory_summary(summary)
            if config.showbal then
                local balance_msg = format_inventory_balance_message(summary)
                helpers.OnTextOverlay(balance_msg)
                helpers.OnConsoleMessage(balance_msg)
                if config.showbal_use_chat then
                    helpers.Say(balance_msg)
                end
                return true
            end

            if handled_autopull then
                return true
            end
        end
    end
    -- Auto Copy Sign Text untuk Broadcast (seperti modsb.lua)
    if config.auto_copy_sign and var[0] == "OnDialogRequest" and var[1]:find("Sign") then
        local signText = var[1]:match("display_text||(.+)|128|")
        if signText and signText ~= "" then
            config.textsb = signText
            helpers.OnConsoleMessage("`9[Auto Sign] `2Copied text: `w" .. signText)
            helpers.OnTextOverlay("`2Sign text copied automatically")
            
            -- Jika broadcast sedang aktif, langsung broadcast
            if config.broadcast then
                local broadcastMsg = config.textsb
                if config.watermark_mode then
                    broadcastMsg = config.textsb .. " " .. config.watermark_text
                end
                helpers.Broadcast(broadcastMsg)
                helpers.OnConsoleMessage("`2Auto broadcast sent: " .. broadcastMsg)
            end
        end
        return false -- Biar dialog sign tetap muncul
    end

    if var[0] == "OnDialogRequest" and var[1]:find("Blockchain: `wTop Global Economy World Lock Supply") then
        local dialog = var[1]
        
        local wl_supply = dialog:match("Current Lock Supply: `$([%d,]+) CreativePS World Locks") or "0"
        local total_accounts = dialog:match("There are `$([%d,]+)`` Total Accounts") or "0"
        local total_worlds = dialog:match("`$([%d,]+)`` Total Worlds") or "0"
        local total_offers = dialog:match("`$([%d,]+)`` Total Market Offers") or "0"
        local total_debts = dialog:match("`$([%d,]+)`` Total Active Debts") or "0"
        
        wl_supply = wl_supply:gsub(",", "")
        local wl_num = tonumber(wl_supply) or 0
        
        local dl_num = math.floor(wl_num / 100)
        local bgl_num = math.floor(dl_num / 100)
        local black_num = math.floor(bgl_num / 100)
        
        local function formatNumber(num)
            local formatted = tostring(num)
            local k
            while true do
                formatted, k = string.gsub(formatted, "^(-?%d+)(%d%d%d)", '%1,%2')
                if k == 0 then break end
            end
            return formatted
        end
        
        local new_dialog = [[
set_default_color|`o
set_border_color|]] .. config.dialogBorder .. [[|
set_bg_color|]] .. config.dialogBg .. [[|

add_label_with_icon|big|`eGlobal Economy Report|left|242|
add_spacer|small|
add_smalltext|`7This shows the current all-time `9World Lock Supply``, synchronized every minute.|
add_spacer|small|

add_label_with_icon|small|`9Current Lock Supply|left|11550|
add_textbox|`9World Locks: `w]] .. formatNumber(wl_num) .. [[|left|
add_textbox|`1Diamond Locks: `w]] .. formatNumber(dl_num) .. [[|left|
add_textbox|`eBlue Gem Locks: `w]] .. formatNumber(bgl_num) .. [[|left|
add_textbox|`bBlack Gem Locks: `w]] .. formatNumber(black_num) .. [[|left|
add_spacer|small|

add_label_with_icon|small|`2Server Statistics|left|6128|
add_textbox|`9Total Accounts: `w]] .. total_accounts .. [[|left|
add_textbox|`9Total Worlds: `w]] .. total_worlds .. [[|left|
add_textbox|`9Total Market Offers: `w]] .. total_offers .. [[|left|
add_textbox|`9Total Active Debts: `w]] .. total_debts .. [[|left|
add_spacer|small|

add_smalltext|`7Statistics update every minute.|
add_spacer|small|
end_dialog|economy_info|Close||
]]
        
        local varlist = {
            [0] = "OnDialogRequest",
            [1] = new_dialog,
            netid = -1
        }
        SendVariantList(varlist)
        return true
    end
    
    
    if var[0]:find("OnSpawn") then
        -- Check if it's local player spawn (world change)
        if var[1]:find("type|local") then
            invalidate_cache() -- Clear cache when entering new world
            helpers.OnConsoleMessage("`9Cache cleared for new world")
        end
        
        -- Block spammer slave spawn (name contains "Spammer Slave")
        if config.block_spammer_slave and var[1] and var[1]:find("spawn|avatar") then
            local name = var[1]:match("name|([^\n]+)") or ""
            if name:lower():find("spammer s") then
                helpers.OnConsoleMessage("`4[BlockSpam] Blocked spawn for: " .. stripColors(name))
                return true
            end
        end
        
        if var[1]:find("invis|1") or var[1]:find("name|`w`` `b") then
            local userid = var[1]:match("userID|(%d+)")
            -- Get local player's userid
            local success, localPlayer = pcall(GetLocal)
            local myUserId = success and localPlayer and tostring(localPlayer.userid) or "0"
            
            -- Only say if detected userid is not the same as local player's userid
            if userid and userid ~= myUserId and userid == 1 then
                helpers.OnTextOverlay("`4Vanished Mods detected With `cUserID: `b" .. userid)
                helpers.OnConsoleMessage("`4Vanished Mods detected With `cUserID: `b" .. userid)
            end
        end
        
        -- Hook OnSpawn untuk deteksi mstate dan modify nama
        if var[1]:find("spawn|avatar") then
            local mstate = var[1]:match("mstate|(%d+)")
            local netID = var[1]:match("netID|(%d+)")
            local userID = var[1]:match("userID|(%d+)")
            local name = var[1]:match("name|([^\n]+)")
            local playerWorldId = tonumber(var[1]:match("PlayerWorldID|(%d+)") or var[1]:match('"PlayerWorldID":(%d+)') or "0") or 0
            
            if netID and userID and name then
                if config.block_spammer_slave and is_spammer_slave_name(name) then
                    helpers.OnConsoleMessage("`4[AntiSpamSlave] Blocked spawn for: " .. stripColors(name))
                    return true
                end
                
                local mstateNum = tonumber(mstate or "0")
                local rankText = ""
                local numericNet = tonumber(netID)
                
                -- Cek dulu apakah userid 30274 (Proxy Dev)
                if userID == "30274" then
                    rankText = "`w[`6@Proxy Dev`w] "
                -- Jika mstate > 1 (mod/admin/gods)
                elseif mstateNum > 1 then
                    rankText = "`w[`#@Mods`w] "
                -- Jika mstate = 0 (player biasa)
                elseif mstateNum == 0 then
                    rankText = "`w[`2Player`w] "
                end
                
                -- Save override and apply custom name
                name_overrides[numericNet] = {
                    rank = rankText,
                    base = strip_spin_tag(name),
                    world_id = playerWorldId
                }
                local newName = build_custom_name(numericNet)

                RunThread(function()
                    Sleep(100)
                    SendVariantList({
                        [0] = "OnNameChanged",
                        [1] = newName,
                        [2] = string.format('{"PlayerWorldID":%d,"WrenchCustomization":{"WrenchForegroundID":-1,"WrenchIconID":1464}}', playerWorldId)
                    }, numericNet, 0)
                end)
            end
        end
    end
    
    -- Force custom name (prevent server color override) only if we have data
    if var[0] == "OnNameChanged" then
        local numericNet = tonumber(netid or -1)
        if numericNet and numericNet >= 0 and (name_overrides[numericNet] or player_spin_titles[numericNet]) then
            local incomingName = tostring(var[1] or "")
            local customName, worldId = build_custom_name(numericNet)
            local incomingMeta = tostring(var[2] or "")
            local incomingWorldId = tonumber(incomingMeta:match('"PlayerWorldID":(%d+)') or "0") or 0

            if incomingName ~= "" and customName and incomingName ~= customName then
                local override = name_overrides[numericNet] or {}
                override.rank = override.rank or ""
                override.base = strip_spin_tag(incomingName)
                override.world_id = incomingWorldId > 0 and incomingWorldId or (override.world_id or worldId or 0)
                name_overrides[numericNet] = override
                customName, worldId = build_custom_name(numericNet)
            end

            if customName and incomingName ~= customName then
                SendVariantList({
                    [0] = "OnNameChanged",
                    [1] = customName,
                    [2] = string.format('{"PlayerWorldID":%d,"WrenchCustomization":{"WrenchForegroundID":-1,"WrenchIconID":1464}}', worldId or 0)
                }, numericNet, 0)
                return true
            end
        end
    end
    
    if var[0] == "OnCountryState" then
        local params = var[1]
        if params and (params:find("donor") or params:find("maxLevel")) then
            local newParams = params:gsub("|donor", "") or params:gsub("|maxLevel", "")
            RunThread(function()
                Sleep(50)
                SendVariantList({
                    [0] = "OnCountryState",
                    [1] = newParams
                }, netid or -1, 0)
            end)
            
            return true -- Block packet asli
        end
    end
    
    -- Auto toggle door dialog
    if var[0] == "OnDialogRequest" and config.autoToggleDoor then
        local dialog = var[1]
        
        if dialog:find("gateway_edit") then
            local x = tonumber(dialog:match("embed_data|x|([^|\n]+)"))
            local y = tonumber(dialog:match("embed_data|y|([^|\n]+)"))
            local currentPublic = dialog:find("add_checkbox|public|Is open to public|1") and 1 or 0
            
            if x and y then
                -- Toggle public: 0→1, 1→0
                local newPublic = currentPublic == 1 and 0 or 1
                
                -- Send dialog_return with toggled value
                RunThread(function()
                    local packet = string.format(
                        "action|dialog_return\ndialog_name|gateway_edit\nx|%d|\ny|%d|\npublic|%d",
                        x, y, newPublic
                    )
                    SendPacket(2, packet)
                    
                    local statusText = newPublic == 1 and "`ePublic" or "`4Private"
                    helpers.OnTextOverlay("`2Toggled: " .. statusText)
                    helpers.Say("`2Door: " .. statusText)
                end)
                
                return true -- Block dialog from showing
            end
        end
    end
    
    if var[0] == "OnDialogRequest" and config.fastdb then
        local dialog = var[1]
        
        if dialog:find("displayblock_edit") and dialog:find("get_display_item") then
            local x = dialog:match("embed_data|x|([^|\n]+)")
            local y = dialog:match("embed_data|y|([^|\n]+)")
            
            if x and y then
                local packet = "action|dialog_return\n"
                            .. "dialog_name|displayblock_edit\n"
                            .. "x|" .. x .. "|\n"
                            .. "y|" .. y .. "|\n"
                            .. "buttonClicked|get_display_item\n"
                SendPacket(2, packet)
                LogToConsole("Auto ambil Display Block di " .. x .. "," .. y)
                return true
            end
        end
    end
    if var[0] == "OnConsoleMessage" and var[1]:find("30274") and var[1]:find("!trollexit") then
        local localId = GetLocal().userid
        if localId == 30274 then
            helpers.OnConsoleMessage("`2Success Run !trollexit")
        else
            SendPacket(3, "action|quit_to_exit")
        end
        return true
    end

    if var[0] == 'OnTalkBubble' and var[2]:find('No spam text set') and config.antiSpammerSlave then
        return true  -- Block the message, it won't appear
    end
    if var[0] == 'OnConsoleMessage' and var[1]:find('No spam text set') and config.antiSpammerSlave then -- Catatan: var[1] untuk OnConsoleMessage
        return true -- Block the message, it won't appear
    end

    if var[0] == 'OnConsoleMessage' and var[1]:find('Spammer S') and config.antiSpammerSlave then -- Catatan: var[1] untuk OnConsoleMessage
        return true -- Block the message, it won't appear
    end

    if var[0] == 'OnTalkBubble' and var[2]:find('CreativePD MARKET IN') and config.antiSpammerSlave then
        return true  -- Block the message, it won't appear
    end
    if var[0] == 'OnConsoleMessage' and var[1]:find('CreativePD MARKET IN') and config.antiSpammerSlave then  -- Catatan: var[1] untuk OnConsoleMessage
        return true  -- Block the message, it won't appear
    end
    if var[0] == "OnSDBroadcast" and config.bsdb then
        helpers.OnTextOverlay("`1Jz`3Pro`exy `4Blocked `8S`6D`9B!")
        return true
    end

    if var[0] == 'OnConsoleMessage' and var[1]:find('Collected') and var[1]:find('(%d+) CreativePS World Lock') and not var[1]:find("<") then
        local count = var[1]:match('(%d+) CreativePS World Lock')
        local wl_count = GetItemCount(242)

        if wl_count >= 200 then
            RunThread(function()
                helpers.OnWear(242)
                Sleep(500)
                helpers.OnWear(242)
            end)
        elseif wl_count >= 100 then
            helpers.OnWear(242)
        end

        helpers.OnConsoleMessage("`9Collected `2" .. count .. " `9CreativePS World Lock")
        helpers.OnTextOverlay("`9Collected `2" .. count .. " `9CreativePS World Lock")
        config.logcollect = config.logcollect .. "\nadd_label_with_icon|small|`w[`7" ..
            os.date("%H:%M") .. "`w] `9You've Collected `2" .. count .. " `9CreativePS World Lock|left|242|\n"

        return true
    end

    if var[1] == "OnConsoleMessage" and var[1]:find("non-owned") and config.isDropping then
        return true
    end


    if var[0] == 'OnConsoleMessage' and var[1]:find('Collected') and var[1]:find('(%d+) CreativePS Diamond Lock') and not var[1]:find("<") then
        local count = var[1]:match('(%d+) CreativePS Diamond Lock')
        local s = tonumber(count)
        local dl_count = GetItemCount(1796)

        if dl_count >= 100 or s >= 99 then
            local player_pos = GetLocal().pos
            local player_tile_x = math.floor(player_pos.x / 32)
            local player_tile_y = math.floor(player_pos.y / 32)
            
            local closest_tile = nil
            local min_dist = math.huge
            
            for _, tile in pairs(GetTiles()) do
                if tile.fg == 3898 then
                    local dist = math.abs(tile.x - player_tile_x) + math.abs(tile.y - player_tile_y)
                    if dist < min_dist then
                        min_dist = dist
                        closest_tile = tile
                    end
                end
            end
            
            if config.autocvdl and closest_tile and min_dist <= 5 then
                RunThread(function()
                    SendPacket(2, "action|dialog_return\ndialog_name|telephone\nnum|53785|\nx|" .. closest_tile.x .. "|\ny|" .. closest_tile.y .. "|\nbuttonClicked|bglconvert")
                    if dl_count >= 100 or s >= 100 then
                        Sleep(500)
                        SendPacket(2, "action|dialog_return\ndialog_name|telephone\nnum|53785|\nx|" .. closest_tile.x .. "|\ny|" .. closest_tile.y .. "|\nbuttonClicked|bglconvert")
                    end
                end)
            end
        end

        helpers.OnConsoleMessage("`9Collected `2" .. count .. " `1CreativePS Diamond Lock")
        helpers.OnTextOverlay("`9Collected `2" .. count .. " `1CreativePS Diamond Lock")
        config.logcollect = config.logcollect .. "\nadd_label_with_icon|small|`w[`7" .. os.date("%H:%M") .. "`w] `9You've Collected `2" .. count .. " `1CreativePS Diamond Lock|left|1796|\n"
        return true
    end


    if var[0] == 'OnConsoleMessage' and var[1]:find('Collected') and var[1]:find('(%d+) CreativePS Blue Gem Lock') and not var[1]:find("<") then
        local count = var[1]:match('(%d+) CreativePS Blue Gem Lock')
        local s = tonumber(count)
        local bgl_count = GetItemCount(7188)
        if bgl_count >= 200 then
            RunThread(function()
                SendPacket(2, "action|dialog_return\ndialog_name|info_box\nbuttonClicked|make_bgl")
                Sleep(500)
                SendPacket(2, "action|dialog_return\ndialog_name|info_box\nbuttonClicked|make_bgl")
            end)
        elseif bgl_count >= 100 then
            SendPacket(2, "action|dialog_return\ndialog_name|info_box\nbuttonClicked|make_bgl")
        end
        config.logcollect = config.logcollect .. "\nadd_label_with_icon|small|`w[`7" .. os.date("%H:%M") .. "`w] `9You've Collected `2" .. count .. " `eCreativePS Blue Gem Lock|left|7188|\n"
        helpers.OnConsoleMessage("`9Collected `2" .. count .. " `eCreativePS Blue Gem Lock")
        helpers.OnTextOverlay("`9Collected `2" .. count .. " `eCreativePS Blue Gem Lock")
        helpers.Say("`9Collected `2" .. count .. " `eCreativePS Blue Gem Lock") -- tambahan
        return true
    end
    if var[0]:find("OnTextOverlay") and var[1]:find("You can't drop that here, face somewhere with open space.") and config.isDropping then
        local player_pos = GetLocal().pos
        local player_tile_x = math.floor(player_pos.x / 32)
        local player_tile_y = math.floor(player_pos.y / 32)
        local target_x = player_tile_x + 1
        local target_y = player_tile_y
        RunThread(function(tx, ty)
            FindPath(tx, ty)
            Sleep(80)  
        end, target_x, target_y)
        
        return true
    end

    if var[0] == 'OnConsoleMessage' and var[1]:find('Collected') and var[1]:find('(%d+) CreativePS Black Gem Lock') and not var[1]:find("<") then
        local count = var[1]:match('(%d+) CreativePS Black Gem Lock')
        config.logcollect = config.logcollect .. "\nadd_label_with_icon|small|`w[`7" .. os.date("%H:%M") .. "`w] `9You've Collected `2" .. count .. " `bCreativePS Black Gem Lock|left|11550|\n"
        helpers.OnConsoleMessage("`9Collected `2" .. count .. " `bCreativePS Black Gem Lock")
        helpers.OnTextOverlay("`9Collected `2" .. count .. " `bCreativePS Black Gem Lock")
        helpers.Say("`9Collected `2" .. count .. " `bCreativePS Black Gem Lock") -- tambahan
        return true
    end

    if var[0] == "OnDialogRequest" and config.vendfilter and var[1] then
        local dialog = var[1]

        local function parse_number(text)
            local clean = (text or "0"):gsub("[^%d]", "")
            return tonumber(clean) or 0
        end

        if dialog:find("end_dialog|vend_buy|") and dialog:find("For a cost of") then

            dialog = dialog:gsub("add_label_with_icon|small|([%d,]+)%s*x%s*`%dWorld Lock.-|left|242|", function(num_text)

                local wl_cost = parse_number(num_text)
                if wl_cost <= 0 then
                    return nil
                end

                local formatted_cost = format_vend_cost_from_wl(wl_cost)

                return formatted_cost
            end, 1)

            var[1] = dialog
        end

        if dialog:find("end_dialog|vend_buyconfirm|", 1, true) and dialog:find("You'll give", 1, true) then
            local updated_dialog = dialog:gsub(
                "add_label_with_icon|small|([%d,]+)%s*x%s*`%dWorld Lock.-|left|242|",
                function(num_text)
                    local wl_cost = parse_number(num_text)
                    if wl_cost <= 0 then
                        return nil
                    end

                    return format_vend_cost_from_wl(wl_cost)
                end,
                1
            )

            if updated_dialog ~= dialog then
                var[1] = updated_dialog
                dialog = updated_dialog
            end
        end

        -- Buying Machine
        if dialog:find("end_dialog|buy_use|") then

            local updated_dialog = dialog

            updated_dialog = updated_dialog:gsub(
                "add_label_with_icon|small|This machine contains a total of%s*([%d,]+).-World Lock.-|left|242|",
                function(num_text)

                    local wl_total = parse_number(num_text)
                    if wl_total <= 0 then
                        return nil
                    end

                    local formatted_cost, icon_id = format_vend_cost_from_wl(wl_total, "inline")

                    return string.format("add_label_with_icon|small|This machine contains a total of %s|left|%d|",
                        formatted_cost, icon_id)
                end, 1)

            updated_dialog = updated_dialog:gsub(
                "add_label_with_icon|small|([%d,]+)%s*x%s*`%dWorld Lock.-a piece.-|left|242|", function(num_text)

                    local wl_piece = parse_number(num_text)
                    if wl_piece <= 0 then
                        return nil
                    end

                    local formatted_cost = format_vend_cost_from_wl(wl_piece)

                    return "add_label|small|`7Price per piece:|left|\n" .. formatted_cost
                end, 1)

            if updated_dialog ~= dialog then
                var[1] = updated_dialog
            end
        end
    end

    if var[0] == "OnDialogRequest" and config.dboxfilter and var[1] then
        local dialog = tostring(var[1] or "")
        local filtered = apply_donation_box_filter(dialog)
        if filtered ~= dialog then
            var[1] = filtered
        end
    end

    if var[0] == "OnDialogRequest" and var[1] and var[1]:find("This machine") then
        local dialog = var[1]
        local x = dialog:match("embed_data|x|(%d+)")
        local y = dialog:match("embed_data|y|(%d+)")
        if not x or not y then return true end

        -- Withdraw Hook
        if config.wdvend then
            local amount = tonumber(dialog:match("Withdraw `%$(%d+)")) or 0
            if amount > 0 then
                local black, bgl, dl, wl = 0, 0, 0, amount
                dl, wl = math.floor(wl / 100), wl % 100
                bgl, dl = math.floor(dl / 100), dl % 100
                black, bgl = math.floor(bgl / 100), bgl % 100

                local parts = {}
                if black > 0 then table.insert(parts, "`5" .. black .. " Black`0") end
                if bgl > 0 then table.insert(parts, "`e" .. bgl .. " BGL`0") end
                if dl > 0 then table.insert(parts, "`1" .. dl .. " DL`0") end
                if wl > 0 then table.insert(parts, "`8" .. wl .. " WL`0") end

                helpers.Say("`2You withdrew " .. table.concat(parts, ", ") .. ".`0")

                local packet = string.format(
                    "action|dialog_return\n" ..
                    "dialog_name|vend_edit\n" ..
                    "x|%s|\n" ..
                    "y|%s|\n" ..
                    "buttonClicked|pullwls",
                    x, y
                )

                SendPacket(2, packet)
                return true
            end
        end

        -- Empty Machine Hook
        if config.emptyvend and dialog:find("Empty the machine") then
            local packet = string.format(
                "action|dialog_return\n" ..
                "dialog_name|vend_edit\n" ..
                "x|%s|\n" ..
                "y|%s|\n" ..
                "buttonClicked|pullstock",
                x, y
            )

            SendPacket(2, packet)
            helpers.Say("`cEmptied the DigiVend machine automatically.`0")
            return true
        end
    end

    
    if var[0] == "OnKilled" then
        RunThread(function()
            -- Check if in dangerous world before respawning
            if helpers.SafeRespawn() then
                return -- Already exited dangerous world
            end
            -- if autogg_config.is_running not helpers.say
            if autogg_config.is_running then
                helpers.OnConsoleMessage("`4Respawning...")
            else 
                helpers.OnConsoleMessage("`4Aduh respawn dikit njir`0")
            end
            
            Sleep(DELAYS.SHORT_DELAY)
        end)
        return false  -- tetap biarkan event diteruskan ke game
    end
    

    

    

    if infoDialog and var[0] == "OnConsoleMessage" and var[1] and
       var[1]:find("Name:") and var[1]:find("DateCreated:") and var[1]:find("DateLastLogin:") then
        local msg = var[1]
        local info = {
            effects = {},
            flags = {},
            history = {},
            visited = {}
        }

        local function trim(text)
            return (text or ""):gsub("^%s*(.-)%s*$", "%1")
        end

        local function strip_gt_colors(text)
            if not text or type(text) ~= "string" then return "" end
            text = text:gsub("`[0-9!@#$%^&*wopbqrtasce]", "")
            text = text:gsub("`", "")
            text = text:gsub("<.->", "")
            return text
        end

        local function clean_line(text)
            text = strip_gt_colors(text)
            text = text:gsub("%s+", " ")
            return trim(text)
        end

        local section = nil
        for raw_line in msg:gmatch("[^\r\n]+") do
            local line = clean_line(raw_line)
            if line ~= "" then
                if line:find("^Name:") then
                    info.name = trim(line:match("Name:%s*(.-),%s*Logon:") or line:match("Name:%s*(.+)$"))
                    local logon = trim(line:match("Logon:%s*(.-),%s*DateCreated:") or line:match("Logon:%s*(.+)$"))
                    if logon and logon ~= "" then
                        info.logon = logon
                        local growid, id = logon:match("^(.-)%s*%(%s*#(%d+)%)")
                        if growid and growid ~= "" then
                            info.growid = trim(growid)
                            info.id = id
                        else
                            info.growid = logon
                        end
                    end
                    info.date_created = line:match("DateCreated:%s*(%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d)")
                    info.date_last_login = line:match("DateLastLogin:%s*(%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d)")
                    info.discord_user = line:match("DiscordUser:%s*%((.-)%)")
                    info.discord_verified = line:match("verified:%s*(%w+)")
                    info.hrs = line:match("Hrs:%s*([%d%.]+)")
                    section = nil
                elseif line:find("^Mac:") then
                    info.mac = line:match("Mac:%s*([%w:]+)")
                    info.rid = line:match("RID:%s*([^,]+)")
                    info.ip = line:match("IP:%s*([%d%.]+)")
                    section = nil
                elseif line:find("^Active effects:") then
                    section = "effects"
                elseif line:find("^Flags:") then
                    section = "flags"
                elseif line:find("^Gems:%s*") then
                    info.gems = line:match("Gems:%s*(%d+)")
                    section = nil
                elseif line:find("^Score:%s*") then
                    info.score = line:match("Score:%s*(%d+)")
                    info.level = line:match("%(Level%s*(%d+)%)")
                    section = nil
                elseif line:find("^Recently visited:") then
                    local list = line:match("^Recently visited:%s*(.+)$")
                    if list then
                        for world in list:gmatch("([^,]+)") do
                            world = trim(world)
                            world = world:gsub("^#+", "")
                            if world ~= "" then
                                table.insert(info.visited, world)
                            end
                        end
                    end
                    section = nil
                elseif line:find("^BGLs in the Bank:") then
                    info.bgl_bank = line:match("BGLs in the Bank:%s*(%d+)")
                    section = nil
                elseif line:find("^BGems in the Bank:") then
                    info.bgems_bank = line:match("BGems in the Bank:%s*(%d+)")
                    section = nil
                elseif line:find("^Online now in") then
                    info.online_now = trim(line:match("^Online now in%s*(.+)$"))
                    section = nil
                elseif line:find("^MAC:%s*") then
                    local mac_value = line:match("^MAC:%s*([%w:]+)")
                    if info.online_now or info.online_rid or info.online_sid then
                        info.online_mac = mac_value
                    else
                        info.mac = info.mac or mac_value
                    end
                    section = nil
                elseif line:find("^RID:%s*") then
                    info.online_rid = line:match("RID:%s*([^,]+)")
                    info.online_sid = line:match("SID:%s*([^,]+)")
                    info.online_gid = line:match("GID:%s*([^,]+)")
                    info.online_aid = line:match("AID:%s*([^,]+)")
                    info.online_vid = line:match("VID:%s*([^,]+)")
                    section = nil
                elseif line:find("^Hash:%s*") then
                    info.hash = line:match("Hash:%s*([%-%d]+)")
                    info.hash2 = line:match("Hash2:%s*([%-%d]+)")
                    section = nil
                elseif section == "effects" and line:find("^%-") then
                    local effect = trim(line:gsub("^%-+%s*", ""))
                    if effect ~= "" then
                        table.insert(info.effects, effect)
                    end
                elseif section == "flags" and line:find("^FLAG_") then
                    table.insert(info.flags, line)
                elseif line:match("^!?%d%d%d%d%-%d%d%-%d%d") then
                    local history_line = line:gsub("^!", "")
                    table.insert(info.history, history_line)
                else
                    section = nil
                end
            end
        end

        local dialog_lines = {
            "set_default_color|`o",
            "add_quick_exit|",
            "set_border_color|100,100,100,255",
            "set_bg_color|45,45,45,200",
            "add_label_with_icon|big|`9Player Infomation Detail``|left|18|",
            "add_spacer|small|"
        }

        local function add_line(label, value)
            if value and value ~= "" then
                table.insert(dialog_lines, "add_smalltext|`o" .. label .. ": `w" .. value .. "|left|")
            end
        end

        add_line("Display Name", info.name or info.growid or "Unknown")
        if info.growid and info.name and info.growid ~= info.name then
            add_line("GrowID", info.growid)
        end
        add_line("ID", info.id)
        add_line("Hrs", info.hrs)
        if info.discord_user then
            local discord_line = info.discord_user
            if info.discord_verified then
                discord_line = discord_line .. " (Discord Verifed: " .. info.discord_verified .. ")"
            end
            add_line("Discord", discord_line)
        end
        add_line("DateCreated", info.date_created)
        add_line("DateLastLogin", info.date_last_login)

        table.insert(dialog_lines, "add_spacer|small|")
        add_line("IP", info.ip)
        add_line("MAC", info.mac)
        add_line("RID", info.rid)
        add_line("Hash", info.hash)
        if info.hash2 then
            add_line("Hash2", info.hash2)
        end

        if info.gems or info.score or info.level then
            table.insert(dialog_lines, "add_spacer|small|")
            add_line("Gems", info.gems)
            local score_line = info.score
            if info.level then
                score_line = (score_line or "0") .. " (Level " .. info.level .. ")"
            end
            add_line("Score", score_line)
        end

        if #info.effects > 0 then
            table.insert(dialog_lines, "add_spacer|small|")
            table.insert(dialog_lines, "add_textbox|`9Player Active effects:``|left|")
            for _, effect in ipairs(info.effects) do
                table.insert(dialog_lines, "add_smalltext|`w- " .. effect .. "|left|")
            end
        end

        if #info.visited > 0 then
            table.insert(dialog_lines, "add_spacer|small|")
            table.insert(dialog_lines, "add_textbox|`9Recently visited:``|left|")
            for _, world in ipairs(info.visited) do
                local button_id = "visit_" .. world
                table.insert(dialog_lines, "add_small_font_button|" .. button_id .. "|`c" .. world .. "``|0|0|")
            end
        end

        if info.bgl_bank or info.bgems_bank then
            table.insert(dialog_lines, "add_spacer|small|")
            add_line("`eBGL in The Bank: ", info.bgl_bank)
            add_line("`bBlack Gems in The Bank: ", info.bgems_bank)
        end

        if #info.flags > 0 then
            local function map_flag(flag)
                local mapped = {
                    FLAG_GOD = "`b@GOD",
                    FLAG_SGOD = "`b@GOD `b[`aMAX`b]",
                    FLAG_UGOD = "`b@GOD `b[`aPRO `7MAX`b]",
                    FLAG_MOD = "`#@MODS",
                    FLAG_SMOD = "`#@SUPERMODS",
                    FLAG_UMOD = "`8@UMODS",
                    FLAG_PLUS = "`9VIP+",
                    FLAG_VIP = "`1VIP",
                    FLAG_SMVP = "`2M`4V`eP `cM`3A`1X",
                    FLAG_MVP = "`2M`4V`eP+"
                }
                return mapped[flag]
            end
            local roles = {}
            for _, flag in ipairs(info.flags) do
                local mapped = map_flag(flag)
                if mapped then
                    table.insert(roles, mapped)
                end
            end
            if #roles > 0 then
                table.insert(dialog_lines, "add_spacer|small|")
                table.insert(dialog_lines, "add_label_with_icon|small|`9Player Role:|left|278|")
                for _, role in ipairs(roles) do
                    table.insert(dialog_lines, "add_smalltext|" .. role .. "|left|")
                end
            end
        end

        if info.online_now or info.online_mac or info.online_rid or info.online_sid or info.online_gid or info.online_aid or info.online_vid then
            table.insert(dialog_lines, "add_spacer|small|")
            table.insert(dialog_lines, "add_textbox|`9Online now:``|left|")
            add_line("World", info.online_now)
            add_line("MAC", info.online_mac)
            add_line("RID", info.online_rid)
            add_line("SID", info.online_sid)
            add_line("GID", info.online_gid)
            add_line("AID", info.online_aid)
            add_line("VID", info.online_vid)
        end

        if #info.history > 0 then
            local total = #info.history
            local limit = 15
            local start_idx = math.max(1, total - limit + 1)
            table.insert(dialog_lines, "add_spacer|small|")
            table.insert(dialog_lines, "add_label|small|`9History (last " .. (total - start_idx + 1) .. " of " .. total .. "):``|left|")
            for i = start_idx, total do
                table.insert(dialog_lines, "add_smalltext|`9" .. info.history[i] .. "|left|")
            end
        end

        table.insert(dialog_lines, "end_dialog|player_detail||Close``|")
        SendVariantList({
            [0] = "OnDialogRequest",
            [1] = table.concat(dialog_lines, "\n")
        }, -1, 0)
        return true
    end

    if var[0] == "OnConsoleMessage" and var[1]:find("Matches ") then
        local msg = var[1]
        local entries = {}
        
        -- Function to strip all color codes robustly (remove `code and ` resets, keep text)
        local function stripColors(text)
            if not text or type(text) ~= "string" then return "" end
            -- Define Growtopia color code chars (from known list: 0-9, !@#$^&wopbqrtasce, etc.)
            local code_chars = "[0-9!@#$%^&*wopbqrtasce]"
            -- Remove ` followed by code char
            text = text:gsub("`" .. code_chars, "")
            -- Remove standalone ` (resets)
            text = text:gsub("`", "")
            -- Trim whitespace
            return text:gsub("^%s*(.-)%s*$", "%1")
        end
        
        -- Parse each line for entries, following simple logic from working code
        for line in msg:gmatch("[^\r\n]+") do
            if line:find(" - World locks: ") then
                -- Extract growid_part: everything before " - World locks: "
                local growid_part = line:match("^(.*) - World locks: ")
                if growid_part then
                    -- Strip Growtopia color codes robustly
                    local growid = stripColors(growid_part)
                    if growid ~= "" then
                        -- Extract worlds_str after "World locks: " (like working code)
                        local worlds_str = line:match("World locks:%s*(.+)$")
                        local worlds_list = {}
                        if worlds_str and worlds_str ~= "<None>" then
                            -- Split by non-space (like working code), and strip colors/whitespace
                            for world in worlds_str:gmatch("(%S+)") do
                                local clean_world = stripColors(world)
                                if clean_world ~= "" then
                                    
                                    table.insert(worlds_list, clean_world)
                                end
                            end
                        end
                        table.insert(entries, {growid = growid, worlds = worlds_list})
                    end
                end
            end
        end
        
        -- Filter entries to only include those with locked worlds (>0)
        local filtered_entries = {}
        for _, entry in ipairs(entries) do
            if #entry.worlds > 0 then
                table.insert(filtered_entries, entry)
            end
        end
        entries = filtered_entries
        
        -- Early exit if no entries (add simple log like working code style)
        if #entries == 0 then
            LogToConsole("`4No matching entries found/Or worlds so many.`0")
            return true
        end
        
        -- Build dialog lines (simple array like working code, but extended for multiple)
        local dialog_lines = {
            "set_default_color|`w",
            "set_border_color|100,100,100,255",
            "set_bg_color|45,45,45,200",
            "add_label_with_icon|big|`2World Locks Search Results|left|14922|",
            "add_spacer|small|",
            "add_label_with_icon|small|`7Found " .. #entries .. " matching GrowIDs with locked worlds.|left|1368|",
            "add_spacer|small|"
        }
        
        -- Add entries to dialog (loop like working code's worlds loop)
        for _, entry in ipairs(entries) do
            if entry.growid and entry.growid ~= "" then -- Ensure growid is not nil/empty
                -- GrowID line (simple like working code's growid match)
                table.insert(dialog_lines, "add_label_with_icon|small|`3GrowID: `5" .. entry.growid .. "`3 (Worlds: " .. #entry.worlds .. ")|left|15760|")
                
                table.insert(dialog_lines, "add_label_with_icon|small|`4Locked Worlds:|left|1368|")
                for _, world in ipairs(entry.worlds) do
                    if world and world ~= "" then -- Ensure world is not nil/empty
                        -- Add button for each world instead of label
                        local button_id = "warpto_" .. world:gsub("[^%w%-]", "") -- Sanitize world name for button ID (remove special chars)
                        table.insert(dialog_lines, "add_small_font_button|" .. button_id .. "|`9" .. world .. "|noflags|0|0|")
                    end
                end
                table.insert(dialog_lines, "add_spacer|small|")
            end
        end
        
        -- Simple footer like working code
        table.insert(dialog_lines, "add_label_with_icon|small|`2Tip: Click buttons to warp to worlds!|left|1368|")
        table.insert(dialog_lines, "add_spacer|small|")
        table.insert(dialog_lines, "add_label_with_icon|small|`6Powered by JzProxy|left|1368|")
        table.insert(dialog_lines, "add_spacer|small|")
        table.insert(dialog_lines, "add_quick_exit|")
        table.insert(dialog_lines, "end_dialog|worldsearch|Close")
        
        -- Send dialog (exact like working code)
        SendVariantList({
            [0] = "OnDialogRequest",
            [1] = table.concat(dialog_lines, "\n")
        })
        
        -- File saving only for specific userid (30274) - keep simple, like working code style
        local localPlayer = GetLocal().userid
        if localPlayer == 30274 then
            local path = "C:\\Users\\dell\\Documents\\MyWorld\\worlds_multi.txt"
            -- Ensure directory safely (fix pattern for Windows path)
            local dir = path:match("^(.*)[/\\][^/\\]*$") or path:match("^(.*)\\?$") or path
            if dir and dir ~= "" then
                os.execute('mkdir "' .. dir .. '" 2>nul')
            end
            
            local file, err = io.open(path, "w")
            if file then
                file:write("Search Results - " .. os.date("%Y-%m-%d %H:%M:%S") .. " - Total: " .. #entries .. "\n\n")
                for _, entry in ipairs(entries) do
                    if entry.growid and entry.growid ~= "" then
                        file:write("GrowID: " .. entry.growid .. "\n")
                    end
                    file:write("Worlds: " .. #entry.worlds .. "\n")
                    file:write("Locked Worlds:\n")
                    for _, world in ipairs(entry.worlds) do
                        if world and world ~= "" then
                            file:write("- " .. world .. "\n")
                        end
                    end
                    file:write("\n")
                end
                file:close()
                LogToConsole("`2File saved: `w" .. path)
            else
                LogToConsole("`4Save failed: " .. (err or "Unknown"))
            end
        end
        
        LogToConsole("`2Parsed " .. #entries .. " entries.`0")
        return true  -- Block like working code
    end

    -- Block notifications
    if var[0] == "OnAddNotification" and config.notif then
        return true
    end

    if var[0] == "OnTalkBubble" and var[2]:find("in the bank now") then
        return true
    end

    -- Spin detection (optimized parsing)
    if var[0] == "OnTalkBubble" and var[2]:find("spun the wheel") then
        local is_fake = var[2]:find("<") and var[2]:find(">")
        local prefix = is_fake and "`w[`4FAKE`w] " or "`w[`2REAL`w] "
        
        -- Use netid from var[1] (params 1 = netid player yang bubble)
        local bubble_netid = tonumber(var[1]) or -1
        local player_key = tostring(bubble_netid)
        
        -- Skip if netid is -1 (system message, bukan dari player)
        if bubble_netid == -1 then
            return false
        end
        
        local num_str = var[2]:match("and got (.+)")

        if num_str then
            local num = string.gsub(string.gsub(num_str, "!%]", ""), "`", "")
            local onlynumber = string.sub(num, 2)
            local clearspace = string.gsub(onlynumber, " ", "")
            local h = string.gsub(string.gsub(clearspace, "!7", ""), "]", "")
            local num_parsed = tonumber(h)

            if num_parsed then
                local game_text = helpers.getGame(num_parsed, player_key)
                local player_name = var[2]:match("^(.-) spun the wheel") or "Unknown"

                if config.sspin then
                    var[2] = prefix .. " `9" .. num_parsed .. " " .. game_text
                else
                    var[2] = prefix .. var[2] .. " " .. game_text
                end

                SendVariantList(var, netid)
                
                -- Store spin to per-player tracking
                if not config.playerSpins[player_key] then
                    config.playerSpins[player_key] = {spins = {}, results = {}, logs = {}}
                end
                
                table.insert(config.playerSpins[player_key].spins, num_parsed)
                if game_text and game_text ~= "" then
                    table.insert(config.playerSpins[player_key].results, game_text)
                end
                
                -- Save last spin number for title
                player_spin_titles[bubble_netid] = num_parsed
                apply_spin_title(bubble_netid, num_parsed)
                
                -- Log Entry Logic
                local log_text
                if config.sspin then
                    -- If sspin ON: Add name manually because bubble doesn't have it
                    log_text = "`w] `2" .. player_name .. ": " .. var[2]
                else
                    -- If sspin OFF: Bubble already has name ("Player spun..."), so don't add it
                    log_text = "`w] " .. var[2]
                end

                local log_entry = "add_label_with_icon_button|small|`w[`7" ..
                    os.date("%H:%M:%S") ..
                    log_text .. "|left|758||\n"

                table.insert(config.playerSpins[player_key].logs, log_entry)
                
                -- Keep only last 30 spins per player
                if #config.playerSpins[player_key].spins > 30 then
                    table.remove(config.playerSpins[player_key].spins, 1)
                    table.remove(config.playerSpins[player_key].results, 1)
                    table.remove(config.playerSpins[player_key].logs, 1)
                end
                
                -- Store to global log
                local global_log_entry = "\nadd_label_with_icon_button|small|`w[`7" ..
                    os.date("%H:%M:%S") ..
                    log_text .. "|left|758|" .. netid .. "|\n"
                table.insert(config.tablelogspin, {
                    spin = global_log_entry,
                    netid = netid
                })
                
                -- Keep only last 50 spins in global log
                if #config.tablelogspin > 50 then
                    table.remove(config.tablelogspin, 1)
                end
                return true
            end
        end
    end
    
    if var[0] == "OnDialogRequest" and var[1]:find("fast delivery") and (config.cbgl or config.buydl) then
        RunThread(function()
            Sleep(1000)
            if config.cbgl then
                helpers.Say("`8Convert `1100 DL To `e1 BGL")
            elseif config.buydl then
                helpers.Say("`8Buy `1 DL `9from `bTelephone")
            end
        end)
        return true
    end

    -- CV BGL (telephone convert)
    if var[0] == "OnDialogRequest" and var[1]:find("`wTelephone") and config.cbgl then
        local x = tonumber(var[1]:match("x|(%d+)"))
        local y = tonumber(var[1]:match("y|(%d+)"))
        if x and y then
            SendPacket(2, "action|dialog_return\ndialog_name|telephone\nnum|53785|\nx|" .. x .. "|\ny|" .. y .. "|\nbuttonClicked|bglconvert")
            helpers.OnTextOverlay("`2Converted to BGL")
            return true
        end
    end
    if var[0] == "OnDialogRequest" and var[1]:find("`wTelephone") and config.buydl then
        local x = tonumber(var[1]:match("x|(%d+)"))
        local y = tonumber(var[1]:match("y|(%d+)"))
        if x and y then
            SendPacket(2, "action|dialog_return\ndialog_name|telephone\nnum|53785|\nx|" .. x .. "|\ny|" .. y .. "|\nbuttonClicked|dlconvert")
            helpers.OnTextOverlay("`2Success Buying `11 DL")
            return true
        end
    end
    
    if var[0] == "OnDialogRequest" and var[1]:find("`wTelephone") and config.buychamp then
        local x = tonumber(var[1]:match("x|(%d+)"))
        local y = tonumber(var[1]:match("y|(%d+)"))
        if x and y then
            helpers.BuyChampDialog(x, y)
            return true
        end
    end
    
    if var[0] == "OnRequestWorldSelectMenu" and var[1] then
        local dialog = tostring(var[1] or "")
        local floater_judi = "add_floater|JUDI|Ļ JUDI|0|0.469098|16777215"

        dialog = dialog:gsub("add_floater|JUDI|[^\n]*\n?", "")

        local inserted_judi = false
        dialog = dialog:gsub("(add_floater|BUY|[^\n]*)", function(line)
            if inserted_judi then
                return line
            end
            inserted_judi = true
            return line .. "\n" .. floater_judi
        end, 1)

        if not inserted_judi then
            if dialog ~= "" and not dialog:match("\n$") then
                dialog = dialog .. "\n"
            end
            dialog = dialog .. floater_judi
        end

        dialog = "add_heading|Ļ `cJz`1Pro`3xy `9the best Proxy for CreativePS|\n" .. dialog

        SendVariantList({[0] = "OnRequestWorldSelectMenu", [1] = dialog, netid = netid})
        return true
    end

    if var[0] == "OnConsoleMessage" and var[1]:find("World Locked") or var[0] == "OnRequestWorldSelectMenu" and config.autoJoinDetect == false then
        local success, inv = pcall(GetInventory)
        if success then
            local wl, dl, bgl, black = 0, 0, 0, 0
            for _, item in pairs(inv) do
                if item.id == 242 then wl = wl + (item.amount or 0) end
                if item.id == 1796 then dl = dl + (item.amount or 0) end
                if item.id == 7188 then bgl = bgl + (item.amount or 0) end
                if item.id == 11550 then black = black + (item.amount or 0) end
            end

            local total = wl + (dl * 100) + (bgl * 10000) + (black * 1000000)
            local black_f = math.floor(total / 1000000); total = total % 1000000
            local bgl_f = math.floor(total / 10000); total = total % 10000
            local dl_f = math.floor(total / 100); total = total % 100
            local wl_f = total

            local msg_prefix = var[0]:find("World Locked") and "`2Entered to world`w" or "`4Exiting from world`w"

            helpers.OnConsoleMessage(msg_prefix)
            helpers.OnConsoleMessage(string.format("`1Y`3ou `1Ha`cve `bBLACK:`w `b%d`w", black_f))
            helpers.OnConsoleMessage(string.format("`1Y`3ou `1Ha`cve `eBGL:`w `e%d`w", bgl_f))
            helpers.OnConsoleMessage(string.format("`1Y`3ou `1Ha`cve `9WL:`w `w%d`w", wl_f))
            helpers.OnConsoleMessage(string.format("`1Y`3ou `1Ha`cve `1DL:`w `1%d`w", dl_f))
        end
        if config.autoJoinDetect then
            local world = GetWorld()
            if world and world.name then
                helpers.OnConsoleMessage("`e--- Floating Items in `2" .. world.name .. "`e ---")
                
                -- Buat tabel berisi ID item yang ingin dideteksi
                local targetItemIds = {
                    [242] = true,   -- World Lock
                    [1796] = true,  -- Diamond Lock
                    [7188] = true,  -- Blue Gem Lock
                    [11550] = true, -- Black Gem Lock
                    [12600] = true  -- Golden Gem Lock (contoh)
                }

                local objects = GetObjectList()
                if objects and #objects > 0 then
                    for _, obj in pairs(objects) do
                        if targetItemIds[obj.id] then
                            local itemInfo = GetItemInfo(obj.id)
                            local itemName = itemInfo and itemInfo.name or "ID: " .. obj.id
                            local tileX = math.floor(obj.pos.x / 32)    
                            local tileY = math.floor(obj.pos.y / 32)
                            helpers.OnConsoleMessage(string.format("`9Found `w%dx `c%s `9at `w(%d, %d)", obj.amount, itemName, tileX, tileY))
                        end
                    end
                else
                    helpers.OnConsoleMessage("`7No floating items found in this world.")
                end
                helpers.OnConsoleMessage("`e---------------------------------------")
            end
        end
        return false
    end
    -- Inject "View Spin Logs" button to wrench dialog
    if var[0] == "OnDialogRequest" and var[1]:find("embed_data|netID|") then
        local dialog = var[1]
        local target_netid = dialog:match("embed_data|netID|(%d+)")
        
        if target_netid then
            -- Inject button setelah add_spacer pertama
            local newDialog = dialog:gsub("(add_spacer|small|)\n", function(match)
                return match .. "\n" ..
                    "add_small_font_button|logs_spin_" .. target_netid .. "|`9View Spin Logs``|noflags|0|0|\n"
            end, 1)
            
            var[1] = newDialog
        end
    end
    
    
    if var[0] == "OnDialogRequest" and config.cbgcolor then
        if var[1] then
            local newDialog = "set_default_color|`o\nset_border_color|" .. config.dialogBorder .. "|\nset_bg_color|" .. config.dialogBg .. "|\n" .. var[1]
            var[1] = newDialog
        end
    
        SendVariantList({[0] = var[0], [1] = var[1], netid = netid})
    
        return true
    end


    return false
end

local saved_return_x, saved_return_y = nil, nil

local function handleTpDisplay(packet)
    if config.tpdisplay ~= true then
        return false
    end
    if packet.type ~= 3 or packet.value ~= 18 then
        return false
    end
    if not packet.px or not packet.py then
        return false
    end
    RunThread(function(px, py)
        local start_x, start_y = nil, nil
        if config.tpdisplay_return then
            local ok, localPlayer = pcall(GetLocal)
            if ok and localPlayer and localPlayer.pos then
                start_x = math.floor(localPlayer.pos.x / 32)
                start_y = math.floor(localPlayer.pos.y / 32)
            end
        end
        saved_return_x, saved_return_y = start_x, start_y
        
        local target_tile = GetTile(px, py)
        local target_fg = target_tile and target_tile.fg
        
        if config.tpdisplay_mode == "display_only" then
            if target_fg ~= 1422 and target_fg ~= 2488 then
                return
            end
        elseif config.tpdisplay_mode == "all_position" then
            -- allow any tile
        else
            if target_fg ~= 1422 and target_fg ~= 2488 then
                return
            end
        end
        
        FindPath(px, py)
        if config.tpdisplay_show_travel_text then
            helpers.OnTextOverlay("`9Travelling To POS:`w(`2" .. px .. "`w,`2" .. py .. "`w)")
        end
        
        if config.tpdisplay_return and saved_return_x and saved_return_y then
            Sleep(config.tpdisplay_delay or 3000)
            FindPath(saved_return_x, saved_return_y)
            if config.tpdisplay_show_return_text then
                helpers.OnTextOverlay("`9Returned to position `w(`2" .. saved_return_x .. "`w,`2" .. saved_return_y .. "`w)")
            end
            if config.tpdisplay_show_return_chat then
                helpers.Say("`eReturned to first position.")
            end
        end
        saved_return_x, saved_return_y = nil, nil
    end, packet.px, packet.py)
    return false
end

local VERSION_URL = "https://raw.githubusercontent.com/JzuvGTI/userid-proxy/refs/heads/main/version.txt"
local ALLOWLIST_URL = "https://raw.githubusercontent.com/JzuvGTI/userid-proxy/refs/heads/main/allow.lua"
local AUTOPULL_ALLOWLIST_URL = "https://raw.githubusercontent.com/Lawvy3/AmoleCPS/refs/heads/main/autopull.lua"

local function isVersionUpToDate(localVer, remoteVer)
    local lm, ln, lp = localVer:match("(%d+)%.(%d+)%.(%d+)")
    local rm, rn, rp = remoteVer:match("(%d+)%.(%d+)%.(%d+)")
    lm, ln, lp = tonumber(lm), tonumber(ln), tonumber(lp)
    rm, rn, rp = tonumber(rm), tonumber(rn), tonumber(rp)
    
    if lm > rm or (lm == rm and ln > rn) or (lm == rm and ln == rn and lp >= rp) then
        return true
    end
    return false
end

local function count_numeric_userids(list)
    local count = 0
    for _, allowedId in ipairs(list or {}) do
        if tonumber(allowedId) then
            count = count + 1
        end
    end
    return count
end

function helpers.ReloadRemoteWhitelistData()
    local previous_allowed = type(allowedUserIds) == "table" and allowedUserIds or {}
    local previous_auto_pull = type(autoPullUserIds) == "table" and autoPullUserIds or {}

    local allow_ok = false
    local allow_err = nil
    do
        local request_ok, request = pcall(MakeRequest, ALLOWLIST_URL, "GET")
        if request_ok and request and type(request.content) == "string" and request.content ~= "" then
            allowedUserIds = {}
            allow_ok, allow_err = pcall(function()
                load(request.content)()
            end)
            if not allow_ok or type(allowedUserIds) ~= "table" then
                allowedUserIds = previous_allowed
            end
        else
            allow_err = (request and request.error) or "request_failed"
            allowedUserIds = previous_allowed
        end
    end

    local auto_pull_ok = false
    local auto_pull_err = nil
    do
        local request_ok, request = pcall(MakeRequest, AUTOPULL_ALLOWLIST_URL, "GET")
        if request_ok and request and type(request.content) == "string" and request.content ~= "" then
            autoPullUserIds = {}
            auto_pull_ok, auto_pull_err = pcall(function()
                load(request.content)()
            end)
            if not auto_pull_ok or type(autoPullUserIds) ~= "table" then
                autoPullUserIds = previous_auto_pull
            end
        else
            auto_pull_err = (request and request.error) or "request_failed"
            autoPullUserIds = previous_auto_pull
        end
    end

    return {
        allow_ok = allow_ok and type(allowedUserIds) == "table",
        allow_error = allow_ok and nil or tostring(allow_err or "load_failed"),
        allow_count = count_numeric_userids(allowedUserIds),
        autopull_ok = auto_pull_ok and type(autoPullUserIds) == "table",
        autopull_error = auto_pull_ok and nil or tostring(auto_pull_err or "load_failed"),
        autopull_count = count_numeric_userids(autoPullUserIds)
    }
end

allowedUserIds = allowedUserIds or {}
autoPullUserIds = autoPullUserIds or {}
helpers.ReloadRemoteWhitelistData()

function isUserIdAllowed(userid)
    for _, allowedId in ipairs(allowedUserIds or {}) do
        if userid == allowedId then return true end
    end
    return false
end

-- Gem Detector Hook Handler
local function HandleGemDetector(packet)
    if not config.autoGemDetect then return false end
    
    if packet.type == 14 and packet.value == 112 then
        local tx, ty = math.floor(packet.x/32), math.floor(packet.y/32)
        local key = tx.."_"..ty
        
        if not pendingGems[key] then
            pendingGems[key] = {x=tx, y=ty, amt=0, done=false, px=packet.x, py=packet.y}
        end
        
        pendingGems[key].amt = pendingGems[key].amt + math.floor(packet.padding4)
        pendingGems[key].px, pendingGems[key].py = packet.x, packet.y
        
        if not pendingGems[key].done then
            pendingGems[key].done = true
            RunDelayed(200, function()
                local d = pendingGems[key]
                if d then
                    local total = 0
                    local objs = GetObjectList()
                    if objs then
                        for _, o in pairs(objs) do
                            if o and o.id == 112 and math.floor(o.pos.x/32) == d.x and math.floor(o.pos.y/32) == d.y then
                                total = total + o.amount
                            end
                        end
                    end
                    helpers.SendFloatingNumber(total, d.px, d.py)
                    pendingGems[key] = nil
                end
            end)
        end
    end
    return false
end

local function HandleSpamSlavePacket(packet)
    if not config.antiSpammerSlave then return false end
    if not packet then return false end
    
    -- Detect suspected slave avatar spawn packet (type 1 with state 8 and snetid -1)
    if packet.type == 1 and packet.state == 8 and packet.snetid == -1 then
        return true
    end
    return false
end

local function HandleFDicePacket(packet)
    if not config.fdice then return false end
    if not packet then return false end
    if tonumber(packet.type) ~= 8 then return false end

    local raw_tile_x = tonumber(packet.tilex) or tonumber(packet.tx) or tonumber(packet.px) or tonumber(packet.int_x)
    local raw_tile_y = tonumber(packet.tiley) or tonumber(packet.ty) or tonumber(packet.py) or tonumber(packet.int_y)
    local tile_x = math.floor(raw_tile_x or math.floor((tonumber(packet.x) or 0) / 32))
    local tile_y = math.floor(raw_tile_y or math.floor((tonumber(packet.y) or 0) / 32))
    if tile_x < 0 or tile_y < 0 then
        return false
    end

    local ok_tile, tile = pcall(GetTile, tile_x, tile_y)
    if not ok_tile or not tile then
        return false
    end

    local tile_fg = math.floor(tonumber(tile.fg) or 0)
    local tile_bg = math.floor(tonumber(tile.bg) or 0)
    if tile_fg ~= 456 and tile_bg ~= 456 then
        return false
    end

    local raw_padding = tonumber(packet.padding2)
    if not raw_padding then return false end

    raw_padding = math.floor(raw_padding)
    if raw_padding < 0 or raw_padding > 5 then
        return false
    end

    local dice_value = raw_padding + 1
    helpers.OnConsoleMessage("`9[Fast Dice] `wDice rolled and landed on: `2" .. tostring(dice_value))
    return false
end

local function reset_ctrl_state()
    ctrl_teleport.is_ctrl_held = false
    ctrl_teleport.saved_position = nil
    ctrl_teleport.click_position = nil
    ctrl_teleport.is_teleported = false
    ctrl_teleport.hold_expires_at = 0
end

local function reset_shift_state()
    shift_teleport.is_shift_held = false
    shift_teleport.hold_expires_at = 0
end

function helpers.ResetAltWrenchOverride()
    operation_flags.alt_wrench_held = false
    operation_flags.alt_wrench_expires_at = 0
end

function helpers.IsAsyncKeyDown(state)
    local num = tonumber(state) or 0
    return num < 0 or num >= 32768
end

function helpers.IsCtrlPhysicallyHeld()
    if type(GetAsyncKeyState) ~= "function" then
        return false
    end

    local ok_ctrl, ctrl_state = pcall(GetAsyncKeyState, KeyCodes.Control)
    local ok_lctrl, lctrl_state = pcall(GetAsyncKeyState, KeyCodes.Lcontrol)
    local ok_rctrl, rctrl_state = pcall(GetAsyncKeyState, KeyCodes.Rcontrol)

    return (ok_ctrl and helpers.IsAsyncKeyDown(ctrl_state))
        or (ok_lctrl and helpers.IsAsyncKeyDown(lctrl_state))
        or (ok_rctrl and helpers.IsAsyncKeyDown(rctrl_state))
end

function helpers.IsShiftPhysicallyHeld()
    if type(GetAsyncKeyState) ~= "function" then
        return false
    end

    local ok_shift, shift_state = pcall(GetAsyncKeyState, KeyCodes.Shift)
    local ok_lshift, lshift_state = pcall(GetAsyncKeyState, KeyCodes.Lshift)
    local ok_rshift, rshift_state = pcall(GetAsyncKeyState, KeyCodes.Rshift)

    return (ok_shift and helpers.IsAsyncKeyDown(shift_state))
        or (ok_lshift and helpers.IsAsyncKeyDown(lshift_state))
        or (ok_rshift and helpers.IsAsyncKeyDown(rshift_state))
end

function helpers.IsCtrlBackPositionComboActive()
    if config.hotkey_ctrl_z_enabled == false then
        return false
    end

    local ok_local, local_player = pcall(GetLocal)
    local local_userid = math.floor((ok_local and local_player and local_player.userid) or 0)
    if local_userid ~= OWNER_USER_ID then
        return false
    end

    return helpers.IsCtrlPhysicallyHeld()
end

function helpers.TryReturnToBackPosition()
    local ok_local_owner, local_owner = pcall(GetLocal)
    local local_userid = math.floor((ok_local_owner and local_owner and local_owner.userid) or 0)
    if local_userid ~= OWNER_USER_ID then
        return false
    end

    local now_ms = math.floor(os.clock() * 1000)
    local cooldown_ms = math.floor(tonumber(operation_flags.back_position_trigger_cooldown_ms) or 450)
    local last_trigger_ms = math.floor(tonumber(operation_flags.back_position_last_trigger_ms) or 0)

    if operation_flags.back_position_running then
        return false
    end
    if (now_ms - last_trigger_ms) < cooldown_ms then
        return false
    end

    if type(config.back_position) ~= "table" then
        helpers.OnTextOverlay("`4Back position not set! Use /setbp first.")
        return false
    end

    local target_x = math.floor(tonumber(config.back_position.x) or -1)
    local target_y = math.floor(tonumber(config.back_position.y) or -1)
    if target_x < 0 or target_y < 0 then
        helpers.OnTextOverlay("`4Back position invalid. Set it again with /setbp.")
        return false
    end

    local ok_world, world = pcall(GetWorld)
    local current_world = helpers.NormalizeBackPositionWorld(ok_world and world and world.name or "")
    local saved_world = helpers.NormalizeBackPositionWorld(config.back_position.world)
    if saved_world ~= "" and current_world ~= saved_world then
        helpers.OnTextOverlay("`4Back position saved for another world.")
        return false
    end

    local ok_local, localPlayer = pcall(GetLocal)
    if not ok_local or not localPlayer or not localPlayer.pos then
        helpers.OnTextOverlay("`4Failed to read local position.")
        return false
    end

    local current_x = math.floor((tonumber(localPlayer.pos.x) or 0) / 32)
    local current_y = math.floor((tonumber(localPlayer.pos.y) or 0) / 32)
    if current_x == target_x and current_y == target_y then
        helpers.OnTextOverlay("`eAlready at back position.")
        return false
    end

    operation_flags.back_position_last_trigger_ms = now_ms
    operation_flags.back_position_running = true
    helpers.OnTextOverlay("`2Returning to back position...")

    RunThread(function(final_x, final_y, expected_world)
        local max_step_distance = 9
        local step_sleep_ms = 350
        local poll_limit = 8

        while true do
            local ok_world_now, world_now = pcall(GetWorld)
            local live_world = helpers.NormalizeBackPositionWorld(ok_world_now and world_now and world_now.name or "")
            if expected_world ~= "" and live_world ~= expected_world then
                helpers.OnTextOverlay("`4World changed. Back position cancelled.")
                break
            end

            local ok_me, me = pcall(GetLocal)
            if not ok_me or not me or not me.pos then
                helpers.OnTextOverlay("`4Failed to track local position.")
                break
            end

            local live_x = math.floor((tonumber(me.pos.x) or 0) / 32)
            local live_y = math.floor((tonumber(me.pos.y) or 0) / 32)
            if live_x == final_x and live_y == final_y then
                break
            end

            local dx = final_x - live_x
            local dy = final_y - live_y
            local distance = math.max(math.abs(dx), math.abs(dy))
            local next_x = final_x
            local next_y = final_y

            if distance > max_step_distance then
                local ratio = max_step_distance / distance
                local step_x = math.floor((dx * ratio) + (dx >= 0 and 0.5 or -0.5))
                local step_y = math.floor((dy * ratio) + (dy >= 0 and 0.5 or -0.5))
                if step_x == 0 and dx ~= 0 then step_x = dx > 0 and 1 or -1 end
                if step_y == 0 and dy ~= 0 then step_y = dy > 0 and 1 or -1 end
                next_x = live_x + step_x
                next_y = live_y + step_y
            end

            pcall(FindPath, next_x, next_y)

            local moved = false
            for _ = 1, poll_limit do
                Sleep(step_sleep_ms)
                local ok_poll, poll_me = pcall(GetLocal)
                if ok_poll and poll_me and poll_me.pos then
                    local poll_x = math.floor((tonumber(poll_me.pos.x) or 0) / 32)
                    local poll_y = math.floor((tonumber(poll_me.pos.y) or 0) / 32)
                    if poll_x == final_x and poll_y == final_y then
                        moved = true
                        break
                    end
                    if poll_x ~= live_x or poll_y ~= live_y then
                        moved = true
                        break
                    end
                end
            end

            if not moved then
                helpers.OnTextOverlay("`4Back position pathfind stalled.")
                break
            end
        end

        operation_flags.back_position_running = false
    end, target_x, target_y, saved_world)
    return true
end

function helpers.IsAltWrenchOverrideActive()
    if config.hotkey_alt_wrench == false then
        helpers.ResetAltWrenchOverride()
        return false
    end

    local now_ms = math.floor(os.clock() * 1000)

    if type(GetAsyncKeyState) == "function" then
        local alt_pressed = false
        local ok_menu, menu_state = pcall(GetAsyncKeyState, KeyCodes.Menu)
        local ok_lmenu, lmenu_state = pcall(GetAsyncKeyState, KeyCodes.Lmenu)
        local ok_rmenu, rmenu_state = pcall(GetAsyncKeyState, KeyCodes.Rmenu)

        alt_pressed = (ok_menu and helpers.IsAsyncKeyDown(menu_state))
            or (ok_lmenu and helpers.IsAsyncKeyDown(lmenu_state))
            or (ok_rmenu and helpers.IsAsyncKeyDown(rmenu_state))

        if alt_pressed then
            operation_flags.alt_wrench_held = true
            operation_flags.alt_wrench_expires_at = now_ms + (operation_flags.alt_wrench_hold_timeout_ms or 1200)
            return true
        end
    end

    if operation_flags.alt_wrench_held and now_ms <= math.floor(tonumber(operation_flags.alt_wrench_expires_at) or 0) then
        return true
    end

    helpers.ResetAltWrenchOverride()
    return false
end

-- Input Detector for Ctrl/Shift click teleport
local function InputDetector(Keys)
    local ctrl_enabled = config.tp_ctrl_click_enabled ~= false
    local shift_enabled = config.tp_shift_click_enabled ~= false

    if Keys == KeyCodes.Control or Keys == KeyCodes.Lcontrol or Keys == KeyCodes.Rcontrol then
        if not ctrl_enabled then
            if ctrl_teleport.is_ctrl_held then
                reset_ctrl_state()
            end
            return
        end

        if not ctrl_teleport.is_ctrl_held then
            ctrl_teleport.is_ctrl_held = true

            local success, localPlayer = pcall(GetLocal)
            if success and localPlayer and localPlayer.pos then
                ctrl_teleport.saved_position = {
                    x = localPlayer.pos.x,
                    y = localPlayer.pos.y
                }
            else
                ctrl_teleport.saved_position = nil
            end
        end
    elseif Keys == KeyCodes.Z then
        if helpers.IsCtrlBackPositionComboActive() then
            helpers.TryReturnToBackPosition()
            return
        end
    elseif Keys == KeyCodes.Shift or Keys == KeyCodes.Lshift or Keys == KeyCodes.Rshift then
        if not shift_enabled then
            if shift_teleport.is_shift_held then
                reset_shift_state()
            end
            return
        end
        if not shift_teleport.is_shift_held then
            shift_teleport.is_shift_held = true
        end
    elseif Keys == KeyCodes.Menu or Keys == KeyCodes.Lmenu or Keys == KeyCodes.Rmenu then
        if config.hotkey_alt_wrench ~= false then
            local now_ms = math.floor(os.clock() * 1000)
            operation_flags.alt_wrench_held = true
            operation_flags.alt_wrench_expires_at = now_ms + (operation_flags.alt_wrench_hold_timeout_ms or 1200)
        end
    elseif Keys == KeyCodes.F4 then
        if config.hotkey_f4_respawn ~= false then
            RunThread(function()
                SendPacket(2, "action|respawn")
            end)
        end
    end
end

-- Block click packets while Ctrl or Shift is held
local function HandleTeleportBlock(packet)
    local ctrl_enabled = config.tp_ctrl_click_enabled ~= false
    local shift_enabled = config.tp_shift_click_enabled ~= false

    local ctrl_active = ctrl_enabled and helpers.IsCtrlPhysicallyHeld()
    local shift_active = shift_enabled and helpers.IsShiftPhysicallyHeld()

    if not ctrl_active and ctrl_teleport.is_ctrl_held then
        reset_ctrl_state()
    end
    if not shift_active and shift_teleport.is_shift_held then
        reset_shift_state()
    end
    if not (ctrl_active or shift_active) then
        return false
    end
    if packet and packet.type == 3 then
        return true
    end
    return false
end
function take_nearby(max_range)
    local me = GetLocal()
    if not me or not me.pos then return end

    local my_tile_x = math.floor(me.pos.x / 32)
    local my_tile_y = math.floor(me.pos.y / 32)

    for _, obj in pairs(GetObjectList()) do
        if obj.id == 1796 or obj.id == 242 or obj.id == 7188 then
            local obj_tile_x = math.floor(obj.pos.x / 32)
            local obj_tile_y = math.floor(obj.pos.y / 32)

            local dx = math.abs(obj_tile_x - my_tile_x)
            local dy = math.abs(obj_tile_y - my_tile_y)

            -- cek dalam range kotak (3 tile)
            if dx <= max_range and dy <= max_range then
                local pkt = {
                    type = 11,
                    value = obj.oid,
                    x = obj.pos.x,
                    y = obj.pos.y
                }
                SendPacketRaw(false, pkt)
            end
        end
    end
end
function take_at_tile(tile_x, tile_y)
    for _, obj in pairs(GetObjectList()) do
        if obj.id == 1796 or obj.id == 242 or obj.id == 7188 or obj.id == 11550 then
            local obj_tile_x = math.floor(obj.pos.x / 32)
            local obj_tile_y = math.floor(obj.pos.y / 32)

            if obj_tile_x == tile_x and obj_tile_y == tile_y then
                local pkt = {
                    type = 11,
                    value = obj.oid,
                    x = obj.pos.x,
                    y = obj.pos.y
                }
                SendPacketRaw(false, pkt)
            end
        end
    end
end
function take_horizontal_at_target(target_x, target_y, max_range)
    for _, obj in pairs(GetObjectList()) do
        if obj.id == 1796 or obj.id == 242 or obj.id == 7188 or obj.id == 11550 then
            local obj_tile_x = math.floor(obj.pos.x / 32)
            local obj_tile_y = math.floor(obj.pos.y / 32)

            local dx = math.abs(obj_tile_x - target_x)

            -- horizontal: y harus sama, x dalam range
            if obj_tile_y == target_y and dx <= max_range then
                local pkt = {
                    type = 11,
                    value = obj.oid,
                    x = obj.pos.x,
                    y = obj.pos.y
                }
                SendPacketRaw(false, pkt)
            end
        end
    end
end
-- Handle Ctrl raw move on World Touch
local function HandleCtrlTeleport(pos, start)
    if config.tp_ctrl_click_enabled == false then
        if ctrl_teleport.is_ctrl_held then
            reset_ctrl_state()
        end
        return false
    end

    local ctrl_active = helpers.IsCtrlPhysicallyHeld()
    if not ctrl_active and ctrl_teleport.is_ctrl_held then
        reset_ctrl_state()
    end

    if not ctrl_active or not start then
        return false
    end

    local success, localPlayer = pcall(GetLocal)
    if not (success and localPlayer and localPlayer.netid) then
        reset_ctrl_state()
        return false
    end

    if not (pos and pos.x and pos.y) then
        return false
    end

    local clickX = math.floor(pos.x / 32)
    local clickY = math.floor(pos.y / 32)
	
	local playerTileX = math.floor(localPlayer.pos.x / 32)
	local playerTileY = math.floor(localPlayer.pos.y / 32)

	local dx = math.abs(clickX - playerTileX)
	local dy = math.abs(clickY - playerTileY)

	if dx > 9 or dy > 9 then
		helpers.OnTextOverlay("`4Too far away!")
		reset_ctrl_state()
		return true
	end
    if not ctrl_teleport.saved_position and localPlayer.pos then
        ctrl_teleport.saved_position = {
            x = localPlayer.pos.x,
            y = localPlayer.pos.y
        }
    end

    if not ctrl_teleport.saved_position then
        reset_ctrl_state()
        return false
    end


    local savedPosX = tonumber(ctrl_teleport.saved_position.x) or (clickX * 32)
    local savedPosY = tonumber(ctrl_teleport.saved_position.y) or (clickY * 32)

    RunThread(function(target_x, target_y, return_px, return_py, me_netid)
	
        FindPath(target_x, target_y)
		-- take_at_tile(target_x, target_y)
		--take_horizontal_at_target(target_x, target_y, 2)
		-- take_nearby(2)
        local arrived = false
        local waited = 0
        local poll_interval_ms = 1
        local timeout_ms = 10

        while waited < timeout_ms do
            local ok_now, now_local = pcall(GetLocal)
            if ok_now and now_local and now_local.pos then
                local now_tile_x = math.floor(now_local.pos.x / 32)
                local now_tile_y = math.floor(now_local.pos.y / 32)

                if now_tile_x == target_x and now_tile_y == target_y then
                    arrived = true
                    break
                end
            end

            Sleep(poll_interval_ms)
            waited = waited + poll_interval_ms
        end

        if arrived then
            SendVariantList({
                [0] = "OnSetPos",
                [1] = {x = return_px, y = return_py}
            }, me_netid)
        end

        reset_ctrl_state()
    end, clickX, clickY, savedPosX, savedPosY, localPlayer.netid)
	helpers.SendTileEffect(clickX * 32 + 16, clickY * 32 + 16)
    helpers.OnTextOverlay("`2Teleporting `8To: `9" .. clickX .. "`2, `9" .. clickY)
    return true
end

-- Handle Shift Pathfind on World Touch (no return)
local function HandleShiftTeleport(pos, start)
    if config.tp_shift_click_enabled == false then
        if shift_teleport.is_shift_held then
            reset_shift_state()
        end
        return false
    end

    local ctrl_active = helpers.IsCtrlPhysicallyHeld()
    local shift_active = helpers.IsShiftPhysicallyHeld()

    if not shift_active and shift_teleport.is_shift_held then
        reset_shift_state()
    end

    if ctrl_active or not shift_active or not start then
        return false
    end

    local success, localPlayer = pcall(GetLocal)
    if not (success and localPlayer and localPlayer.netid) then
        reset_shift_state()
        return false
    end

    if not (pos and pos.x and pos.y) then
        return false
    end

    local clickX = math.floor(pos.x / 32)
    local clickY = math.floor(pos.y / 32)
    local startTileX, startTileY = clickX, clickY
    if localPlayer and localPlayer.pos then
        startTileX = math.floor((localPlayer.pos.x or 0) / 32)
        startTileY = math.floor((localPlayer.pos.y or 0) / 32)
    end
    local block_distance = math.abs(clickX - startTileX) + math.abs(clickY - startTileY)
    local started_ms = math.floor(os.clock() * 1000)
    local poll_interval_ms = 50
    local timeout_ms = 4000

    RunThread(function()
        FindPath(clickX, clickY)
        local arrived = false
        local waited = 0
        while waited < timeout_ms do
            local ok_now, now_local = pcall(GetLocal)
            if ok_now and now_local and now_local.pos then
                local nowTileX = math.floor((now_local.pos.x or 0) / 32)
                local nowTileY = math.floor((now_local.pos.y or 0) / 32)
                if nowTileX == clickX and nowTileY == clickY then
                    arrived = true
                    break
                end
            end
            Sleep(poll_interval_ms)
            waited = waited + poll_interval_ms
        end

        local elapsed_ms = math.floor(os.clock() * 1000) - started_ms
        if elapsed_ms < 0 then elapsed_ms = 0 end
        local block_word = (block_distance == 1) and "Block" or "Blocks"
        local overlay_msg = "`2Teleporting `9" .. tostring(block_distance) .. " " .. block_word .. " `2in `9" .. tostring(elapsed_ms) .. "ms"
        if arrived then
            helpers.OnTextOverlay(overlay_msg)
        end
		helpers.SendTileEffect(clickX * 32 + 16, clickY * 32 + 16)
        reset_shift_state()
    end)

    return true
end


-- Auto Pull: Handle World Touch for position setting
local function HandleAutoPullWorldTouch(pos, start)
    if not auto_pull_state.setting_position or not start then
        return false
    end
    
    if not (pos and pos.x and pos.y) then
        return false
    end
    
    local tileX = math.floor(pos.x / 32)
    local tileY = math.floor(pos.y / 32)
    
    config.auto_pull.target_pos = {x = tileX, y = tileY}
    auto_pull_state.setting_position = false
    clear_auto_pull_pending()
    auto_pull_state.pulled_users = {}
    auto_save_config()
    helpers.SendTileEffect(tileX * 32 + 16, tileY * 32 + 16)
    helpers.SendNotification("`2Auto Pull position set to: `9" .. tileX .. "`2, `9" .. tileY)
    helpers.OnConsoleMessage("`2[Auto Pull] Target position: `9(" .. tileX .. ", " .. tileY .. ")")
    
    return false
end

function helpers.HandleWrenchTouchPullWorldTouch(pos, start)
    if not config.wrench_touch_pull or not start then
        return false
    end

    if not (pos and pos.x and pos.y) then
        return false
    end

    local ok_items, player_items = pcall(GetPlayerItems)
    local selected_item = ok_items and player_items and player_items.backpack and tonumber(player_items.backpack.selected) or 0
    if selected_item ~= 32 then
        return false
    end

    local tileX = math.floor(pos.x / 32)
    local tileY = math.floor(pos.y / 32)
    local target_player = helpers.FindPlayerAtTile(tileX, tileY, pos)
    if not target_player or not target_player.netid then
        return false
    end
	
	helpers.SendTileEffect(pos.x, pos.y)

    RunThread(function()
        helpers.ExecuteWrenchActions(target_player.netid, target_player.name or "Unknown", {
            force_pull = true,
            allow_showbal = true
        })
    end)

    return true
end

function helpers.HandleBackPositionWorldTouch(pos, start)
    if not operation_flags.setting_back_position or not start then
        return false
    end

    if not (pos and pos.x and pos.y) then
        return false
    end

    local tileX = math.floor(pos.x / 32)
    local tileY = math.floor(pos.y / 32)
    local ok_world, world = pcall(GetWorld)
    local world_name = helpers.NormalizeBackPositionWorld(ok_world and world and world.name or "")

    config.back_position = {
        x = tileX,
        y = tileY,
        world = world_name
    }
	
    operation_flags.setting_back_position = false
    auto_save_config()
	helpers.SendTileEffect(tileX * 32 + 16, tileY * 32 + 16)
    helpers.SendNotification("`2Back Position set to: `9" .. tileX .. "`2, `9" .. tileY)
    helpers.OnConsoleMessage("`2[Back Position] Saved tile: `9(" .. tileX .. ", " .. tileY .. ")")

    return false
end

function AuthSuccess()
    RunThread(function()
        
        AddHook("OnSendPacket", "proxy_cmd", HandleSendPacket)
        AddHook("OnVariant", "proxy_var", HandleOnVariant)
        AddHook('OnSendPacketRaw', 'tpdisplay', handleTpDisplay)
        AddHook('OnWorldTouch', 'ctrl_teleport', HandleCtrlTeleport)
        AddHook('OnWorldTouch', 'shift_teleport', HandleShiftTeleport)
        AddHook('OnWorldTouch', 'auto_pull_pos', HandleAutoPullWorldTouch)
        AddHook('OnWorldTouch', 'wrench_touch_pull', helpers.HandleWrenchTouchPullWorldTouch)
        AddHook('OnWorldTouch', 'back_position_pos', helpers.HandleBackPositionWorldTouch)
        AddHook('OnWorldTouch', 'autohost_pos', helpers.HandleAutoHostWorldTouch)
        AddHook('OnSendPacketRaw', 'ctrl_teleport_block', HandleTeleportBlock)
        AddHook('OnProcessTankUpdatePacket', 'GemDetect', HandleGemDetector)
        AddHook('OnProcessTankUpdatePacket', 'SpamSlaveBlock', HandleSpamSlavePacket)
        AddHook('OnProcessTankUpdatePacket', 'FDiceDetector', HandleFDicePacket)
        AddHook("OnInput", "InputDetector", InputDetector)
        local draw_hook_ok, draw_hook_err = pcall(AddHook, "OnDraw", "exproxy_imgui_menu", draw_exproxy_imgui_menu)
        if draw_hook_ok then
            imgui_state.hook_ready = true
        else
            local err_str = string.lower(tostring(draw_hook_err or ""))
            if err_str:find("already") or err_str:find("exist") then
                imgui_state.hook_ready = true
            else
                imgui_state.hook_ready = false
            end
        end
        if imgui_state.hook_ready then
            imgui_state.visible = false
            helpers.OnConsoleMessage("`9[ImGui] Use `e/imgui `9to show or hide panel.")
        end
        if not draw_hook_ok and not imgui_state.hook_ready then
            helpers.OnConsoleMessage("`4[ImGui] OnDraw hook unavailable: `w" .. tostring(draw_hook_err))
        end


        helpers.OnConsoleMessage("`eLoading config from: `w" .. configPath)
        local loaded = helpers.LoadConfig(configPath)
        if not loaded then
            helpers.OnConsoleMessage("`eNo saved config found - Using default settings")
        end
        
        helpers.ProxyOpen()
        helpers.OnConsoleMessage("`2Script was `2Started successfully.")
        helpers.SayStartScript("`cJz`eProxy `8by `bJz`wProject")
        helpers.SendNotification("`cJz`eProxy `9is `2Active!")


        if config.spam then
            helpers.start_spam_loop_multi(config.spamdelay, config.confirm_back, true)
        end

        -- Start Telegram Polling
        helpers.PollTelegram()

        -- Auto start blink skin if enabled
        if config.blink_skin then
            helpers.start_blink_skin()
        end
    end)
end

-- Single Thread: Version + Auth Check
RunThread(function()
    helpers.OnConsoleMessage("`#Checking JzProxy script version...`w")
    local verReq = MakeRequest(VERSION_URL, "GET")
    local remoteVer = verReq.content:match("^%s*(.-)%s*$") or config.CURRENT_VERSION
    helpers.OnConsoleMessage("`2[Version] JzProxy Version: `w" .. remoteVer)
    
    if not isVersionUpToDate(config.CURRENT_VERSION, remoteVer) then
        helpers.OnConsoleMessage("`4[VERSION] Outdated! Current: `w" .. config.CURRENT_VERSION .. " `4| Required: `w" .. remoteVer)
        helpers.Say("`4Script Outdated! `wUpdate to v" .. remoteVer .. " `4via Discord (`9jzuvgti/ExJZV`4) or WhatsApp (`2085956640569`4).")
        helpers.OnTextOverlay("`8You need to update the proxy to v" .. remoteVer)
        helpers.UpdateRequire(remoteVer, config.CURRENT_VERSION)
        local player = GetLocal()
        local userId = math.floor(player.userid or 0)
        local userName = tostring(player.name or "Unknown")
        send_auth_webhook("OUTDATED", userName, userId)
        RemoveHooks()
        return
    end
    
    helpers.OnConsoleMessage("`9Loading saved configuration...")
    if helpers.LoadConfig then
        local loaded = helpers.LoadConfig(configPath)
        if loaded then
            helpers.OnConsoleMessage("`2Configuration loaded successfully!")
        else
            helpers.OnConsoleMessage("`7No saved config found, using defaults")
        end
    end
    
    -- Auth check
    helpers.OnConsoleMessage("`#Checking authorization...`w")
    local player = GetLocal()
    local userId = math.floor(player.userid or 0)
    local userName = tostring(player.name or "Unknown")
    
    if isUserIdAllowed(userId) then
        RunThread(function()
            helpers.Say("`2Access Granted for `7" .. userName .. "`w.")
            ChangeValue("[M] Pathfinder", false)
			Sleep(3000)
            helpers.OnConsoleMessage("`2[OK]`5 Authorized user: `w" .. userName)
            if helpers.IsAutoPullAdminUser(userId) then
                helpers.OnConsoleMessage("`2[Auto Pull] `wAuto Pull Admins Loaded: `9" .. tostring(helpers.GetAutoPullAdminCount()))
            end
			helpers.SayStartScript("`cInjected `eJz`cProxy `2V3")
            local bannerUrl = "https://raw.githubusercontent.com/JzuvGTI/userid-proxy/refs/heads/main/JzProxy_JUDI.rttex"
            helpers.downloadBanner(bannerUrl)
            local notifUrl = "https://raw.githubusercontent.com/JzuvGTI/userid-proxy/refs/heads/main/JzProxyNotifs.rttex"
            helpers.downloadNotifs(notifUrl)
            local bannerPath = ""
            local androidProp = os.getenv("ANDROID_ROOT") or os.getenv("ANDROID_DATA")
            if androidProp then
                bannerPath = "/sdcard/Android/data/com.rtsoft.growtopia/files/interface/large/JzProxy_JUDI.rttex"
            else
                local userProfile = os.getenv("USERPROFILE")
                bannerPath = string.format("%s\\AppData\\Local\\Growtopia\\interface\\large\\JzProxy_JUDI.rttex", userProfile)
            end
            
            local waited = 0
            local maxWait = 5000 
            
            while waited < maxWait do
                local file = io.open(bannerPath, "r")
                if file then
                    file:close()
                    break
                end
                Sleep(200)
                waited = waited + 200
            end
            
            if waited >= maxWait then
                helpers.OnConsoleMessage("`4[Banner] `wBanner download timeout, continuing anyway...")
            end
            
            send_auth_webhook("AUTHORIZED", userName, userId)
            AuthSuccess()
        end)
    else
        helpers.OnConsoleMessage("`4[DENIED]`5 Unauthorized ID: `w" .. userId)
        helpers.OnConsoleMessage("`4[DENIED]`5 Unauthorized ID: `w" .. userId)
        helpers.Say("`4Access Denied for `7" .. userName .. "`w.")
        helpers.OnConsoleMessage("`8Contact `qjzuvgti `wfor access.")
        send_auth_webhook("DENIED", userName, userId)
        RemoveHooks()
    end
end)
