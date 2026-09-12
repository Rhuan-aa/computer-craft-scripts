-- stock.lua -- Mantenedor de estoque AE2 + painel no monitor
-- ATM10 7.3 / CC:Tweaked 1.113.1 / Advanced Peripherals 0.7.62b / AE2 19.2.17

local VERSION = "v8 -- monitor + toque"

local CONFIG = {
  interval   = 10,
  cpuName    = "StockCPU",
  retryBusy  = 20,
  retryFail  = 300,
  reserveCPU = 1,
  fallbackCPUs = 2,
  maxStrikes = 2,
  dryRun     = false,

  monitorScale = 0.5,
  showExternal = true,   -- barras dos bauS via storage bus
  autoRefresh  = 0,      -- 0 = so no toque; ou segundos (ex: 300)

  items = {
    { name = "ae2:fluix_smart_cable",           min = 64, batch = 32 },
    { name = "ae2:logic_processor",             min = 16,  batch = 8  },
    { name = "ae2:calculation_processor",       min = 16,  batch = 8  },
    { name = "ae2:engineering_processor",       min = 16,  batch = 8  },
    { name = "extendedae:concurrent_processor", min = 16,  batch = 8  },
    { name = "ae2:formation_core",       	min = 8,  batch = 8  },
    { name = "ae2:annihilation_core",       	min = 8,  batch = 8  },
  },
}

-- ---------------------------------------------------------------- setup

local bridge = peripheral.find("me_bridge") or peripheral.find("meBridge")
if not bridge then error("ME Bridge nao encontrado.") end

local mon = peripheral.find("monitor")
if mon then mon.setTextScale(CONFIG.monitorScale) end

local hasCPUs = bridge.getCraftingCPUs ~= nil
local cpuName = CONFIG.cpuName

local jobs, baseline, cooldowns, strikes, disabled = {}, {}, {}, {}, {}

-- Estado compartilhado entre o loop de estoque e o painel
local ui = {
  rows        = {},   -- { name, have, min, status }
  storage     = nil,
  lastRefresh = nil,
  lastCycle   = nil,
}

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

local function amountOf(item)
  if type(item) ~= "table" then return 0 end
  return item.count or item.amount or 0
end

