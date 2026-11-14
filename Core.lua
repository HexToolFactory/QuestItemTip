-- QuestItemTip: shows in an item's tooltip which quests the item belongs to.
--
--   Needed for      the item is a quest objective, or is needed to do the quest without being counted
--   Used for        the item is used to complete an objective
--   Provided for    the quest giver hands the item out with the quest
--   Starts          using the item starts the quest
--   Related to      the database links the item to the quest without saying how
--   Reward from     the quest rewards the item (off by default)
--
-- Two sources are combined:
--   1. QuestieDB (optional). Its quests name their items, so one pass over all quests at login builds the
--      reverse table item -> quests. That covers quests that are not in the log, which is the point: it tells
--      whether a drop is worth keeping.
--   2. The quest log. An item objective is matched by its name, which also covers quests the database lacks.
--
-- After a quest is handed in, quest items of it that are still in the bags and belong to no quest that is
-- still open are offered for deletion (see "Leftover quest items").
--
-- Values from the game can be secret on this client (instances, combat). A secret is never compared or
-- indexed here; the tooltip then simply gets no line.
local ADDON = ...

local PREFIX = "|cffffd100QuestItemTip|r "
local BUILD_DELAY = 5           -- seconds after login before the index build starts
local BUILD_BUDGET_MS = 4       -- time per frame the build may use

local defaults = {
  enabled = true,
  showDone = true,              -- quests already completed
  showOther = false,            -- quests of the other faction or another class
  showRewards = false,          -- "Reward from" lines
  showIds = false,              -- quest IDs behind the names
  maxLines = 6,
  askDelete = true,             -- ask to delete leftover quest items after handing a quest in
  keep = {},                    -- [itemId] = true: answered "Keep", never asked again
}

local ROLE = {
  objective = { prio = 1, label = "Needed for" },
  required  = { prio = 2, label = "Needed for" },
  used      = { prio = 3, label = "Used for" },
  provided  = { prio = 4, label = "Provided for" },
  starts    = { prio = 5, label = "Starts" },
  related   = { prio = 6, label = "Related to" },
  reward    = { prio = 7, label = "Reward from" },
}

local STATE_ORDER = { log = 1, open = 2, done = 3, other = 4 }

local db
local lib                       -- LibQuestieDB, when usable
local index = {}                -- [itemId] = { [questId] = role }
local indexReady = false
local build                     -- running build: { ids, pos, started, frames }
local generation = 0            -- bumped whenever a cached tooltip result may be stale
local cache = {}                -- [itemId] = { gen = generation, lines = {...} }
local logSnapshot, logGeneration
local playerRaceMask, playerClassMask
local justDone = {}             -- quests handed in this session; the game's completed flag can lag behind the event
local hookedClear = {}
local shownOn = {}              -- [tooltip] = itemId whose lines are on it right now

local function IsSecret(v) return issecretvalue ~= nil and issecretvalue(v) end
local function PublicTable(t)
  return not IsSecret(t) and type(t) == "table" and not (issecrettable ~= nil and issecrettable(t))
end
local function PlainNumber(v) if not IsSecret(v) and type(v) == "number" then return v end end
local function PlainString(v) if not IsSecret(v) and type(v) == "string" and v ~= "" then return v end end

local function Print(text) print(PREFIX .. text) end

local function Invalidate() generation = generation + 1 end

------------------------------------------------------------------------
-- QuestieDB access
------------------------------------------------------------------------
local function QuestField(questId, key)
  if not lib then return nil end
  local ok, value = pcall(lib.Quest.Get, questId, key)
  if ok then return value end
end

local function ItemField(itemId, key)
  if not lib then return nil end
  local ok, value = pcall(lib.Item.Get, itemId, key)
  if ok then return value end
end

local function FindLibrary()
  local candidate = _G.LibQuestieDB
  if type(candidate) ~= "table" then return nil end
  local quest, item = candidate.Quest, candidate.Item
  if type(quest) ~= "table" or type(item) ~= "table" then return nil end
  if type(quest.Get) ~= "function" or type(quest.GetAllIds) ~= "function" or type(item.Get) ~= "function" then
    return nil
  end
  return candidate
end

------------------------------------------------------------------------
-- Index: item -> quests
------------------------------------------------------------------------
local function Link(itemId, questId, role)
  if type(itemId) ~= "number" or itemId <= 0 then return end
  local quests = index[itemId]
  if not quests then
    quests = {}
    index[itemId] = quests
  end
  local known = quests[questId]
  if not known or ROLE[role].prio < ROLE[known].prio then quests[questId] = role end
