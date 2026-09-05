local storage = {}

local INDEX_VERSION = 1
local programDirectory = fs.getDir(shell.getRunningProgram())
local indexPath = fs.combine(programDirectory, "index")
local backupPath = indexPath .. ".bak"
local temporaryPath = indexPath .. ".tmp"

local function locationKey(name, slot)
  return name .. ":" .. slot
end

function storage.itemKey(item)
  return item.name .. "#" .. (item.nbt or "")
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

function storage.rebuildLookups(index)
  local items = {}
  local mergeTargets = {}
  local emptySlots = {}

  for name, inventory in pairs(index.inventories) do
    local emptyCount = 0

    for slot = 1, inventory.size do
      local record = inventory.slots[slot]
      local location = locationKey(name, slot)

      if record == false then
        emptyCount = emptyCount + 1
        emptySlots[location] = true
      else
        local item = items[record.key]
        if not item then
          item = {
            name = record.name,
            nbt = record.nbt,
            displayName = record.displayName,
            total = 0,
            locations = {},
          }
          items[record.key] = item
        end

        item.total = item.total + record.count
        item.locations[location] = record.count

        local remaining = record.maxCount - record.count
        if remaining > 0 then
          local targets = mergeTargets[record.key] or {}
          targets[location] = remaining
          mergeTargets[record.key] = targets
        end
      end
    end

    inventory.emptyCount = emptyCount
  end

  index.items = items
  index.mergeTargets = mergeTargets
  index.emptySlots = emptySlots
end

local function readIndex(path)
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

  if index.version ~= INDEX_VERSION or type(index.trusted) ~= "boolean" or type(index.inventories) ~= "table" then
    return nil, "index file has an unsupported format"
  end

  storage.rebuildLookups(index)
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

  local size = chest.size()
  local listed = chest.list()
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
      local detail = chest.getItemDetail(slot)
      if not detail or type(detail.maxCount) ~= "number" then
        return nil, "could not read item details for " .. name .. " slot " .. slot
      end

      local item = {
        name = basic.name,
        nbt = basic.nbt,
      }
      inventory.slots[slot] = {
        key = storage.itemKey(item),
        name = basic.name,
        nbt = basic.nbt,
        displayName = detail.displayName,
        count = basic.count,
        maxCount = detail.maxCount,
      }
    end
  end

  return inventory
end

function storage.addInventory(index, name, inventory)
  index.inventories[name] = inventory
  storage.rebuildLookups(index)
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

return storage
