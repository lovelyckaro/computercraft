local storage = require("storage")

local index, loadError = storage.loadIndex()
if not index then
  print("Could not load storage index: " .. loadError)
  return
end

local summary = storage.indexSummary(index)

if index.trusted then
  print("Index: trusted")
else
  print("Index: UNTRUSTED - run reconcile")
end

print("Registered chests: " .. summary.registeredChests .. " (" .. summary.connectedChests .. " connected)")
print("Slots: " .. summary.totalSlots .. " total, " .. summary.occupiedSlots .. " occupied, " .. summary.emptySlots .. " empty")
print("Indexed items: " .. summary.itemCount .. " across " .. summary.itemTypes .. " item types")
print("Partial-stack capacity: " .. summary.partialCapacity)

if #summary.missingChests > 0 then
  print("Missing registered chests:")
  for _, name in ipairs(summary.missingChests) do
    print("  " .. name)
  end
end
