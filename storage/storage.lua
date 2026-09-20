--- Storage module.
-- Functions needed by storage service for handling index, inventories, inbox, outbox etc.
-- @module storage
local storage = {}

--- Type definitions for storage module

--- Unique key for an item, which is a combination of the item name and its NBT data (if any).
---@alias ItemKey string

--- Unique key for an inventory, which is the same as the peripheral name.
--- @alias InventoryName string

--- Unique key for a location, which is a combination of the inventory name and the slot number.
---@alias LocationKey string

--- Information about an item in an inventory, as returned by peripheral.getItemDetail().
--- @class Item
--- @field name string
--- @field nbt string|nil
--- @field count integer
--- @field displayName string?
--- @field maxCount integer?

---@alias ItemDetail Item

---@class InventoryPeripheral
---@field size fun(): integer
---@field list fun(): table<integer, Item>
---@field getItemDetail fun(slot: integer, detailed: boolean?): ItemDetail?
---@field getItemLimit fun(slot: integer): integer
---@field pushItems fun(toName: string, fromSlot: integer, limit: integer?, toSlot: integer?): integer
---@field pullItems fun(fromName: string, fromSlot: integer, limit: integer?, toSlot: integer?): integer

--- Information kept for each item in the index.
---@class ItemRecord
---@field name string
---@field nbt string?
---@field maxCount integer
---@field total integer
---@field locations table<LocationKey, number>

--- Information kept for each slot in an inventory
---@class SlotRecord
---@field key ItemKey
---@field name string
---@field count integer
---@field displayName string
---@field nbt string|nil
---@field maxCount integer

--- Information kept for each registered inventory
---@class InventoryRecord
---@field size integer
---@field emptyCount integer
---@field slots table<number, SlotRecord|false>

--- Main storage index structure, which contains all the information about registered inventories and items. As well as tables for efficient lookup of items.
---@class Index
---@field version number
---@field trusted boolean
---@field inventories table<InventoryName, InventoryRecord>
---@field items table<ItemKey, ItemRecord>
---@field mergeTargets table<ItemKey, table<LocationKey, number>>
---@field emptySlots table<LocationKey, boolean>

-- end of type definitions

local INDEX_VERSION = 2
local INBOX_NAME = "minecraft:barrel_0"
local OUTBOX_NAME = "minecraft:barrel_1"
local programDirectory = fs.getDir(shell.getRunningProgram())
local indexPath = fs.combine(programDirectory, "index")
local backupPath = indexPath .. ".bak"
local temporaryPath = indexPath .. ".tmp"
local serviceMarkerPath = fs.combine(programDirectory, "service.running")

--- Create location key
--- @param name InventoryName
--- @param slot number
--- @return LocationKey
local function locationKey(name, slot)
  return name .. ":" .. slot
end

--- Create item key
--- @param item Item
--- @return ItemKey
function storage.itemKey(item)
  return item.name .. "#" .. (item.nbt or "")
end

---Create a slot record
---@param detail ItemDetail The item details for the slot.
---@param count number? The number of items in the slot, if different from the item details.
---@return SlotRecord
function storage.slotRecord(detail, count)
  return {
    key = storage.itemKey(detail),
    name = detail.name,
    nbt = detail.nbt,
    displayName = detail.displayName,
    count = count or detail.count,
    maxCount = detail.maxCount,
  }
end

--- Get an inventory with the expected name and label
--- @param name InventoryName
--- @param label string
--- @return InventoryPeripheral? peripheral, string? error message.
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

--- Get the inbox inventory peripheral
--- @return InventoryPeripheral? peripheral, string? error message.
function storage.getInbox()
  return roleInventory(INBOX_NAME, "inbox")
end

--- Get the outbox inventory peripheral
--- @return InventoryPeripheral? peripheral, string? error message.
function storage.getOutbox()
  return roleInventory(OUTBOX_NAME, "outbox")
end

--- Get the name of the outbox inventory peripheral
--- @return InventoryName
function storage.outboxName()
  return OUTBOX_NAME
end

--- Creates a new, empty storage index
--- @return Index index
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

--- Validate the structure of a storage index
--- @param index Index
--- @return boolean valid
local function validIndex(index)
  return type(index.trusted) == "boolean"
    and type(index.inventories) == "table"
    and type(index.items) == "table"
    and type(index.mergeTargets) == "table"
    and type(index.emptySlots) == "table"
end

--- Read an index from disk
--- @param path string
--- @return Index? index, string? error
local function readIndex(path)
  local handle, openError = fs.open(path, "r")
  if not handle then
    return nil, openError
  end

  local contents = handle.readAll()
  handle.close()

  local index = textutils.unserialize(contents)

  if not validIndex(index) 
    then return nil, "index file is not valid serialized data" 
  end

  return index
end

--- Load the storage index from disk, restoring from backup if necessary, or creating a new index if none exists
--- @return Index? index, string? error
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

--- Store index to disk
--- @param index Index
--- @return boolean? success, string? error
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

--- Determine if the service is running by checking for the presence of the service marker file
--- @return boolean running
function storage.serviceIsRunning()
  return fs.exists(serviceMarkerPath)