local function stockOf(name)
  return amountOf(safe(bridge.getItem, { name = name }))
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
  for i = 1, math.min(#miss, 3) do
    local m = miss[i]
    parts[#parts + 1] = string.format("%s x%s",
      shortName(m.name or m.displayName or "?"),
      tostring(m.count or m.amount or "?"))
  end
  if #miss > 3 then parts[#parts + 1] = "(+" .. (#miss - 3) .. ")" end
  return table.concat(parts, ", ")
end

-- ------------------------------------------------------ armazenamento

-- Consulta cara: so roda no toque ou no autoRefresh.
local function readStorage()
  local function pair(usedFn, totalFn)
    local u, t = safe(usedFn), safe(totalFn)
    if type(u) ~= "number" or type(t) ~= "number" or t <= 0 then return nil end
    return { used = u, total = t, pct = u / t * 100 }
  end

  local s = {
    itens   = pair(bridge.getUsedItemStorage,  bridge.getTotalItemStorage),
    fluidos = pair(bridge.getUsedFluidStorage, bridge.getTotalFluidStorage),
  }
  if CONFIG.showExternal then
    s.itensExt = pair(bridge.getUsedExternalItemStorage,
                      bridge.getTotalExternalItemStorage)
    s.fluidExt = pair(bridge.getUsedExternalFluidStorage,
                      bridge.getTotalExternalFluidStorage)
  end
  ui.storage = s
  ui.lastRefresh = stamp()
end

-- ---------------------------------------------------------------- painel

local function human(n)
  if n >= 1e9 then return string.format("%.1fG", n / 1e9) end
  if n >= 1e6 then return string.format("%.1fM", n / 1e6) end
  if n >= 1e3 then return string.format("%.1fk", n / 1e3) end
  return tostring(math.floor(n))
end

local function pctColor(p)
  if p >= 90 then return colors.red end
  if p >= 70 then return colors.orange end
  return colors.lime
end

local function drawBar(y, label, data, width)
  mon.setCursorPos(1, y)
  mon.setTextColor(colors.lightGray)
  mon.write(string.format("%-8s", label:sub(1, 8)))

  if not data then
    mon.setTextColor(colors.gray)
    mon.write("indisponivel")
    return
  end

  local barW = math.max(6, width - 26)
  local fill = math.floor(barW * math.min(data.pct, 100) / 100 + 0.5)

  mon.setTextColor(colors.gray); mon.write("[")
  mon.setTextColor(pctColor(data.pct))
  mon.write(string.rep("|", fill))
  mon.setTextColor(colors.gray)
  mon.write(string.rep(".", barW - fill) .. "] ")

  mon.setTextColor(pctColor(data.pct))
  mon.write(string.format("%3d%% ", math.floor(data.pct)))
  mon.setTextColor(colors.lightGray)
  mon.write(human(data.used) .. "/" .. human(data.total))
end

local statusColor = {
  ok         = colors.lime,
  craftando  = colors.cyan,
  calculando = colors.cyan,
  esperando  = colors.orange,
  faltando   = colors.red,
  off        = colors.gray,
}

local function draw()
  if not mon then return end
  local w, h = mon.getSize()

  mon.setBackgroundColor(colors.black)
  mon.clear()

  mon.setCursorPos(1, 1)
  mon.setTextColor(colors.white)
  mon.write("AE2 STOCK")
  mon.setCursorPos(w - #VERSION + 1, 1)
  mon.setTextColor(colors.gray)
  mon.write(VERSION)

  local y = 3
  local s = ui.storage
  if s then
    drawBar(y, "Itens", s.itens, w);   y = y + 1
    if CONFIG.showExternal then
      drawBar(y, "Bau", s.itensExt, w); y = y + 1
    end
    drawBar(y, "Fluidos", s.fluidos, w); y = y + 1
    if CONFIG.showExternal and s.fluidExt then
      drawBar(y, "Bau fl.", s.fluidExt, w); y = y + 1
    end
  else
    mon.setCursorPos(1, y)
    mon.setTextColor(colors.gray)
    mon.write("toque para ler o armazenamento")
    y = y + 1
  end

  y = y + 1
  mon.setCursorPos(1, y)
  mon.setTextColor(colors.gray)
  mon.write(string.rep("-", w))
  y = y + 1

  mon.setCursorPos(1, y)
  mon.setTextColor(colors.white)
  mon.write("REESTOCANDO")
  y = y + 1

  for _, r in ipairs(ui.rows) do
    if y >= h then break end
    mon.setCursorPos(1, y)
    mon.setTextColor(colors.lightGray)
    mon.write(shortName(r.name):sub(1, math.max(10, w - 20)))

    mon.setCursorPos(math.max(12, w - 19), y)
    local full = r.have >= r.min
    mon.setTextColor(full and colors.lime or colors.yellow)
    mon.write(string.format("%5d/%-5d", r.have, r.min))

    mon.setCursorPos(math.max(24, w - 9), y)
    mon.setTextColor(statusColor[r.status] or colors.white)
    mon.write(r.status:sub(1, 10))
    y = y + 1
  end

  mon.setCursorPos(1, h)
  mon.setTextColor(colors.gray)
  mon.write(("ciclo %s | disco %s | toque=atualizar")
    :format(ui.lastCycle or "--", ui.lastRefresh or "--"):sub(1, w))
end

-- ---------------------------------------------------------------- job

local function trackJob(name, job)
  if jcall(job, "isDone") == true then
    jobs[name] = nil
    local have = stockOf(name)
    if have > (baseline[name] or 0) then
      strikes[name] = 0
      print(("[%s] pronto: %s (%d)"):format(stamp(), shortName(name), have))
    else
      strikes[name] = (strikes[name] or 0) + 1
      print(("[%s] SUSPEITO %s: estoque segue %d"):format(stamp(), shortName(name), have))
      if strikes[name] >= CONFIG.maxStrikes then
        disabled[name] = true
        print("  >> DESATIVADO. rode: find " .. shortName(name))
      end
    end
    return false
  end

  if jcall(job, "isCanceled") == true then
    jobs[name] = nil
    cooldowns[name] = now() + CONFIG.retryBusy
    return false
  end

  if jcall(job, "isCalculationNotSuccessful") == true
     or jcall(job, "hasErrorOccurred") == true then
    jobs[name] = nil
    local msg = tostring(jcall(job, "getDebugMessage") or "")
    if msg:find("BUSY") then
      cooldowns[name] = now() + CONFIG.retryBusy
    else
      cooldowns[name] = now() + CONFIG.retryFail
      print(("[%s] FALHOU %s -> %s"):format(stamp(), shortName(name),
        missingReport(job) or msg or "desconhecido"))
    end
    return false
  end

  return true
end

-- ---------------------------------------------------------------- loops

local function stockLoop()
  while true do
    local free = countFreeCPUs() - CONFIG.reserveCPU
    local t = now()
    local rows = {}

    for _, e in ipairs(CONFIG.items) do
      local status = "ok"

      if disabled[e.name] then
        status = "off"
      else
        local busy = false
        if jobs[e.name] then
          busy = trackJob(e.name, jobs[e.name])
          if busy then
            free = free - 1
            status = (jcall(jobs[e.name], "isCraftingStarted") == true)
              and "craftando" or "calculando"
          end
        end

        if not busy then
          local have = stockOf(e.name)
          if have >= e.min then
            cooldowns[e.name] = nil
          elseif free > 0 and (not cooldowns[e.name] or t > cooldowns[e.name]) then
            local count = math.min(e.batch, e.min - have)
            if CONFIG.dryRun then
              cooldowns[e.name] = t + CONFIG.retryFail
              status = "esperando"
            else
              baseline[e.name] = have
              local job = requestCraft(e.name, count)
              if job then
                jobs[e.name] = job
                free = free - 1
                status = "calculando"
                print(("[%s] pedido: %d x %s (%d/%d)")
                  :format(stamp(), count, shortName(e.name), have, e.min))
              else
                cooldowns[e.name] = t + CONFIG.retryFail
                status = "faltando"
              end
            end
          elseif cooldowns[e.name] then
            status = "esperando"
          end
        end
      end

      rows[#rows + 1] = {
        name = e.name, min = e.min, status = status,
        have = stockOf(e.name),
      }
    end

    ui.rows = rows
    ui.lastCycle = stamp()
    draw()
    sleep(CONFIG.interval)
  end
end

local function uiLoop()
  while true do
    local timeout = (CONFIG.autoRefresh > 0) and CONFIG.autoRefresh or nil
    local timer = timeout and os.startTimer(timeout) or nil
    local ev = { os.pullEvent() }

    if ev[1] == "monitor_touch" or ev[1] == "key" then
      readStorage()
      draw()
    elseif ev[1] == "timer" and timer and ev[2] == timer then
      readStorage()
      draw()
    end
  end
end

-- ---------------------------------------------------------------- boot

term.clear(); term.setCursorPos(1, 1)
print("Stock keeper " .. VERSION)
print(#CONFIG.items .. " itens" .. (mon and "  | monitor ok" or "  | sem monitor"))

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

readStorage()
parallel.waitForAny(stockLoop, uiLoop)
