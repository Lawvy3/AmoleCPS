-- ============================================================
--  AUTO PLANT SCRIPT - Bothax Growtopia
--  Logic:
--    - Scan world cari tile fg == TargetTileID
--    - TelePath ke tile tersebut
--    - FindPath (rangeTrigger) ke tile tersebut agar server register posisi
--    - Kirim packet plant SeedID
-- ============================================================

-- ============================================================
--  KONFIGURASI BEBAS (Custom oleh User)
-- ============================================================

SeedID        = SeedID        or 5640   -- ID seed di INVENTORY yang akan ditanam
TargetTileID  = TargetTileID  or 455    -- ID tile fg di WORLD yang dicari/ditumpuk

DelayFindPath = DelayFindPath or 50
DelayStepPath = DelayStepPath or 100
DelayShortPath= DelayShortPath or 0
DelayPlant    = DelayPlant    or 68
WorldSizeX    = WorldSizeX    or 199
WorldSizeY    = WorldSizeY    or 192

-- ============================================================
--  InWorld
-- ============================================================

function InWorld()
  local ok, world = pcall(GetWorld)
  return ok and world ~= nil
end

-- ============================================================
--  Cek inventory
-- ============================================================

function HasSeed(id)
  local ok, inv = pcall(GetInventory)
  if not ok or not inv then return false end
  for _, item in pairs(inv) do
    if item.id == id and item.amount > 0 then
      return true
    end
  end
  return false
end

-- ============================================================
--  PATHFINDING (persis dari referensi PTHT asli)
-- ============================================================

local _origFindPath = (type(FindPath) == "function") and FindPath or function(x, y, r) end
local TELEPATH_STEP_SLEEP        = DelayStepPath
local TELEPATH_TRY_PER_STEP      = 5
local TELEPATH_MAX_STEPS         = 1000
local TELEPATH_FALLBACK          = true
local TELEPATH_NO_PROGRESS_LIMIT = 3
local TELEPATH_STEP_SIZE         = 2

local function sign(v) return (v > 0 and 1) or (v < 0 and -1) or 0 end

function GoPath(t, s, v, x, y)
  if not InWorld() then return end
  SendPacketRaw(false, {type = t, state = s, value = v, px = x, py = y, x = x * 32, y = y * 32})
  if t == nil then
    SendVariantList({[0] = "OnSetPos", [1] = {x = x * 32, y = y * 32}}, GetLocal().netid)
  end
end

function gOgOPath(x, y)
  GoPath(nil, nil, nil, x, y)
  GoPath(3, 1, 0, x, y)
end

function TelePath(tx, ty, rangeTrigger)
  rangeTrigger = rangeTrigger or DelayFindPath
  if not InWorld() then return end

  local player = GetLocal()
  if player and player.pos then
    local px = math.floor(player.pos.x / 32)
    local py = math.floor(player.pos.y / 32)
    local distance = math.abs(px - tx) + math.abs(py - ty)
    if distance <= 10 then
      ShortDelay = true
    else
      ShortDelay = false
    end
  end

  if ShortDelay then return GoPath(nil, nil, nil, tx, ty) end

  local pl = GetLocal()
  if not pl or not pl.pos then
    return _origFindPath(tx, ty, 520)
  end

  local cx = pl.pos.x // 32
  local cy = pl.pos.y // 32
  if cx == tx and cy == ty then return end

  local steps = 0
  local no_progress_count = 0

  while (cx ~= tx or cy ~= ty) and InWorld() and steps < TELEPATH_MAX_STEPS do
    steps = steps + 1
    local dx = tx - cx
    local dy = ty - cy
    local nx, ny = cx, cy

    if math.abs(dx) >= math.abs(dy) then
      nx = cx + sign(dx) * math.min(TELEPATH_STEP_SIZE, math.abs(dx))
    else
      ny = cy + sign(dy) * math.min(TELEPATH_STEP_SIZE, math.abs(dy))
    end

    gOgOPath(nx, ny)
    Sleep(ShortDelay and DelayShortPath or DelayFindPath)

    local try = 0
    local reached = false
    while try < TELEPATH_TRY_PER_STEP and InWorld() do
      Sleep(TELEPATH_STEP_SLEEP)
      local pl2 = GetLocal()
      if pl2 and pl2.pos and pl2.pos.x // 32 == nx and pl2.pos.y // 32 == ny then
        reached = true
        break
      end
      try = try + 1
    end

    if reached then
      cx, cy = nx, ny
      no_progress_count = 0
    else
      -- coba alternatif arah Y
      local alt_done = false
      if nx ~= cx and cy ~= ty then
        local alt_ny = cy + sign(ty - cy) * math.min(TELEPATH_STEP_SIZE, math.abs(ty - cy))
        gOgOPath(cx, alt_ny)
        local try2 = 0
        while try2 < TELEPATH_TRY_PER_STEP and InWorld() do
          Sleep(TELEPATH_STEP_SLEEP)
          local pl3 = GetLocal()
          if pl3 and pl3.pos and pl3.pos.x // 32 == cx and pl3.pos.y // 32 == alt_ny then
            cy = alt_ny
            alt_done = true
            break
          end
          try2 = try2 + 1
        end
      end
      if not alt_done then
        no_progress_count = no_progress_count + 1
      end
    end

    if no_progress_count >= TELEPATH_NO_PROGRESS_LIMIT then
      if TELEPATH_FALLBACK then _origFindPath(tx, ty, 520) end
      return
    end

    Sleep(10)
  end