end

--- Acquire a lock to indicate that no other storage service is running
--- @return boolean? success, string? error
function storage.acquireServiceLock()
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

--- Release the lock indicating that the storage service is no longer running
--- @return boolean? success, string? error
function storage.releaseServiceLock()
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

--- Determine if a chest peripheral is connected with the given name
--- @param name InventoryName
--- @return boolean isChest
function storage.isChest(name)
  return peripheral.isPresent(name) and peripheral.hasType(name, "minecraft:chest")
end

--- Discover all un-indexed chests connected to the computer
--- @param index Index
--- @return InventoryName[] names
function storage.discoverChests(index)
  local names = {}

  for _, name in ipairs(peripheral.getNames()) do
    if not index.inventories[name] and storage.isChest(name) then
      table.insert(names, name)
    end
  end

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

      inventory.slots[slot] = storage.slotRecord(detail)
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

---comment
---@param index Index
---@param name InventoryName
---@param slot number
---@param record SlotRecord|false
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

--- Recalculate all lookup tables in an index
--- @param index Index
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

---comment
---@param index Index
---@param name InventoryName
---@param slot number
---@param record SlotRecord
function storage.setSlot(index, name, slot, record)
  local inventory = index.inventories[name]
  local previous = inventory.slots[slot]

  removeSlotLookup(index, name, slot, previous)
  inventory.slots[slot] = record
  addSlotLookup(index, name, slot, record)
end

--- Seearch function used in list/get. Sorts results in descending order of indexed counts.
--- @param index Index
--- @param query string
--- @return ItemRecord[] results
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

local function beginTransfer(index, state, beforeMove)
  if state.started then
    return true
  end
  if beforeMove then
    local started, startError = beforeMove(index)
    if not started then
      return nil, startError
    end
  end
  state.started = true
  return true
end

function storage.import(index, beforeMove)
  if not index.trusted then
    print("Storage index is untrusted. Run reconcile before importing.")
    return false
  end
  if #storage.registeredChests(index) == 0 then
    print("No storage chests are registered. Run register first.")
    return false
  end
  local connected, missing = storage.validateRegisteredChests(index)
  if not connected then
    print("Cannot import while registered chests are missing:")
    for _, name in ipairs(missing) do print("  " .. name) end
    return false
  end
  local inbox, inboxError = storage.getInbox()
  if not inbox then print("Cannot import: " .. inboxError) return false end
  local _, outboxError = storage.getOutbox()
  if outboxError then print("Cannot import: " .. outboxError) return false end
  local sized, inboxSize = pcall(inbox.size)
  local listed, inboxItems = pcall(inbox.list)
  if not sized or type(inboxSize) ~= "number" or not listed or type(inboxItems) ~= "table" then
    print("Could not read inbox contents.")
    return false
  end

  local state = { started = false }
  local imported = 0
  local function moveTo(sourceSlot, item, destination, limit)
    local started, startError = beginTransfer(index, state, beforeMove)
    if not started then return nil, startError end
    local movedOk, moved = pcall(inbox.pushItems, destination.name, sourceSlot, limit, destination.slot)
    if not movedOk or type(moved) ~= "number" or moved <= 0 or moved > limit then
      return nil, "selected destination " .. destination.name .. " slot " .. destination.slot .. " accepted no items"
    end
    local previous = index.inventories[destination.name].slots[destination.slot]
    local record = previous == false and storage.slotRecord(item, moved) or {
      key = previous.key, name = previous.name, nbt = previous.nbt,
      displayName = previous.displayName, count = previous.count + moved, maxCount = previous.maxCount,
    }
    storage.setSlot(index, destination.name, destination.slot, record)
    return moved
  end
  local function fill(sourceSlot, item, remaining, locations)
    local movedTotal = 0
    while remaining > 0 do
      local destination = storage.anyLocation(locations)
      if not destination then break end
      local moved, moveError = moveTo(sourceSlot, item, destination, remaining)
      if not moved then return nil, moveError end
      remaining = remaining - moved
      movedTotal = movedTotal + moved
    end
    return remaining, movedTotal
  end
  for sourceSlot = 1, inboxSize do
    if inboxItems[sourceSlot] then
      local detailed, item = pcall(inbox.getItemDetail, sourceSlot)
      if not detailed or not item or type(item.maxCount) ~= "number" then
        print("Could not read item details for inbox slot " .. sourceSlot .. ".")
        if state.started then index.trusted = false end
        return imported > 0
      end
      local remaining, moved = fill(sourceSlot, item, item.count, index.mergeTargets[storage.itemKey(item)] or {})
      if not remaining then
        print("Import stopped: " .. moved)
        index.trusted = false
        return true
      end
      imported = imported + moved
      if remaining > 0 then
        remaining, moved = fill(sourceSlot, item, remaining, index.emptySlots)
        if not remaining then
          print("Import stopped: " .. moved)
          index.trusted = false
          return true
        end
        imported = imported + moved
      end
      if remaining > 0 then print("Left " .. remaining .. " x " .. (item.displayName or item.name) .. " in inbox slot " .. sourceSlot .. ": pool is full.") end
    end
  end
  print(imported == 0 and "No items imported." or "Imported " .. imported .. " item(s).")
  return state.started
