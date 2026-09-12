-- stock.lua -- Mantenedor de estoque AE2 via ME Bridge (Advanced Peripherals)
-- ATM10 7.3 / CC:Tweaked 1.113.1 / AP 0.7.62b / AE2 19.2.17

local CONFIG = {
  interval  = 15,          -- segundos entre verificacoes
  cpuName   = "StockCPU",  -- nome da CPU dedicada (bigorna)
  cooldown  = 180,         -- seg. antes de repedir o mesmo item
  reserveCPU = 1,          -- CPUs deixadas livres para crafts manuais

  items = {
    -- { name = "modid:item", min = <gatilho>, batch = <quanto pedir> }
    { name = "mekanism:steel_ingot",         min = 512,  batch = 256 },
    { name = "mekanism:alloy_infused",       min = 256,  batch = 128 },
    { name = "mekanism:alloy_reinforced",    min = 128,  batch = 64  },
    { name = "ae2:calculation_processor",    min = 128,  batch = 64  },
    { name = "ae2:logic_processor",          min = 128,  batch = 64  },
    { name = "ae2:engineering_processor",    min = 128,  batch = 64  },
    { name = "minecraft:iron_ingot",         min = 1024, batch = 512 },
  },
}

local bridge = peripheral.find("meBridge")
if not bridge then
  error("ME Bridge nao encontrado. Verifique o modem e o cabo de rede.")
end

local pending = {}  -- name -> timestamp de expiracao do pedido

local function now()
  return os.epoch("utc") / 1000
end

-- Toda chamada ao bridge vai encapsulada: AP lanca erro (nao retorna nil)
-- quando o item e desconhecido ou a rede esta offline.
local function safe(fn, ...)
  local ok, res = pcall(fn, ...)
  if ok then return res end
  return nil, res
end

local function stockOf(name)
  local item = safe(bridge.getItem, { name = name })
  if item and item.amount then return item.amount end
  return 0
end

local function isCrafting(name)
  return safe(bridge.isItemCrafting, { name = name }) == true
end

local function countFreeCPUs()
  local cpus = safe(bridge.getCraftingCPUs) or {}
  local free = 0
  for _, c in ipairs(cpus) do
    if not c.isBusy then free = free + 1 end
  end
  return free
end

-- A assinatura de craftItem mudou entre builds do AP; tenta as 3 formas.
local function requestCraft(name, count)
  local item = { name = name, count = count }
  local r = safe(bridge.craftItem, item, CONFIG.cpuName)
  if r == nil then
    item.cpu = CONFIG.cpuName
    r = safe(bridge.craftItem, item)
  end
  if r == nil then
    r = safe(bridge.craftItem, { name = name, count = count })
  end
  return r == true or (type(r) == "table" and r.status ~= nil)
end

-- Valida a lista na inicializacao contra os padroes realmente existentes.
local function validate()
  local list = safe(bridge.listCraftableItems)
  if not list then
    print("[aviso] listCraftableItems indisponivel; pulando validacao.")
    return
  end
  local set = {}
  for _, i in ipairs(list) do set[i.name] = true end
  for _, e in ipairs(CONFIG.items) do
    if not set[e.name] then
      print("[ERRO] sem padrao de craft para: " .. e.name)
    end
  end
end

print("Stock keeper iniciado -- " .. #CONFIG.items .. " itens monitorados")
validate()

while true do
  local free = countFreeCPUs() - CONFIG.reserveCPU
  local t = now()

  for _, e in ipairs(CONFIG.items) do
    local have = stockOf(e.name)

    if have >= e.min then
      pending[e.name] = nil
    elseif free > 0
       and (not pending[e.name] or t > pending[e.name])
       and not isCrafting(e.name) then

      local count = math.min(e.batch, e.min - have)
      if requestCraft(e.name, count) then
        pending[e.name] = t + CONFIG.cooldown
        free = free - 1
        print(string.format("[%s] craft: %d x %s (estoque %d/%d)",
          os.date("%H:%M:%S"), count, e.name, have, e.min))
      else
        print("[falha] nao consegui agendar: " .. e.name)
        pending[e.name] = t + CONFIG.cooldown
      end
    end
  end

  sleep(CONFIG.interval)
end
