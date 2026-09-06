local storage = {}

local INDEX_VERSION = 2
local INBOX_NAME = "minecraft:barrel_0"
local OUTBOX_NAME = "minecraft:barrel_1"
local programDirectory = fs.getDir(shell.getRunningProgram())
local indexPath = fs.combine(programDirectory, "index")
local backupPath = indexPath .. ".bak"
local temporaryPath = indexPath .. ".tmp"
local serviceMarkerPath = fs.combine(programDirectory, "service.running")

local function locationKey(name, slot)
  return name .. ":" .. slot
end

function storage.itemKey(item)
  return item.name .. "#" .. (item.nbt or "")
end

function storage.slotRecord(item, detail, count)
  return {
    key = storage.itemKey(item),
    name = item.name,
    nbt = item.nbt,
    displayName = detail.displayName,
    count = count or item.count,
    maxCount = detail.maxCount,
  }
end

local function roleInventory(name, label)
  if not peripheral.isPresent(name) then
    return nil, label .. " barrel is not connected: " .. name
  end

  if not peripheral.hasType(name, "minecraft:barrel") or not peripheral.hasType(name, "inventory") then
    return nil, label .. " is not an inventory barrel: " .. name
  end

  local inventory = peripheral.wrap(name)
  if not inventory or type(inventory.size) ~= "function" or type(inventory.list) ~= "function" or type(inventory.getItemDetail) ~= "function" or type(inventory.getItemLimit) ~= "function" or type(inventory.pushItems) ~= "function" then
    return nil, label .. " barrel does not provide the required inventory methods: " .. name
  end

  return inventory
end

function storage.getInbox()
  return roleInventory(INBOX_NAME, "inbox")
end

function storage.getOutbox()
  return roleInventory(OUTBOX_NAME, "outbox")
end

function storage.outboxName()
  return OUTBOX_NAME
end

function storage.newIndex()
  return {
    version = INDEX_VERSION,
    trusted = true,
    inventories = {},
    items = {},
    mergeTargets = {},
    emptySlots = {},
  }
end

local function validIndex(index)
  return type(index.trusted) == "boolean"
    and type(index.inventories) == "table"
    and type(index.items) == "table"
    and type(index.mergeTargets) == "table"
    and type(index.emptySlots) == "table"
end

local function readIndex(path, allowLegacy)
  local handle, openError = fs.open(path, "r")
  if not handle then
    return nil, openError
  end

  local contents = handle.readAll()
  handle.close()

  local index = textutils.unserialize(contents)
  if type(index) ~= "table" then
    return nil, "index file is not valid serialized data"
  end

  if index.version == 1 and allowLegacy and type(index.trusted) == "boolean" and type(index.inventories) == "table" then
    return index
  end

  if index.version ~= INDEX_VERSION or not validIndex(index) then
    if index.version == 1 then
      return nil, "storage index version 1 requires reconcile"
    end
    return nil, "index file has an unsupported format"
  end

  return index
end

function storage.loadIndex()
  if not fs.exists(indexPath) and fs.exists(backupPath) then
    local restored, restoreError = pcall(fs.move, backupPath, indexPath)
    if not restored then
      return nil, "could not restore index backup: " .. tostring(restoreError)
    end
  end

  if not fs.exists(indexPath) then
    return storage.newIndex()
  end

  return readIndex(indexPath)
end

function storage.loadIndexForReconcile()
  if not fs.exists(indexPath) and fs.exists(backupPath) then
    local restored, restoreError = pcall(fs.move, backupPath, indexPath)
    if not restored then
      return nil, "could not restore index backup: " .. tostring(restoreError)
    end
  end

  if not fs.exists(indexPath) then
    return nil, "storage index does not exist; run register first"
  end

  return readIndex(indexPath, true)
end

