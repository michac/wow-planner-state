--[[  PlannerState
      Captures the reset-state the Blizzard profile API can't see (Great Vault
      slot progress, M+ runs this week, raid lockouts, world-boss weekly kills,
      per-currency weekly-earned, configured weekly quests + items, and the
      in-game event calendar) and writes
      it to SavedVariables so the session planner can subtract "what I've already
      done this reset" and surface live/upcoming holiday events (the fun radar).

      Data flows out on PLAYER_LOGOUT (always current at logout) or on demand
      via /ps — SavedVariables only flush to disk on logout/reload, so after
      /ps you still need /reload to persist.

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

-- ------------------------------------------------------------------ scanners
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

  -- UNRESOLVED — leads only, deliberately NOT active (would false-report done):
  --   delve_weekly_cache   : 93909 "Midnight: Delves" is a spark-PILLAR meta, not the bountiful-cache quest — unconfirmed
  --   housing_weekly       : 93769 "Midnight: Housing" is the spark-pillar wrapper; the "from Vaeli" quest-of-week rotates
  --   delve_tier_objective : no discrete weekly quest (Tier 11 is Great Vault progression, not a quest flag)
  --   dungeon_weekly       : Halduron Brightwing 1500-rep weekly — name/ID not exposed by any source
  --   liadrin_spark        : several Liadrin spark weeklies (93744 / 95245 / pillars) — couldn't confirm which
}
ns.ITEMS = ns.ITEMS or {
  -- [itemID]  = "label",   e.g. [246111] = "Spark of Radiance",
}

local function scanQuests()
  local out = {}
  for id, label in pairs(ns.WEEKLY_QUESTS) do
    out[#out + 1] = {
      id = id, label = label,
      complete = safe(C_QuestLog and C_QuestLog.IsQuestFlaggedCompleted, id) or false,
    }
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
  local _, equippedIL = pcall(function() return select(2, GetAverageItemLevel()) end)

  PlannerStateDB = {
    schema = 3,
    updated = safe(GetServerTime) or (time and time()) or 0,
    character = safe(UnitName, "player"),
    realm = safe(GetRealmName),
    faction = safe(UnitFactionGroup, "player"),
    class = classFile,
    level = safe(UnitLevel, "player"),
    equippedIlvl = equippedIL,
    money = safe(GetMoney),
    secondsUntilWeeklyReset = safe(C_DateAndTime and C_DateAndTime.GetSecondsUntilWeeklyReset),
    vault = scanVault(),
    mythicPlus = scanMythicPlus(),
    lockouts = scanLockouts(),
    worldBosses = scanWorldBosses(),
    currencies = scanCurrencies(),
    weeklyQuests = scanQuests(),
    items = scanItems(),
    calendar = scanCalendar(),
  }
  return PlannerStateDB
end

-- ----------------------------------------------------------------- lifecycle
local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_LOGOUT")
frame:SetScript("OnEvent", function(_, event)
  if event == "PLAYER_LOGIN" then
    safe(C_Calendar and C_Calendar.OpenCalendar)  -- prime async calendar load
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
