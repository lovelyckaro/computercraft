local storage = require("storage")

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
  local text = string.rep(" ", width)
  local textColours = string.rep(colors.toBlit(textColour), width)
  local backgroundColours = ""

  for _, segment in ipairs(segments) do
    backgroundColours = backgroundColours .. string.rep(colors.toBlit(segment.colour), segment.width)
  end

  term.blit(text, textColours, backgroundColours)
  term.setTextColour(textColour)
  term.setBackgroundColour(backgroundColour)
  print()
end

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

drawCapacityBar(summary)