function storage.saveIndex(index)
  local handle, openError = fs.open(temporaryPath, "w")
  if not handle then
    return nil, openError
  end

  handle.write(textutils.serialize(index))
  handle.close()

  if fs.exists(backupPath) then
    fs.delete(backupPath)
  end

  if fs.exists(indexPath) then
    local moved, moveError = pcall(fs.move, indexPath, backupPath)
    if not moved then
      fs.delete(temporaryPath)
      return nil, "could not create index backup: " .. tostring(moveError)
    end
  end

  local replaced, replaceError = pcall(fs.move, temporaryPath, indexPath)
  if not replaced then
    if fs.exists(backupPath) and not fs.exists(indexPath) then
      fs.move(backupPath, indexPath)
    end
    return nil, "could not replace index: " .. tostring(replaceError)
  end

  if fs.exists(backupPath) then
    fs.delete(backupPath)
  end

  return true
end

function storage.serviceIsRunning()
  return fs.exists(serviceMarkerPath)
end

function storage.startService()
  if storage.serviceIsRunning() then
    return nil, "storage service is already running or stopped uncleanly"
  end

  local handle, openError = fs.open(serviceMarkerPath, "w")
  if not handle then
    return nil, "could not create service marker: " .. openError
  end
  handle.close()
  return true
end

function storage.stopService()
  if fs.exists(serviceMarkerPath) then
    fs.delete(serviceMarkerPath)
  end

  if fs.exists(serviceMarkerPath) then
    return nil, "could not remove service marker"
  end
  return true
end

function storage.beginTransaction(index)
  index.trusted = false
  local saved, saveError = storage.saveIndex(index)
  if saved then
    return true
  end

  index.trusted = true
  return nil, saveError
end

function storage.completeTransaction(index)
  index.trusted = true
  return storage.saveIndex(index)
end

function storage.isChest(name)
  return name ~= "left" and name ~= "right"
    and peripheral.isPresent(name)
    and peripheral.hasType(name, "minecraft:chest")
end

function storage.discoverChests(index)
  local names = {}

  for _, name in ipairs(peripheral.getNames()) do
    if not index.inventories[name] and storage.isChest(name) then
      table.insert(names, name)
    end
  end

  table.sort(names)
  return names
end

function storage.scanChest(name)
  if not storage.isChest(name) then
    return nil, "not a connected storage chest: " .. name
  end

  local chest = peripheral.wrap(name)
  if not chest or type(chest.size) ~= "function" or type(chest.list) ~= "function" or type(chest.getItemDetail) ~= "function" then
    return nil, "chest does not provide the required inventory methods: " .. name
  end

  local sized, size = pcall(chest.size)
  if not sized or type(size) ~= "number" then
    return nil, "could not read inventory size for " .. name .. ": " .. tostring(size)
  end

  local listedOk, listed = pcall(chest.list)
  if not listedOk or type(listed) ~= "table" then
    return nil, "could not list inventory contents for " .. name .. ": " .. tostring(listed)
  end

  local inventory = {
    size = size,
    emptyCount = 0,
    slots = {},
  }

  for slot = 1, size do
    local basic = listed[slot]
    if not basic then
      inventory.slots[slot] = false
      inventory.emptyCount = inventory.emptyCount + 1
    else
      local detailed, detail = pcall(chest.getItemDetail, slot)
      if not detailed or not detail or type(detail.maxCount) ~= "number" then
        return nil, "could not read item details for " .. name .. " slot " .. slot
      end

      inventory.slots[slot] = storage.slotRecord(basic, detail)
    end
  end

  return inventory
end

local function addSlotLookup(index, name, slot, record)
  local inventory = index.inventories[name]
  local location = locationKey(name, slot)

  if record == false then
    inventory.emptyCount = inventory.emptyCount + 1
    index.emptySlots[location] = true
    return
  end

  local item = index.items[record.key]
  if not item then
    item = {
      name = record.name,
      nbt = record.nbt,
      displayName = record.displayName,
      maxCount = record.maxCount,
      total = 0,
      locations = {},
    }
    index.items[record.key] = item
  end

  item.total = item.total + record.count
  item.locations[location] = record.count

  local remaining = record.maxCount - record.count
  if remaining > 0 then
    local targets = index.mergeTargets[record.key] or {}
    targets[location] = remaining
    index.mergeTargets[record.key] = targets
  end
