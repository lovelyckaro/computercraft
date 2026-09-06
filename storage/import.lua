local storage = require("storage")

local function moveTo(index, state, inbox, sourceSlot, item, destination, limit)
  if not state.started then
    local started, startError = storage.beginTransaction(index)
    if not started then
      return nil, startError
    end
    state.started = true
  end

  local movedOk, moved = pcall(inbox.pushItems, destination.name, sourceSlot, limit, destination.slot)
  if not movedOk then
    return nil, "could not transfer to " .. destination.name .. " slot " .. destination.slot .. ": " .. tostring(moved)
  end

  if type(moved) ~= "number" or moved <= 0 or moved > limit then
    return nil, "selected destination " .. destination.name .. " slot " .. destination.slot .. " accepted no items"
  end

  local previous = index.inventories[destination.name].slots[destination.slot]
  local record
  if previous == false then
    record = storage.slotRecord(item, item, moved)
  else
    record = {
      key = previous.key,
      name = previous.name,
      nbt = previous.nbt,
      displayName = previous.displayName,
      count = previous.count + moved,
      maxCount = previous.maxCount,
    }
  end

  storage.setSlot(index, destination.name, destination.slot, record)
  return moved
end

local function fillLocations(index, state, inbox, sourceSlot, item, remaining, locations)
  local movedTotal = 0

  while remaining > 0 do
    local destination = storage.anyLocation(locations)
    if not destination then
      break
    end

    local moved, moveError = moveTo(index, state, inbox, sourceSlot, item, destination, remaining)
    if not moved then
      return nil, moveError
    end

    remaining = remaining - moved
    movedTotal = movedTotal + moved
  end

  return remaining, movedTotal
end

local index, loadError = storage.loadIndex()
if not index then
  print("Could not load storage index: " .. loadError)
  return
end

if not index.trusted then
  print("Storage index is untrusted. Run reconcile before importing.")
  return
end

if #storage.registeredChests(index) == 0 then
  print("No storage chests are registered. Run register first.")
  return
end

local connected, missing = storage.validateRegisteredChests(index)
if not connected then
  print("Cannot import while registered chests are missing:")
  for _, name in ipairs(missing) do
    print("  " .. name)
  end
  return
end

local inbox, inboxError = storage.getInbox()
if not inbox then
  print("Cannot import: " .. inboxError)
  return
end

local _, outboxError = storage.getOutbox()
if outboxError then
  print("Cannot import: " .. outboxError)
  return
end

local sized, inboxSize = pcall(inbox.size)
local listed, inboxItems = pcall(inbox.list)
if not sized or type(inboxSize) ~= "number" or not listed or type(inboxItems) ~= "table" then
  print("Could not read inbox contents.")
  return
end

local imported = 0
local importState = { started = false }
for sourceSlot = 1, inboxSize do
  if inboxItems[sourceSlot] then
    local detailed, item = pcall(inbox.getItemDetail, sourceSlot)
    if not detailed or not item or type(item.maxCount) ~= "number" then
      print("Could not read item details for inbox slot " .. sourceSlot .. ".")
      return
    end

    local key = storage.itemKey(item)
    local remaining = item.count
    local moved
    remaining, moved = fillLocations(index, importState, inbox, sourceSlot, item, remaining, index.mergeTargets[key] or {})
    if not remaining then
      print("Import stopped: " .. moved)
      if importState.started then
        print("Storage index remains untrusted. Run reconcile before importing again.")
      end
      return
    end
    imported = imported + moved

    if remaining > 0 then
      remaining, moved = fillLocations(index, importState, inbox, sourceSlot, item, remaining, index.emptySlots)
      if not remaining then
        print("Import stopped: " .. moved)
        if importState.started then
          print("Storage index remains untrusted. Run reconcile before importing again.")
        end
        return
      end
      imported = imported + moved
    end

    if remaining > 0 then
      print("Left " .. remaining .. " x " .. (item.displayName or item.name) .. " in inbox slot " .. sourceSlot .. ": pool is full.")
    end
  end
end

if importState.started then
  local saved, saveError = storage.completeTransaction(index)
  if not saved then
    print("Could not save completed storage index: " .. saveError)
    print("Storage index remains untrusted. Run reconcile before importing again.")
    return
  end
end

if imported == 0 then
  print("No items imported.")
else
  print("Imported " .. imported .. " item(s).")
end
