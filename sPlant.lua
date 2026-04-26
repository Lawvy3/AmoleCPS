-- ============================================================
--  AUTO PLANT SCRIPT - Bothax Growtopia (DEBUG VERSION)
-- ============================================================

SeedID        = SeedID        or 5640
TargetTileID  = TargetTileID  or 455

DelayFindPath = DelayFindPath or 50
DelayStepPath = DelayStepPath or 100
DelayShortPath= DelayShortPath or 0
DelayPlant    = DelayPlant    or 300  -- dinaikkan sementara untuk debug
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
--  PATHFINDING
-- ============================================================

local _origFP = (type(FindPath) == "function") and FindPath or function(x, y, r) end
local STEP_SIZE    = 2
local MAX_STEPS    = 2000
local TRY_PER_STEP = 5
local NO_PROG_LIM  = 3

local function sign(v) return (v > 0 and 1) or (v < 0 and -1) or 0 end

local function gOgOPath(x, y)
  if not InWorld() then return end
  local pl = GetLocal()
  if not pl then return end
  SendVariantList({[0] = "OnSetPos", [1] = {x = x * 32, y = y * 32}}, pl.netid)
  SendPacketRaw(false, {type = 3, state = 1, value = 0, px = x, py = y, x = x * 32, y = y * 32})
end

function TelePath(tx, ty)
  if not InWorld() then return end
  local pl = GetLocal()
  if not pl or not pl.pos then pcall(_origFP, tx, ty, 520) return end

  local cx = math.floor(pl.pos.x / 32)
  local cy = math.floor(pl.pos.y / 32)
  if cx == tx and cy == ty then return end

  if (math.abs(cx - tx) + math.abs(cy - ty)) <= 10 then
    local pl2 = GetLocal()
    if pl2 then
      SendVariantList({[0] = "OnSetPos", [1] = {x = tx * 32, y = ty * 32}}, pl2.netid)
    end
    Sleep(DelayShortPath)
    return
  end

  local steps = 0
  local no_prog = 0

  while (cx ~= tx or cy ~= ty) and InWorld() and steps < MAX_STEPS do
    steps = steps + 1
    local dx, dy = tx - cx, ty - cy
    local nx, ny = cx, cy

    if math.abs(dx) >= math.abs(dy) then
      nx = cx + sign(dx) * math.min(STEP_SIZE, math.abs(dx))
    else
      ny = cy + sign(dy) * math.min(STEP_SIZE, math.abs(dy))
    end

    gOgOPath(nx, ny)
    Sleep(DelayFindPath)

    local reached = false
    for _ = 1, TRY_PER_STEP do
      Sleep(DelayStepPath)
      local pl2 = GetLocal()
      if pl2 and pl2.pos then
        if math.floor(pl2.pos.x / 32) == nx and math.floor(pl2.pos.y / 32) == ny then
          reached = true
          break
        end
      end
    end

    if reached then
      cx, cy = nx, ny
      no_prog = 0
    else
      no_prog = no_prog + 1
      if no_prog >= NO_PROG_LIM then pcall(_origFP, tx, ty, 520) return end
    end
    Sleep(10)
  end
end

-- ============================================================
--  SCAN
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
--  PLANT (dengan debug log lengkap)
-- ============================================================

function PlantAt(tx, ty)
  TelePath(tx, ty)
  Sleep(DelayPlant)

  -- Debug: cek posisi player sekarang
  local pl = GetLocal()
  if pl and pl.pos then
    local px = math.floor(pl.pos.x / 32)
    local py = math.floor(pl.pos.y / 32)
    LogToConsole(string.format("`1[DEBUG] `7Posisi player setelah TelePath: X:`6%d `7Y:`6%d `7| Target: X:`6%d `7Y:`6%d", px, py, tx, ty))
  end

  -- Debug: cek fg tile target sekarang
  local ok, tile = pcall(GetTile, tx, ty)
  if not ok or not tile then
    LogToConsole("`1[DEBUG] `4GetTile gagal di X:" .. tx .. " Y:" .. ty)
    return false
  end

  LogToConsole(string.format("`1[DEBUG] `7Tile fg sekarang: `6%d `7| TargetTileID: `6%d", tile.fg, TargetTileID))

  -- Kirim packet tanpa cek (bypass re-check) untuk debug
  LogToConsole("`1[DEBUG] `2Mengirim packet plant...")
  SendPacketRaw(false, {
    type  = 3,
    value = SeedID,
    state = 32,
    x     = tx * 32,
    y     = ty * 32
  })
  Sleep(200)

  -- Debug: cek fg tile setelah packet dikirim
  local ok2, tile2 = pcall(GetTile, tx, ty)
  if ok2 and tile2 then
    LogToConsole(string.format("`1[DEBUG] `7Tile fg SETELAH packet: `6%d `7(SeedID=`6%d`7)", tile2.fg, SeedID))
    if tile2.fg == SeedID then
      LogToConsole("`1[DEBUG] `2BERHASIL ditanam!")
      return true
    else
      LogToConsole("`1[DEBUG] `4GAGAL tanam - tile fg tidak berubah ke SeedID")
      return false
    end
  end

  return true
end

-- ============================================================
--  MAIN
-- ============================================================

function Main()
  if not InWorld() then
    LogToConsole("`1[AutoPlant] `4ERROR: Player belum masuk world!")
    return
  end

  if not HasSeed(SeedID) then
    LogToConsole("`1[AutoPlant] `4ERROR: Seed ID " .. SeedID .. " tidak ada di inventory!")
    return
  end

  LogToConsole("`1[AutoPlant] `2Script dimulai (DEBUG MODE).")
  LogToConsole("`1[AutoPlant] `7Seed Inventory: `6" .. SeedID .. " `7| Tile Target fg: `6" .. TargetTileID)

  local targets = ScanTargetTiles()

  if #targets == 0 then
    LogToConsole("`1[AutoPlant] `4Tidak ada tile fg=" .. TargetTileID .. " ditemukan. Script berhenti.")
    return
  end

  LogToConsole("`1[AutoPlant] `2Ditemukan `6" .. #targets .. " `2tile. Coba plant tile pertama dulu...")

  -- DEBUG: hanya coba 1 tile pertama
  local tile = targets[1]
  LogToConsole(string.format("`1[AutoPlant] `7Target pertama: X:`6%d `7Y:`6%d", tile.x, tile.y))
  PlantAt(tile.x, tile.y)

  LogToConsole("`1[AutoPlant] `7Debug selesai. Cek log di atas untuk diagnosis.")
end

Main()
