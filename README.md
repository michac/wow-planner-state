# PlannerState

A tiny World of Warcraft addon that dumps the **reset-state the Blizzard profile
API can't see** to SavedVariables, so an out-of-game session planner can subtract
"what I've already done this reset" from its recommendations.

It's the data feed for the [wow](https://github.com/michac/wow) session planner —
the same pattern that project already uses to read currencies from Syndicator,
but purpose-built and under our control.

## What it captures

Per character, on logout (or on demand via `/ps` + `/reload`):

- **Great Vault** — every slot's `type / threshold / progress / level` from
  `C_WeeklyRewards.GetActivities()` (the API blind spot: your actual vault
  progress this week).
- **Mythic+** — runs this week from `C_MythicPlus.GetRunHistory`.
- **Raid/dungeon lockouts** — from `GetSavedInstanceInfo`.
- **Currencies** — every currency with a nonzero balance, including
  `quantityEarnedThisWeek` / weekly cap (so the planner sees weekly crest
  progress, catalyst charges, etc.).
- **Weekly quests + items** — a configurable ID list (see below); empty by
  default so it never reports a false completion.
- Identity, equipped ilvl, gold, seconds-until-weekly-reset.

Everything is written to `PlannerStateDB` (SavedVariablesPerCharacter), landing at:

```
_retail_/WTF/Account/<ACCOUNT>/<Realm>/<Character>/SavedVariables/PlannerState.lua
```

## Install

Via the [ghaddons](https://github.com/michac/wow) manager (`add michac/wow-planner-state`),
or drop the `PlannerState/` folder into `_retail_/Interface/AddOns/`.

## Configuring weekly quests / items

Midnight weekly quest and item IDs aren't hardcoded (they change per patch).
Add them in `PlannerState.lua`:

```lua
ns.WEEKLY_QUESTS = {
  [80123] = "Liadrin spark weekly",
  [80456] = "Housing weekly (Vaeli)",
}
ns.ITEMS = {
  [246111] = "Spark of Radiance",
}
```

Find a quest ID by hovering the quest with a tooltip-ID addon, or from Wowhead.

## Usage

1. Log in on the character (or `/reload`).
2. `/ps` to capture now, then `/reload` to flush to disk — or just log out,
   which captures automatically.
3. The planner reads `PlannerState.lua` off disk.

## License

MIT — see [LICENSE](LICENSE).
