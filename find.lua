-- find.lua -- procura itens na rede ME pelo nome
-- uso: find cable        (busca parcial, sem diferenciar maiuscula)

local termo = ...
if not termo then print("uso: find <texto>") return end
termo = termo:lower()

local bridge = peripheral.find("me_bridge") or peripheral.find("meBridge")
if not bridge then error("ME Bridge nao encontrado.") end

print("consultando a rede...")
local ok, items = pcall(bridge.listItems)
if not ok or type(items) ~= "table" then
  error("listItems falhou: " .. tostring(items))
end

local hits = {}
for _, i in ipairs(items) do
  local n = tostring(i.name or "")
  local d = tostring(i.displayName or "")
  if n:lower():find(termo, 1, true) or d:lower():find(termo, 1, true) then
    hits[#hits + 1] = i
  end
end

if #hits == 0 then
  print("nada encontrado para: " .. termo)
  print("total de itens na rede: " .. #items)
  return
end

local linhas = {}
for _, i in ipairs(hits) do
  linhas[#linhas + 1] = string.format("%s  x%s", i.name, tostring(i.amount or "?"))
  -- mostra chaves extras (componentes, fingerprint) se existirem
  for k, v in pairs(i) do
    if k ~= "name" and k ~= "amount" and k ~= "displayName"
       and k ~= "tags" and type(v) ~= "table" and type(v) ~= "function" then
      linhas[#linhas + 1] = "    " .. k .. " = " .. tostring(v)
    end
  end
end

print(#hits .. " resultado(s):")
textutils.pagedPrint(table.concat(linhas, "\n"))
