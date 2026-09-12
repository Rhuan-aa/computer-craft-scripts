-- stock.lua -- Mantenedor de estoque AE2 via ME Bridge
-- ATM10 7.3 / CC:Tweaked 1.113.1 / Advanced Peripherals 0.7.62b / AE2 19.2.17

local CONFIG = {
  interval   = 15,
  cpuName    = "StockCPU",  -- nil = deixa o AE2 escolher a CPU
  cooldown   = 180,
  reserveCPU = 1,
  fallbackCPUs = 2,
  debug      = true,        -- mostra o retorno cru do craftItem

  items = {
    { name = "ae2:fluix_smart_cable",            min = 10, batch = 10 },
    { name = "ae2:logic_processor",              min = 8,  batch = 8  },
    { name = "ae2:calculation_processor",        min = 8,  batch = 8  },
    { name = "ae2:engineering_processor",        min = 8,  batch = 8  },
    { name = "extendedae:concurrent_processor",  min = 8,  batch = 8  },
  },
}

-- ---------------------------------------------------------------- setup

local bridge = peripheral.find("me_bridge") or peripheral.find("meBridge")
if not bridge then
  error("ME Bridge nao encontrado.")
end

local hasCPUs      = bridge.getCraftingCPUs ~= nil
local hasCraftable = bridge.isCraftable ~= nil
local cpuName      = CONFIG.cpuName

local pending = {}

local function now() return os.epoch("utc") / 1000 end

-- Preserva TODOS os retornos: o AP devolve false, "motivo" em caso de recusa.
local function safe(fn, ...)
  if not fn then return { n = 0 } end
  local r = table.pack(pcall(fn, ...))
  if not r[1] then return { n = 1, nil, err = r[2] } end
  return table.pack(table.unpack(r, 2, r.n))
end

local function first(fn, ...)
  return safe(fn, ...)[1]
end

-- serialise nao aceita funcoes; este dump aceita e marca como <fn>
local function dump(v, depth)
  depth = depth or 0
  local t = type(v)
  if t == "function" then return "<fn>" end
  if t ~= "table" then return tostring(v) end
  if depth > 2 then return "{...}" end
  local parts = {}
  for k, val in pairs(v) do
    parts[#parts + 1] = tostring(k) .. "=" .. dump(val, depth + 1)
  end
  return "{" .. table.concat(parts, ", ") .. "}"
end

local function describe(r)
  if r.err then return "erro: " .. tostring(r.err) end
  local parts = {}
  for i = 1, math.max(r.n, 1) do
    parts[#parts + 1] = dump(r[i])
  end
  return table.concat(parts, " | ")
end

-- ---------------------------------------------------------------- bridge

local function stockOf(name)
  local item = first(bridge.getItem, { name = name })
  if item and item.amount then return item.amount end
  return 0
end

local function isCraftingNow(name)
  return first(bridge.isCrafting, { name = name }) == true
end

local function listCPUs()
  if not hasCPUs then return nil end
  return first(bridge.getCraftingCPUs)
end

local function countFreeCPUs()
  local cpus = listCPUs()
  if not cpus then return CONFIG.fallbackCPUs end
  local free = 0
  for _, c in ipairs(cpus) do
    if not c.isBusy then free = free + 1 end
  end
  return free
end

-- Retorna: status ("ok" | "?" | "falha"), detalhe (string)
local function classify(r)
  if r.err then return "falha" end
  if r[1] == true then return "ok" end
  if type(r[1]) == "table" then return "?" end  -- objeto de job: indeterminado
  return "falha"
end

local function requestCraft(name, count)
  local r
  if cpuName then
    r = safe(bridge.craftItem, { name = name, count = count }, cpuName)
    if classify(r) == "falha" then
      r = safe(bridge.craftItem, { name = name, count = count, cpu = cpuName })
    end
  end
  if not r or classify(r) == "falha" then
    r = safe(bridge.craftItem, { name = name, count = count })
  end
  return classify(r), describe(r)
end

-- ---------------------------------------------------------------- boot

term.clear(); term.setCursorPos(1, 1)
print("Stock keeper -- " .. #CONFIG.items .. " itens")

if bridge.isOnline and bridge.isOnline() ~= true then
  print("[aviso] bridge offline / sem channel")
end

-- A CPU nomeada existe mesmo? Se nao, para de pedir por nome.
if cpuName then
  local cpus, found = listCPUs(), false
  if cpus then
    for _, c in ipairs(cpus) do
      if c.name == cpuName then found = true end
    end
    print("CPUs na rede: " .. #cpus)
    if not found then
      print("[aviso] CPU '" .. cpuName .. "' nao existe; usando qualquer uma")
      cpuName = nil
    end
  end
end

if hasCraftable then
  for _, e in ipairs(CONFIG.items) do
    if first(bridge.isCraftable, { name = e.name }) ~= true then
      print("[ERRO] sem padrao: " .. e.name)
    end
  end
end

-- ---------------------------------------------------------------- loop

while true do
  local free = countFreeCPUs() - CONFIG.reserveCPU
  local t = now()

  for _, e in ipairs(CONFIG.items) do
    local have = stockOf(e.name)

    if have >= e.min then
      pending[e.name] = nil

    elseif free > 0
       and (not pending[e.name] or t > pending[e.name])
       and not isCraftingNow(e.name) then

      local count = math.min(e.batch, e.min - have)
      pending[e.name] = t + CONFIG.cooldown
      local status, detail = requestCraft(e.name, count)

      if status ~= "falha" then free = free - 1 end

      print(string.format("[%s] %s %d x %s (%d/%d)",
        os.date("%H:%M:%S"), status, count, e.name, have, e.min))

      if CONFIG.debug or status == "falha" then
        print("  retorno: " .. detail)
      end
    end
  end

  sleep(CONFIG.interval)
end