end

local function IndexQuest(questId)
  local objectives = lib.Quest.Get(questId, "objectives")
  if type(objectives) == "table" then
    local items = objectives[3]
    if type(items) == "table" then
      for _, entry in pairs(items) do
        if type(entry) == "table" then Link(entry[1], questId, "objective") end
      end
    end
    local spells = objectives[6]          -- { spellId, text, itemId }: the item that casts the spell
    if type(spells) == "table" then
      for _, entry in pairs(spells) do
        if type(entry) == "table" then Link(entry[3], questId, "used") end
      end
    end
  end

  local required = lib.Quest.Get(questId, "requiredSourceItems")
  if type(required) == "table" then
    for _, itemId in pairs(required) do Link(itemId, questId, "required") end
  end

  Link(lib.Quest.Get(questId, "sourceItemId"), questId, "provided")

  local startedBy = lib.Quest.Get(questId, "startedBy")
  if type(startedBy) == "table" and type(startedBy[3]) == "table" then
    for _, itemId in pairs(startedBy[3]) do Link(itemId, questId, "starts") end
  end
end

local buildFrame = CreateFrame("Frame")
buildFrame:Hide()

local function FinishBuild()
  buildFrame:Hide()
  local items, links = 0, 0
  for _, quests in pairs(index) do
    items = items + 1
    for _ in pairs(quests) do links = links + 1 end
  end
  db.diag.index = {
    quests = #build.ids, items = items, links = links, errors = build.errors,
    seconds = time() - build.started, frames = build.frames, at = time(),
  }
  build = nil
  indexReady = true
  Invalidate()
end

buildFrame:SetScript("OnUpdate", function()
  if not build then buildFrame:Hide() return end
  build.frames = build.frames + 1
  local ids, stop = build.ids, debugprofilestop() + BUILD_BUDGET_MS
  while build.pos <= #ids do
    local questId = ids[build.pos]
    build.pos = build.pos + 1
    local ok, err = pcall(IndexQuest, questId)
    if not ok then
      build.errors = build.errors + 1
      db.diag.lastError = ("quest %s: %s"):format(tostring(questId), tostring(err))
    end
    if debugprofilestop() >= stop then return end
  end
  FinishBuild()
end)

local function StartBuild()
  if not lib or build then return end
  local ok, ids = pcall(lib.Quest.GetAllIds)
  if not ok or type(ids) ~= "table" then
    db.diag.lastError = "quest list unavailable: " .. tostring(ids)
    return
  end
  index, indexReady = {}, false
  build = { ids = ids, pos = 1, started = time(), frames = 0, errors = 0 }
  buildFrame:Show()
end

------------------------------------------------------------------------
-- Quest log
------------------------------------------------------------------------
-- "Wolf Pelt: 3/8" and "3/8 Wolf Pelt" both name the item "Wolf Pelt".
local function ObjectiveName(text)
  local name = text:gsub("%s*:%s*%d+%s*/%s*%d+%s*$", "")
  name = name:gsub("^%s*%d+%s*/%s*%d+%s+", "")
  return name
end

local function ReadLog()
  local snapshot = {}
  local api = C_QuestLog
  if not (api and api.GetNumQuestLogEntries and api.GetInfo) then return snapshot end
  local count = PlainNumber(api.GetNumQuestLogEntries())
  for i = 1, count or 0 do
    local info = api.GetInfo(i)
    if PublicTable(info) then
      local questId, isHeader = PlainNumber(info.questID), info.isHeader
      if questId and questId > 0 and not IsSecret(isHeader) and not isHeader then
        local entry = { title = PlainString(info.title), level = PlainNumber(info.level), objectives = {} }
        local objectives = api.GetQuestObjectives and api.GetQuestObjectives(questId)
        if PublicTable(objectives) then
          for _, objective in ipairs(objectives) do
            if PublicTable(objective) then
              local text = PlainString(objective.text)
              if text then
                entry.objectives[#entry.objectives + 1] = {
                  name = ObjectiveName(text),
                  have = PlainNumber(objective.numFulfilled),
                  need = PlainNumber(objective.numRequired),
                }
              end
            end
          end
        end
        snapshot[questId] = entry
      end
    end
  end
  return snapshot
end

