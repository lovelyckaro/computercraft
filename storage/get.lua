local storage = require("storage")

local function usage()
  print("Usage: get <query> [count|all]")
end

local function emptyOutboxTargets(outbox, item)
  local sized, size = pcall(outbox.size)
  local listed, items = pcall(outbox.list)
  if not sized or type(size) ~= "number" or not listed or type(items) ~= "table" then
    return nil, "could not read outbox contents"
  end

  local empty = {}
  local capacity = 0

  for slot = 1, size do
    if not items[slot] then
      local limited, slotLimit = pcall(outbox.getItemLimit, slot)
      if not limited or type(slotLimit) ~= "number" then
        return nil, "could not read outbox slot limit for slot " .. slot
      end

      local slotCapacity = math.min(slotLimit, item.maxCount)
      if slotCapacity > 0 then
        table.insert(empty, { slot = slot, capacity = slotCapacity })
        capacity = capacity + slotCapacity
      end
    end
  end

  return empty, capacity
end

local function moveToOutbox(index, state, source, destination, limit)
  if not state.started then
    local started, startError = storage.beginTransaction(index)
    if not started then
      return nil, "could not mark storage index untrusted: " .. startError
    end
    state.started = true
  end

  local chest = peripheral.wrap(source.name)
  if not chest or type(chest.pushItems) ~= "function" then
    return nil, "could not access source chest " .. source.name
  end

  local movedOk, moved = pcall(chest.pushItems, storage.outboxName(), source.slot, limit, destination.slot)
  if not movedOk then
    return nil, "could not transfer from " .. source.name .. " slot " .. source.slot .. ": " .. tostring(moved)
  end

  if type(moved) ~= "number" or moved ~= limit then
    return nil, "outbox accepted fewer items than expected"
  end

  local previous = index.inventories[source.name].slots[source.slot]
  local record
  if moved == previous.count then
    record = false
  else
    record = {
      key = previous.key,
      name = previous.name,
      nbt = previous.nbt,
      displayName = previous.displayName,
      count = previous.count - moved,
      maxCount = previous.maxCount,
    }
  end

  storage.setSlot(index, source.name, source.slot, record)
  return moved
end

local function fillOutbox(index, state, item, amount, targets)
  local transferred = 0

  for _, destination in ipairs(targets) do
    while amount > 0 and destination.capacity > 0 do
      local source = storage.anyLocation(item.locations)
      if not source then
        return nil, "selected item ran out unexpectedly"
      end

      local record = index.inventories[source.name].slots[source.slot]
      local limit = math.min(amount, destination.capacity, record.count)
      local moved, moveError = moveToOutbox(index, state, source, destination, limit)
      if not moved then
        return nil, moveError
      end

      amount = amount - moved
      destination.capacity = destination.capacity - moved
      transferred = transferred + moved
    end
  end

  if amount > 0 then
    return nil, "outbox capacity changed unexpectedly"
  end

  return transferred
end

local arguments = { ... }
if #arguments == 0 then
  usage()
  return
end

local amountType = "default"
local requested
if #arguments > 1 then
  local last = arguments[#arguments]
  if last == "all" then
    amountType = "all"
    table.remove(arguments)
  elseif tonumber(last) ~= nil then
    if not last:match("^%d+$") or tonumber(last) < 1 then
      print("Count must be a positive whole number or all.")
      return
    end
    amountType = "count"
    requested = tonumber(last)
    table.remove(arguments)
  end
end

local query = table.concat(arguments, " ")
if query == "" then
  usage()
  return
end

local index, loadError = storage.loadIndex()
if not index then
  print("Could not load storage index: " .. loadError)
  return
end

if not index.trusted then
  print("Storage index is untrusted. Run reconcile before exporting items.")
  return
end

local matches = storage.searchItems(index, query)
if #matches == 0 then
  print("No matching items for " .. query .. ".")
  return
end

local item = matches[1]
local displayName = item.displayName or item.name
local available = item.total
if #matches > 1 then
  print("Selected " .. displayName .. " with " .. available .. " items available.")
end

local connected, missing = storage.validateRegisteredChests(index)
if not connected then
  print("Cannot export while registered chests are missing:")
  for _, name in ipairs(missing) do
    print("  " .. name)
  end
  return
end

local _, inboxError = storage.getInbox()
if inboxError then
  print("Cannot export: " .. inboxError)
  return
end

local outbox, outboxError = storage.getOutbox()
if not outbox then
  print("Cannot export: " .. outboxError)
  return
end

local targets, capacity = emptyOutboxTargets(outbox, item)
if not targets then
  print("Cannot export: " .. capacity)
  return
end

local amount
if amountType == "all" then
  amount = math.min(available, capacity)
elseif amountType == "count" then
  amount = math.min(requested, available, capacity)
else
  amount = math.min(item.maxCount, available, capacity)
end

if amount == 0 then
  print("Outbox has no empty slots; no items moved.")
  return
end

local state = { started = false }
local transferred, transferError = fillOutbox(index, state, item, amount, targets)

if not transferred then
  print("Export stopped: " .. transferError)
  if state.started then
    print("Storage index remains untrusted. Run reconcile before exporting again.")
  end
  return
end

local saved, saveError = storage.completeTransaction(index)
if not saved then
  print("Could not save completed storage index: " .. saveError)
  print("Storage index remains untrusted. Run reconcile before exporting again.")
  return
end

print("Exported " .. transferred .. " x " .. displayName .. ".")
if (amountType == "count" and requested > available) or (amountType == "default" and item.maxCount > available) then
  print("The selected " .. displayName .. " ran out; no other matching items were used.")
end
if (amountType == "count" and capacity < math.min(requested, available))
  or (amountType == "default" and capacity < math.min(item.maxCount, available))
  or (amountType == "all" and available > capacity) then
  print("Outbox had room for only " .. transferred .. " x " .. displayName .. ".")
end
