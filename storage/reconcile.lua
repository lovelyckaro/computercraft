local storage = require("storage")

local index, loadError = storage.loadIndexForReconcile()
if not index then
  print("Could not load storage index: " .. loadError)
  print("Restore a valid index backup, or remove the invalid index and run register.")
  return
end

local names = storage.registeredChests(index)
if #names == 0 then
  print("No storage chests are registered. Run register first.")
  return
end

local inventories = {}
local failures = {}

for _, name in ipairs(names) do
  local inventory, scanError = storage.scanChest(name)
  if inventory then
    inventories[name] = inventory
  else
    table.insert(failures, name .. ": " .. scanError)
  end
end

if #failures > 0 then
  print("Reconciliation failed; the existing inventory records were kept.")
  for _, failure in ipairs(failures) do
    print("  " .. failure)
  end

  if index.trusted then
    index.trusted = false
    local saved, saveError = storage.saveIndex(index)
    if not saved then
      print("Could not mark storage index untrusted: " .. saveError)
    end
  end
  return
end

storage.replaceInventories(index, inventories)
index.trusted = true

local saved, saveError = storage.saveIndex(index)
if not saved then
  print("Could not save reconciled storage index: " .. saveError)
  return
end

local summary = storage.indexSummary(index)
print("Reconciled " .. summary.registeredChests .. " storage chest(s).")
print("Slots: " .. summary.totalSlots .. " total, " .. summary.occupiedSlots .. " occupied, " .. summary.emptySlots .. " empty")
print("Indexed items: " .. summary.itemCount .. " across " .. summary.itemTypes .. " item types")