local function Log()
  if logGeneration ~= generation or not logSnapshot then
    local ok, snapshot = pcall(ReadLog)
    logSnapshot = ok and snapshot or {}
    logGeneration = generation
  end
  return logSnapshot
end

local function Flag(func, questId)
  if type(func) ~= "function" then return false end
  local ok, value = pcall(func, questId)
  return ok and not IsSecret(value) and value == true
end

------------------------------------------------------------------------
-- What to show for one item
------------------------------------------------------------------------
-- Race masks here go beyond 32 bits, which bit.band cuts off. `flag` is a single power of two.
local function MaskHas(mask, flag)
  return math.floor(mask / flag) % 2 == 1
end

local function Eligible(questId)
  local races = QuestField(questId, "requiredRaces")
  if type(races) == "number" and races > 0 and playerRaceMask and not MaskHas(races, playerRaceMask) then
    return false
  end
  local classes = QuestField(questId, "requiredClasses")
  if type(classes) == "number" and classes > 0 and playerClassMask and not MaskHas(classes, playerClassMask) then
    return false
  end
  return true
end

local function ItemName(itemId)
  local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
  if type(getInfo) == "function" then
    local ok, name = pcall(getInfo, itemId)
    if ok and PlainString(name) then return name end
  end
  local name = ItemField(itemId, "name")
  if type(name) == "string" and name ~= "" then return name end
end

local function Collect(itemId, withRewards)
  local roles = {}
  local function Add(questId, role)
    if type(questId) ~= "number" or questId <= 0 then return end
    local known = roles[questId]
    if not known or ROLE[role].prio < ROLE[known].prio then roles[questId] = role end
  end

  if index[itemId] then
    for questId, role in pairs(index[itemId]) do Add(questId, role) end
  end
  if lib then
    Add(ItemField(itemId, "startQuest"), "starts")
    local related = ItemField(itemId, "relatedQuests")
    if type(related) == "table" then
      for _, questId in pairs(related) do Add(questId, "related") end
    end
    if withRewards then
      local rewards = ItemField(itemId, "questRewards")
      if type(rewards) == "table" then
        for _, questId in pairs(rewards) do Add(questId, "reward") end
      end
    end
  end

  local log, progress = Log(), {}
  local name = ItemName(itemId)
  for questId, entry in pairs(log) do
    for _, objective in ipairs(entry.objectives) do
      if name and objective.name == name then
        Add(questId, "objective")
        progress[questId] = objective
        break
      end
    end
  end
  return roles, progress, log
end

-- A repeatable quest is never done for good: its items stay useful after handing it in.
local function Repeatable(questId)
  local special = QuestField(questId, "specialFlags")
  if type(special) == "number" and special % 2 == 1 then return true end
  local flags = QuestField(questId, "questFlags")      -- 4096 daily, 32768 weekly
  if type(flags) == "number" and flags > 0 and (MaskHas(flags, 4096) or MaskHas(flags, 32768)) then return true end
  return Flag(C_QuestLog and C_QuestLog.IsRepeatableQuest, questId)
end

local function QuestState(questId, log)
  if log[questId] or Flag(C_QuestLog and C_QuestLog.IsOnQuest, questId) then return "log" end
  if (justDone[questId] or Flag(C_QuestLog and C_QuestLog.IsQuestFlaggedCompleted, questId))
    and not Repeatable(questId) then
    return "done"
  end
  if not Eligible(questId) then return "other" end
  return "open"
end

local function QuestTitle(questId, log)
  local inLog = log and log[questId]
  local title = (inLog and inLog.title) or QuestField(questId, "name")
  if type(title) == "string" and title ~= "" then return title end
  local getTitle = C_QuestLog and C_QuestLog.GetTitleForQuestID
  local ok, found = pcall(getTitle or error, questId)
  return ok and PlainString(found) or ("Quest " .. questId)
end