end

-- ============================================================
--  SCAN WORLD
-- ============================================================

function ScanTargetTiles()
  local tiles = {}
  for y = 0, WorldSizeY - 1 do
    for x = 0, WorldSizeX - 1 do
      local ok, tile = pcall(GetTile, x, y)
      if ok and tile and tile.fg == TargetTileID then
        table.insert(tiles, {x = x, y = y})
      end
    end
  end
  return tiles
end

-- ============================================================
--  PLANT
--  Menggunakan FindPath (bukan TelePath) sebagai trigger plant
--  persis seperti cara script PTHT asli register posisi ke server
-- ============================================================

function PlantAt(tx, ty)
  -- Step 1: TelePath dulu biar dekat
  TelePath(tx, ty, DelayFindPath)
  Sleep(DelayPlant)

  -- Step 2: re-check tile
  local ok, tile = pcall(GetTile, tx, ty)
  if not ok or not tile or tile.fg ~= TargetTileID then
    return false
  end

  -- Step 3: FindPath ke tile (register posisi ke server seperti referensi asli)
  _origFindPath(tx, ty, 520)
  Sleep(50)

  -- Step 4: kirim packet plant (dengan px/py, persis referensi asli line 676-684)
  SendPacketRaw(false, {
    type  = 3,
    value = SeedID,
    state = 32,
    x     = tx * 32,
    y     = ty * 32,
    px    = tx,
    py    = ty
  })
  Sleep(20)
  return true
end

-- ============================================================
--  MAIN
-- ============================================================

function Main()
  if not InWorld() then
    LogToConsole("`1[AmoleXClaude] `4ERROR: Player belum masuk world!")
    return
  end

  if not HasSeed(SeedID) then
    LogToConsole("`1[AmoleXClaude] `4ERROR: Seed ID " .. SeedID .. " tidak ada di inventory!")
    return
  end

  LogToConsole("`1[AmoleXClaude] `2Script dimulai.")
  LogToConsole("`1[AmoleXClaude] `7Seed Inventory : `6" .. SeedID)
  LogToConsole("`1[AmoleXClaude] `7Tile Target fg : `6" .. TargetTileID)
  LogToConsole("`1[AmoleXClaude] `7World Size     : `6" .. WorldSizeX .. " x " .. WorldSizeY)
  LogToConsole("`1[AmoleXClaude] `2Scanning world...")

  local targets = ScanTargetTiles()

  if #targets == 0 then
    LogToConsole("`1[AmoleXClaude] `4Tidak ada tile fg=" .. TargetTileID .. " di world. Script berhenti.")
    return
  end

  LogToConsole("`1[AmoleXClaude] `2Ditemukan `6" .. #targets .. " `2tile. Mulai menanam...")

  local planted = 0
  local skipped = 0

  for i, tile in ipairs(targets) do
    if not InWorld() then
      LogToConsole("`1[AmoleXClaude] `4Koneksi terputus.")
      break
    end
    if not HasSeed(SeedID) then
      LogToConsole("`1[AmoleXClaude] `4Seed habis di inventory. Script berhenti.")
      break
    end

    LogToConsole(string.format("`1[AmoleXClaude] `7[%d/%d] `2X:`6%d `2Y:`6%d", i, #targets, tile.x, tile.y))

    local ok = PlantAt(tile.x, tile.y)
    if ok then planted = planted + 1 else skipped = skipped + 1 end
  end

  local remaining = ScanTargetTiles()
  LogToConsole("`1[AmoleXClaude] `2==============================")
  LogToConsole("`1[AmoleXClaude] `2Selesai! Ditanam: `6" .. planted .. " `2| Dilewati: `8" .. skipped)
  if #remaining == 0 then
    LogToConsole("`1[AmoleXClaude] `2Tidak ada lagi tile fg=" .. TargetTileID .. ". Script selesai.")
  else
    LogToConsole("`1[AmoleXClaude] `4Masih ada `6" .. #remaining .. " `4tile tersisa.")
  end
end

LogToConsole("`2Version: `91.0")
Sleep(5)
LogToConsole("`1[AmoleXClaude] `4Loading...")
Sleep(1000)
Main()
