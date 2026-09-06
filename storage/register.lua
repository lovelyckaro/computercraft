local storage = require("storage")

local index, loadError = storage.loadIndex()
if not index then
  print("Could not load storage index: " .. loadError)
  return
end

if not storage.register(index) then
  return
end

local saved, saveError = storage.saveIndex(index)
if not saved then
  print("Could not save storage index: " .. saveError)
  return
end
