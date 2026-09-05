local storage = require("storage")

local index, loadError = storage.loadIndex()
if not index then
  print("Could not load storage index: " .. loadError)
  return
end

local names = storage.discoverChests(index)
if #names == 0 then
  print("No unregistered storage chests found.")
  return
end

local registered = 0
for _, name in ipairs(names) do
  local inventory, scanError = storage.scanChest(name)
  if not inventory then
    print("Skipped " .. name .. ": " .. scanError)
  else
    storage.addInventory(index, name, inventory)
    registered = registered + 1
    print("Registered " .. name .. " (" .. inventory.size .. " slots).")
  end
end

if registered == 0 then
  print("No storage chests were registered.")
  return
end

local saved, saveError = storage.saveIndex(index)
if not saved then
  print("Could not save storage index: " .. saveError)
  return
end

print("Registered " .. registered .. " storage chest(s).")
