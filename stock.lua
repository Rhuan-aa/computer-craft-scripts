-- stock.lua -- Mantenedor de estoque AE2 via ME Bridge
-- ATM10 7.3 / CC:Tweaked 1.113.1 / Advanced Peripherals 0.7.62b / AE2 19.2.17

local VERSION = "v5 -- acompanha job object"

local CONFIG = {
  interval   = 10,
  cpuName    = "StockCPU",  -- nil = deixa o AE2 escolher
  cooldown   = 300,         -- espera apos um job falhar
  reserveCPU = 1,
  fallbackCPUs = 2,

  items = {
    { name = "ae2:fluix_smart_cable",           min = 10, batch = 10 },
    { name = "ae2:logic_processor",             min = 8,  batch = 8  },
    { name = "ae2:calculation_processor",       min = 8,  batch = 8  },
    { name = "ae2:engineering_processor",       min = 8,  batch = 8  },
    { name = "extendedae:concurrent_processor", min = 8,  batch = 8  },
  },
}

-- ---------------------------------------------------------------- setup

local bridge = peripheral.find("me_bridge") or peripheral.find("meBridge")
if not bridge then error("ME Bridge nao encontrado.") end

local hasCPUs   = bridge.getCraftingCPUs ~= nil
local cpuName   = CONFIG.cpuName
local jobs      = {}   -- name -> objeto de job em andamento
local cooldowns = {}   -- name -> timestamp de liberacao

local function now() return os.epoch("utc") / 1000 end

local function safe(fn, ...)
  if type(fn) ~= "function" then return nil end
  local ok, res = pcall(fn, ...)
  if ok then return res end
  return nil
end

-- Chama um metodo do objeto de job com seguranca
local function jcall(job, method, ...)
  if not job then return nil end
  return safe(job[method], ...)
end

local function shortName(id)
  return (tostring(id):gsub("^.-:", ""))
end

-- ---------------------------------------------------------------- bridge

local function stockOf(name)
  local item = safe(bridge.getItem, { name = name })
  return (item and item.amount) or 0
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

local function requestCraft(name, count)
  local item = { name = name, count = count }
  local r
  if cpuName then
    r = safe(bridge.craftItem, item, cpuName)
    if type(r) ~= "table" then
      r = safe(bridge.craftItem, { name = name, count = count, cpu = cpuName })
    end
  end
  if type(r) ~= "table" then
    r = safe(bridge.craftItem, item)
  end
  return (type(r) == "table") and r or nil
end

-- Lista o que esta faltando para o job sair do papel
local function missingReport(job)
  local miss = jcall(job, "getMissingItems")
  if type(miss) ~= "table" or #miss == 0 then return nil end
  local parts = {}
  for i = 1, math.min(#miss, 4) do
    local m = miss[i]
    parts[#parts + 1] = string.format("%s x%s",
      shortName(m.name or m.displayName or "?"), tostring(m.amount or m.count or "?"))
  end
  if #miss > 4 then parts[#parts + 1] = "(+" .. (#miss - 4) .. ")" end
  return table.concat(parts, ", ")
end

-- ---------------------------------------------------------------- boot

term.clear(); term.setCursorPos(1, 1)
print("Stock keeper " .. VERSION)
print(#CONFIG.items .. " itens monitorados")

if bridge.isOnline and bridge.isOnline() ~= true then
  print("[aviso] bridge offline / sem channel")
end

if cpuName and hasCPUs then
  local cpus, found = safe(bridge.getCraftingCPUs) or {}, false
  for _, c in ipairs(cpus) do
    if c.name == cpuName then found = true end
  end
  print("CPUs na rede: " .. #cpus)
  if not found then
    print("[aviso] CPU '" .. cpuName .. "' nao existe; usando qualquer uma")
    cpuName = nil
  end
end

if bridge.isCraftable then
  for _, e in ipairs(CONFIG.items) do
    if safe(bridge.isCraftable, { name = e.name }) ~= true then
      print("[ERRO] sem padrao: " .. e.name)
    end
  end
end

print("---")

-- ---------------------------------------------------------------- job

-- Retorna true se o job ainda ocupa a vaga (em andamento)
local function trackJob(name, job)
  local stamp = os.date("%H:%M:%S")

  if jcall(job, "isDone") == true then
    print(string.format("[%s] pronto: %s", stamp, shortName(name)))
    jobs[name] = nil
    return false
  end

  if jcall(job, "isCanceled") == true then
    print(string.format("[%s] cancelado: %s", stamp, shortName(name)))
    jobs[name] = nil
    cooldowns[name] = now() + CONFIG.cooldown
    return false
  end

  if jcall(job, "isCalculationNotSuccessful") == true
     or jcall(job, "hasErrorOccurred") == true then
    local why = missingReport(job) or jcall(job, "getDebugMessage") or "motivo desconhecido"
    print(string.format("[%s] FALHOU %s", stamp, shortName(name)))
    print("  faltando: " .. tostring(why))
    jobs[name] = nil
    cooldowns[name] = now() + CONFIG.cooldown
    return false
  end

  return true  -- calculando ou craftando
end

-- ---------------------------------------------------------------- loop

while true do
  local free = countFreeCPUs() - CONFIG.reserveCPU
  local t = now()

  for _, e in ipairs(CONFIG.items) do
    local busy = false

    if jobs[e.name] then
      busy = trackJob(e.name, jobs[e.name])
      if busy then free = free - 1 end
    end

    if not busy then
      local have = stockOf(e.name)
      if have >= e.min then
        cooldowns[e.name] = nil
      elseif free > 0 and (not cooldowns[e.name] or t > cooldowns[e.name]) then
        local count = math.min(e.batch, e.min - have)
        local job = requestCraft(e.name, count)
        if job then
          jobs[e.name] = job
          free = free - 1
          print(string.format("[%s] pedido: %d x %s (%d/%d)",
            os.date("%H:%M:%S"), count, shortName(e.name), have, e.min))
        else
          print(string.format("[%s] recusado: %s",
            os.date("%H:%M:%S"), shortName(e.name)))
          cooldowns[e.name] = t + CONFIG.cooldown
        end
      end
    end
  end

  sleep(CONFIG.interval)
end
