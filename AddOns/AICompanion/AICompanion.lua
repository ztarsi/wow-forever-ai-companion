-- AI Companion for World of Warcraft: Forever
-- Saves a read-only snapshot of the character to SavedVariables (written to disk
-- on /reload or logout) so an out-of-game AI companion can read it.
-- It never automates gameplay: it only reads data the game already shows you.

local ADDON_NAME, ns = ...
ns = type(ns) == "table" and ns or {}
local VERSION = "0.13.1"
local PREFIX = "|cff66ccffAI Companion|r: "

local DB            -- AICompanionDB once loaded
local note          -- note(what): remember the add-on's last action (defined with say below)
local charKey       -- "Name@Realm"
local lastSnapshotAt = 0
local dirty, pending = false, false

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------

local issecret = (type(issecretvalue) == "function") and issecretvalue or nil

local function isSecret(v)
    return issecret ~= nil and issecret(v) == true
end

-- Call a function that may not exist or may error; return its results or nil.
local function try(fn, ...)
    if type(fn) ~= "function" then return nil end
    return (function(ok, ...)
        if ok then return ... end
        return nil
    end)(pcall(fn, ...))
end

-- Keep only plain data that SavedVariables can hold.
local function clean(v, depth)
    depth = depth or 0
    if isSecret(v) then return "<hidden>" end
    local t = type(v)
    if t == "string" or t == "number" or t == "boolean" then return v end
    if t == "table" and depth < 7 then
        local out = {}
        for k, val in pairs(v) do
            if not isSecret(k) then
                local kt = type(k)
                if kt == "string" or kt == "number" then
                    local c = clean(val, depth + 1)
                    if c ~= nil then out[k] = c end
                end
            end
        end
        return out
    end
    return nil
end

local function pack(...)
    local t = {}
    for i = 1, select("#", ...) do t[i] = (select(i, ...)) end
    return t
end

local function strip(text)
    if type(text) ~= "string" then return text end
    text = text:gsub("|c%x%x%x%x%x%x%x%x", "")
    text = text:gsub("|cn[^:]+:", "")
    text = text:gsub("|r", "")
    text = text:gsub("|T.-|t", "")
    text = text:gsub("|A.-|a", "")
    text = text:gsub("|n", " ")
    return text
end