end

local function removeSlotLookup(index, name, slot, record)
  local inventory = index.inventories[name]
  local location = locationKey(name, slot)

  if record == false then
    inventory.emptyCount = inventory.emptyCount - 1
    index.emptySlots[location] = nil
    return
  end

  local item = index.items[record.key]
  item.total = item.total - record.count
  item.locations[location] = nil
  if item.total == 0 then
    index.items[record.key] = nil
  end

  local targets = index.mergeTargets[record.key]
  if targets then
    targets[location] = nil
    if not next(targets) then
      index.mergeTargets[record.key] = nil
    end
  end
end

function storage.rebuildLookups(index)
  index.items = {}
  index.mergeTargets = {}
  index.emptySlots = {}

  for _, inventory in pairs(index.inventories) do
    inventory.emptyCount = 0
  end

  for name, inventory in pairs(index.inventories) do
    for slot = 1, inventory.size do
      addSlotLookup(index, name, slot, inventory.slots[slot])
    end
  end
end

function storage.addInventory(index, name, inventory)
  index.inventories[name] = inventory
  inventory.emptyCount = 0

  for slot = 1, inventory.size do
    addSlotLookup(index, name, slot, inventory.slots[slot])
  end
end

function storage.register(index)
  local names = storage.discoverChests(index)
  if #names == 0 then
    print("No unregistered storage chests found.")
    return false
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
    return false
  end

  print("Registered " .. registered .. " storage chest(s).")
  return true
end

function storage.registeredChests(index)
  local names = {}

  for name in pairs(index.inventories) do
    table.insert(names, name)
  end

  table.sort(names)
  return names
end

function storage.replaceInventories(index, inventories)
  index.inventories = inventories
  index.version = INDEX_VERSION
  storage.rebuildLookups(index)
end

function storage.reconcile(index)
  local names = storage.registeredChests(index)
  if #names == 0 then
    print("No storage chests are registered. Run register first.")
    return false
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
      return true
    end
    return false
  end

  storage.replaceInventories(index, inventories)
  index.trusted = true

  local summary = storage.indexSummary(index)
  print("Reconciled " .. summary.registeredChests .. " storage chest(s).")
  print("Slots: " .. summary.totalSlots .. " total, " .. summary.occupiedSlots .. " occupied, " .. summary.emptySlots .. " empty")
  print("Indexed items: " .. summary.itemCount .. " across " .. summary.itemTypes .. " item types")
  return true
end

function storage.validateRegisteredChests(index)
  local missing = {}

  for _, name in ipairs(storage.registeredChests(index)) do
    if not storage.isChest(name) then
      table.insert(missing, name)
    end
  end

  if #missing > 0 then
    return nil, missing
  end

  return true
end

function storage.anyLocation(locations)
  local location = next(locations)
  if not location then
    return nil
  end

  local name, slot = location:match("^(.*):(%d+)$")
  return {
    name = name,
    slot = tonumber(slot),
  }
end

function storage.setSlot(index, name, slot, record)
  local inventory = index.inventories[name]
  local previous = inventory.slots[slot]

  removeSlotLookup(index, name, slot, previous)
  inventory.slots[slot] = record
  addSlotLookup(index, name, slot, record)
end

function storage.searchItems(index, query)
  local results = {}
  local normalizedQuery = query:lower()

  for _, item in pairs(index.items) do
    local displayName = item.displayName or item.name
    if normalizedQuery == "" or item.name:lower():find(normalizedQuery, 1, true) or displayName:lower():find(normalizedQuery, 1, true) then
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

  return results
end

