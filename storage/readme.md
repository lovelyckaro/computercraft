# Storage System

## Purpose

This system manages a shared pool of chest inventories from one CC: Tweaked
computer. It provides an explicit inbox for deposits and an outbox for item
requests, while keeping a persisted index so normal searches do not need to
scan every chest.

## Relevant Documentation

- [Peripheral API](https://tweaked.cc/module/peripheral.html): discover,
  identify, and wrap connected peripherals.
- [Inventory peripheral](https://tweaked.cc/generic_peripheral/inventory.html):
  inspect inventory slots and transfer items with `pushItems` and `pullItems`.
- [Item details](https://tweaked.cc/reference/item_details.html): interpret
  item names, NBT hashes, display names, and stack limits.
- [Terminal API](https://tweaked.cc/module/term.html): size terminal output and
  render the status capacity bar.
- [Colors API](https://tweaked.cc/module/colors.html): select the status bar's
  red, yellow, and green segment colors.

## Physical Layout

- The inbox barrel is the wired peripheral `minecraft:barrel_0`.
- The outbox barrel is the wired peripheral `minecraft:barrel_1`.
- Storage-pool inventories are registered chest peripherals connected to the
  computer through a wired modem network.
- Inbox and outbox are never registered as pool inventories.

The inbox, outbox, and every pool chest must be attached to the same wired modem
network. This is required by `pushItems` and `pullItems`, including when the
inbox or outbox is adjacent to the computer. The inbox and outbox must remain
connected while the program is running. Pool chests may be added later through
the registration command.

## File Structure

Each command is a standalone executable. `storage.lua` is the shared library
for peripheral access, index persistence, item keys, validation, and common
inventory operations.

```text
storage/
  storage.lua     Shared storage library
  import.lua      Import inbox contents into the pool
  get.lua         Export requested items to the outbox
  list.lua        List indexed items
  register.lua    Register newly connected pool chests
  reconcile.lua   Rebuild the persisted index
  status.lua      Display pool and index status
  index           Generated persisted storage index
  readme.md       System design
```

## Command Interface

The first version uses the computer terminal as its interface.

| Command | Behavior |
| --- | --- |
| `import` | Moves all items from the inbox into the storage pool. |
| `list [query]` | Shows indexed item names and available counts, optionally filtered by text. |
| `get <item> [count]` | Moves the requested quantity to the outbox. When stock is insufficient, moves what is available and reports the shortfall. |
| `register` | Discovers unregistered eligible chest peripherals, scans each once, and adds them to the pool. |
| `reconcile` | Rebuilds the complete index from all registered pool chests. |
| `status` | Reports registered inventories, occupied and empty slots, partial-stack capacity, and index health. Ends with a full-width bar: red for full slots, yellow for partial stacks, and green for empty slots. |

`get` must not mix item types in the outbox. It should fail before moving items
when the outbox contains a different item, or when it lacks enough free space
for the amount that can be exported.

## Index

The persisted index has a format version and a `trusted` flag. The flag is true
only when every recorded change has been confirmed. The canonical inventory
record is the physical layout and per-slot state; all other index tables are
derived lookup tables that make normal operations fast.

### Inventory Records

`inventories` is keyed by peripheral name. Each record stores the chest slot
count, an `emptyCount`, and slot records keyed by slot number. An occupied slot
records its item key, item name, count, and maximum stack size. Empty slots are
recorded as `false`.

```lua
inventories = {
  ["minecraft:chest_0"] = {
    size = 27,
    emptyCount = 1,
    slots = {
      [1] = { key = "minecraft:stone", name = "minecraft:stone", count = 42, maxCount = 64 },
      [2] = false,
    },
  },
}
```

A slot location is addressed as a peripheral name and slot number. The
implementation may serialize that pair as a string, such as
`minecraft:chest_0:1`, for use as a table key.

### Item Catalog

`items` is keyed by item key and provides the fast lookup used by `list` and
`get`. Every entry contains the item's display data, its aggregate `total`, and
the count at every occupied location.

```lua
items = {
  ["minecraft:stone"] = {
    name = "minecraft:stone",
    total = 106,
    locations = {
      ["minecraft:chest_0:1"] = 42,
      ["minecraft:chest_1:4"] = 64,
    },
  },
}
```

An item key is the item `name` plus its optional `nbt` hash. This documented
pair identifies items that can stack together and distinguishes variants that
cannot, rather than treating every item with the same name as identical.

### Import Lookups

`mergeTargets` is keyed by item key, then location. It contains every partial
stack and its remaining capacity. `import` uses it first to fill compatible
stacks without searching all inventories.

```lua
mergeTargets = {
  ["minecraft:stone"] = {
    ["minecraft:chest_0:1"] = 22,
  },
}
```

`emptySlots` contains every unoccupied pool location. If no merge target has
capacity, `import` chooses a location from this table. An empty slot has no
fixed item capacity: its capacity depends on the item placed into it, so it is
not represented as a fixed free-item count.

```lua
emptySlots = {
  ["minecraft:chest_0:2"] = true,
  ["minecraft:chest_1:9"] = true,
}
```

### Updates

After each confirmed transfer, update the source and destination records in
`inventories`, the affected `items` totals and locations, matching
`mergeTargets`, and `emptySlots`. These targeted updates avoid full scans as
the pool grows. Before an item-moving command begins its first transfer, persist
the index as untrusted. Keep its updates in memory, then atomically persist the
completed trusted index when the command finishes. An interrupted command
therefore requires `reconcile` without writing the complete index per transfer.

`reconcile` rebuilds the canonical inventory records from the registered
chests, then recreates the catalog and import lookup tables from those records.

## Inventory Operations

### Import

Items stay in the inbox until `import` is run. For each inbox stack, the
system:

1. Fills compatible partial stacks already in the pool.
2. Uses an empty compatible pool slot when additional space is needed.
3. Leaves any unmovable remainder in the inbox and reports insufficient pool
   capacity.

The index is updated after each confirmed move so an interrupted import can be
continued safely.

### Export

For `get`, the system finds indexed locations for the requested item and moves
from them into the outbox until the request, stock, or outbox space is
exhausted. It reports the requested amount, transferred amount, and any
shortfall. Source slot records are updated after each confirmed move.

## Registration And Reconciliation

`register` discovers connected chest peripherals that are not already in the
registered inventory list. Each candidate is checked to ensure it exposes the
inventory methods required by the system, then scanned once before it is added
to the persisted index. This permits expansion without making every normal
command scan every chest.

The index assumes that registered pool chests are changed only through this
system. If a player or another automation modifies a pool chest directly, run
`reconcile`. Reconciliation scans every registered chest and rebuilds all item
locations and capacity records. It is also the recovery path for an untrusted
index that still has a readable registration list. If the index cannot be read,
restore a backup or remove the invalid index and run `register` to intentionally
create a new pool.

## Persistence And Failure Handling

- Save index changes atomically: write a replacement file, then replace the
  previous index only after the write succeeds.
- On startup, verify that the inbox, outbox, and all registered peripherals are
  present and expose the expected inventory operations.
- Stop the affected operation and clearly report a missing peripheral, failed
  move, full outbox, or exhausted pool capacity.
- Reconciliation is all-or-nothing. If any registered chest cannot be scanned,
  keep the existing inventory records and mark the index untrusted.
- If a move cannot be confirmed or the program stops during a transfer, mark
  the index untrusted and require `reconcile` before subsequent indexed moves.
- Never discard an item to recover from an error. Items not transferred remain
  in their source inventory.

## Operating Rules

- Use the inbox only for deposits and the outbox only for collected requests.
- Empty the outbox before requesting a different item type.
- Add pool chests with `register` rather than relying on automatic discovery
  during normal operations.
- Run `reconcile` after manually changing pool contents, replacing a chest, or
  recovering from an interrupted operation.