local function money(copper)
    if type(copper) ~= "number" then return "?" end
    local g = math.floor(copper / 10000)
    local s = math.floor((copper % 10000) / 100)
    local c = copper % 100
    local parts = {}
    if g > 0 then parts[#parts + 1] = g .. "g" end
    if s > 0 or g > 0 then parts[#parts + 1] = s .. "s" end
    parts[#parts + 1] = c .. "c"
    return table.concat(parts, " ")
end

local QUALITY = { [0] = "Poor", [1] = "Common", [2] = "Uncommon", [3] = "Rare", [4] = "Epic", [5] = "Legendary" }

local function tipLines(data)
    if type(data) ~= "table" or type(data.lines) ~= "table" then return nil end
    local out = {}
    for _, line in ipairs(data.lines) do
        if type(line) == "table" then
            local l, r = line.leftText, line.rightText
            if isSecret(l) or isSecret(r) then
                out[#out + 1] = "<hidden>"
            elseif type(l) == "string" and l ~= "" then
                l = strip(l)
                if type(r) == "string" and r ~= "" then
                    out[#out + 1] = l .. "  |  " .. strip(r)
                else
                    out[#out + 1] = l
                end
            end
        end
    end
    return out
end

local function itemRecord(link, count, tooltip)
    local rec = { link = link, count = count, tooltip = tooltip }
    if type(link) == "string" then
        rec.itemID = tonumber(link:match("item:(%d+)"))
        local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
        local name, _, quality, itemLevel, minLevel, itemType, itemSubType, maxStack,
              equipLoc, _, sellPrice = try(getInfo, link)
        rec.name = name or link:match("%[(.-)%]")
        rec.quality = quality
        rec.qualityName = quality and QUALITY[quality] or nil
        rec.itemLevel = itemLevel
        rec.requiredLevel = minLevel
        rec.type = itemType
        rec.subType = itemSubType
        rec.maxStack = maxStack
        rec.equipSlot = (equipLoc ~= "" and equipLoc) or nil
        rec.sellPriceEach = sellPrice
        rec.sellPriceEachText = sellPrice and money(sellPrice) or nil
    end
    return rec
end

-------------------------------------------------------------------------------
-- Snapshot sections
-------------------------------------------------------------------------------

local function scanCharacter()
    local c = {}
    c.name = UnitName("player")
    c.realm = try(GetRealmName)
    c.fullName = pack(try(UnitFullName, "player"))
    c.lastName = c.fullName[2]
    local className, classFile = UnitClass("player")
    c.class, c.classFile = className, classFile
    local raceName, raceFile = UnitRace("player")
    c.race, c.raceFile = raceName, raceFile
    c.faction = (try(UnitFactionGroup, "player"))
    c.sex = try(UnitSex, "player")
    c.gender = (c.sex == 2 and "Male") or (c.sex == 3 and "Female") or nil
    c.level = UnitLevel("player")
    c.xp = try(UnitXP, "player")
    c.xpMax = try(UnitXPMax, "player")
    c.restedXP = try(GetXPExhaustion)
    c.isResting = try(IsResting)
    c.money = try(GetMoney)
    c.moneyText = money(c.money)
    c.guild = pack(try(GetGuildInfo, "player"))
    c.healthMax = try(UnitHealthMax, "player")
    c.powerType = pack(try(UnitPowerType, "player"))
    c.powerMax = try(UnitPowerMax, "player")
    c.armor = pack(try(UnitArmor, "player"))
    c.stats = {}
    local statNames = { "Strength", "Agility", "Stamina", "Intellect", "Spirit" }
    for i = 1, 5 do
        local base, stat, pos, neg = try(UnitStat, "player", i)
        if base ~= nil then
            c.stats[statNames[i]] = { base = base, total = stat, bonus = pos, penalty = neg }
        end
    end
    c.attackPower = pack(try(UnitAttackPower, "player"))
    c.rangedAttackPower = pack(try(UnitRangedAttackPower, "player"))
    c.critChance = try(GetCritChance)
    c.dodgeChance = try(GetDodgeChance)
    c.unspentTalentPoints = pack(try(UnitCharacterPoints, "player"))
    c.isDead = try(UnitIsDeadOrGhost, "player")
    if try(UnitExists, "pet") then
        c.pet = {
            name = UnitName("pet"),
            level = try(UnitLevel, "pet"),
            family = try(UnitCreatureFamily, "pet"),
            happiness = pack(try(GetPetHappiness)),
        }
    end
    return c
end

local function scanLocation()
    local loc = {}
    loc.zone = try(GetRealZoneText)
    loc.zoneText = try(GetZoneText)
    loc.subZone = try(GetSubZoneText)
    loc.minimapZone = try(GetMinimapZoneText)
    loc.hearthstone = try(GetBindLocation)
    loc.instance = pack(try(GetInstanceInfo))
    if C_Map and C_Map.GetBestMapForUnit then
        local mapID = try(C_Map.GetBestMapForUnit, "player")
        loc.mapID = mapID
        if mapID then
            local info = try(C_Map.GetMapInfo, mapID)
            if type(info) == "table" then
                loc.mapName = info.name
                loc.parentMapID = info.parentMapID
            end
            local pos = try(C_Map.GetPlayerMapPosition, mapID, "player")
            if pos and pos.GetXY then
                local x, y = pos:GetXY()
                if type(x) == "number" and type(y) == "number" then
                    loc.x = math.floor(x * 1000 + 0.5) / 10
                    loc.y = math.floor(y * 1000 + 0.5) / 10
                end
            end
        end
    end
    return loc
end

local SLOT_NAMES = {
    [0] = "Ammo", "Head", "Neck", "Shoulder", "Shirt", "Chest", "Waist", "Legs", "Feet", "Wrist",
    "Hands", "Finger1", "Finger2", "Trinket1", "Trinket2", "Back", "MainHand", "OffHand", "Ranged", "Tabard",
}

local function scanEquipment()
    local eq = {}
    for slot = 0, 19 do
        local link = try(GetInventoryItemLink, "player", slot)
        if link then
            local tip = C_TooltipInfo and tipLines(try(C_TooltipInfo.GetInventoryItem, "player", slot)) or nil
            local rec = itemRecord(link, try(GetInventoryItemCount, "player", slot), tip)
            rec.slot = slot
            rec.slotName = SLOT_NAMES[slot]
            local cur, max = try(GetInventoryItemDurability, slot)
            rec.durability, rec.durabilityMax = cur, max
            eq[#eq + 1] = rec
        end
    end
    return eq
end

local function scanBagRange(first, last)
    local bags = {}
    if not (C_Container and C_Container.GetContainerNumSlots) then
        error("C_Container is not available in this client")
    end
    for bag = first, last do
        local n = try(C_Container.GetContainerNumSlots, bag) or 0
        if type(n) == "number" and n > 0 then
            local b = { bag = bag, slots = n, items = {} }
            b.free = (try(C_Container.GetContainerNumFreeSlots, bag))
            b.name = try(C_Container.GetBagName, bag)
            for slot = 1, n do
                local info = try(C_Container.GetContainerItemInfo, bag, slot)
                if type(info) == "table" then
                    local tip = C_TooltipInfo and tipLines(try(C_TooltipInfo.GetBagItem, bag, slot)) or nil
                    local rec = itemRecord(info.hyperlink, info.stackCount, tip)
                    rec.slot = slot
                    rec.itemID = rec.itemID or info.itemID
                    rec.name = rec.name or info.itemName
                    rec.bound = info.isBound
                    rec.noVendorValue = info.hasNoValue
                    rec.quality = rec.quality or info.quality
                    b.items[#b.items + 1] = rec
                end
            end
            bags[#bags + 1] = b
        end
    end
    return bags
end

local function lastPlayerBag()
    return (type(NUM_TOTAL_EQUIPPED_BAG_SLOTS) == "number" and NUM_TOTAL_EQUIPPED_BAG_SLOTS) or 5
end

local function scanBags()
    return scanBagRange(0, lastPlayerBag())
end

local function scanBank()
    local out = scanBagRange(-3, -1)
    local start = lastPlayerBag() + 1
    for _, b in ipairs(scanBagRange(start, start + 20)) do out[#out + 1] = b end
    return out
end

local function scanQuests()
    if not (C_QuestLog and C_QuestLog.GetNumQuestLogEntries) then
        error("C_QuestLog is not available in this client")
    end
    local out = {}
    local n = C_QuestLog.GetNumQuestLogEntries() or 0
    local header
    for i = 1, n do
        local info = try(C_QuestLog.GetInfo, i)
        if type(info) == "table" then
            if info.isHeader then
                header = info.title
            elseif not info.isHidden then
                local qid = info.questID
                local q = {
                    logIndex = i,
                    title = info.title,
                    questID = qid,
                    level = info.level,
                    difficultyLevel = info.difficultyLevel,
                    suggestedGroup = info.suggestedGroup,
                    frequency = info.frequency,
                    category = header,
                    isTask = info.isTask,
                    isOnMap = info.isOnMap,
                }
                q.complete = try(C_QuestLog.IsComplete, qid)
                q.failed = try(C_QuestLog.IsFailed, qid)
                q.readyForTurnIn = try(C_QuestLog.ReadyForTurnIn, qid)
                q.objectives = try(C_QuestLog.GetQuestObjectives, qid)
                q.tag = try(C_QuestLog.GetQuestTagInfo, qid)
                local desc, obj = try(GetQuestLogQuestText, i)
                q.description, q.objectiveText = desc, obj
                q.rewardMoney = try(GetQuestLogRewardMoney, qid)
                q.rewardXP = try(GetQuestLogRewardXP, qid)
                local nr = try(GetNumQuestLogRewards, qid)
                if type(nr) == "number" and nr > 0 then
                    q.rewardItems = {}
                    for r = 1, nr do q.rewardItems[r] = pack(try(GetQuestLogRewardInfo, r, qid)) end
                end
                local nc = try(GetNumQuestLogChoices, qid)
                if type(nc) == "number" and nc > 0 then
                    q.rewardChoices = {}
                    for r = 1, nc do q.rewardChoices[r] = pack(try(GetQuestLogChoiceInfo, r, qid)) end
                end
                out[#out + 1] = q
            end
        end
    end
    return out
end

-- Every quest this character has ever completed. Titles load in the background,
-- so a first snapshot may hold IDs whose titles arrive in the next one.
local titleRequested = {}
local function scanCompletedQuests()
    if not (C_QuestLog and C_QuestLog.GetAllCompletedQuestIDs) then
        error("completed-quest list is not available in this client")
    end
    local ids = C_QuestLog.GetAllCompletedQuestIDs()
    if type(ids) ~= "table" then error("completed-quest list returned nothing") end
    DB.questTitles = DB.questTitles or {}
    local out = { count = #ids, untitled = 0, quests = {} }
    for _, id in ipairs(ids) do
        local title = DB.questTitles[id]
        if not title then
            title = try(C_QuestLog.GetTitleForQuestID, id)
            if type(title) == "string" and title ~= "" and not isSecret(title) then
                DB.questTitles[id] = title
            else
                title = nil
                out.untitled = out.untitled + 1
                if not titleRequested[id] then
                    titleRequested[id] = true
                    try(C_QuestLog.RequestLoadQuestByID, id)
                end
            end
        end
        out.quests[#out.quests + 1] = { id = id, title = title }
    end
    return out
end

local function scanSkills()
    local out = { skillLines = {}, professions = {} }
    -- Classic-style skill list (professions, weapon skills, languages)
    local n = try(GetNumSkillLines)
    if type(n) == "number" then
        local header
        for i = 1, n do
            local r = pack(try(GetSkillLineInfo, i))
            if r[1] then
                if r[2] then
                    header = r[1]
                else
                    out.skillLines[#out.skillLines + 1] = {
                        name = r[1], category = header, rank = r[4], tempBonus = r[5],
                        modifier = r[6], max = r[7],
                    }
                end
            end
        end
    end
    -- Modern-style profession list
    local profs = pack(try(GetProfessions))
    for i = 1, 6 do
        local idx = profs[i]
        if idx then
            local r = pack(try(GetProfessionInfo, idx))
            if r[1] then
                out.professions[#out.professions + 1] = { name = r[1], rank = r[3], max = r[4], skillLine = r[7], raw = r }
            end
        end
    end
    return out
end

local function scanSpells()
    local out = {}
    if not (C_SpellBook and C_SpellBook.GetNumSpellBookSkillLines) then
        error("C_SpellBook is not available in this client")
    end
    local bank = Enum and Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player or 0
    local lines = C_SpellBook.GetNumSpellBookSkillLines() or 0
    for i = 1, lines do
        local line = try(C_SpellBook.GetSpellBookSkillLineInfo, i)
        if type(line) == "table" then
            local tab = { name = line.name, spells = {} }
            local offset, count = line.itemIndexOffset or 0, line.numSpellBookItems or 0
            for s = offset + 1, offset + count do
                local info = try(C_SpellBook.GetSpellBookItemInfo, s, bank)
                if type(info) == "table" and info.name then
                    tab.spells[#tab.spells + 1] = {
                        name = info.name, rank = info.subName, spellID = info.spellID,
                        passive = info.isPassive, offSpec = info.isOffSpec,
                    }
                end
            end
            out[#out + 1] = tab
        end
    end
    return out
end

local function spellName(spellID)
    if not spellID then return nil end
    return (C_Spell and try(C_Spell.GetSpellName, spellID)) or nil
end

-- Reads one tree of the trait system (class talents and Legacy trees both use it).
local function scanTraitTree(configID, treeID)
    local tree = { treeID = treeID, configID = configID, nodes = {} }
    tree.groupDisplay = try(C_Traits.GetGroupDisplayInfoByTreeID, treeID)
    tree.currencies = try(C_Traits.GetTreeCurrencyInfo, configID, treeID, false)
    local nodeIDs = try(C_Traits.GetTreeNodes, treeID)
    if type(nodeIDs) ~= "table" then
        tree.note = "no nodes returned"
        return tree
    end
    for _, nodeID in ipairs(nodeIDs) do
        local n = try(C_Traits.GetNodeInfo, configID, nodeID)
        if type(n) == "table" and n.ID and n.ID ~= 0 and n.isVisible ~= false then
            local rec = {
                nodeID = nodeID,
                rank = n.currentRank or n.ranksPurchased,
                activeRank = n.activeRank,
                maxRank = n.maxRanks,
                groupIDs = n.groupIDs,
                posX = n.posX, posY = n.posY,
                available = n.isAvailable,
                canPurchase = n.canPurchaseRank,
                meetsEdgeRequirements = n.meetsEdgeRequirements,
            }
            local entryID = (type(n.activeEntry) == "table" and n.activeEntry.entryID)
                or (type(n.entryIDs) == "table" and n.entryIDs[1])
            if entryID then
                local e = try(C_Traits.GetEntryInfo, configID, entryID)
                if type(e) == "table" and e.definitionID then
                    local d = try(C_Traits.GetDefinitionInfo, e.definitionID)
                    if type(d) == "table" then
                        rec.spellID = d.spellID or d.overriddenSpellID
                        rec.name = d.overrideName or spellName(rec.spellID)
                        rec.description = d.overrideDescription
                            or (rec.spellID and C_Spell and strip(try(C_Spell.GetSpellDescription, rec.spellID)))
                    end
                end
            end
            tree.nodes[#tree.nodes + 1] = rec
        end
    end
    return tree
end

local function scanTalents()
    if not C_Traits then error("C_Traits is not available in this client") end
    local out = { trees = {} }
    local configID, source
    if C_SpecializationInfo then
        local group = try(C_SpecializationInfo.GetActiveSpecGroup) or 1
        out.activeSpecGroup = group
        configID = try(C_SpecializationInfo.GetCombatConfigIDForSpecGroup, group)
        if configID then source = "C_SpecializationInfo.GetCombatConfigIDForSpecGroup" end
    end
    if not configID and C_ClassTalents then
        configID = try(C_ClassTalents.GetActiveConfigID)
        if configID then source = "C_ClassTalents.GetActiveConfigID" end
    end
    out.configID, out.configSource = configID, source
    if not configID then
        out.note = "no talent config found (talents may not be unlocked yet)"
        return out
    end
    local cfg = try(C_Traits.GetConfigInfo, configID)
    if type(cfg) ~= "table" then
        out.note = "talent config could not be read"
        return out
    end
    out.configName, out.configType = cfg.name, cfg.type
    for _, treeID in ipairs(cfg.treeIDs or {}) do
        out.trees[#out.trees + 1] = scanTraitTree(configID, treeID)
    end
    return out
end

-- Legacy trees. The tree and currency numbers are best-effort values reported by other add-on authors.
local LEGACY_TREES = { { 1187, "Professions" }, { 1188, "Adventure" }, { 1189, "Progression" } }
local LEGACY_CURRENCY_ID = 4225

local function scanLegacy()
    local out = { trees = {} }
    if C_CurrencyInfo and C_CurrencyInfo.GetCurrencyInfo then
        out.pointsCurrency = try(C_CurrencyInfo.GetCurrencyInfo, LEGACY_CURRENCY_ID)
    end
    if not C_Traits then return out end
    for _, t in ipairs(LEGACY_TREES) do
        local treeID, label = t[1], t[2]
        local configID = try(C_Traits.GetConfigIDByTreeID, treeID)
        if configID then
            local tree = scanTraitTree(configID, treeID)
            tree.label = label
            out.trees[#out.trees + 1] = tree
        else
            out.trees[#out.trees + 1] = { treeID = treeID, label = label, note = "no config for this tree (not unlocked, or the ID is wrong)" }
        end
    end
    return out
end

local function scanCurrencies()
    local out = {}
    if not (C_CurrencyInfo and C_CurrencyInfo.GetCurrencyListSize) then return out end
    local n = try(C_CurrencyInfo.GetCurrencyListSize) or 0
    for i = 1, math.min(n, 200) do
        local c = try(C_CurrencyInfo.GetCurrencyListInfo, i)
        if type(c) == "table" and c.name then
            out[#out + 1] = {
                name = c.name, isHeader = c.isHeader, quantity = c.quantity,
                max = c.maxQuantity, currencyID = c.currencyID,
            }
        end
    end
    return out
end

-- Legacy challenges, if the game exposes them through the achievement interface.
local function scanChallenges()
    local out = { categories = {} }
    out.totalPoints = try(GetTotalAchievementPoints)
    local cats = try(GetCategoryList)
    if type(cats) ~= "table" then
        out.note = "achievement-style interface not found"
        return out
    end
    local total = 0
    for _, catID in ipairs(cats) do
        local name, parent = try(GetCategoryInfo, catID)
        local n = try(GetCategoryNumAchievements, catID) or 0
        local cat = { id = catID, name = name, parent = parent, entries = {} }
        for i = 1, n do
            if total >= 400 then break end
            local r = pack(try(GetAchievementInfo, catID, i))
            if r[2] then
                cat.entries[#cat.entries + 1] = { id = r[1], name = r[2], points = r[3], completed = r[4], description = r[8] }
                total = total + 1
            end
        end
        out.categories[#out.categories + 1] = cat
    end
    return out
end

-- Professions through the modern trade skill interface, plus whatever C_SkillInfo offers.
local function scanSkillsModern()
    local out = { tradeSkillLines = {}, skillInfo = {} }
    if C_TradeSkillUI and C_TradeSkillUI.GetAllProfessionTradeSkillLines then
        local ids = try(C_TradeSkillUI.GetAllProfessionTradeSkillLines)
        if type(ids) == "table" then
            for _, id in ipairs(ids) do
                local info = try(C_TradeSkillUI.GetProfessionInfoBySkillLineID, id)
                if type(info) == "table" and (info.skillLevel or 0) > 0 then
                    out.tradeSkillLines[#out.tradeSkillLines + 1] = {
                        skillLineID = id, name = info.professionName, rank = info.skillLevel,
                        max = info.maxSkillLevel, modifier = info.skillModifier, parent = info.parentProfessionName,
                    }
                end
            end
        end
    end
    -- Full skill list (professions, weapon skills, languages) through C_SkillInfo.
    out.allSkills = {}
    if type(C_SkillInfo) == "table" and C_SkillInfo.GetNumSkillLines and C_SkillInfo.GetSkillLineInfo then
        local n = try(C_SkillInfo.GetNumSkillLines)
        if type(n) == "number" then
            for i = 1, math.min(n, 120) do
                local r = pack(try(C_SkillInfo.GetSkillLineInfo, i))
                if type(r[1]) == "table" then
                    out.allSkills[#out.allSkills + 1] = r[1]
                elseif r[1] ~= nil then
                    out.allSkills[#out.allSkills + 1] = r
                end
            end
        end
    end
    -- Read-only getters that need no arguments; results show how skills are exposed.
    if type(C_SkillInfo) == "table" then
        for name, fn in pairs(C_SkillInfo) do
            if type(name) == "string" and type(fn) == "function" and name:find("^Get") then
                local r = pack(try(fn))
                if #r > 0 then out.skillInfo[name] = r end
            end
        end
    end
    return out
end

local function scanReputation()
    local out = {}
    if C_Reputation and C_Reputation.GetNumFactions and C_Reputation.GetFactionDataByIndex then
        local n = C_Reputation.GetNumFactions() or 0
        for i = 1, n do
            local d = try(C_Reputation.GetFactionDataByIndex, i)
            if type(d) == "table" and d.name then
                out[#out + 1] = {
                    name = d.name, isHeader = d.isHeader, reaction = d.reaction,
                    standing = d.currentStanding, floor = d.currentReactionThreshold,
                    ceiling = d.nextReactionThreshold, atWar = d.atWarWith,
                }
            end
        end
    elseif GetNumFactions then
        local n = try(GetNumFactions) or 0
        for i = 1, n do out[#out + 1] = pack(try(GetFactionInfo, i)) end
    end
    return out
end

local function scanAuras()
    local out = { buffs = {}, debuffs = {} }
    if not (C_UnitAuras and C_UnitAuras.GetAuraDataByIndex) then return out end
    for _, f in ipairs({ { "HELPFUL", out.buffs }, { "HARMFUL", out.debuffs } }) do
        for i = 1, 40 do
            local a = try(C_UnitAuras.GetAuraDataByIndex, "player", i, f[1])
            if type(a) ~= "table" then break end
            f[2][#f[2] + 1] = { name = a.name, spellID = a.spellId, stacks = a.applications, duration = a.duration }
        end
    end
    return out
end

local function scanClient()
    local version, build, buildDate, interface = try(GetBuildInfo)
    return {
        version = version, build = build, buildDate = buildDate, interface = interface,
        projectID = WOW_PROJECT_ID, camelotProjectID = WOW_PROJECT_CAMELOT,
        locale = try(GetLocale),
        addonVersion = VERSION,
        -- false when the AICompanion_Data add-on is missing or not ticked; the companion creates it
        dataAddon = type(AICompanionAdvice) == "table" or type(AICompanionPlans) == "table"
            or type(AICompanionShopping) == "table",
    }
end

-------------------------------------------------------------------------------
-- Snapshot assembly
-------------------------------------------------------------------------------

local scanAuctionator -- defined with the auction code below

local SECTIONS = {
    { "client", scanClient },
    { "character", scanCharacter },
    { "location", scanLocation },
    { "equipment", scanEquipment },
    { "bags", scanBags },
    { "quests", scanQuests },
    { "completedQuests", scanCompletedQuests },
    { "skills", scanSkills },
    { "spells", scanSpells },
    { "talents", scanTalents },
    { "legacy", scanLegacy },
    { "currencies", scanCurrencies },
    { "challenges", scanChallenges },
    { "skillsModern", scanSkillsModern },
    { "reputation", scanReputation },
    { "auras", scanAuras },
    { "auctionator", function() return scanAuctionator() end },
}

local function charStore()
    DB.characters[charKey] = DB.characters[charKey] or {}
    return DB.characters[charKey]
end

-- During a real logout the game unloads character data before add-ons are told,
-- so bags read as empty and money as zero. Only snapshot while the data is present.
local function worldDataReady()
    if not (C_Container and C_Container.GetContainerNumSlots) then return true end
    local slots = try(C_Container.GetContainerNumSlots, 0)
    if isSecret(slots) then return false end
    return type(slots) == "number" and slots > 0
end

local function takeSnapshot(reason)
    if not DB or not charKey then return nil end
    if not worldDataReady() then
        DB.lastSkipped = { atText = date("%Y-%m-%d %H:%M:%S"), reason = reason, why = "character data not loaded" }
        return nil
    end
    if note then note("snapshot (" .. tostring(reason) .. ")") end
    local store = charStore()
    local old = store.snapshot
    local snap = {
        takenAt = time(),
        takenAtText = date("%Y-%m-%d %H:%M:%S"),
        reason = reason,
        errors = {},
        stale = {},
    }
    for _, s in ipairs(SECTIONS) do
        local name, fn = s[1], s[2]
        local ok, res = pcall(fn)
        if ok then
            snap[name] = clean(res)
        else
            snap.errors[name] = tostring(res)
        end
        if snap[name] == nil and old and old[name] ~= nil then
            snap[name] = old[name]
            snap.stale[name] = old.takenAtText
        end
    end
    store.snapshot = snap
    DB.lastCharacter = charKey
    DB.lastSnapshotAt = snap.takenAt
    lastSnapshotAt = snap.takenAt
    dirty = false
    return snap
end

local function requestSnapshot()
    dirty = true
    if pending then return end
    pending = true
    C_Timer.After(5, function()
        pending = false
        if not dirty then return end
        if InCombatLockdown and InCombatLockdown() then return end -- retried on leaving combat
        takeSnapshot("auto")
    end)
end

-------------------------------------------------------------------------------
-- Things captured only while their window is open
-------------------------------------------------------------------------------

local function captureBank()
    local ok, res = pcall(scanBank)
    local store = charStore()
    if ok then
        store.bank = { seenAtText = date("%Y-%m-%d %H:%M:%S"), bags = clean(res) }
    else
        store.bankError = tostring(res)
    end
end

local function captureTrainer()
    local n = try(GetNumTrainerServices)
    if type(n) ~= "number" then
        -- Older trainer functions are missing: record what the modern interface returns instead.
        if type(C_Trainer) == "table" then
            local raw = {}
            for name, fn in pairs(C_Trainer) do
                if type(name) == "string" and type(fn) == "function" and name:find("^Get") then
                    local r = pack(try(fn))
                    if #r > 0 then raw[name] = r end
                end
            end
            charStore().trainerRaw = { seenAtText = date("%Y-%m-%d %H:%M:%S"), results = clean(raw) }
        end
        return
    end
    if n == 0 then return end
    local list = {}
    for i = 1, n do
        local info = pack(try(GetTrainerServiceInfo, i))
        if info[1] then
            list[#list + 1] = {
                info = info,
                cost = pack(try(GetTrainerServiceCost, i)),
                levelReq = try(GetTrainerServiceLevelReq, i),
                skillReq = pack(try(GetTrainerServiceSkillReq, i)),
            }
        end
    end
    local store = charStore()
    store.trainers = store.trainers or {}
    local who = try(UnitName, "npc") or try(UnitName, "target") or "Unknown trainer"
    if isSecret(who) then who = "Unknown trainer" end
    store.trainers[who] = { seenAtText = date("%Y-%m-%d %H:%M:%S"), zone = try(GetRealZoneText), services = clean(list) }
end

local function captureMerchant()
    local n = try(GetMerchantNumItems)
    if type(n) ~= "number" or n == 0 then return end
    local list = {}
    for i = 1, n do
        local info
        if C_MerchantFrame and C_MerchantFrame.GetItemInfo then
            info = try(C_MerchantFrame.GetItemInfo, i)
        end
        if type(info) ~= "table" then info = pack(try(GetMerchantItemInfo, i)) end
        list[#list + 1] = { info = info, link = try(GetMerchantItemLink, i) }
    end
    local store = charStore()
    store.merchants = store.merchants or {}
    local who = try(UnitName, "npc") or try(UnitName, "target") or "Unknown merchant"
    if isSecret(who) then who = "Unknown merchant" end
    store.merchants[who] = {
        seenAtText = date("%Y-%m-%d %H:%M:%S"), zone = try(GetRealZoneText),
        canRepair = try(CanMerchantRepair), items = clean(list),
    }
end

local function captureTaxi()
    if not (C_TaxiMap and C_TaxiMap.GetAllTaxiNodes) then return end
    local mapID = try(GetTaxiMapID) or (C_Map and try(C_Map.GetBestMapForUnit, "player"))
    if not mapID then return end
    local nodes = try(C_TaxiMap.GetAllTaxiNodes, mapID)
    if type(nodes) ~= "table" then return end
    local list = {}
    for _, node in ipairs(nodes) do
        list[#list + 1] = { name = node.name, state = node.state, nodeID = node.nodeID }
    end
    charStore().flightPaths = { seenAtText = date("%Y-%m-%d %H:%M:%S"), note = "state 0 = current, 1 = reachable, 2 = not yet learned", nodes = clean(list) }
end

local function captureRecipes()
    if not (C_TradeSkillUI and C_TradeSkillUI.GetAllRecipeIDs) then return end
    local ids = try(C_TradeSkillUI.GetAllRecipeIDs)
    if type(ids) ~= "table" then return end
    local profession = "Unknown"
    local base = try(C_TradeSkillUI.GetBaseProfessionInfo)
    if type(base) == "table" and base.professionName then profession = base.professionName end
    local list = {}
    for _, id in ipairs(ids) do
        local r = try(C_TradeSkillUI.GetRecipeInfo, id)
        if type(r) == "table" and r.name then
            list[#list + 1] = { name = r.name, recipeID = id, learned = r.learned, difficulty = r.relativeDifficulty, craftable = r.craftable, numAvailable = r.numAvailable }
        end
    end
    if #list == 0 then return end
    local store = charStore()
    store.recipes = store.recipes or {}
    store.recipes[profession] = { seenAtText = date("%Y-%m-%d %H:%M:%S"), recipes = clean(list) }
end

-------------------------------------------------------------------------------
-- One-time look at which game interfaces exist (helps future versions)
-------------------------------------------------------------------------------

local function probeAPI()
    local p = { namespaces = {}, interesting = {} }
    for k, v in pairs(_G) do
        if type(k) == "string" then
            local isNamespace = k:sub(1, 2) == "C_" and type(v) == "table"
            if isNamespace then p.namespaces[#p.namespaces + 1] = k end
            local lk = k:lower()
            if (lk:find("legacy") or lk:find("camping") or lk:find("campsite") or lk:find("campfire")
                or lk:find("forever") or lk:find("camelot")) and #p.interesting < 400 then
                if type(v) == "function" then
                    p.interesting[#p.interesting + 1] = k
                elseif isNamespace then
                    local fns = {}
                    for fk, fv in pairs(v) do
                        if type(fk) == "string" and type(fv) == "function" then fns[#fns + 1] = fk end
                    end
                    table.sort(fns)
                    p.interesting[#p.interesting + 1] = k .. ": " .. table.concat(fns, ", ")
                end
            end
        end
    end
    p.namespaceFunctions = {}
    for _, nsName in ipairs({ "C_SkillInfo", "C_SpecializationInfo", "C_ClassTalents", "C_Traits", "C_GameRules",
        "C_Trainer", "C_Bank", "C_AchievementInfo", "C_PaperDollInfo", "C_TradeSkillUI", "C_SwingTimer",
        "C_MerchantFrame", "C_TaxiMap", "C_CurrencyInfo", "C_QuestLog", "C_PlayerInfo", "C_AuctionHouse" }) do
        local nsTable = _G[nsName]
        if type(nsTable) == "table" then
            local fns = {}
            for fk, fv in pairs(nsTable) do
                if type(fk) == "string" and type(fv) == "function" then fns[#fns + 1] = fk end
            end
            table.sort(fns)
            p.namespaceFunctions[nsName] = table.concat(fns, " ")
        end
    end
    p.globals = {}
    for k, v in pairs(_G) do
        if type(k) == "string" and type(v) == "function" and #p.globals < 600 then
            local lk = k:lower()
            if (lk:find("skill") or lk:find("talent") or lk:find("trainer") or lk:find("achievement")
                or lk:find("legacy") or lk:find("profession")) and not k:find("Mixin") and not k:find("Frame") then
                p.globals[#p.globals + 1] = k
            end
        end
    end
    table.sort(p.globals)
    p.version = 3
    table.sort(p.namespaces)
    table.sort(p.interesting)
    p.takenAtText = date("%Y-%m-%d %H:%M:%S")
    return p
end

-------------------------------------------------------------------------------
-- Text summary and copy window
-------------------------------------------------------------------------------

local function buildSummary(snap)
    local L = {}
    local function add(s) L[#L + 1] = s end
    local c, loc = snap.character or {}, snap.location or {}
    add("AI Companion snapshot, " .. tostring(snap.takenAtText))
    add(("%s: level %s %s %s (%s)"):format(tostring(c.name), tostring(c.level), tostring(c.race), tostring(c.class), tostring(c.faction)))
    add(("XP %s/%s, rested %s, money %s"):format(tostring(c.xp), tostring(c.xpMax), tostring(c.restedXP or 0), tostring(c.moneyText)))
    add(("Location: %s / %s (%s, %s), hearth: %s"):format(tostring(loc.zone), tostring(loc.subZone), tostring(loc.x), tostring(loc.y), tostring(loc.hearthstone)))
    add("")
    add("SKILLS")
    local sk = snap.skills or {}
    for _, s in ipairs(sk.skillLines or {}) do
        add(("  %s %s/%s (%s)"):format(tostring(s.name), tostring(s.rank), tostring(s.max), tostring(s.category)))
    end
    for _, s in ipairs(sk.professions or {}) do
        add(("  %s %s/%s"):format(tostring(s.name), tostring(s.rank), tostring(s.max)))
    end
    for _, sline in ipairs((snap.skillsModern or {}).tradeSkillLines or {}) do
        add(("  %s %s/%s"):format(tostring(sline.name), tostring(sline.rank), tostring(sline.max)))
    end
    add("")
    add("TALENTS")
    for _, tree in ipairs((snap.talents or {}).trees or {}) do
        for _, node in ipairs(tree.nodes or {}) do
            if (node.rank or 0) > 0 then
                add(("  %s %s/%s"):format(tostring(node.name), tostring(node.rank), tostring(node.maxRank)))
            end
        end
    end
    add("")
    add("EQUIPMENT")
    for _, it in ipairs(snap.equipment or {}) do
        add(("  %s: %s [%s]"):format(tostring(it.slotName), tostring(it.name), tostring(it.qualityName)))
    end
    add("")
    add("BAGS")
    for _, b in ipairs(snap.bags or {}) do
        add(("  Bag %s: %s slots, %s free"):format(tostring(b.bag), tostring(b.slots), tostring(b.free)))
        for _, it in ipairs(b.items or {}) do
            add(("    %s x%s [%s, %s] sells %s each"):format(tostring(it.name), tostring(it.count or 1),
                tostring(it.qualityName), tostring(it.type), tostring(it.sellPriceEachText or "n/a")))
        end
    end
    add("")
    add("QUESTS")
    for _, q in ipairs(snap.quests or {}) do
        local status = q.complete and "COMPLETE" or "in progress"
        add(("  [%s] %s (%s) - %s"):format(tostring(q.level), tostring(q.title), tostring(q.category), status))
        for _, o in ipairs(q.objectives or {}) do
            if type(o) == "table" and o.text then add("      - " .. strip(tostring(o.text))) end
        end
    end
    local hasErr = false
    for name, err in pairs(snap.errors or {}) do
        if not hasErr then add("") add("ERRORS") hasErr = true end
        add("  " .. tostring(name) .. ": " .. tostring(err))
    end
    return table.concat(L, "\n")
end

local copyFrame
local function showCopy(text)
    if not copyFrame then
        local f = CreateFrame("Frame", "AICompanionCopyFrame", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
        f:SetSize(660, 500)
        f:SetPoint("CENTER")
        f:SetFrameStrata("DIALOG")
        if f.SetBackdrop then
            f:SetBackdrop({
                bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
                edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                edgeSize = 14, insets = { left = 3, right = 3, top = 3, bottom = 3 },
            })
            f:SetBackdropColor(0, 0, 0, 0.92)
        end
        f:EnableMouse(true)
        f:SetMovable(true)
        f:RegisterForDrag("LeftButton")
        f:SetScript("OnDragStart", f.StartMoving)
        f:SetScript("OnDragStop", f.StopMovingOrSizing)
        local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        title:SetPoint("TOPLEFT", 12, -10)
        title:SetText("AI Companion: press Ctrl+C to copy, Esc to close")
        local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
        close:SetPoint("TOPRIGHT", 0, 0)
        local sf = CreateFrame("ScrollFrame", "AICompanionCopyScroll", f, "UIPanelScrollFrameTemplate")
        sf:SetPoint("TOPLEFT", 12, -32)
        sf:SetPoint("BOTTOMRIGHT", -32, 12)
        local eb = CreateFrame("EditBox", nil, sf)
        eb:SetMultiLine(true)
        eb:SetFontObject(ChatFontNormal)
        eb:SetWidth(600)
        eb:SetAutoFocus(false)
        eb:SetScript("OnEscapePressed", function() f:Hide() end)
        sf:SetScrollChild(eb)
        f.editBox = eb
        copyFrame = f
    end
    copyFrame.editBox:SetText(text)
    copyFrame:Show()
    copyFrame.editBox:SetFocus()
    copyFrame.editBox:HighlightText()
end

-------------------------------------------------------------------------------
-- Slash commands
-------------------------------------------------------------------------------

local function say(msg) print(PREFIX .. msg) end

-- What the add-on did last, kept so a blocked action can be traced from the saved file.
local lastAction = "nothing yet"
note = function(what) lastAction = tostring(what) .. " at " .. date("%H:%M:%S") end



-------------------------------------------------------------------------------
-- Auction house price checks
-- Runs only while the auction window is open and only after the player asks.
-- It searches for one item name at a time and records the lowest price seen.
-------------------------------------------------------------------------------

local ah = { queue = {}, running = false, current = nil, token = 0, done = 0, total = 0 }
local priceIndex -- newest recorded price per item, rebuilt when prices change

local function ahMode()
    if C_AuctionHouse and C_AuctionHouse.SendBrowseQuery and C_AuctionHouse.GetBrowseResults then return "modern" end
    if type(QueryAuctionItems) == "function" and type(GetNumAuctionItems) == "function" then return "classic" end
    return nil
end

local function ahStore()
    local st = charStore()
    st.auction = st.auction or {}
    return st.auction
end

-- What to look up: the shopping list written for this character, then every
-- tradeable item in the bags and in the last bank capture.
local function ahBuildQueue()
    local list, seen = {}, {}
    local function add(name, itemID, kind, count)
        if type(name) ~= "string" or name == "" or seen[name] or #list >= 90 then return end
        seen[name] = true
        list[#list + 1] = { name = name, itemID = itemID, kind = kind, count = count }
    end
    local shopping = type(AICompanionShopping) == "table" and AICompanionShopping or {}
    local mine = shopping[UnitName("player") or ""] or shopping[charKey or ""]
    if type(mine) == "table" then
        for _, entry in ipairs(mine) do
            if type(entry) == "table" then add(entry.name, entry.itemID, "shopping")
            elseif type(entry) == "string" then add(entry, nil, "shopping") end
        end
    end
    local okBags, bags = pcall(scanBags)
    if okBags then
        for _, b in ipairs(bags) do
            for _, it in ipairs(b.items) do
                if not it.bound and it.type ~= "Quest" then add(it.name, it.itemID, "bag", it.count) end
            end
        end
    end
    local bank = charStore().bank
    if type(bank) == "table" and type(bank.bags) == "table" then
        for _, b in pairs(bank.bags) do
            if type(b) == "table" and type(b.items) == "table" then
                for _, it in pairs(b.items) do
                    if type(it) == "table" and not it.bound and it.type ~= "Quest" then add(it.name, it.itemID, "bank", it.count) end
                end
            end
        end
    end
    return list
end

-------------------------------------------------------------------------------
-- Auctionator (optional). Its public functions for other add-ons (Auctionator.API.v1) give the
-- price it last saw for an item and how many days ago, so no search is needed while its data is
-- fresh. Its saved files are never read: their format is internal to Auctionator.
-------------------------------------------------------------------------------

local CALLER = "AICompanion"
local AUCTIONATOR_MAX_AGE_DAYS = 5 -- default; the player sets it with /aic ah age <days>

local function atorAPI()
    local A = Auctionator
    local v1 = type(A) == "table" and type(A.API) == "table" and A.API.v1
    if type(v1) == "table" and type(v1.GetAuctionPriceByItemID) == "function"
       and type(v1.GetAuctionAgeByItemID) == "function" then return v1 end
    return nil
end

local function atorMaxAge()
    local n = DB and tonumber(DB.auctionatorMaxAgeDays)
    if n and n >= 0 then return n end
    return AUCTIONATOR_MAX_AGE_DAYS
end

-- Auctionator's price (copper) and age (days; nil if older than 21 days) for an item, or nil.
local function atorPrice(itemID)
    local v1 = atorAPI()
    if not v1 or type(itemID) ~= "number" then return nil end
    local okP, price = pcall(v1.GetAuctionPriceByItemID, CALLER, itemID)
    if not okP or type(price) ~= "number" or isSecret(price) then return nil end
    local okA, age = pcall(v1.GetAuctionAgeByItemID, CALLER, itemID)
    if not okA or type(age) ~= "number" or isSecret(age) then age = nil end
    return price, age
end

local function atorFresh(age) return type(age) == "number" and age <= atorMaxAge() end

-- Auctionator's prices for what the character carries, banks and shops for. Freshness of the
-- whole set: at least one item seen within the age setting.
scanAuctionator = function()
    local out = { loaded = atorAPI() ~= nil, maxAgeDays = atorMaxAge() }
    if not out.loaded then return out end
    local items, priced, fresh, newest = {}, 0, 0, nil
    for _, e in ipairs(ahBuildQueue()) do
        local price, age = atorPrice(e.itemID)
        if price then
            priced = priced + 1
            if atorFresh(age) then fresh = fresh + 1 end
            if age and (not newest or age < newest) then newest = age end
            items[e.name] = { itemID = e.itemID, price = price, priceText = money(price), ageDays = age,
                              fresh = atorFresh(age), kind = e.kind, count = e.count }
        end
    end
    out.items, out.priced, out.fresh, out.newestAgeDays = items, priced, fresh, newest
    out.dataFresh = fresh > 0
    return out
end

-- The manual check is needed when Auctionator is missing or none of its prices is fresh.
local function ahNeedsCheck()
    local ok, a = pcall(scanAuctionator)
    return not (ok and type(a) == "table" and a.loaded and a.dataFresh)
end

local ahNext

local function ahRecord(entry, result)
    local store = ahStore()
    store.results = store.results or {}
    result.kind = entry.kind
    result.itemID = result.itemID or entry.itemID
    result.checkedAt = time()
    store.results[entry.name] = clean(result)
    priceIndex = nil
    ah.done = ah.done + 1
end

local function ahFinish(reason)
    if not ah.running then return end
    ah.running = false
    ah.current = nil
    ah.queue = {}
    local store = ahStore()
    store.scannedAtText = date("%Y-%m-%d %H:%M:%S")
    local found = 0
    for _, r in pairs(store.results or {}) do if type(r) == "table" and r.found then found = found + 1 end end
    store.lastRun = { checked = ah.done, planned = ah.total, found = found, ended = reason, mode = ahMode(), filtersUsed = ah.lastFilters }
    say(("auction check %s: %d of %d items searched, %d with listings. Results reach your companion at your next logout or /aic save."):format(reason, ah.done, ah.total, found))
end

ahNext = function()
    if not ah.running or ah.current then return end
    if #ah.queue == 0 then ahFinish("finished") return end
    local mode = ahMode()
    if mode == "modern" and C_AuctionHouse.IsThrottledMessageSystemReady and not C_AuctionHouse.IsThrottledMessageSystemReady() then
        C_Timer.After(0.5, ahNext)
        return
    end
    if mode == "classic" and type(CanSendAuctionQuery) == "function" and not CanSendAuctionQuery() then
        C_Timer.After(0.5, ahNext)
        return
    end
    local entry = table.remove(ah.queue, 1)
    ah.current = entry
    ah.token = ah.token + 1
    local token = ah.token
    local ok, err
    if mode == "modern" then
        local sortPrice = (Enum and Enum.AuctionHouseSortOrder and Enum.AuctionHouseSortOrder.Price) or 0
        -- The quality filters must all be switched on, or the search matches nothing.
        local filters = {}
        local F = Enum and Enum.AuctionHouseFilter
        if type(F) == "table" then
            for _, key in ipairs({ "PoorQuality", "CommonQuality", "UncommonQuality", "RareQuality", "EpicQuality",
                                   "LegendaryQuality", "ArtifactQuality", "ExactMatch" }) do
                if F[key] ~= nil then filters[#filters + 1] = F[key] end
            end
        end
        ah.lastFilters = #filters
        ok, err = pcall(C_AuctionHouse.SendBrowseQuery, {
            searchString = entry.name,
            sorts = { { sortOrder = sortPrice, reverseSort = false } },
            filters = filters,
            itemClassFilters = {},
        })
    else
        ok, err = pcall(QueryAuctionItems, entry.name, nil, nil, 0, nil, nil, false, true, nil)
    end
    if not ok then
        ahRecord(entry, { found = false, error = tostring(err) })
        ah.current = nil
        C_Timer.After(0.5, ahNext)
        return
    end
    -- Move on if the game never answers this search.
    C_Timer.After(8, function()
        if ah.running and ah.current == entry and ah.token == token then
            ahRecord(entry, { found = false, error = "no answer from the auction house" })
            ah.current = nil
            ahNext()
        end
    end)
end

local function ahBrowseResults()
    if not ah.running or not ah.current or ahMode() ~= "modern" then return end
    local entry = ah.current
    local results = try(C_AuctionHouse.GetBrowseResults)
    local best, candidates = nil, {}
    if type(results) == "table" then
        for _, r in ipairs(results) do
            if type(r) == "table" and type(r.itemKey) == "table" then
                local id = r.itemKey.itemID
                local info = try(C_AuctionHouse.GetItemKeyInfo, r.itemKey)
                local name = (type(info) == "table" and info.itemName) or (C_Item and try(C_Item.GetItemNameByID, id))
                local cand = { itemID = id, name = name, minPrice = r.minPrice, quantity = r.totalQuantity }
                if #candidates < 6 then candidates[#candidates + 1] = cand end
                local match = (entry.itemID and id == entry.itemID) or (not entry.itemID and name == entry.name)
                if match and (not best or (cand.minPrice or 0) < (best.minPrice or 0)) then best = cand end
            end
        end
    end
    if best then
        ahRecord(entry, { found = true, itemID = best.itemID, minPrice = best.minPrice, minPriceText = money(best.minPrice),
                          quantity = best.quantity, carried = entry.count })
    else
        ahRecord(entry, { found = false, listings = #candidates, similar = candidates, carried = entry.count })
    end
    ah.current = nil
    C_Timer.After(0.4, ahNext)
end

local function ahClassicResults()
    if not ah.running or not ah.current or ahMode() ~= "classic" then return end
    local entry = ah.current
    local n = try(GetNumAuctionItems, "list") or 0
    local best, qty = nil, 0
    for i = 1, math.min(n, 50) do
        local r = pack(try(GetAuctionItemInfo, "list", i))
        local name, count, buyout = r[1], r[3] or 1, r[10]
        if name == entry.name and type(buyout) == "number" and buyout > 0 and count > 0 then
            local each = math.floor(buyout / count)
            qty = qty + count
            if not best or each < best then best = each end
        end
    end
    if best then
        ahRecord(entry, { found = true, minPrice = best, minPriceText = money(best), quantity = qty, carried = entry.count })
    else
        ahRecord(entry, { found = false, listings = n, carried = entry.count })
    end
    ah.current = nil
    C_Timer.After(0.4, ahNext)
end

local function ahStart()
    if not DB or not charKey then return end
    local mode = ahMode()
    if not mode then say("this client has no auction interface I recognise.") return end
    if ah.running then say("an auction check is already running.") return end
    local queue = ahBuildQueue()
    if #queue == 0 then say("nothing to price-check.") return end
    if atorAPI() then
        -- Auctionator already knows these; search only what it lacks or saw too long ago.
        local need = {}
        for _, e in ipairs(queue) do
            local price, age = atorPrice(e.itemID)
            if not (price and atorFresh(age)) then need[#need + 1] = e end
        end
        if #need == 0 then
            say(("Auctionator has prices seen within %d days for all %d items; nothing to check."):format(atorMaxAge(), #queue))
            return
        end
        queue = need
    end
    local store = ahStore()
    store.results = {}
    ah.queue, ah.running, ah.current, ah.done, ah.total = queue, true, nil, 0, #queue
    say(("checking %d prices. Keep the auction window open; this takes about %d seconds and the search list will flicker."):format(#queue, #queue * 2))
    ahNext()
end

-- The "check prices" button: the add-on's own frame on UIParent, placed under the auction
-- window's bottom right by reading the window's position. It is not a child of, anchored to,
-- or written onto the game's auction window, so it cannot taint buying or bidding.
local ahButton
local function placeAhButton()
    local w = AuctionHouseFrame or AuctionFrame
    local right, bottom = w and w:GetRight(), w and w:GetBottom()
    if not (right and bottom) then ahButton:Hide() return end
    local scale = (w:GetEffectiveScale() or 1) / (UIParent:GetEffectiveScale() or 1)
    ahButton:ClearAllPoints()
    ahButton:SetPoint("TOPRIGHT", UIParent, "BOTTOMLEFT", right * scale - 4, bottom * scale - 4)
    ahButton:Show()
end

local function ahShow()
    local ok, err = pcall(function()
        if not ahButton then
            local b = CreateFrame("Button", "AICompanionAuctionButton", UIParent, "UIPanelButtonTemplate")
            b:SetSize(230, 24)
            b:SetFrameStrata("HIGH")
            b:SetText("AI Companion: check prices")
            b:SetScript("OnClick", function() local okStart, e = pcall(ahStart) if not okStart then say("auction check failed: " .. tostring(e)) end end)
            ahButton = b
        end
        if ahNeedsCheck() then placeAhButton() else ahButton:Hide() end
    end)
    if not ok and DB then DB.lastEventError = "auction button: " .. tostring(err) end
    if ahButton and ahButton:IsShown() then
        say("auction house open. Click 'AI Companion: check prices' below the right corner of the window, or type /aic ah.")
    else
        say(("auction house open. Prices come from Auctionator (seen within %d days). /aic ah checks the rest."):format(atorMaxAge()))
    end
end

local function ahClosed()
    if ahButton then ahButton:Hide() end
    if ah.running then ahFinish("stopped early because the window closed") end
end

-------------------------------------------------------------------------------
-- Item tooltips: the companion's advice for the item, and the last auction price recorded
-------------------------------------------------------------------------------

local function rebuildPriceIndex()
    local byID, byName = {}, {}
    for _, st in pairs(DB.characters or {}) do
        local a = type(st) == "table" and st.auction
        if type(a) == "table" and type(a.results) == "table" then
            for name, r in pairs(a.results) do
                if type(r) == "table" and type(r.checkedAt) == "number" and not r.error then
                    local cur = byName[name]
                    if not cur or r.checkedAt > cur.checkedAt then
                        byName[name] = r
                        if r.itemID then byID[r.itemID] = r end
                    end
                end
            end
        end
    end
    priceIndex = { byID = byID, byName = byName }
end

local function ageText(t)
    local s = time() - (t or 0)
    if s < 90 then return "just now" end
    if s < 3600 then return math.floor(s / 60) .. "m ago" end
    if s < 172800 then return math.floor(s / 3600) .. "h ago" end
    return math.floor(s / 86400) .. "d ago"
end

local ADVICE_LABEL = {
    equip   = { "Equip now", 0.4, 1, 0.4 },
    use     = { "Use now", 0.4, 0.8, 1 },
    craft   = { "Craft now", 0.4, 0.8, 1 },
    sell    = { "Sell to vendor", 1, 0.8, 0.3 },
    auction = { "List on auction", 1, 0.8, 0.3 },
    mail    = { "Mail", 0.8, 0.6, 1 },
    bank    = { "Put in bank", 0.8, 0.6, 1 },
    quest   = { "Quest, keep in bags", 0.8, 0.6, 1 },
    carry   = { "Keep in bags", 1, 1, 1 },
    keep    = { "Keep in bags", 1, 1, 1 },
    check   = { "Ask me first", 1, 0.5, 0.4 },
}

-- The companion's recommendation for this item on the character you are playing.
local function adviceFor(name)
    local A = type(AICompanionAdvice) == "table" and AICompanionAdvice or nil
    if not A or type(A.characters) ~= "table" or type(name) ~= "string" then return nil end
    local me = try(UnitName, "player")
    if type(me) ~= "string" or isSecret(me) then return nil end
    local mine = A.characters[me] or A.characters[(me:match("^(%S+)")) or ""]
    local a = type(mine) == "table" and mine[name] or nil
    if type(a) ~= "table" then return nil end
    return a[1], a[2], A.asOf
end

-- Built-in rules (AICompanion_Rules.lua), worked out from the latest snapshot. Used when the companion has said nothing.
local ruleCache, ruleCacheAt
local function ruleFor(name)
    local Rules = type(AICompanionRules) == "table" and AICompanionRules or nil
    if not Rules or type(Rules.adviseAll) ~= "function" or not charKey or type(name) ~= "string" then return nil end
    local st = DB.characters and DB.characters[charKey]
    local snap = type(st) == "table" and st.snapshot or nil
    if type(snap) ~= "table" then return nil end
    if not ruleCache or ruleCacheAt ~= snap then
        local ok, out = pcall(Rules.adviseAll, DB, charKey)
        ruleCache, ruleCacheAt = (ok and type(out) == "table") and out or {}, snap
    end
    local a = ruleCache[name]
    if type(a) ~= "table" then return nil end
    return a[1], a[2]
end

local function onItemTooltip(tooltip, data)
    if not DB or not tooltip or type(tooltip.AddDoubleLine) ~= "function" then return end
    if InCombatLockdown and InCombatLockdown() then return end
    local id = type(data) == "table" and data.id or nil
    if id == nil or isSecret(id) then return end
    if not priceIndex then rebuildPriceIndex() end
    local name = C_Item and try(C_Item.GetItemNameByID, id)
    if type(name) ~= "string" or isSecret(name) then name = nil end
    local r = priceIndex.byID[id] or (name and priceIndex.byName[name]) or nil
    if r and atorPrice(id) then r = nil end -- Auctionator shows its own price line
    local action, note, asOf = adviceFor(name)
    local fromRule = false
    if not action then
        action, note = ruleFor(name)
        fromRule = action ~= nil
    end
    if not r and not action then return end
    tooltip:AddLine(" ")
    if action then
        local L = ADVICE_LABEL[action] or { tostring(action), 1, 1, 1 }
        tooltip:AddDoubleLine("AI Companion: " .. L[1], fromRule and "rule" or tostring(asOf or " "), L[2], L[3], L[4], 0.6, 0.6, 0.6)
        if type(note) == "string" and note ~= "" then tooltip:AddLine(note, 0.9, 0.9, 0.9, true) end
    end
    if not r then return end
    local head = action and "Auction" or "AI Companion: auction"
    if r.found and type(r.minPrice) == "number" then
        local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
        local vendor = select(11, try(getInfo, id))
        local right, rr, rg, rb = " ", 0.6, 0.6, 0.6
        if type(vendor) == "number" and vendor > 0 then
            right = "vendor " .. money(vendor)
            if r.minPrice > vendor then rr, rg, rb = 0.4, 1, 0.4 else rr, rg, rb = 1, 0.8, 0.3 end
        end
        tooltip:AddDoubleLine(head .. " " .. money(r.minPrice) .. " (" .. tostring(r.quantity or "?") .. " listed, " .. ageText(r.checkedAt) .. ")", right, 0.4, 0.8, 1, rr, rg, rb)
    else
        tooltip:AddDoubleLine(head .. ": none listed", ageText(r.checkedAt), 0.4, 0.8, 1, 0.6, 0.6, 0.6)
    end
end

local function hookTooltips()
    if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType then
        return pcall(TooltipDataProcessor.AddTooltipPostCall, Enum.TooltipDataType.Item, function(tooltip, data)
            pcall(onItemTooltip, tooltip, data)
        end)
    end
    if GameTooltip and GameTooltip.HookScript then
        return pcall(GameTooltip.HookScript, GameTooltip, "OnTooltipSetItem", function(tooltip)
            local _, link = tooltip:GetItem()
            local id = type(link) == "string" and tonumber(link:match("item:(%d+)"))
            pcall(onItemTooltip, tooltip, { id = id })
        end)
    end
    return false, "no tooltip hook available"
end


-------------------------------------------------------------------------------
-- Bag sort by recommended action
-- Groups the items in the ordinary bags by what to do with them, one swap at a time,
-- waiting for the game to confirm each move. Special bags (quiver, ammo pouch, reagent
-- bag) are left alone. It stops, with nothing lost, if the bags change under it.
-------------------------------------------------------------------------------

local SORT_GROUP = { sell = 1, auction = 2, mail = 3, bank = 4, use = 5, craft = 6, quest = 7, carry = 8, keep = 8 }
local sorter = { running = false }
local sortStep, sortStart   -- defined below; declared first because they and the bag button refer to each other

local function sortSlots()
    local slots = {}
    for bag = 0, math.min(lastPlayerBag(), 4) do
        local n = try(C_Container.GetContainerNumSlots, bag)
        local _, family = try(C_Container.GetContainerNumFreeSlots, bag)
        if type(n) == "number" and n > 0 and (family == nil or family == 0) then
            for slot = 1, n do slots[#slots + 1] = { bag = bag, slot = slot } end
        end
    end
    return slots
end

local function slotItem(p)
    local info = try(C_Container.GetContainerItemInfo, p.bag, p.slot)
    if type(info) ~= "table" or info.itemID == nil or isSecret(info.itemID) then return false, false, nil end
    return info.itemID, info.isLocked == true, info
end

-- The item ID each slot should hold once sorted, or false for an empty slot.
local function sortTarget(slots)
    local items = {}
    for _, p in ipairs(slots) do
        local id, _, info = slotItem(p)
        if id then
            local name = info.itemName or (C_Item and try(C_Item.GetItemNameByID, id))
            if type(name) ~= "string" or isSecret(name) then name = nil end
            local action = adviceFor(name)
            if not action then action = ruleFor(name) end
            items[#items + 1] = { id = id, name = name or "", group = SORT_GROUP[action] or 9 }
        end
    end
    table.sort(items, function(a, b)
        if a.group ~= b.group then return a.group < b.group end
        if a.name ~= b.name then return a.name < b.name end
        return a.id < b.id
    end)
    local want = {}
    for i = 1, #slots do want[i] = items[i] and items[i].id or false end
    return want
end

local function itemLabel(id)
    if not id then return "empty" end
    local n = C_Item and try(C_Item.GetItemNameByID, id)
    if type(n) == "string" and not isSecret(n) then return n end
    return "item " .. tostring(id)
end

local function slotLabel(p) return ("bag %d slot %d"):format(p.bag, p.slot) end

local function sortDebug()
    DB.sortDebug = type(DB.sortDebug) == "table" and DB.sortDebug or {}
    return DB.sortDebug
end

local function sortStop(message, detail)
    sorter.running = false
    if try(CursorHasItem) then try(ClearCursor) end   -- puts a held item back where it came from
    sortDebug().lastStop = { atText = date("%Y-%m-%d %H:%M:%S"), message = message, detail = detail, moves = sorter.moves }
    say(message .. (detail and (" (" .. detail .. ")") or ""))
end

local SORT_TICK, SORT_GRACE, SORT_CONFIRM_TIMEOUT = 0.1, 10, 5

local function sortLater() C_Timer.After(SORT_TICK, sortStep) end

-- A move is pending from the moment it is made until both of its slots show their new
-- contents and are unlocked. Until then each of the two slots may read as before or after
-- the move: the server confirms them separately. Any other difference is a real change, and
-- gets SORT_GRACE re-reads (about a second) before the sort gives up.
sortStep = function()
    if not sorter.running then return end
    if InCombatLockdown and InCombatLockdown() then return sortStop("bag sort stopped: you entered combat. Nothing was lost.") end
    local slots, model, want, pend = sorter.slots, sorter.model, sorter.want, sorter.pending
    if try(CursorHasItem) then return sortStop("bag sort stopped: something is on your cursor. Nothing was lost.") end
    local now = GetTime()
    local read, anyLocked, mismatch = {}, false, nil
    for i, p in ipairs(slots) do
        local id, locked = slotItem(p)
        read[i] = { id = id, locked = locked }
        if locked then anyLocked = true end
        local ok
        if pend and (i == pend.i or i == pend.j) then
            -- written out: "x and a or b" picks b when a is false (an empty slot)
            local before, after
            if i == pend.i then before, after = pend.oldI, pend.oldJ else before, after = pend.oldJ, pend.oldI end
            ok = id == before or id == after
        else
            ok = id == model[i]
        end
        if not ok and not mismatch then mismatch = { p = p, expected = model[i], found = id } end
    end
    if mismatch then
        sorter.grace = sorter.grace + 1
        if sorter.grace <= SORT_GRACE then return sortLater() end
        return sortStop("bag sort stopped: your bags changed while sorting. Nothing was lost; sort again.",
            ("%s: expected %s, found %s"):format(slotLabel(mismatch.p), itemLabel(mismatch.expected), itemLabel(mismatch.found)))
    end
    sorter.grace = 0
    if pend then
        local ri, rj = read[pend.i], read[pend.j]
        if not (ri.id == pend.oldJ and rj.id == pend.oldI and not ri.locked and not rj.locked) then
            if now - pend.at > SORT_CONFIRM_TIMEOUT then
                return sortStop("bag sort stopped: the game did not confirm a move. Nothing was lost.",
                    ("%s to %s"):format(itemLabel(pend.oldJ), slotLabel(slots[pend.i])))
            end
            return sortLater()
        end
        model[pend.i], model[pend.j] = pend.oldJ, pend.oldI
        sorter.pending, sorter.moves, sorter.pos = nil, sorter.moves + 1, pend.i + 1
    end
    if anyLocked then
        sorter.waits = sorter.waits + 1
        if sorter.waits * SORT_TICK > SORT_CONFIRM_TIMEOUT then return sortStop("bag sort stopped: an item stayed locked. Nothing was lost.") end
        return sortLater()
    end
    sorter.waits = 0
    for i = sorter.pos, #slots do
        if not want[i] then break end
        if model[i] ~= want[i] then
            -- take the wanted item from a later slot, preferring one that is itself out of place
            local j
            for k = i + 1, #slots do
                if model[k] == want[i] and model[k] ~= want[k] then j = k break end
            end
            if not j then
                for k = i + 1, #slots do
                    if model[k] == want[i] then j = k break end
                end
            end
            if not j then return sortStop("bag sort stopped: lost track of an item. Nothing was lost; sort again.", itemLabel(want[i])) end
            -- model[i] and model[j] differ, so this is a move or a swap, never a stack merge
            note(("sort: moving %s to %s"):format(itemLabel(model[j]), slotLabel(slots[i])))
            try(C_Container.PickupContainerItem, slots[j].bag, slots[j].slot)
            try(C_Container.PickupContainerItem, slots[i].bag, slots[i].slot)
            if not sorter.running then return end   -- the game forbade the move
            if try(CursorHasItem) then
                return sortStop("bag sort stopped: the game refused a move. Nothing was lost.",
                    ("%s to %s"):format(itemLabel(model[j]), slotLabel(slots[i])))
            end
            sorter.pending = { i = i, j = j, oldI = model[i], oldJ = model[j], at = now }
            return sortLater()
        end
    end
    sorter.running = false
    sortDebug().lastRun = { atText = date("%Y-%m-%d %H:%M:%S"), moves = sorter.moves, slots = #slots }
    say(("bags sorted by advice in %d moves: sell, auction, mail, bank, use, craft, quest, keep, then the rest."):format(sorter.moves))
end

-- The bag windows /aic sort debug reports on. The "Sort by advice" button that followed them is
-- withdrawn while the sort is rethought; /aic sort remains.
local BAG_WINDOWS = { "ContainerFrameCombinedBags", "ContainerFrame1" }

sortStart = function()
    if not DB or not charKey then return end
    if InCombatLockdown and InCombatLockdown() then say("can't sort bags in combat.") return end
    if sorter.running then say("already sorting your bags.") return end
    if not (C_Container and C_Container.PickupContainerItem) then say("this client does not let add-ons move items.") return end
    if try(CursorHasItem) then say("put down the item on your cursor first, then sort again.") return end
    takeSnapshot("sort")
    local slots = sortSlots()
    local model = {}
    for i, p in ipairs(slots) do
        local id, locked = slotItem(p)
        if locked then say("an item is still moving; try again in a moment.") return end
        model[i] = id
    end
    sorter = { running = true, slots = slots, model = model, want = sortTarget(slots), pos = 1, moves = 0, waits = 0, grace = 0 }
    sortStep()
end

local function sortDebugReport()
    local d = sortDebug()
    local found = {}
    for _, name in ipairs(BAG_WINDOWS) do
        local f = _G[name]
        if type(f) == "table" then found[#found + 1] = name .. ((type(f.IsShown) == "function" and f:IsShown()) and " (open)" or " (closed)") end
    end
    d.bagWindows, d.buttonOver = found, nil
    say("bag windows: " .. (#found > 0 and table.concat(found, ", ") or "none found"))
    local blocked = DB.blockedActions
    if type(blocked) == "table" and #blocked > 0 then
        local b = blocked[#blocked]
        say(("last blocked action %s: %s (%s), add-on was doing: %s"):format(tostring(b.atText), tostring(b.func), tostring(b.event), tostring(b.lastAction)))
    end
    local st = d.lastStop
    if type(st) == "table" then say("last stop " .. tostring(st.atText) .. ": " .. tostring(st.message) .. (st.detail and (" (" .. st.detail .. ")") or "")) end
    local run = d.lastRun
    if type(run) == "table" then say("last full sort " .. tostring(run.atText) .. ": " .. tostring(run.moves) .. " moves.") end
    say("saved for your companion at your next /aic save.")
end

-------------------------------------------------------------------------------
-- Feedback: report a problem or share an idea from inside the game. The game lets no add-on
-- reach the internet, so it is kept in the saved file; after /aic save the companion reads it
-- and files it as a GitHub issue. The plan's `reported` table, in the data add-on, says which
-- entries were filed, and as which issue.
-------------------------------------------------------------------------------

local FEEDBACK_KEEP = 30
local FEEDBACK_MAX_LETTERS = 500
local feedbackFrame
local feedbackKind = "problem"

local function plainText(v) if type(v) == "string" and not isSecret(v) then return v end end

local function feedbackList()
    DB.feedback = type(DB.feedback) == "table" and DB.feedback or {}
    return DB.feedback
end

-- Marks each entry the companion has filed with its issue, from the data add-on's plan.
local function markReported()
    if not DB then return end
    local plans = AICompanionPlans
    local reported = type(plans) == "table" and type(plans.reported) == "table" and plans.reported or {}
    for _, e in ipairs(feedbackList()) do
        local issue = type(e) == "table" and reported[e.id]
        if type(issue) == "string" then e.issue = issue end
    end
end

local function addFeedback(kind, text)
    if not DB then return nil end
    text = tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" then return nil end
    if #text > FEEDBACK_MAX_LETTERS then text = text:sub(1, FEEDBACK_MAX_LETTERS) end
    local list = feedbackList()
    DB.feedbackCount = (tonumber(DB.feedbackCount) or 0) + 1
    local blocked = type(DB.blockedActions) == "table" and DB.blockedActions[#DB.blockedActions] or nil
    local inCombat = (InCombatLockdown and InCombatLockdown()) == true
    local e = {
        id = date("%Y%m%d-%H%M%S") .. "-" .. DB.feedbackCount,
        atText = date("%Y-%m-%d %H:%M:%S"),
        kind = kind, text = text, character = charKey,
        addonVersion = VERSION, clientVersion = plainText(try(GetBuildInfo)),
        zone = plainText(try(GetZoneText)), subZone = plainText(try(GetSubZoneText)),
        inCombat = inCombat, lastAction = lastAction,
        lastBlocked = type(blocked) == "table" and blocked.func or nil,
        lastEventError = plainText(DB.lastEventError),
    }
    list[#list + 1] = e
    while #list > FEEDBACK_KEEP do table.remove(list, 1) end
    note("feedback " .. e.id)
    if not inCombat then takeSnapshot("feedback") end
    say("feedback saved. Type /aic save to send it to your companion, who files it on GitHub.")
    return e
end

local function feedbackStatus()
    local waiting, sent = 0, {}
    for _, e in ipairs(feedbackList()) do
        if type(e) == "table" then
            if e.issue then sent[#sent + 1] = e.issue else waiting = waiting + 1 end
        end
    end
    if waiting == 0 and #sent == 0 then
        return "Saved here until you type /aic save; your companion files it on GitHub."
    end
    local s = ("Waiting for your companion: %d."):format(waiting)
    if #sent > 0 then
        local shown = {}
        for i = math.max(1, #sent - 2), #sent do shown[#shown + 1] = sent[i] end
        s = s .. (" Sent as issues: %d (%s)."):format(#sent, table.concat(shown, ", "))
    end
    return s
end

local function setFeedbackKind(kind)
    feedbackKind = kind
    local f = feedbackFrame
    if not f then return end
    for k, b in pairs({ problem = f.problemButton, idea = f.ideaButton }) do
        if k == kind then b:LockHighlight() else b:UnlockHighlight() end
    end
    f.kindLabel:SetText(kind == "idea" and "Your idea:" or "What went wrong? Where were you, what did you do?")
end

-- The window is the add-on's own frame on UIParent, like the copy window: no game window is touched.
local function showFeedback(kind)
    if not DB then return end
    if not feedbackFrame then
        local f = CreateFrame("Frame", "AICompanionFeedbackFrame", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
        f:SetSize(480, 280)
        f:SetPoint("CENTER")
        f:SetFrameStrata("FULLSCREEN_DIALOG")   -- above the panel, which it opens from
        if f.SetBackdrop then
            f:SetBackdrop({
                bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
                edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                edgeSize = 14, insets = { left = 3, right = 3, top = 3, bottom = 3 },
            })
            f:SetBackdropColor(0, 0, 0, 0.92)
        end
        f:EnableMouse(true)
        f:SetMovable(true)
        f:RegisterForDrag("LeftButton")
        f:SetScript("OnDragStart", f.StartMoving)
        f:SetScript("OnDragStop", f.StopMovingOrSizing)
        local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        title:SetPoint("TOPLEFT", 12, -10)
        title:SetText("AI Companion: report a problem or share an idea")
        local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
        close:SetPoint("TOPRIGHT", 0, 0)
        local function button(text, w)
            local b = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
            b:SetSize(w, 22)
            b:SetText(text)
            return b
        end
        f.problemButton = button("Problem", 100)
        f.problemButton:SetPoint("TOPLEFT", 12, -32)
        f.problemButton:SetScript("OnClick", function() setFeedbackKind("problem") end)
        f.ideaButton = button("Idea", 100)
        f.ideaButton:SetPoint("LEFT", f.problemButton, "RIGHT", 6, 0)
        f.ideaButton:SetScript("OnClick", function() setFeedbackKind("idea") end)
        f.kindLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        f.kindLabel:SetPoint("TOPLEFT", 14, -62)
        local box = CreateFrame("Frame", nil, f)
        box:SetPoint("TOPLEFT", 12, -78)
        box:SetPoint("BOTTOMRIGHT", -12, 64)
        local bg = box:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints(box)
        bg:SetColorTexture(1, 1, 1, 0.06)
        local eb = CreateFrame("EditBox", nil, box)
        eb:SetMultiLine(true)
        eb:SetMaxLetters(FEEDBACK_MAX_LETTERS)
        eb:SetFontObject(ChatFontNormal)
        eb:SetPoint("TOPLEFT", 6, -6)
        eb:SetPoint("BOTTOMRIGHT", -6, 6)
        eb:SetAutoFocus(false)
        eb:SetScript("OnEscapePressed", function() f:Hide() end)
        f.editBox = eb
        f.status = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        f.status:SetPoint("BOTTOMLEFT", 14, 42)
        f.status:SetPoint("RIGHT", f, "RIGHT", -14, 0)
        f.status:SetJustifyH("LEFT")
        f.status:SetWordWrap(true)
        f.saveButton = button("Save", 90)
        f.saveButton:SetPoint("BOTTOMRIGHT", -12, 12)
        f.saveButton:SetScript("OnClick", function()
            if addFeedback(feedbackKind, eb:GetText()) then
                eb:SetText("")
                f:Hide()
            else
                say("write what happened first, then Save.")
            end
        end)
        f.cancelButton = button("Cancel", 90)
        f.cancelButton:SetPoint("RIGHT", f.saveButton, "LEFT", -6, 0)
        f.cancelButton:SetScript("OnClick", function() eb:SetText("") f:Hide() end)
        -- Escape closes it, like the game's own windows.
        if type(UISpecialFrames) == "table" then table.insert(UISpecialFrames, "AICompanionFeedbackFrame") end
        feedbackFrame = f
    end
    markReported()
    setFeedbackKind(kind or feedbackKind)
    feedbackFrame.status:SetText(feedbackStatus())
    feedbackFrame:Show()
    feedbackFrame.editBox:SetFocus()
end

local function countErrors(snap)
    local n = 0
    for _ in pairs(snap.errors or {}) do n = n + 1 end
    return n
end

local function describe(snap)
    local items = 0
    for _, b in ipairs(snap.bags or {}) do items = items + #(b.items or {}) end
    return ("snapshot taken: %d bag items, %d active quests, %d completed quests, %d section errors."):format(
        items, #(snap.quests or {}), (snap.completedQuests or {}).count or 0, countErrors(snap))
end

local function handleSlash(msg)
    msg = (msg or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local cmd, rest = msg:match("^(%S*)%s*(.-)$")
    cmd = (cmd or ""):lower()
    if not DB then say("not loaded yet, try again in a moment.") return end

    if cmd == "" or cmd == "snap" then
        local snap = takeSnapshot("manual")
        if not snap then say("could not take a snapshot right now.") end
        if snap then say(describe(snap) .. " Type /aic save to write it to disk for your companion.") end
    elseif cmd == "save" or cmd == "sync" then
        local snap = takeSnapshot("save")
        if snap then say(describe(snap) .. " Reloading to write it to disk. If the screen does not reload, type /reload.") end
        -- Must run directly from the typed command: the game blocks reloads started from a timer.
        ReloadUI()
    elseif cmd == "copy" then
        local snap = takeSnapshot("copy")
        if snap then
            local ok, err = pcall(showCopy, buildSummary(snap))
            if not ok then say("could not open the copy window: " .. tostring(err)) end
        end
    elseif cmd == "ask" then
        if rest == "" then say("usage: /aic ask <your question>") return end
        DB.questions = DB.questions or {}
        DB.questions[#DB.questions + 1] = { askedAtText = date("%Y-%m-%d %H:%M:%S"), character = charKey, text = rest }
        takeSnapshot("ask")
        say("question noted. Type /aic save to send it with a fresh snapshot.")
    elseif cmd == "feedback" or cmd == "report" or cmd == "bug" or cmd == "idea" then
        local kind = (cmd == "bug" and "problem") or (cmd == "idea" and "idea") or nil
        if rest == "" then
            local ok, err = pcall(showFeedback, kind)
            if not ok then say("could not open the feedback window: " .. tostring(err)) end
        else
            addFeedback(kind or "feedback", rest)
        end
    elseif cmd == "ah" or cmd == "auction" then
        local days = rest:lower():match("^age%s+(%d+)$")
        if days then
            DB.auctionatorMaxAgeDays = tonumber(days)
            say(("Auctionator prices count as fresh for %d days."):format(DB.auctionatorMaxAgeDays))
        elseif rest:lower() == "age" then
            say(("Auctionator prices count as fresh for %d days. Change with /aic ah age <days>."):format(atorMaxAge()))
        else
            ahStart()
        end
    elseif cmd == "sort" then
        if rest:lower() == "debug" then sortDebugReport() else sortStart() end
    elseif cmd == "panel" then
        if ns.panel and ns.panel.toggle then ns.panel.toggle() else say("the panel is not loaded; restart the game once after updating.") end
    elseif cmd == "probe" then
        local ok, res = pcall(probeAPI)
        if ok then DB.apiProbe = clean(res) say("interface probe stored (" .. #res.namespaces .. " namespaces).")
        else say("probe failed: " .. tostring(res)) end
    else
        say("commands:")
        print("  /aic            take a snapshot now")
        print("  /aic save       take a snapshot and reload so it is written to disk")
        print("  /aic copy       show a text summary you can copy and paste")
        print("  /aic ask <q>    note a question for your companion")
        print("  /aic feedback   report a problem or share an idea (opens a window; also on the panel)")
        print("  /aic bug <text> report a problem in one line; /aic idea <text> for an idea")
        print("  /aic ah         at an auctioneer: check prices for your bags, bank and shopping list")
        print("  /aic ah age <n> with Auctionator: use its prices seen within n days (default 5)")
        print("  /aic sort       group your bags by advice: sell, auction, mail, bank, use, craft, quest, keep")
        print("  /aic panel      open or close your companion panel (also the minimap button)")
        print("  /aic sort debug what the bag sort found, and why it last stopped")
    end
end

-- What AICompanion_Panel.lua needs from this file.
ns.core = {
    db = function() return DB end,
    charKey = function() return charKey end,
    adviceFor = adviceFor, ruleFor = ruleFor, say = say, try = try, isSecret = isSecret,
    takeSnapshot = function(reason) return takeSnapshot(reason) end,
    showFeedback = function(kind) return showFeedback(kind) end,
    ADVICE_LABEL = ADVICE_LABEL,
}

SLASH_AICOMPANION1 = "/aic"
SLASH_AICOMPANION2 = "/companion"
SlashCmdList["AICOMPANION"] = function(msg)
    local ok, err = pcall(handleSlash, msg)
    if not ok then print(PREFIX .. "error: " .. tostring(err)) end
end

-------------------------------------------------------------------------------
-- Events
-------------------------------------------------------------------------------

local frame = CreateFrame("Frame")

local handlers = {}

function handlers.ADDON_LOADED(name)
    if name ~= ADDON_NAME then return end
    if type(AICompanionDB) ~= "table" then AICompanionDB = {} end
    DB = AICompanionDB
    DB.addonVersion = VERSION
    DB.characters = DB.characters or {}
    DB.questions = DB.questions or {}
    local okHook, hookErr = hookTooltips()
    DB.tooltipHook = okHook and "ok" or ("failed: " .. tostring(hookErr))
end

-- Defined before PLAYER_LOGIN, whose periodic ticker calls it.
local function snapshotNow(reason)
    if not DB or not charKey then return end
    if InCombatLockdown and InCombatLockdown() then return end
    takeSnapshot(reason)
end

function handlers.PLAYER_LOGIN()
    if not DB then return end
    local name = UnitName("player") or "Unknown"
    local realm = try(GetRealmName) or "Unknown"
    charKey = name .. "@" .. realm
    pcall(markReported)
    C_Timer.After(5, function()
        if type(DB.apiProbe) ~= "table" or DB.apiProbe.version ~= 3 then
            local ok, res = pcall(probeAPI)
            if ok then DB.apiProbe = clean(res) else DB.apiProbeError = tostring(res) end
        end
        if not (InCombatLockdown and InCombatLockdown()) then takeSnapshot("login") end
        if C_Timer.NewTicker then
            C_Timer.NewTicker(120, function() pcall(snapshotNow, "periodic") end)
        end
        say("v" .. VERSION .. " ready. Type /aic save to send your companion a fresh snapshot, /aic help for more.")
    end)
end

function handlers.PLAYER_LOGOUT()
    -- Deliberately no snapshot here: character data is already unloading on a real logout.
    if DB then DB.lastLogoutText = date("%Y-%m-%d %H:%M:%S") end
end

-- Fired when the logout or exit countdown starts, and when leaving the world.
handlers.PLAYER_CAMPING = function() snapshotNow("logout started") end
handlers.PLAYER_QUITING = function() snapshotNow("exit started") end
handlers.PLAYER_LEAVING_WORLD = function() snapshotNow("leaving world") end

function handlers.PLAYER_REGEN_ENABLED()
    if dirty then requestSnapshot() end
end

handlers.BANKFRAME_OPENED = function() C_Timer.After(0.5, function() pcall(captureBank) end) end
handlers.TRAINER_SHOW = function() C_Timer.After(0.5, function() pcall(captureTrainer) end) end
handlers.MERCHANT_SHOW = function() C_Timer.After(0.5, function() pcall(captureMerchant) end) end
handlers.TAXIMAP_OPENED = function() C_Timer.After(0.5, function() pcall(captureTaxi) end) end
handlers.TRADE_SKILL_LIST_UPDATE = function() pcall(captureRecipes) end
handlers.PLAYER_REGEN_DISABLED = function() if sorter.running then sortStop("bag sort stopped: you entered combat. Nothing was lost.") end end
-- The game blocked or forbade something it blames on this add-on. Keep a record in the saved
-- file (the last 20) so the cause can be traced, and say so once per session.
local blockedSaid = false
local function recordBlocked(event, addon, func)
    if addon ~= ADDON_NAME or not DB then return end
    DB.blockedActions = type(DB.blockedActions) == "table" and DB.blockedActions or {}
    local list = DB.blockedActions
    list[#list + 1] = { atText = date("%Y-%m-%d %H:%M:%S"), event = event, func = tostring(func),
                        inCombat = (InCombatLockdown and InCombatLockdown()) == true, lastAction = lastAction,
                        addonVersion = VERSION }
    while #list > 20 do table.remove(list, 1) end
    if not blockedSaid then
        blockedSaid = true
        say("the game blocked " .. tostring(func) .. ". Recorded for your companion; type /aic save to send it.")
    end
end
handlers.ADDON_ACTION_FORBIDDEN = function(addon, func)
    recordBlocked("ADDON_ACTION_FORBIDDEN", addon, func)
    if addon == ADDON_NAME and sorter.running then sortStop("bag sort stopped: the game does not let add-ons move items here.") end
end
handlers.ADDON_ACTION_BLOCKED = function(addon, func) recordBlocked("ADDON_ACTION_BLOCKED", addon, func) end
handlers.AUCTION_HOUSE_SHOW = ahShow
handlers.AUCTION_HOUSE_CLOSED = ahClosed
handlers.AUCTION_HOUSE_BROWSE_RESULTS_UPDATED = ahBrowseResults
handlers.AUCTION_ITEM_LIST_UPDATE = ahClassicResults
handlers.AUCTION_HOUSE_THROTTLED_SYSTEM_READY = function() if ah.running and not ah.current then ahNext() end end

local REFRESH_EVENTS = {
    "BAG_UPDATE_DELAYED", "QUEST_LOG_UPDATE", "PLAYER_LEVEL_UP", "PLAYER_MONEY",
    "ZONE_CHANGED_NEW_AREA", "PLAYER_EQUIPMENT_CHANGED", "SKILL_LINES_CHANGED",
    "SPELLS_CHANGED", "CHARACTER_POINTS_CHANGED", "HEARTHSTONE_BOUND",
    "PLAYER_XP_UPDATE", "ZONE_CHANGED", "ZONE_CHANGED_INDOORS", "UPDATE_FACTION",
    "TRAIT_CONFIG_UPDATED", "QUEST_DATA_LOAD_RESULT", "PLAYER_UPDATE_RESTING", "QUEST_TURNED_IN", "QUEST_ACCEPTED",
}

frame:SetScript("OnEvent", function(_, event, ...)
    local h = handlers[event]
    if h then
        local ok, err = pcall(h, ...)
        if not ok and DB then DB.lastEventError = event .. ": " .. tostring(err) end
        return
    end
    if DB and charKey then requestSnapshot() end
end)

for event in pairs(handlers) do pcall(frame.RegisterEvent, frame, event) end
for _, event in ipairs(REFRESH_EVENTS) do pcall(frame.RegisterEvent, frame, event) end
