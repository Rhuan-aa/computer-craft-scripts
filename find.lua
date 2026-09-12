-- find.lua -- procura itens na rede ME pelo nome
-- uso: find cable

local termo = ...
if not termo then print("uso: find <texto>") return end
termo = termo:lower()

local bridge = peripheral.find("me_bridge") or peripheral.find("meBridge")
if not bridge then error("ME Bridge nao encontrado.") end

print("consultando a rede...")
local ok, items = pcall(bridge.getItems)
if not ok or type(items) ~= "table" then
  error("getItems falhou: " .. tostring(items))
end

local linhas = {}
for _, i in ipairs(items) do
  local n = tostring(i.name or "")
  local d = tostring(i.displayName or "")
  if n:lower():find(termo, 1, true) or d:lower():find(termo, 1, true) then
    linhas[#linhas + 1] = string.format("%-42s %6d  %s",
      n, i.count or 0, i.isCraftable and "craftavel" or "")
  end
end

if #linhas == 0 then
  print("nada para '" .. termo .. "'  (rede tem " .. #items .. " itens)")
  return
end

table.sort(linhas)
print(#linhas .. " resultado(s) de " .. #items .. " na rede:")
textutils.pagedPrint(table.concat(linhas, "\n"))
