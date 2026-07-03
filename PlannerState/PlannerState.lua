--[[  PlannerState
      Captures the reset-state the Blizzard profile API can't see (Great Vault
      slot progress, M+ runs this week, raid lockouts, per-currency weekly-earned,
      configured weekly quests + items) and writes it to SavedVariables so the
      session planner can subtract "what I've already done this reset."

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

-- Enum.WeeklyRewardChestThresholdType → readable slot type.
local VAULT_TYPE = { [1] = "raid", [2] = "dungeon", [3] = "world", [4] = "pvp" }

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

-- Configurable per patch: the weekly quests + tracked items the planner cares
-- about. Fill these with real IDs (see README) — left empty by default so the
-- addon never reports false completions.
ns.WEEKLY_QUESTS = ns.WEEKLY_QUESTS or {
  -- [questID] = "label",   e.g. [80123] = "Liadrin spark weekly",
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

-- ------------------------------------------------------------------- capture
local function capture()
  local _, classFile = pcall(function() return select(2, UnitClass("player")) end)
  local _, equippedIL = pcall(function() return select(2, GetAverageItemLevel()) end)

  PlannerStateDB = {
    schema = 1,
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
    currencies = scanCurrencies(),
    weeklyQuests = scanQuests(),
    items = scanItems(),
  }
  return PlannerStateDB
end

-- ----------------------------------------------------------------- lifecycle
local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGOUT")
frame:SetScript("OnEvent", function()
  pcall(capture)  -- never let a scan error block logout / the save
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
