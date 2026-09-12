-- stock.lua -- Mantenedor de estoque AE2 via ME Bridge
-- ATM10 7.3 / CC:Tweaked 1.113.1 / Advanced Peripherals 0.7.62b / AE2 19.2.17
-- Calibrado para a API real: tipo "me_bridge", metodos isCrafting / isCraftable

local CONFIG = {
  interval   = 15,          -- segundos entre verificacoes
  cpuName    = "StockCPU",  -- nome da CPU dedicada (renomeie na bigorna)
  cooldown   = 180,         -- seg. antes de repedir o mesmo item
  reserveCPU = 1,           -- CPUs deixadas livres para crafts manuais
  fallbackCPUs = 2,         -- usado so se getCraftingCPUs nao existir

  items = {
    -- { name = "modid:item", min = <gatilho>, batch = <quanto pedir> }
    -- Comece com 2 ou 3 itens que voce tem CERTEZA que tem pattern.
    { name = "ae2:fluix_smart_cable", min = 10, batch = 40 },
    { name = "ae2:logic_processor", min = 8, batch = 16 },
    { name = "ae2:calculation_processor", min = 8, batch = 16 },
    { name = "ae2:engineering_processor", min = 8, batch = 16 },
    { name = "extendedae:concurrent_processor", min = 8, batch = 16 },
  },
}

-- ---------------------------------------------------------------- setup

local bridge = peripheral.find("me_bridge") or peripheral.find("meBridge")
if not bridge then
  error("ME Bridge nao encontrado. Confira o lado/modem com peripheral.getNames()")
end

local hasCPUs      = bridge.getCraftingCPUs ~= nil
local hasCraftable = bridge.isCraftable ~= nil

local pending = {}  -- name -> timestamp de expiracao do pedido

local function now() return os.epoch("utc") / 1000 end

-- O AP lanca erro (nao retorna nil) para item desconhecido ou rede offline.
local function safe(fn, ...)
  if not fn then return nil end
  local ok, res = pcall(fn, ...)
  if ok then return res end
  return nil
end

-- ---------------------------------------------------------------- bridge

local function stockOf(name)
  -- getItem retorna nil quando a quantidade e zero, nao amount = 0
  local item = safe(bridge.getItem, { name = name })
  if item and item.amount then return item.amount end
  return 0
end

local function isCraftingNow(name)
  return safe(bridge.isCrafting, { name = name }) == true
end

local function countFreeCPUs()
  if not hasCPUs then return CONFIG.fallbackCPUs end
  local cpus = safe(bridge.getCraftingCPUs) or {}
  local free = 0
  for _, c in ipairs(cpus) do
    if not c.isBusy then free = free + 1 end
  end
  return free
end

-- A assinatura de craftItem varia entre builds do AP; tenta as 3 formas.
local function requestCraft(name, count)
  local r = safe(bridge.craftItem, { name = name, count = count }, CONFIG.cpuName)
  if r == nil then
    r = safe(bridge.craftItem, { name = name, count = count, cpu = CONFIG.cpuName })
  end
  if r == nil then
    r = safe(bridge.craftItem, { name = name, count = count })
  end
  return r == true or type(r) == "table"
end

-- ---------------------------------------------------------------- boot

local function validate()
  if not hasCraftable then
    print("[aviso] isCraftable indisponivel; pulando validacao de padroes.")
    return
  end
  for _, e in ipairs(CONFIG.items) do
    if safe(bridge.isCraftable, { name = e.name }) ~= true then
      print("[ERRO] sem padrao de craft: " .. e.name)
    end
  end
end

term.clear()
term.setCursorPos(1, 1)
print("Stock keeper -- " .. #CONFIG.items .. " itens monitorados")

if bridge.isOnline and bridge.isOnline() ~= true then
  print("[aviso] bridge offline/sem channel -- verifique a rede AE2")
end
if not hasCPUs then
  print("[aviso] getCraftingCPUs ausente; assumindo "
        .. CONFIG.fallbackCPUs .. " CPUs livres")
end

validate()

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

      if requestCraft(e.name, count) then
        free = free - 1
        print(string.format("[%s] craft: %d x %s (%d/%d)",
          os.date("%H:%M:%S"), count, e.name, have, e.min))
      else
        print(string.format("[%s] FALHA ao agendar: %s",
          os.date("%H:%M:%S"), e.name))
      end
    end
  end

  sleep(CONFIG.interval)
end
