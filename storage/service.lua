local storage = require("storage")

local prompt = "storage> "
local input = ""
local terminated = false

local function drawPrompt()
  write(prompt .. input)
end

local function redrawPrompt()
  print()
  drawPrompt()
end

local function waitForNextPage()
  while true do
    local event, key = os.pullEventRaw()
    if event == "terminate" then
      terminated = true
      return false
    end
    if event == "key" then
      return key ~= keys.q
    end
  end
end

local function help()
  print("Commands: status, list [query], register, reconcile, import, get <query> [count|all], help, exit")
end

if storage.serviceIsRunning() then
  print("Storage service is already running or stopped uncleanly.")
  print("Reconcile the storage pool and remove service.running before restarting.")
  return
end

local index, loadError = storage.loadIndex()
if not index then
  print("Could not load storage index: " .. loadError)
  return
end

local started, startError = storage.acquireServiceLock()
if not started then
  print("Could not start storage service: " .. startError)
  return
end

print("Storage service started. Type help for commands.")
drawPrompt()

while not terminated do
  local event, value = os.pullEventRaw()

  if event == "terminate" then
    terminated = true
  elseif event == "char" or event == "paste" then
    local width = term.getSize()
    local available = width - #prompt - #input
    if available > 0 then
      local appended = value:sub(1, available)
      input = input .. appended
      write(appended)
    end
  elseif event == "key" then
    if value == keys.backspace and #input > 0 then
      input = input:sub(1, -2)
      local x, y = term.getCursorPos()
      term.setCursorPos(x - 1, y)
      write(" ")
      term.setCursorPos(x - 1, y)
    elseif value == keys.enter then
      print()
      local arguments = {}
      for word in input:gmatch("%S+") do
        table.insert(arguments, word)
      end
      input = ""

      local command = table.remove(arguments, 1)
      if command == "status" then
        storage.printStatus(index)
      elseif command == "list" then
        storage.printList(index, table.concat(arguments, " "), waitForNextPage)
      elseif command == "register" then
        storage.register(index)
      elseif command == "reconcile" then
        storage.reconcile(index)
      elseif command == "import" then
        storage.import(index)
      elseif command == "get" then
        storage.get(index, arguments)
      elseif command == "help" then
        help()
      elseif command == "exit" then
        local saved, saveError = storage.saveIndex(index)
        if not saved then
          print("Could not checkpoint storage index: " .. saveError)
        else
          local stopped, stopError = storage.releaseServiceLock()
          if not stopped then
            print("Could not remove service marker: " .. stopError)
          else
            print("Storage service stopped.")
            return
          end
        end
      elseif command then
        print("Unknown command: " .. command .. ". Type help for commands.")
      end
      if not terminated then
        drawPrompt()
      end
    end
  elseif event == "term_resize" then
    redrawPrompt()
  end
end

print("Storage service stopped without checkpointing.")