end

local function parseGet(arguments)
  local usageHint = "Usage: get <item name> [count|all]"
  if #arguments == 0 then error(usageHint) end
  local amountType, requested = "default", nil
  if #arguments > 1 then
    local last = arguments[#arguments]
    if last == "all" then
      amountType = "all"
      table.remove(arguments)
    elseif tonumber(last) ~= nil then
      if not last:match("^%d+$") or tonumber(last) < 1 then
        error("Count must be a positive whole number or all.")
      end
      amountType, requested = "count", tonumber(last)
      table.remove(arguments)
    end
  end
  local query = table.concat(arguments, " ")
  if query == "" then error(usageHint) end
  return query, amountType, requested
end

--- Determine the top matched item in a get/list style query
--- @param index Index
--- @param query string
--- @return ItemRecord
local function selectGetItem(index, query)
  local matches = storage.searchItems(index, query)
  if #matches == 0 then error("No matching items for " .. query .. ".") end
  local item = matches[1]
  local displayName, available = item.displayName or item.name, item.total

  if #matches > 1 then print("Multiple matches found for " .. query .. ", selected " .. displayName) end
  return item
end

--- comment
--- @param outbox InventoryPeripheral
--- @param item Item
--- @return number capacity, integer[] targets
local function outboxTargets(outbox, item)
  local sized, outboxSize = pcall(outbox.size)
  local listed, outboxItems = pcall(outbox.list)
  if not sized or type(outboxSize) ~= "number" or not listed or type(outboxItems) ~= "table" then error("Cannot export: could not read outbox contents") end
  local targets, capacity = {}, 0
  for slot = 1, outboxSize do
    if not outboxItems[slot] then
      local limited, slotLimit = pcall(outbox.getItemLimit, slot)
      if not limited or type(slotLimit) ~= "number" then error("Cannot export: could not read outbox slot limit for slot " .. slot) end
      local slotCapacity = math.min(slotLimit, item.maxCount)
      if slotCapacity > 0 then
        table.insert(targets, { slot = slot, capacity = slotCapacity })
        capacity = capacity + slotCapacity
      end
    end
  end
  return capacity, targets
end

--- Move items from the storage to the outbox. Accepts arguments like "get query 32", "get query" or "get query all", where query supports the same matching rules as list. The item returned is the top hit from query.
---@param index Index
---@param arguments string[]
---@return boolean
function storage.get(index, arguments)

  local parseOk, query, amountType, requested = pcall(parseGet, arguments)
  if not parseOk or requested == nil then print(query) return false end
  if not index.trusted then print("Storage index is untrusted. Run reconcile before exporting items.") return false end
  local selectOk, item = pcall(selectGetItem, index, query)
  if not selectOk then print(item) return false end
  local available, displayName = item.total, item.displayName
  
  local outbox, outboxError = storage.getOutbox()
  if not outbox then print("Cannot export: " .. outboxError) return false end

  local targetsFound, capacity, targets = pcall(outboxTargets, outbox, item)
  if not targetsFound then print("Cannot export: " .. capacity) return false end

  local amount = amountType == "all" and math.min(available, capacity)
    or amountType == "count" and math.min(requested, available, capacity)
    or math.min(item.maxCount, available, capacity)
  if amount == 0 then print("Outbox has no empty slots; no items moved.") return false end

  local state, transferred = { started = false }, 0
  for _, destination in ipairs(targets) do
    for source, sourceAmount in pairs(item.locations) do
      if amount <= 0 then break end
      print("Fetching item from inventory: " .. source.name .. ", slot: " .. source.slot)
      local record = index.inventories[source.name].slots[source.slot]
      if not record then 
        print("Export stopped: source slot is empty or does not exist")
        return true
      end
      local limit = math.min(amount, destination.capacity, record.count)
      local movedOk, moved = pcall(outbox.pullItems, source.name, source.slot, limit, destination.slot)
      if not movedOk or type(moved) ~= "number" or moved ~= limit then
          print("Export stopped: outbox accepted fewer items than expected")
          index.trusted = false
          return true
      end
      local updated = moved == record.count and false or {
        key = record.key, name = record.name, nbt = record.nbt,
        displayName = record.displayName, count = record.count - moved, maxCount = record.maxCount,
      }
      storage.setSlot(index, source.name, source.slot, updated)
      amount, destination.capacity, transferred = amount - moved, destination.capacity - moved, transferred + moved
    end
  end
  print("Exported " .. transferred .. " x " .. displayName .. ".")
  if (amountType == "count" and requested > available) or (amountType == "default" and item.maxCount > available) then print("The selected " .. displayName .. " ran out; no other matching items were used.") end
  if (amountType == "count" and capacity < math.min(requested, available)) or (amountType == "default" and capacity < math.min(item.maxCount, available)) or (amountType == "all" and available > capacity) then print("Outbox had room for only " .. transferred .. " x " .. displayName .. ".") end
  return state.started
end

return storage