local function Describe(itemId)
  local roles, progress, log = Collect(itemId, db.showRewards)
  local playerLevel = PlainNumber(UnitLevel("player")) or 0
  local quests = {}

  for questId, role in pairs(roles) do
    local inLog = log[questId]
    local title = QuestTitle(questId, log)
    local level = QuestField(questId, "questLevel")
    if type(level) ~= "number" or level <= 0 then level = inLog and inLog.level or nil end

    local state = QuestState(questId, log)

    if (state ~= "done" or db.showDone) and (state ~= "other" or db.showOther) then
      local status, r, g, b
      if state == "log" then
        local objective = progress[questId]
        if objective and objective.have and objective.need and objective.need > 0 then
          status = ("In log %d/%d"):format(objective.have, objective.need)
          if objective.have >= objective.need then r, g, b = 0.25, 1, 0.25 else r, g, b = 1, 1, 1 end
        else
          status, r, g, b = "In log", 1, 1, 1
        end
      elseif state == "done" then
        status, r, g, b = "Completed", 0.5, 0.5, 0.5
      elseif state == "other" then
        status, r, g, b = "Not for you", 0.5, 0.5, 0.5
      else
        local needs = QuestField(questId, "requiredLevel")
        if type(needs) == "number" and needs > playerLevel then
          status, r, g, b = ("From level %d"):format(needs), 1, 0.5, 0.25
        else
          status, r, g, b = "Not started", 0.75, 0.75, 0.75
        end
      end
      quests[#quests + 1] = {
        id = questId, role = role, state = state, title = title, level = level,
        status = status, r = r, g = g, b = b,
      }
    end
  end

  table.sort(quests, function(a, b)
    if a.state ~= b.state then return STATE_ORDER[a.state] < STATE_ORDER[b.state] end
    if a.role ~= b.role then return ROLE[a.role].prio < ROLE[b.role].prio end
    if (a.level or 0) ~= (b.level or 0) then return (a.level or 0) < (b.level or 0) end
    return a.id < b.id
  end)

  -- Several quests can share one name (a repeatable twin, one per faction). Without quest IDs their lines
  -- would read the same, so only the first of each kind stays.
  if not db.showIds then
    local seen, unique = {}, {}
    for _, quest in ipairs(quests) do
      local key = table.concat({ ROLE[quest.role].label, quest.title, quest.level or 0, quest.status }, "\0")
      if not seen[key] then
        seen[key] = true
        unique[#unique + 1] = quest
      end
    end
    quests = unique
  end

  local lines = {}
  local limit = math.max(1, db.maxLines or defaults.maxLines)
  for i, quest in ipairs(quests) do
    if i > limit then
      lines[#lines + 1] = { left = ("|cff808080... and %d more quests|r"):format(#quests - limit) }
      break
    end
    local name = quest.title
    if quest.level then name = ("[%d] %s"):format(quest.level, name) end
    if db.showIds then name = ("%s (%d)"):format(name, quest.id) end

    local nr, ng, nb = 1, 0.82, 0
    if quest.state == "done" or quest.state == "other" then
      nr, ng, nb = 0.5, 0.5, 0.5
    elseif quest.level and type(GetQuestDifficultyColor) == "function" then
      local ok, color = pcall(GetQuestDifficultyColor, quest.level)
      if ok and type(color) == "table" and type(color.r) == "number" then nr, ng, nb = color.r, color.g, color.b end
    end
    local label = (quest.state == "done" or quest.state == "other") and "|cff808080%s:|r %s" or "|cffffd100%s:|r %s"
    lines[#lines + 1] = {
      left = label:format(ROLE[quest.role].label, name), lr = nr, lg = ng, lb = nb,
      right = quest.status, rr = quest.r, rg = quest.g, rb = quest.b,
    }
  end
  return lines
end

local function LinesFor(itemId)
  local cached = cache[itemId]
  if cached and cached.gen == generation then return cached.lines end
  local ok, lines = pcall(Describe, itemId)
  if not ok then
    db.diag.lastError = ("item %s: %s"):format(tostring(itemId), tostring(lines))
    lines = {}
  end
  -- While the index is still being built an answer can be incomplete, so it is not kept.
  if indexReady or not lib then cache[itemId] = { gen = generation, lines = lines } end
  return lines
end

------------------------------------------------------------------------
-- Tooltip
------------------------------------------------------------------------
local function TooltipItemId(tooltip, data)
  if PublicTable(data) then
    local id = PlainNumber(data.id)
    if id then return id end
  end
  if type(tooltip.GetItem) == "function" then
    local ok, _, link = pcall(tooltip.GetItem, tooltip)
    if ok and PlainString(link) then return tonumber(link:match("item:(%d+)")) end
  end
end

local function OnItemTooltip(tooltip, data)
  if not db or not db.enabled or type(tooltip) ~= "table" then return end
  if tooltip.IsForbidden and tooltip:IsForbidden() then return end
  if tooltip == ShoppingTooltip1 or tooltip == ShoppingTooltip2 then return end   -- the compare tooltips
  if type(tooltip.AddDoubleLine) ~= "function" then return end

  local itemId = TooltipItemId(tooltip, data)
  if not itemId then return end

  if not hookedClear[tooltip] and type(tooltip.HookScript) == "function"
    and tooltip.HasScript and tooltip:HasScript("OnTooltipCleared") then
    hookedClear[tooltip] = true
    tooltip:HookScript("OnTooltipCleared", function(self) shownOn[self] = nil end)
  end
  -- One rebuild can report the same item twice; the lines go on once.
  if hookedClear[tooltip] then
    if shownOn[tooltip] == itemId then return end
    shownOn[tooltip] = itemId
  end

  local lines = LinesFor(itemId)
  for _, line in ipairs(lines) do
    if line.right then
      tooltip:AddDoubleLine(line.left, line.right, line.lr, line.lg, line.lb, line.rr, line.rg, line.rb)
    else
      tooltip:AddLine(line.left)
    end
  end
  db.diag.lastItem = { id = itemId, lines = #lines, at = time() }
end

local function SafeItemTooltip(tooltip, data)
  local ok, err = pcall(OnItemTooltip, tooltip, data)
  if not ok and db then db.diag.lastError = "tooltip: " .. tostring(err) end
end

local function HookTooltips()
  local modern = type(GameTooltip.GetPrimaryTooltipData) == "function"
    and TooltipDataProcessor and type(TooltipDataProcessor.AddTooltipPostCall) == "function"
    and Enum and Enum.TooltipDataType and Enum.TooltipDataType.Item
  if modern then
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, SafeItemTooltip)
    return "TooltipDataProcessor"
  end
  local hooked = false
  for _, tooltip in ipairs({ GameTooltip, ItemRefTooltip }) do
    if tooltip and tooltip.HasScript and tooltip:HasScript("OnTooltipSetItem") then
      tooltip:HookScript("OnTooltipSetItem", SafeItemTooltip)
      hooked = true
    end
  end
  return hooked and "OnTooltipSetItem" or "none"
end

------------------------------------------------------------------------
-- Leftover quest items
------------------------------------------------------------------------
-- An item is offered for deletion only when all of this holds:
--   * the quest index is complete, so every quest that names the item is known
--   * the game classes it as a quest item (keys, reagents and gear are never offered)
--   * no quest rewards it
--   * every quest it belongs to is completed, or closed to this character (other faction or class), and at
--     least one is completed. A quest in the log, a quest not started and a repeatable quest all block it.
local QUEST_ITEM_CLASS = (Enum and Enum.ItemClass and Enum.ItemClass.Questitem) or 12
local askQueue, asking = {}, nil
local prompt

local function ItemInfo(itemId)
  local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
  if type(getInfo) ~= "function" then return nil end
  local ok, name, link, _, _, _, _, _, _, _, icon, _, classId = pcall(getInfo, itemId)
  if not ok or not PlainString(name) then return nil end
  return { name = name, link = PlainString(link), icon = not IsSecret(icon) and icon or nil, classId = PlainNumber(classId) }
end

-- Returns the quests the item belongs to and one completed quest among them, or nil when it may still be needed.
local function Leftover(itemId)
  if not lib or not indexReady then return nil end
  local info = ItemInfo(itemId)
  if not info or info.classId ~= QUEST_ITEM_CLASS then return nil end
  local rewards = ItemField(itemId, "questRewards")
  if type(rewards) == "table" and next(rewards) ~= nil then return nil end

  local roles, _, log = Collect(itemId, false)
  local doneQuest
  for questId in pairs(roles) do
    local state = QuestState(questId, log)
    if state == "log" or state == "open" then return nil end
    if state == "done" then doneQuest = doneQuest or questId end
  end
  if not doneQuest then return nil end
  return roles, doneQuest, info
end

local function BagSlots(itemId)
  local found, api = {}, C_Container
  if not (api and api.GetContainerNumSlots and api.GetContainerItemID) then return found end
  for bag = 0, NUM_BAG_SLOTS or 4 do
    for slot = 1, PlainNumber(api.GetContainerNumSlots(bag)) or 0 do
      local id = PlainNumber(api.GetContainerItemID(bag, slot))
      if id and (itemId == nil or id == itemId) then found[#found + 1] = { bag = bag, slot = slot, id = id } end
    end
  end
  return found
end

local function ItemCount(itemId)
  local getCount = (C_Item and C_Item.GetItemCount) or GetItemCount
  local ok, count = pcall(getCount or error, itemId)
  return ok and PlainNumber(count) or nil
end

local ShowNextPrompt

-- Runs inside the click on "Delete". The game lets an item be destroyed only from a key press or click, and one
-- click pays for one delete: a second DeleteCursorItem in the same click is blocked. So this destroys one stack.
-- entry.gone remembers the slots already destroyed, the bags may not show it yet at the next click.
-- Returns "deleted", "refused" (the item stays on the cursor) or "none", and the number of slots still to do.
local function DeleteOneStack(entry)
  local result, left = "none", 0
  entry.gone = entry.gone or {}
  for _, pos in ipairs(BagSlots(entry.itemId)) do
    local key = pos.bag * 1000 + pos.slot
    if not entry.gone[key] then
      if result ~= "none" then
        left = left + 1
      else
        ClearCursor()
        C_Container.PickupContainerItem(pos.bag, pos.slot)
        local kind, id = GetCursorInfo()
        if not IsSecret(kind) and kind == "item" and PlainNumber(id) == entry.itemId then
          DeleteCursorItem()
          if GetCursorInfo() ~= nil then
            result, left = "refused", left + 1
          else
            result = "deleted"
            entry.gone[key] = true
          end
        else
          ClearCursor()   -- locked or moved: not this click
          left = left + 1
        end
      end
    end
  end
  return result, left
end

local function OnDeleteClick(frame)
  local current = asking
  if not current then frame:Hide() return end
  local result, left = DeleteOneStack(current)
  if result == "deleted" then current.deleted = (current.deleted or 0) + 1 end
  db.diag.lastDelete = { item = current.itemId, result = result, left = left, deleted = current.deleted or 0, at = time() }

  if result == "deleted" and left > 0 then
    frame.delete:SetText(("Delete (%d left)"):format(left))   -- stays open: one more click per stack
    return
  end
  frame:Hide()
  if result == "refused" then
    -- Still on the cursor. It stays there so it can be dropped by hand.
    db.diag.deleteRefused = time()
    Print(("the game refused to delete %s. It is on your cursor: click the ground to destroy it, right-click to put it back."):format(current.link))
    return
  end
  local itemId, link = current.itemId, current.link
  C_Timer.After(1.5, function()
    if #BagSlots(itemId) == 0 then
      Print(("deleted %s"):format(link))
    else
      db.diag.deleteFailed = time()
      Print(("%s is still in your bags, the delete did not go through."):format(link))
    end
  end)
end

local function CreatePrompt()
  local frame = CreateFrame("Frame", "QuestItemTipPrompt", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
  frame:SetSize(380, 150)
  frame:SetPoint("TOP", UIParent, "TOP", 0, -200)
  frame:SetFrameStrata("DIALOG")
  frame:EnableMouse(true)
  frame:Hide()
  if frame.SetBackdrop then
    frame:SetBackdrop({
      bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
      edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
      tile = true, tileSize = 32, edgeSize = 32,
      insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })
  else
    local background = frame:CreateTexture(nil, "BACKGROUND")
    background:SetAllPoints()
    background:SetColorTexture(0, 0, 0, 0.9)
  end

  frame.icon = frame:CreateTexture(nil, "ARTWORK")
  frame.icon:SetSize(36, 36)
  frame.icon:SetPoint("TOPLEFT", 24, -24)

  frame.text = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
  frame.text:SetPoint("TOPLEFT", frame.icon, "TOPRIGHT", 12, 2)
  frame.text:SetPoint("RIGHT", frame, "RIGHT", -24, 0)
  frame.text:SetJustifyH("LEFT")
  frame.text:SetJustifyV("TOP")

  frame.note = frame:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
  frame.note:SetPoint("BOTTOM", frame, "BOTTOM", 0, 46)
  frame.note:SetText("Keep: never ask again for this item.  Escape: decide later.")

  frame.delete = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  frame.delete:SetSize(120, 22)
  frame.delete:SetPoint("BOTTOMRIGHT", frame, "BOTTOM", -6, 18)
  frame.delete:SetText("Delete")
  frame.delete:SetScript("OnClick", function() OnDeleteClick(frame) end)

  frame.keep = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  frame.keep:SetSize(120, 22)
  frame.keep:SetPoint("BOTTOMLEFT", frame, "BOTTOM", 6, 18)
  frame.keep:SetText("Keep")
  frame.keep:SetScript("OnClick", function()
    if asking then db.keep[asking.itemId] = true end
    frame:Hide()
  end)

  frame:SetScript("OnHide", function(self)
    if self:IsShown() then return end   -- only the UI was hidden (Alt+Z, cinematic): it comes back with it
    asking = nil
    C_Timer.After(0.3, function() ShowNextPrompt() end)
  end)
  if type(UISpecialFrames) == "table" then table.insert(UISpecialFrames, "QuestItemTipPrompt") end   -- Escape closes it
  return frame
end

ShowNextPrompt = function()
  if asking or not db or not db.askDelete then return end
  if type(InCombatLockdown) == "function" and InCombatLockdown() then return end   -- PLAYER_REGEN_ENABLED resumes
  while #askQueue > 0 do
    local entry = table.remove(askQueue, 1)
    -- The bags and the quest log may have changed while it waited.
    local ok, roles, doneQuest, info = pcall(Leftover, entry.itemId)
    if ok and roles and #BagSlots(entry.itemId) > 0 and not db.keep[entry.itemId] then
      prompt = prompt or CreatePrompt()
      local link = info.link or info.name
      local count = ItemCount(entry.itemId)
      asking = { itemId = entry.itemId, link = link }
      local stacks = #BagSlots(entry.itemId)
      prompt.delete:SetText(stacks > 1 and ("Delete (%d left)"):format(stacks) or "Delete")
      prompt.icon:SetTexture(info.icon)
      prompt.text:SetText(("You completed |cffffd100%s|r.\n\n%s%s belongs to no quest you still have open. Delete it?"):format(
        QuestTitle(entry.questId or doneQuest), link, count and count > 1 and (" x" .. count) or ""))
      prompt:Show()
      db.diag.lastAsked = { item = entry.itemId, quest = entry.questId or doneQuest, at = time() }
      return
    end
  end
end

-- questId: only items of that quest (after handing it in). nil: every leftover in the bags.
local function CheckLeftovers(questId)
  local queued, kept, seen = 0, 0, {}
  for _, entry in ipairs(askQueue) do seen[entry.itemId] = true end
  if asking then seen[asking.itemId] = true end
  for _, pos in ipairs(BagSlots()) do
    if not seen[pos.id] then
      seen[pos.id] = true
      local ok, roles = pcall(Leftover, pos.id)
      if ok and roles and (questId == nil or roles[questId]) then
        if db.keep[pos.id] then
          kept = kept + 1
        else
          askQueue[#askQueue + 1] = { itemId = pos.id, questId = questId }
          queued = queued + 1
        end
      end
    end
  end
  ShowNextPrompt()
  return queued, kept
end

------------------------------------------------------------------------
-- Slash command
------------------------------------------------------------------------
local function OnOff(value) return value and "|cff40ff40on|r" or "|cffff4040off|r" end

local function Status()
  Print(("tooltip lines %s"):format(OnOff(db.enabled)))
  if not lib then
    Print("QuestieDB not found: only quests in your log are recognised.")
  elseif build then
    Print(("building the quest index: %d of %d quests"):format(build.pos - 1, #build.ids))
  elseif indexReady and db.diag.index then
    local stats = db.diag.index
    Print(("quest index: %d items in %d quests"):format(stats.items, stats.quests))
  else
    Print("quest index: not built yet")
  end
  Print(("completed quests %s, other faction/class %s, rewards %s, quest IDs %s, max %d lines"):format(
    OnOff(db.showDone), OnOff(db.showOther), OnOff(db.showRewards), OnOff(db.showIds), db.maxLines))
  local keptCount = 0
  for _ in pairs(db.keep) do keptCount = keptCount + 1 end
  Print(("ask to delete leftover quest items %s, %d items marked Keep"):format(OnOff(db.askDelete), keptCount))
  Print("/qit on | off | done | other | rewards | ids | max <n> | item <id or link> | rebuild")
  Print("/qit ask | cleanup | forget")
end

local function Toggle(key, what)
  db[key] = not db[key]
  Invalidate()
  Print(("%s %s"):format(what, OnOff(db[key])))
end

local function ShowItem(rest)
  local itemId = tonumber(rest:match("item:(%d+)") or rest:match("(%d+)"))
  if not itemId then Print("usage: /qit item <item ID or shift-clicked link>") return end
  local lines = LinesFor(itemId)
  Print(("%s (%d): %d quest lines"):format(ItemName(itemId) or "item", itemId, #lines))
  for _, line in ipairs(lines) do
    print("   " .. line.left .. (line.right and ("  |cffffffff- " .. line.right .. "|r") or ""))
  end
end

SLASH_QUESTITEMTIP1 = "/qit"
SLASH_QUESTITEMTIP2 = "/questitemtip"
SlashCmdList.QUESTITEMTIP = function(msg)
  if not db then return end
  msg = (msg or ""):match("^%s*(.-)%s*$")
  local command, rest = msg:match("^(%S*)%s*(.*)$")
  command = command:lower()
  if command == "" or command == "status" then
    Status()
  elseif command == "on" or command == "off" then
    db.enabled = command == "on"
    Print(("tooltip lines %s"):format(OnOff(db.enabled)))
  elseif command == "done" then
    Toggle("showDone", "completed quests")
  elseif command == "other" then
    Toggle("showOther", "quests of the other faction or another class")
  elseif command == "rewards" then
    Toggle("showRewards", "reward lines")
  elseif command == "ids" then
    Toggle("showIds", "quest IDs")
  elseif command == "max" then
    local n = tonumber(rest)
    if n and n >= 1 and n <= 30 then
      db.maxLines = math.floor(n)
      Invalidate()
      Print(("at most %d quest lines per item"):format(db.maxLines))
    else
      Print("usage: /qit max <1-30>")
    end
  elseif command == "ask" then
    Toggle("askDelete", "ask to delete leftover quest items")
  elseif command == "cleanup" then
    if not lib then
      Print("QuestieDB not found: without it the addon cannot tell that an item is no longer needed.")
    elseif not indexReady then
      Print("the quest index is still being built, try again in a moment.")
    elseif not db.askDelete then
      Print("the question is switched off, turn it on with /qit ask first.")
    else
      local queued, kept = CheckLeftovers(nil)
      Print(("%d leftover quest items found%s"):format(queued, kept > 0 and (", " .. kept .. " more are marked Keep (/qit forget)") or ""))
    end
  elseif command == "forget" then
    db.keep = {}
    Print("forgot all Keep answers")
  elseif command == "item" then
    ShowItem(rest)
  elseif command == "rebuild" then
    if lib then
      StartBuild()
      Print("rebuilding the quest index")
    else
      Print("QuestieDB not found, there is no index to build.")
    end
  else
    Status()
  end
end

------------------------------------------------------------------------
-- Events
------------------------------------------------------------------------
local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("QUEST_LOG_UPDATE")
events:RegisterEvent("QUEST_ACCEPTED")
events:RegisterEvent("QUEST_REMOVED")
events:RegisterEvent("QUEST_TURNED_IN")
events:RegisterEvent("PLAYER_REGEN_ENABLED")
events:SetScript("OnEvent", function(_, event, arg1)
  if event == "ADDON_LOADED" then
    if arg1 ~= ADDON then return end
    QuestItemTipDB = type(QuestItemTipDB) == "table" and QuestItemTipDB or {}
    db = QuestItemTipDB
    for key, value in pairs(defaults) do
      if type(db[key]) ~= type(value) then db[key] = value end
    end
    db.diag = { loadedAt = time() }
    db.diag.hook = HookTooltips()
  elseif event == "PLAYER_LOGIN" then
    lib = FindLibrary()
    db.diag.questieDB = lib ~= nil

    local _, _, raceId = UnitRace("player")
    local _, _, classId = UnitClass("player")
    raceId, classId = PlainNumber(raceId), PlainNumber(classId)
    local raceMasks = lib and type(lib.Enum) == "table" and lib.Enum.raceMaskById
    playerRaceMask = raceId and type(raceMasks) == "table" and raceMasks[raceId] or nil
    playerClassMask = classId and 2 ^ (classId - 1) or nil

    if lib then C_Timer.After(BUILD_DELAY, StartBuild) end
  elseif event == "PLAYER_REGEN_ENABLED" then
    ShowNextPrompt()
  else
    Invalidate()
    if event == "QUEST_TURNED_IN" then
      local questId = PlainNumber(arg1)
      if questId then
        justDone[questId] = true
        -- The handed-in items leave the bags a moment after the event.
        if db.askDelete then C_Timer.After(2, function() CheckLeftovers(questId) end) end
      end
    end
  end
end)