function storage.indexSummary(index)
  local summary = {
    registeredChests = 0,
    connectedChests = 0,
    missingChests = {},
    totalSlots = 0,
    emptySlots = 0,
    occupiedSlots = 0,
    partialSlots = 0,
    fullSlots = 0,
    itemTypes = 0,
    itemCount = 0,
    partialCapacity = 0,
  }

  for name, inventory in pairs(index.inventories) do
    summary.registeredChests = summary.registeredChests + 1
    summary.totalSlots = summary.totalSlots + inventory.size
    summary.emptySlots = summary.emptySlots + inventory.emptyCount

    if storage.isChest(name) then
      summary.connectedChests = summary.connectedChests + 1
    else
      table.insert(summary.missingChests, name)
    end
  end

  summary.occupiedSlots = summary.totalSlots - summary.emptySlots

  for _, item in pairs(index.items) do
    summary.itemTypes = summary.itemTypes + 1
    summary.itemCount = summary.itemCount + item.total
  end

  for _, targets in pairs(index.mergeTargets) do
    for _, remaining in pairs(targets) do
      summary.partialSlots = summary.partialSlots + 1
      summary.partialCapacity = summary.partialCapacity + remaining
    end
  end

  summary.fullSlots = summary.occupiedSlots - summary.partialSlots
  table.sort(summary.missingChests)
  return summary
end

local function drawCapacityBar(summary)
  if summary.totalSlots == 0 then
    print("Capacity: no registered slots")
    return
  end

  local width = term.getSize()
  local segments = {
    { amount = summary.fullSlots, colour = colors.red, remainder = 0, width = 0 },
    { amount = summary.partialSlots, colour = colors.yellow, remainder = 0, width = 0 },
    { amount = summary.emptySlots, colour = colors.green, remainder = 0, width = 0 },
  }
  local assigned = 0

  for _, segment in ipairs(segments) do
    local exactWidth = segment.amount * width / summary.totalSlots
    segment.width = math.floor(exactWidth)
    segment.remainder = exactWidth - segment.width
    assigned = assigned + segment.width
  end

  for _ = assigned + 1, width do
    local chosen = segments[1]
    for _, segment in ipairs(segments) do
      if segment.remainder > chosen.remainder then
        chosen = segment
      end
    end
    chosen.width = chosen.width + 1
    chosen.remainder = -1
  end

  local textColour = term.getTextColour()
  local backgroundColour = term.getBackgroundColour()
  term.blit(string.rep(" ", width), string.rep(colors.toBlit(textColour), width), (string.rep(colors.toBlit(colors.red), segments[1].width) .. string.rep(colors.toBlit(colors.yellow), segments[2].width) .. string.rep(colors.toBlit(colors.green), segments[3].width)))
  term.setTextColour(textColour)
  term.setBackgroundColour(backgroundColour)
  print()
end

function storage.printStatus(index)
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

  drawCapacityBar(summary)
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
  local count = ("%" .. countWidth .. "d"):format(item.total)
  local displayName = item.displayName or item.name
  local variant = item.nbt and " [NBT]" or ""
  local text = count .. " x " .. displayName .. " (" .. item.name .. ")" .. variant
  local textColours = string.rep(colors.toBlit(colors.green), #count)
    .. string.rep(colors.toBlit(colors.white), #(" x " .. displayName))
    .. string.rep(colors.toBlit(colors.lightGray), #(" (" .. item.name .. ")" .. variant))
  local fittedText = fitToWidth(text, width)
  local textColour = term.getTextColour()
  local backgroundColour = term.getBackgroundColour()
  term.blit(fittedText, textColours:sub(1, #fittedText), string.rep(colors.toBlit(backgroundColour), #fittedText))
  term.setTextColour(textColour)
  term.setBackgroundColour(backgroundColour)
  print()
end

function storage.printList(index, query, waitForNextPage)
  if not index.trusted then
    print("Storage index is untrusted. Run reconcile before listing items.")
    return
  end

  local results = storage.searchItems(index, query or "")
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
      local continue = waitForNextPage and waitForNextPage() or select(2, os.pullEvent("key")) ~= keys.q
      if not continue then
        print("Displayed " .. displayed .. " of " .. #results .. " matching items.")
        return
      end
    end
  end

  print("Displayed " .. displayed .. " matching item(s).")
end

return storage
