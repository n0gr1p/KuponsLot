# KuponsLot

Windower 4 addon that coordinates **Kupon I-Seal** lotting across local FFXI clients.

KuponsLot is modeled after [RemsTales](https://github.com/n0gr1p/RemsTales), but it is intentionally simpler: Kupon I-Seals are normal inventory items, so there is no Monisette/currency snapshot dependency.

## What it tracks

KuponsLot tracks:

- **Kupon I-Seal** — item ID **3442**

Counts are taken across:

- Inventory
- Mog Safe
- Mog Safe 2
- Storage
- Mog Locker
- Mog Satchel
- Mog Sack
- Mog Case

The balancing target is each character's total physical Kupon I-Seal count across those bags.

## Coordination model

Every loaded KuponsLot client that sees the same treasure pool coordinates through Windower IPC.

For each pool containing Kupon I-Seals:

1. KuponsLot waits briefly for the drop burst to settle.
2. Every matching local client reports its current Kupon total and Inventory receive capacity.
3. A deterministic coordinator is elected.
4. Kupons are processed in treasure-slot order.
5. Each Kupon is assigned to the eligible character with the lowest **virtual** total.
6. The selected client lots that slot.
7. Lot acknowledgement is monitored; failed assignments can fall back to another eligible client.

Clients that are disabled, are not in the same zone/pool, or cannot receive another Kupon are excluded.

## Intelligent balancing

KuponsLot uses a virtual running balance while allocating the current pool.

Example:

```text
Terrasjr   10
Nyoourke   11
Etamame    20

Three Kupon I-Seals drop.
```

Allocation behaves like:

```text
1 -> Terrasjr (10 -> 11 virtual)
2 -> Nyoourke (11 -> 12 virtual)
3 -> Terrasjr (11 -> 12 virtual)
```

It does not blindly give every drop in the pool to whoever started with the lowest count.

Equal totals use a deterministic tie-breaker so every local client reaches the same assignment decision.

## Inventory safety

Kupons can only land in main Inventory, so KuponsLot calculates receive capacity as:

```text
remaining room in existing Inventory Kupon stacks
+ free Inventory slots * Kupon stack size
```

Capacity is reserved virtually as the pool is assigned.

This prevents a character from being assigned more Kupons than can actually land.

## Commands

```text
//kuponlot status
//kuponlot totals
//kuponlot peers
//kuponlot on
//kuponlot off
//kuponlot observe
//kuponlot observe on
//kuponlot observe off
//kuponlot verbose
//kuponlot verbose on
//kuponlot verbose off
```

Short alias:

```text
//klot
```

### `//kuponlot status`

Shows local mode, Kupon total, Inventory receive capacity, active pool state, peer count, and coordinator.

### `//kuponlot totals`

Shows this character's Kupon I-Seal total across tracked bags.

### `//kuponlot peers`

Shows the local-client Kupon totals and receive capacities collected for the current or most recent pool.

### `//kuponlot on` / `off`

Enables or disables this client as an allocation participant.

The default is enabled.

### `//kuponlot observe [on|off]`

Observe mode participates in coordination and computes assignments but does not lot.

If every participating client is in observe mode, the whole pool is a dry run.

If any valid auto-lot clients are present, observe-only clients are not selected as winners.

### `//kuponlot verbose [on|off]`

Enables extra coordination diagnostics.

## Installation

Place the repository folder at:

```text
Windower4/addons/KuponsLot/
```

Load it on every participating local client:

```text
//lua l KuponsLot
```

## Recommended first test

Load KuponsLot on all participating characters, then enable observe mode everywhere:

```text
//klot observe on
```

Farm until a Kupon I-Seal enters the treasure pool and inspect:

```text
//klot totals
//klot peers
//klot status
```

Once assignments look correct:

```text
//klot observe off
```

## Coexistence with Treasury / other auto-lot addons

Do not configure another addon to independently auto-lot **Kupon I-Seal**.

KuponsLot intentionally leaves non-winning clients alone rather than auto-passing them. A second auto-lot system targeting the same item can defeat the single-winner coordination model.

## Version 0.1.0

- Coordinate local Windower clients through IPC.
- Count Kupon I-Seals across common storage bags.
- Allocate each drop to the lowest-total eligible client.
- Virtually rebalance multiple Kupons in the same treasure pool.
- Track actual Inventory receive capacity in item units.
- Use deterministic tie-breaking.
- Support observe-only dry runs.
- Retry local lot requests and monitor server lot activity.
- Reassign failed lots to another eligible client.
- Avoid auto-passing non-winning clients.
