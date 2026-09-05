local storage = require("storage")

local function matches(item, query)
  if query == "" then
    return true
  end

  local displayName = item.displayName or item.name
  return item.name:lower():find(query, 1, true) ~= nil
    or displayName:lower():find(query, 1, true) ~= nil
end

local function itemLine(item, countWidth)
  local count = ("%" .. countWidth .. "d"):format(item.total)
  local displayName = item.displayName or item.name
  local variant = item.nbt and " [NBT]" or ""
  local text = count .. " x " .. displayName .. " (" .. item.name .. ")" .. variant
  local textColours = string.rep(colors.toBlit(colors.green), #count)
    .. string.rep(colors.toBlit(colors.white), #(" x " .. displayName))
    .. string.rep(colors.toBlit(colors.lightGray), #(" (" .. item.name .. ")" .. variant))
  return text, textColours
end

local function fitToWidth(text, width)
  if #text <= width then
    return text
  end

  if width <= 3 then
    return string.rep(".", width)
  end

  return text:sub(1, width - 3) .. "..."
end

local function printItem(item, countWidth, width)
  local text, textColours = itemLine(item, countWidth)
  local fittedText = fitToWidth(text, width)
  local fittedColours = textColours:sub(1, #fittedText)

  local textColour = term.getTextColour()
  local backgroundColour = term.getBackgroundColour()
  term.blit(fittedText, fittedColours, string.rep(colors.toBlit(backgroundColour), #fittedText))
  term.setTextColour(textColour)
  term.setBackgroundColour(backgroundColour)
  print()
end

local query = table.concat({ ... }, " "):lower()
local index, loadError = storage.loadIndex()
if not index then
  print("Could not load storage index: " .. loadError)
  return
end

if not index.trusted then
  print("Storage index is untrusted. Run reconcile before listing items.")
  return
end

local results = {}
for _, item in pairs(index.items) do
  if matches(item, query) then
    table.insert(results, item)
  end
end

table.sort(results, function(a, b)
  if a.total ~= b.total then
    return a.total > b.total
  end

  local aDisplay = (a.displayName or a.name):lower()
  local bDisplay = (b.displayName or b.name):lower()
  if aDisplay ~= bDisplay then
    return aDisplay < bDisplay
  end

  if a.name ~= b.name then
    return a.name < b.name
  end

  return (a.nbt or "") < (b.nbt or "")
end)

if #results == 0 then
  print("No matching items.")
  return
end

local width, height = term.getSize()
local pageSize = math.max(1, height - 1)
local countWidth = #tostring(results[1].total)
local displayed = 0

for _, item in ipairs(results) do
  printItem(item, countWidth, width)
  displayed = displayed + 1

  if displayed < #results and displayed % pageSize == 0 then
    print(fitToWidth("Press any key for next page; Q to stop.", width))
    local _, key = os.pullEvent("key")
    if key == keys.q then
      print("Displayed " .. displayed .. " of " .. #results .. " matching items.")
      return
    end
  end
end

print("Displayed " .. displayed .. " matching item(s).")
