local storage = require("storage")

local index, loadError = storage.loadIndexForReconcile()
if not index then
  print("Could not load storage index: " .. loadError)
  print("Restore a valid index backup, or remove the invalid index and run register.")
  return
end

if not storage.reconcile(index) then
  return
end

local saved, saveError = storage.saveIndex(index)
if not saved then
  print("Could not save reconciled storage index: " .. saveError)
  return
end
