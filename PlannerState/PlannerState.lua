--[[  PlannerState
      Captures the reset-state the Blizzard profile API can't see (Great Vault
      slot progress, M+ runs this week, raid lockouts, world-boss weekly kills,
      per-currency weekly-earned, per-slot equipment ilvls + upgrade track/step
      ("Champion 5/6"), the "…of the Dawn" upgrade achievements, configured weekly
      quests + items, and the in-game event calendar) and writes it to
      SavedVariables so the session planner can subtract "what I've already done
      this reset", target the weakest gear slot, and surface live/upcoming
      holiday events (the fun radar).

      WRITE MODEL — read this if a /ps seems to "not take":
      SavedVariables only serialize to disk on /reload and on clean logout (a
      crash / Alt-F4 writes nothing). capture() runs on BOTH /ps and
      PLAYER_LOGOUT, and whichever ran last before the disk-write wins. So a
      mid-session /ps that you never /reload'd is OVERWRITTEN by the logout
      capture when you quit. To persist a mid-session snapshot: /ps then /reload
      (not logout). For normal use just play and log out — the logout capture is
      current. (equippedIlvl is exempt from the logout-unreliability that bit
      pre-0.4: gear is snapshotted from a cache warmed in-world — see below.)

      Every game-API call is guarded: on a client where a function is missing
      the field is simply omitted rather than erroring the whole dump.
--]]

local ADDON, ns = ...

PlannerStateDB = PlannerStateDB or {}

-- Call a single-return API safely; nil on any error/missing function.
local function safe(fn, ...)
  if type(fn) ~= "function" then return nil end
  local ok, res = pcall(fn, ...)
  if ok then return res end
  return nil
end

-- Enum.WeeklyRewardChestThresholdType → readable slot type. Midnight reports the
-- Mythic+/dungeon column as 6 (observed live: raid=1, world=3, dungeon=6); [2] is
-- kept for backwards-compat in case an older/other client still uses it.
local VAULT_TYPE = { [1] = "raid", [2] = "dungeon", [3] = "world", [4] = "pvp", [6] = "dungeon" }

-- Real gear slots (cosmetic shirt=4 / tabard=19 / defunct ranged=18 omitted) →
-- readable name, for per-slot ilvl scanning (planner v2b weakest-slot targeting).
local EQUIP_SLOTS = {
  [1] = "head", [2] = "neck", [3] = "shoulder", [5] = "chest", [6] = "waist",
  [7] = "legs", [8] = "feet", [9] = "wrist", [10] = "hands", [11] = "finger1",
  [12] = "finger2", [13] = "trinket1", [14] = "trinket2", [15] = "back",
  [16] = "mainhand", [17] = "offhand",
}

-- ------------------------------------------------------------ upgrade track
-- The profile API + GetDetailedItemLevelInfo give a slot's ilvl but NOT its
-- upgrade TRACK/step ("Champion 5/6" vs "Hero 1/6") — and those two collide at
-- ilvl 259, so ilvl alone can't tell them apart or say how much crest headroom a
-- slot has. C_ItemUpgrade.GetItemUpgradeItemInfo only reads the item in the open
-- upgrade UI (useless headless), so instead we read the item's own tooltip:
-- C_TooltipInfo.GetInventoryItem returns structured lines, and the upgrade line
-- reads "<Track> <cur>/<max>" (enUS Season-1 Dawn track names). Returns nil when
-- the API/line is absent so the slot simply omits the fields (graceful degrade).
local UPGRADE_TRACKS = {
  Adventurer = true, Veteran = true, Champion = true, Hero = true, Myth = true,
}
local function slotUpgrade(slotId)
  local getter = C_TooltipInfo and C_TooltipInfo.GetInventoryItem
  if type(getter) ~= "function" then return nil end
  local data = safe(getter, "player", slotId)
  if type(data) ~= "table" or type(data.lines) ~= "table" then return nil end
  for _, line in ipairs(data.lines) do
    local txt = type(line) == "table" and line.leftText
    if type(txt) == "string" then
      -- match anywhere in the line so a "Upgrade Level: " prefix is tolerated
      for word, cur, max in txt:gmatch("(%a+)%s+(%d+)/(%d+)") do
        if UPGRADE_TRACKS[word] then
          return word, tonumber(cur), tonumber(max), txt
        end
      end
    end
  end
  return nil
