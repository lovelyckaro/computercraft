local storage = require("storage")

local index, loadError = storage.loadIndex()
if not index then
  print("Could not load storage index: " .. loadError)
  return
end

local changed = storage.import(index, storage.beginTransaction)
if changed and index.trusted then
  local saved, saveError = storage.completeTransaction(index)
  if not saved then
    print("Could not save completed storage index: " .. saveError)
    print("Storage index remains untrusted. Run reconcile before importing again.")
  end
end
