local storage = require("storage")

local query = table.concat({ ... }, " "):lower()
local index, loadError = storage.loadIndex()
if not index then
  print("Could not load storage index: " .. loadError)
  return
end

storage.printList(index, query)