end

-- ------------------------------------------------------------------ equipment
-- Item/ilvl APIs are UNRELIABLE at PLAYER_LOGOUT (the client is tearing down —
-- this is why the pre-0.4 dump wrote equippedIlvl=0). So we snapshot equipment
-- on stable in-world events (login + equipment change) into equipCache and have
-- capture() reuse it, guaranteeing the logout write carries last-known-good gear.
-- (The tooltip-based track read rides the same cache, so it's read in-world too.)
local equipCache = nil

local function refreshEquip()
  local slots = {}
  for slotId, name in pairs(EQUIP_SLOTS) do
    local link = safe(GetInventoryItemLink, "player", slotId)
    if link then
      local track, ulevel, umax, utext = slotUpgrade(slotId)
      slots[#slots + 1] = {
        slot = name,
        slotId = slotId,
        ilvl = safe(C_Item and C_Item.GetDetailedItemLevelInfo, link),
        itemID = safe(GetInventoryItemID, "player", slotId),
        track = track,             -- "Champion" | "Hero" | … (nil if unreadable)
        upgradeLevel = ulevel,     -- current step, e.g. 5
        upgradeMax = umax,         -- track ceiling steps, e.g. 6
        upgradeText = utext,       -- raw tooltip line — parser fallback
      }
    end
  end
  -- GetAverageItemLevel() → (overall, equipped, pvp)
  local ok, overall, equipped = pcall(GetAverageItemLevel)
  if #slots > 0 then  -- only overwrite a good cache with another good read
    equipCache = {
      slots = slots,
      avgItemLevel = ok and overall or nil,
      equippedIlvl = ok and equipped or nil,
      updated = safe(GetServerTime),
    }
  end
  return equipCache
end

-- ------------------------------------------------------------------ scanners
-- Off-list ("hidden") currencies the visible currency panel doesn't enumerate, so
-- the GetCurrencyListInfo walk below never sees them. Read each directly by ID via
-- GetCurrencyInfo and append. ⚠ Only add IDs VERIFIED against the live build (wago
-- CurrencyTypes) — a wrong ID dumps garbage, worse than a gap.
-- Note (2026-07-10 datamine): the two we thought were hidden currencies aren't —
-- **catalyst charges = "Dawnlight Manaflux" (3378), a VISIBLE currency already
-- captured by scanCurrencies**, and **Ascendant Voidshard is an ITEM** (268650, in
-- ns.ITEMS). Table stays empty until a genuine off-list currency turns up.
ns.HIDDEN_CURRENCY_IDS = ns.HIDDEN_CURRENCY_IDS or {}

local function scanCurrencies()
  local out = {}
  local size = safe(C_CurrencyInfo and C_CurrencyInfo.GetCurrencyListSize) or 0
  for i = 1, size do
    local info = safe(C_CurrencyInfo.GetCurrencyListInfo, i)
    if info and not info.isHeader and (info.quantity or 0) > 0 then
      out[#out + 1] = {
        id = info.currencyTypesID,
        name = info.name,
        quantity = info.quantity,
        max = info.maxQuantity,
        weekly = info.quantityEarnedThisWeek,
        weeklyMax = info.maxWeeklyQuantity,
      }
    end
  end
  -- append the hidden-by-ID currencies (mechanism ships even while the table is
  -- empty; fill ns.HIDDEN_CURRENCY_IDS once the IDs are datamined)
  local getInfo = C_CurrencyInfo and C_CurrencyInfo.GetCurrencyInfo
  if type(getInfo) == "function" and type(ns.HIDDEN_CURRENCY_IDS) == "table" then
    for id, label in pairs(ns.HIDDEN_CURRENCY_IDS) do
      local info = safe(getInfo, id)
      if info and (info.quantity or 0) >= 0 then
        out[#out + 1] = {
          id = id,
          name = info.name or label,
          quantity = info.quantity,
          max = info.maxQuantity,
          weekly = info.quantityEarnedThisWeek,
          weeklyMax = info.maxWeeklyQuantity,
          hidden = true,
        }
      end
    end
  end
  return out
end

-- --------------------------------------------------------------- achievements
-- Account-wide "…of the Dawn" upgrade-track achievements. Each, once earned,
-- grants the 50% warband Dawncrest discount for that track (and unlocks the
-- Vaskarn crest-trade). Reading `completed` tells the planner directly whether
-- the discount is live, instead of inferring it from whether every slot hit the
-- track's ceiling ilvl. IDs from wago Achievement DB2 (live 12.0.7);
-- GetAchievementInfo is account-wide. See knowledge/endgame/dawncrests.md.
ns.DAWN_ACHIEVEMENTS = ns.DAWN_ACHIEVEMENTS or {
  [61809] = "adventurer",  -- 237 in every slot
  [42767] = "veteran",     -- 250
  [42768] = "champion",    -- 263  (unlocks the 50% Champion discount)
  [42769] = "hero",        -- 276
  [42770] = "myth",        -- 285
}
local function scanAchievements()
  if type(GetAchievementInfo) ~= "function" then return nil end
  local out = {}
  for id, label in pairs(ns.DAWN_ACHIEVEMENTS) do
    -- GetAchievementInfo → id, name, points, completed, ... (multi-return, so
    -- pcall directly rather than via safe(), which keeps only the first value)
    local ok, aid, _name, _points, completed = pcall(GetAchievementInfo, id)
    if ok and aid then
      out[#out + 1] = { id = id, label = label, completed = completed or false }
    end
  end
  return out
end

local function scanVault()
  local acts = safe(C_WeeklyRewards and C_WeeklyRewards.GetActivities)
  if not acts then return nil end
  local slots = {}
  for _, a in ipairs(acts) do
    slots[#slots + 1] = {
      type = VAULT_TYPE[a.type] or a.type,
      index = a.index,
      threshold = a.threshold,  -- runs/bosses required to unlock this slot
      progress = a.progress,    -- runs/bosses done toward it
      level = a.level,          -- reward ilvl / key level earned
      id = a.id,
    }
  end
  return {
    slots = slots,
    hasRewards = safe(C_WeeklyRewards.HasAvailableRewards) or false,
  }
end

local function scanMythicPlus()
  local runs = safe(C_MythicPlus and C_MythicPlus.GetRunHistory, false, true) or {}
  local out = {}
  for _, r in ipairs(runs) do
    out[#out + 1] = {
      mapChallengeModeID = r.mapChallengeModeID,
      level = r.level,
      completed = r.completed,
      thisWeek = r.thisWeek,
    }
  end
  return out
end

local function scanLockouts()
  local out = {}
  local n = safe(GetNumSavedInstances) or 0
  for i = 1, n do
    local ok, name, _id, reset, _diff, locked, _ext, _instID, isRaid,
          _maxP, diffName, maxBosses, defeated = pcall(GetSavedInstanceInfo, i)
    if ok and name and locked then
      out[#out + 1] = {
        name = name, difficulty = diffName, isRaid = isRaid,
        defeated = defeated, maxBosses = maxBosses, resetsIn = reset,
      }
    end
  end
  return out
end

-- World bosses are NOT returned by GetSavedInstanceInfo (scanLockouts is blind to
-- them — which is why candidates.json's old {type:lockout,name_contains:world}
-- gate never fired). GetSavedWorldBossInfo(i) lists ONLY bosses you've already
-- KILLED this reset, i.e. the weekly world-boss lockout signal itself. The planner
-- reads this under the top-level `worldBosses` key (world_boss_weekly gate).
local function scanWorldBosses()
  local out = {}
  local n = safe(GetNumSavedWorldBosses) or 0
  for i = 1, n do
    local ok, name, worldBossID = pcall(GetSavedWorldBossInfo, i)
    if ok and name then
      out[#out + 1] = { name = name, id = worldBossID }
    end
  end
  return out
end

-- Configurable per patch: the weekly quests + tracked items the planner cares
-- about. Value is the candidates.json gate slug (plan.py matches on it). Only add
-- IDs verified for the LIVE build — a wrong/stale ID false-reports "done", which
-- is worse than a gap. Verified 2026-07-02 against QuestV2 in build 12.0.7.68367
-- + Wowhead title/objective. Multiple IDs may share a slug (rotating weeklies);
-- plan.py's weekly_quest gate treats the slug as done if ANY mapped quest is done.
ns.WEEKLY_QUESTS = ns.WEEKLY_QUESTS or {
  [94446] = "prey_weekly",    -- "A Nightmarish Task" — obj "Nightmare Hunts completed (3)"  [high]
  [94385] = "void_assault",   -- "Void Assaults: Eversong Woods"  (rotates weekly with 94386) [high]
  [94386] = "void_assault",   -- "Void Assaults: Zul'Aman"        (rotates weekly with 94385) [high]

  -- Hand-vetted from the active-quest-log discovery (2026-07-09, off Uncomplete's
  -- live log — ID<->title confirmed by the dump, so no false-"done" risk). Slugs
  -- are intentionally UNIQUE (not reusing candidate gate slugs) so these only
  -- track completion / stop re-discovery and can't accidentally gate a candidate.
  -- Promote a slug to a real candidate gate only after confirming the mapping.
  [95843] = "ritual_sites_weekly",  -- "Midnight: Ritual Sites"  (weekly ritual pillar)      [high]
  [93595] = "delve_call_weekly",    -- "A Call to Delves"        (weekly delve)               [high]
  [93755] = "nalorakk_weekly",      -- "Den of Nalorakk"         (weekly dungeon)             [high]
  [94390] = "special_assignment",   -- "Special Assignment: A Hunter's Regret"                [high]
  [82146] = "special_assignment",   -- "Special Assignment: Cinderbee Surge"                  [high]
  [82156] = "special_assignment",   -- "Special Assignment: When the Deeps Stir"              [high]

  -- UNRESOLVED — leads only, deliberately NOT active (would false-report done):
  --   delve_weekly_cache   : 93909 "Midnight: Delves" is a spark-PILLAR meta, not the bountiful-cache quest — unconfirmed
  --   housing_weekly       : 93769 "Midnight: Housing" is the spark-pillar wrapper; the "from Vaeli" quest-of-week rotates
  --   delve_tier_objective : no discrete weekly quest (Tier 11 is Great Vault progression, not a quest flag)
  --   dungeon_weekly       : Halduron Brightwing 1500-rep weekly — name/ID not exposed by any source
  --   liadrin_spark        : several Liadrin spark weeklies (93744 / 95245 / pillars) — couldn't confirm which
}
ns.ITEMS = ns.ITEMS or {
  -- [itemID] = "label" — dumped via GetItemCount (count-in-bags+bank). Verify each ID
  -- against the live build; a wrong ID silently dumps the wrong item's count.
  [232875] = "spark_of_radiance",    -- Spark of Radiance — S1 crafting spark (verified item API 2026-07-10)
  [268650] = "ascendant_voidshard",  -- Ascendant Voidshard — 5 → 1 Voidcore, weapon/trinket overcap mat (verified 2026-07-10)
}

-- ns.WEEKLY_QUESTS (hand-verified, slug-labelled) takes precedence over
-- ns.GENERATED_QUESTS (auto-wired from repeatables.json by the planner's
-- gen_addon_quests tool — numeric-ID gated). Dedup by id, hand map first, so a
-- verified slug never gets clobbered by a generated numeric label.
-- Rolled-up objective progress (have/need) across a quest's countable objectives
-- — e.g. prey's "Nightmare Hunts 1/3". Only available while the quest is in the
-- log (GetQuestObjectives returns nil once turned in), so partial progress rides
-- alongside the `complete` flag rather than replacing it. nil,nil when unknown.
local function questProgress(id)
  local objs = safe(C_QuestLog and C_QuestLog.GetQuestObjectives, id)
  if type(objs) ~= "table" then return nil end
  local have, need = 0, 0
  for _, o in ipairs(objs) do
    if type(o) == "table" and (o.numRequired or 0) > 0 then
      have = have + (o.numFulfilled or 0)
      need = need + o.numRequired
    end
  end
  if need == 0 then return nil end
  return have, need
end

local function scanQuests()
  local out, seen = {}, {}
  local function add(id, label)
    id = tonumber(id) or id
    if seen[id] then return end
    seen[id] = true
    local have, need = questProgress(id)
    out[#out + 1] = {
      id = id, label = label,
      complete = safe(C_QuestLog and C_QuestLog.IsQuestFlaggedCompleted, id) or false,
      have = have, need = need,
    }
  end
  for id, label in pairs(ns.WEEKLY_QUESTS) do add(id, label) end
  if type(ns.GENERATED_QUESTS) == "table" then
    for id, label in pairs(ns.GENERATED_QUESTS) do add(id, label) end
  end
  return out
end

local function scanItems()
  local out = {}
  for id, label in pairs(ns.ITEMS) do
    out[#out + 1] = { id = id, label = label, count = safe(GetItemCount, id, true) or 0 }
  end
  return out
end

-- ------------------------------------------------------------- active quest log
-- The FULL set of quests currently ACCEPTED (not yet turned in), so the planner
-- can discover weeklies/dailies/campaign quests without a hand-maintained
-- watchlist. Complements scanQuests(): the watchlist detects completion AFTER a
-- quest leaves the log (IsQuestFlaggedCompleted), while this sees only in-progress
-- quests but needs zero curation — the planner cross-references the two, and
-- auto-promotes unknown weekly-frequency IDs it sees here into its master list.
-- `frequency` is the raw Enum.QuestFrequency (0 default / 1 daily / 2 weekly);
-- dumped raw so plan.py owns the interpretation. `classification` is the raw
-- Enum.QuestClassification and `important` is the derived flag for Blizzard's
-- "Important" tag (the purple-! in the UI) — a strong "this matters" signal the
-- planner/discovery can rank on. Headers are skipped.
local function scanQuestLog()
  local out = {}
  local n = safe(C_QuestLog and C_QuestLog.GetNumQuestLogEntries) or 0
  for i = 1, n do
    local info = safe(C_QuestLog.GetInfo, i)
    if type(info) == "table" and not info.isHeader and info.questID and info.questID > 0 then
      local have, need = questProgress(info.questID)
      local cls = safe(C_QuestInfoSystem and C_QuestInfoSystem.GetQuestClassification, info.questID)
      out[#out + 1] = {
        id = info.questID,
        title = info.title,
        frequency = info.frequency,   -- Enum.QuestFrequency: 0 default, 1 daily, 2 weekly
        campaign = info.campaignID,   -- >0 when the quest belongs to a campaign
        isComplete = safe(C_QuestLog.IsComplete, info.questID) or false,  -- objectives done, ready to hand in
        classification = cls,         -- raw Enum.QuestClassification (Important/Campaign/Legendary/Meta/…)
        important = (Enum and Enum.QuestClassification
                     and cls == Enum.QuestClassification.Important) or false,  -- purple-! tag
        have = have, need = need,
      }
    end
  end
  return out
end

-- ------------------------------------------------------------------ calendar
-- The in-game event calendar (HOLIDAY events: Timewalking, Darkmoon Faire, world
-- events, micro-holidays) is the ONLY source for what's live/upcoming — it is
-- NOT in the Blizzard REST API. C_Calendar loads asynchronously, so we prime it
-- with OpenCalendar() at login (see lifecycle) and read the warmed data here.
-- Holidays only, deduped to one record per event with an `active` flag the
-- planner's fun-radar gate keys on.

-- CalendarTime {year,month,monthDay,hour,...} -> sortable YYYYMMDDHH integer.
local function timeRank(t)
  if type(t) ~= "table" then return nil end
  return (((t.year or 0) * 100 + (t.month or 0)) * 100
         + (t.monthDay or 0)) * 100 + (t.hour or 0)
end

-- CalendarTime -> "YYYY-MM-DD" (nil-safe).
local function isoDate(t)
  if type(t) ~= "table" then return nil end
  return string.format("%04d-%02d-%02d", t.year or 0, t.month or 0, t.monthDay or 0)
end

local function scanCalendar()
  local Cal = C_Calendar
  if not Cal or type(Cal.GetNumDayEvents) ~= "function" then return nil end
  safe(Cal.OpenCalendar)  -- idempotent; harmless if already primed at login
  local now = safe(C_DateAndTime and C_DateAndTime.GetCurrentCalendarTime)
  if type(now) ~= "table" then return nil end
  local nowRank = timeRank(now)

  -- Anchor the browsing baseline on the current real month, then walk this
  -- month (from today onward) + next month, collecting HOLIDAY events. A
  -- multi-day holiday shows up as one day-event per day it spans, so dedupe by
  -- title, keeping the widest start..end seen.
  safe(Cal.SetAbsMonth, now.month, now.year)
  local byTitle = {}
  for _, mo in ipairs({ 0, 1 }) do
    local mi = safe(Cal.GetMonthInfo, mo)
    local numDays = (type(mi) == "table" and mi.numDays) or 0
    local firstDay = (mo == 0) and (now.monthDay or 1) or 1
    for day = firstDay, numDays do
      local nEvents = safe(Cal.GetNumDayEvents, mo, day) or 0
      for i = 1, nEvents do
        local ev = safe(Cal.GetDayEvent, mo, day, i)
        if type(ev) == "table" and ev.calendarType == "HOLIDAY" and ev.title then
          local sRank, eRank = timeRank(ev.startTime), timeRank(ev.endTime)
          local rec = byTitle[ev.title]
          if not rec then
            byTitle[ev.title] = {
              title = ev.title, startRank = sRank, endRank = eRank,
              startTime = isoDate(ev.startTime), endTime = isoDate(ev.endTime),
            }
          else
            if sRank and (not rec.startRank or sRank < rec.startRank) then
              rec.startRank, rec.startTime = sRank, isoDate(ev.startTime)
            end
            if eRank and (not rec.endRank or eRank > rec.endRank) then
              rec.endRank, rec.endTime = eRank, isoDate(ev.endTime)
            end
          end
        end
      end
    end
  end

  local out = {}
  for _, rec in pairs(byTitle) do
    out[#out + 1] = {
      title = rec.title,
      active = (nowRank and rec.startRank and rec.endRank
                and rec.startRank <= nowRank and nowRank <= rec.endRank) or false,
      startTime = rec.startTime,
      endTime = rec.endTime,
    }
  end
  return out
end

-- ------------------------------------------------------------------- capture
local function capture()
  local _, classFile = pcall(function() return select(2, UnitClass("player")) end)
  -- Prefer the cache warmed in-world; only scan live if it's still empty (e.g.
  -- /ps fired before the login refresh landed). Never trust a logout-time scan.
  local eq = (equipCache and equipCache.slots and #equipCache.slots > 0)
             and equipCache or refreshEquip() or {}

  PlannerStateDB = {
    schema = 8,
    updated = safe(GetServerTime) or (time and time()) or 0,
    character = safe(UnitName, "player"),
    realm = safe(GetRealmName),
    faction = safe(UnitFactionGroup, "player"),
    class = classFile,
    level = safe(UnitLevel, "player"),
    equippedIlvl = eq.equippedIlvl,
    avgItemLevel = eq.avgItemLevel,
    equipment = eq.slots,
    money = safe(GetMoney),
    secondsUntilWeeklyReset = safe(C_DateAndTime and C_DateAndTime.GetSecondsUntilWeeklyReset),
    vault = scanVault(),
    mythicPlus = scanMythicPlus(),
    lockouts = scanLockouts(),
    worldBosses = scanWorldBosses(),
    currencies = scanCurrencies(),
    achievements = scanAchievements(),
    weeklyQuests = scanQuests(),
    activeQuests = scanQuestLog(),
    items = scanItems(),
    calendar = scanCalendar(),
  }
  return PlannerStateDB
end

-- ----------------------------------------------------------------- lifecycle
local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_LOGOUT")
frame:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
frame:SetScript("OnEvent", function(_, event)
  if event == "PLAYER_LOGIN" then
    safe(C_Calendar and C_Calendar.OpenCalendar)  -- prime async calendar load
    -- Item data isn't fully loaded at login; warm the equip cache a beat later.
    if C_Timer and C_Timer.After then C_Timer.After(2, refreshEquip) else refreshEquip() end
  elseif event == "PLAYER_EQUIPMENT_CHANGED" then
    refreshEquip()
  else  -- PLAYER_LOGOUT
    pcall(capture)  -- never let a scan error block logout / the save
  end
end)

SLASH_PLANNERSTATE1 = "/ps"
SLASH_PLANNERSTATE2 = "/plannerstate"
SlashCmdList["PLANNERSTATE"] = function()
  local ok = pcall(capture)
  if ok then
    print("|cff33ff99PlannerState|r captured — type /reload or log out to write it to disk.")
  else
    print("|cffff5555PlannerState|r capture failed (some API unavailable on this client).")
  end
end
