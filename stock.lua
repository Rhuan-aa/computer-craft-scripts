-- stock.lua -- Mantenedor de estoque AE2 via ME Bridge
-- ATM10 7.3 / CC:Tweaked 1.113.1 / Advanced Peripherals 0.7.62b / AE2 19.2.17

local VERSION = "v6 -- trava anti-loop + CPU_BUSY"

local CONFIG = {
  interval   = 10,
  cpuName    = "StockCPU",  -- nil = deixa o AE2 escolher
  retryBusy  = 20,          -- espera curta quando a CPU esta ocupada
  retryFail  = 300,         -- espera longa quando falta ingrediente
  reserveCPU = 1,
  fallbackCPUs = 2,
  maxStrikes = 2,           -- crafts que concluem sem aumentar o estoque
  dryRun     = false,       -- true = so registra, nao pede craft

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

local hasCPUs = bridge.getCraftingCPUs ~= nil
local cpuName = CONFIG.cpuName

local jobs      = {}  -- name -> job em andamento
local baseline  = {}  -- name -> estoque no momento do pedido
local cooldowns = {}  -- name -> timestamp de liberacao
local strikes   = {}  -- name -> crafts concluidos sem efeito
local disabled  = {}  -- name -> true (desistiu deste item)

local function now() return os.epoch("utc") / 1000 end
local function stamp() return os.date("%H:%M:%S") end

local function safe(fn, ...)
  if type(fn) ~= "function" then return nil end
  local ok, res = pcall(fn, ...)
  if ok then return res end
  return nil
end

local function jcall(job, method, ...)
  if not job then return nil end
  return safe(job[method], ...)
end

local function shortName(id) return (tostring(id):gsub("^.-:", "")) end

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
  if type(r) ~= "table" then r = safe(bridge.craftItem, item) end
  return (type(r) == "table") and r or nil
end

local function missingReport(job)
  local miss = jcall(job, "getMissingItems")
  if type(miss) ~= "table" or #miss == 0 then return nil end
  local parts = {}
  for i = 1, math.min(#miss, 4) do
    local m = miss[i]
    parts[#parts + 1] = string.format("%s x%s",
      shortName(m.name or m.displayName or "?"),
      tostring(m.amount or m.count or "?"))
  end
  if #miss > 4 then parts[#parts + 1] = "(+" .. (#miss - 4) .. ")" end
  return table.concat(parts, ", ")
end

-- ---------------------------------------------------------------- boot

term.clear(); term.setCursorPos(1, 1)
print("Stock keeper " .. VERSION)
print(#CONFIG.items .. " itens" .. (CONFIG.dryRun and "  [DRY RUN]" or ""))

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

-- Checagem de sanidade: ID que le zero e suspeito de estar errado
for _, e in ipairs(CONFIG.items) do
  local have = stockOf(e.name)
  local craftable = safe(bridge.isCraftable, { name = e.name })
  print(string.format("  %-28s estoque=%-6d padrao=%s",
    shortName(e.name), have, tostring(craftable)))
end

print("---")

-- ---------------------------------------------------------------- job

-- true = job ainda ocupando vaga
local function trackJob(name, job)
  if jcall(job, "isDone") == true then
    jobs[name] = nil
    local have = stockOf(name)
    if have > (baseline[name] or 0) then
      strikes[name] = 0
      print(string.format("[%s] pronto: %s (%d)", stamp(), shortName(name), have))
    else
      -- Craft concluiu mas o estoque nao subiu: o ID nao casa com a rede.
      strikes[name] = (strikes[name] or 0) + 1
      print(string.format("[%s] SUSPEITO %s: craft concluiu, estoque segue %d",
        stamp(), shortName(name), have))
      if strikes[name] >= CONFIG.maxStrikes then
        disabled[name] = true
        print("  >> DESATIVADO. O ID provavelmente esta errado.")
        print("  >> rode: find " .. shortName(name))
      end
    end
    return false
  end

  if jcall(job, "isCanceled") == true then
    jobs[name] = nil
    cooldowns[name] = now() + CONFIG.retryBusy
    print(string.format("[%s] cancelado: %s", stamp(), shortName(name)))
    return false
  end

  if jcall(job, "isCalculationNotSuccessful") == true
     or jcall(job, "hasErrorOccurred") == true then
    jobs[name] = nil
    local msg  = tostring(jcall(job, "getDebugMessage") or "")
    local miss = missingReport(job)

    if msg:find("CPU_BUSY") or msg:find("BUSY") then
      cooldowns[name] = now() + CONFIG.retryBusy
      -- silencioso: CPU ocupada e situacao normal, nao falha
    else
      cooldowns[name] = now() + CONFIG.retryFail
      print(string.format("[%s] FALHOU %s -> %s",
        stamp(), shortName(name), miss or msg or "motivo desconhecido"))
    end
    return false
  end

  return true
end

-- ---------------------------------------------------------------- loop

while true do
  local free = countFreeCPUs() - CONFIG.reserveCPU
  local t = now()

  for _, e in ipairs(CONFIG.items) do
    if not disabled[e.name] then
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
          if CONFIG.dryRun then
            print(string.format("[%s] (dry) pediria %d x %s (%d/%d)",
              stamp(), count, shortName(e.name), have, e.min))
            cooldowns[e.name] = t + CONFIG.retryFail
          else
            baseline[e.name] = have
            local job = requestCraft(e.name, count)
            if job then
              jobs[e.name] = job
              free = free - 1
              print(string.format("[%s] pedido: %d x %s (%d/%d)",
                stamp(), count, shortName(e.name), have, e.min))
            else
              cooldowns[e.name] = t + CONFIG.retryFail
              print(string.format("[%s] recusado: %s", stamp(), shortName(e.name)))
            end
          end
        end
      end
    end
  end

  sleep(CONFIG.interval)
end
