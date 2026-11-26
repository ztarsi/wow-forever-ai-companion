-- AI Companion panel: the companion's plan for the character you are playing, inside the game.
-- Opened from the minimap button, the add-on menu next to the minimap (where the client has
-- one), or /aic panel. Content comes from AICompanionPlans (written by gen_data.py into the
-- AICompanion_Data add-on) and from the latest snapshot, so steps tick themselves as you play.

local _, ns = ...
ns = type(ns) == "table" and ns or {}
local Panel = {}
ns.panel = Panel

local function core() return ns.core or {} end
local function list(t) return type(t) == "table" and t or {} end
local function say(msg) local s = core().say if s then s(msg) end end
local function try(...) local t = core().try if t then return t(...) end end

-------------------------------------------------------------------------------
-- Content: pure functions over the plan and the saved snapshot
-------------------------------------------------------------------------------

Panel.SECTIONS = {
    { key = "next", label = "Do next" },
    { key = "questing", label = "Questing" },
    { key = "professions", label = "Professions" },
    { key = "gear", label = "Gear" },
    { key = "talents", label = "Talents" },
    { key = "items", label = "Items" },
}

-- Where a recommendation comes from. The list shows no tags; an expanded step says it in
-- plain words, and only when the player should be careful.
Panel.CAUTION = {
    classic = "From the original game. Not confirmed for Forever.",
    unverified = "Not verified yet.",
}

-- The headline shown in the panel: the plan's short headline, or the first sentence of the full one.
function Panel.headline(plan)
    if type(plan) ~= "table" then return nil end
    if type(plan.headlineShort) == "string" and plan.headlineShort ~= "" then return plan.headlineShort end
    local h = plan.headline
    if type(h) ~= "string" then return nil end
    local first = h:match("^(.-[%.!%?])%s") or h
    return first
end

local ITEM_ORDER = { "sell", "auction", "mail", "bank", "use", "craft", "quest", "equip", "carry", "keep", "check" }

-- Facts the done rules need, read once from the snapshot and the character's store.
function Panel.facts(store)
    local s = type(store) == "table" and store.snapshot or nil
    if type(s) ~= "table" then return nil end
    local f = { equipped = {}, slots = {}, bagItems = {}, active = {}, completed = nil, skills = {}, freeSlots = 0,
                durability = nil, talentsSpent = 0, store = store }
    for _, e in ipairs(list(s.equipment)) do
        if type(e) == "table" then
            if e.name then f.equipped[e.name] = true end
            if e.slotName then f.slots[e.slotName] = true end
            local cur, max = tonumber(e.durability), tonumber(e.durabilityMax)
            if cur and max and max > 0 then
                local pct = cur / max * 100
                if not f.durability or pct < f.durability then f.durability = pct end
            end
        end
    end
    for _, b in ipairs(list(s.bags)) do
        if type(b) == "table" then
            f.freeSlots = f.freeSlots + (tonumber(b.free) or 0)
            for _, it in ipairs(list(b.items)) do
                if type(it) == "table" and it.name then f.bagItems[it.name] = (f.bagItems[it.name] or 0) + (tonumber(it.count) or 1) end
            end
        end
    end
    for _, q in ipairs(list(s.quests)) do
        if type(q) == "table" and q.title then f.active[q.title] = true end
    end
    if type(s.completedQuests) == "table" then
        f.completed = {}
        for _, q in ipairs(list(s.completedQuests.quests)) do
            if type(q) == "table" and q.title then f.completed[q.title] = true end
        end
    end
    for _, p in ipairs(list(type(s.skills) == "table" and s.skills.professions)) do
        if type(p) == "table" and p.name then f.skills[p.name] = { rank = tonumber(p.rank) or 0, max = tonumber(p.max) or 0 } end
    end
    for _, k in ipairs(list(type(s.skillsModern) == "table" and s.skillsModern.allSkills)) do
        if type(k) == "table" and k.name and not k.isHeader and not f.skills[k.name] then
            f.skills[k.name] = { rank = tonumber(k.rank or k.skillRank) or 0, max = tonumber(k.maxRank or k.skillMaxRank) or 0 }
        end
    end
    local c = type(s.character) == "table" and s.character or {}
    f.level, f.money = tonumber(c.level), tonumber(c.money)
    local tree = type(s.talents) == "table" and list(s.talents.trees)[1] or nil
    local cur = type(tree) == "table" and list(tree.currencies)[1] or nil
    if type(cur) == "table" then f.talentsSpent = tonumber(cur.spent) or 0 end
    return f
end

-- true or false when the snapshot settles a done rule; nil when it cannot (unknown rule).
function Panel.check(rule, f)
    if type(rule) ~= "table" or type(f) ~= "table" then return nil end
    local kind, arg = next(rule)
    if kind == nil or next(rule, kind) ~= nil then return nil end
    if kind == "all" then
        for _, r in ipairs(list(arg)) do
            local ok = Panel.check(r, f)
            if ok ~= true then return ok end
        end
        return true
    end
    if kind == "equipped" then return f.equipped[arg] == true end
    if kind == "notEquipped" then return f.equipped[arg] ~= true end
    if kind == "slotFilled" then return f.slots[arg] == true end
    if kind == "notInBags" then
        for _, n in ipairs(list(arg)) do if f.bagItems[n] then return false end end
        return true
    end
    if kind == "questDone" then return not f.active[arg] and (f.completed == nil or f.completed[arg] == true) end
    if kind == "skill" or kind == "skillCapAbove" then
        local sk = type(arg) == "table" and f.skills[arg[1]] or nil
        local n = type(arg) == "table" and tonumber(arg[2]) or nil
        if not n then return nil end
        if kind == "skill" then return sk ~= nil and sk.rank >= n end
        return sk ~= nil and sk.max > n
    end
    if kind == "talentsSpent" then return f.talentsSpent >= (tonumber(arg) or math.huge) end
    if kind == "level" then return f.level ~= nil and f.level >= (tonumber(arg) or math.huge) end
    if kind == "money" then return f.money ~= nil and f.money >= (tonumber(arg) or math.huge) end
    if kind == "freeSlots" then return f.freeSlots >= (tonumber(arg) or math.huge) end
    if kind == "repaired" then return f.durability ~= nil and f.durability >= (tonumber(arg) or 101) end
    if kind == "captured" then
        local st = f.store
        if arg == "completed" then return f.completed ~= nil end
        if type(arg) == "string" and arg:find("^recipes:") then return type(st.recipes) == "table" and st.recipes[arg:sub(9)] ~= nil end
        if arg == "trainers" then return st.trainers ~= nil or st.trainerRaw ~= nil end
        return type(arg) == "string" and st[arg] ~= nil
    end
    return nil
end

-- One step as a panel line: its tick state and where it comes from.
-- A step's place (issue #44): "Innkeeper Farley \226\128\148 Elwynn Forest 42.1, 65.9", or nil.
function Panel.place(w)
    if type(w) ~= "table" or type(w.zone) ~= "string" or w.zone == "" then return nil end
    local x, y = tonumber(w.x), tonumber(w.y)
    if not (x and y) then return nil end
    local at = ("%s %.1f, %.1f"):format(w.zone, x, y)
    if type(w.label) == "string" and w.label ~= "" then return w.label .. " \226\128\148 " .. at end
    return at
end

-- The Waypoint button (issue #45). The zone's map comes from the game's own map list; TomTom,
-- when installed, gets one waypoint through its public AddWaypoint; otherwise, or if TomTom
-- fails, the game's own map pin is set and tracked. Nothing here is protected or touches a game frame.
local ZONE_MAP = 3                    -- Enum.UIMapType.Zone
local mapCache = {}

function Panel.mapIDFor(zone)
    if type(zone) ~= "string" or zone == "" or not C_Map then return nil end
    local key = zone:lower()
    if mapCache[key] then return mapCache[key] end
    local function named(info) return type(info) == "table" and type(info.name) == "string" and info.name:lower() == key end
    local here = try(C_Map.GetBestMapForUnit, "player")
    if here and named(try(C_Map.GetMapInfo, here)) then mapCache[key] = here return here end
    local root = try(C_Map.GetFallbackWorldMapID) or 947
    local found
    local kids = try(C_Map.GetMapChildrenInfo, root, nil, true)
    for _, m in ipairs(type(kids) == "table" and kids or {}) do
        if named(m) and type(m.mapID) == "number" then
            if m.mapType == ZONE_MAP then found = m.mapID break end
            found = found or m.mapID
        end
    end
    mapCache[key] = found
    return found
end

function Panel.waypoint(w)
    local text = Panel.place(w)
    if not text then return false end
    local id = Panel.mapIDFor(w.zone)
    if not id then say(("could not find the map for %s, so no waypoint was set."):format(w.zone)) return false end
    local x, y = tonumber(w.x) / 100, tonumber(w.y) / 100
    local title = (type(w.label) == "string" and w.label ~= "") and w.label or w.zone
    if type(TomTom) == "table" and type(TomTom.AddWaypoint) == "function" then
        local ok, uid = pcall(TomTom.AddWaypoint, TomTom, id, x, y, { title = title, from = "AI Companion", persistent = false })
        if ok and uid then say("TomTom arrow set: " .. text .. ".") return true end
    end
    if not (C_Map and type(C_Map.SetUserWaypoint) == "function") then say("this game has no map pins. " .. text .. ".") return false end
    if try(C_Map.CanSetUserWaypointOnMap, id) == false then say(w.zone .. " does not take a map pin. " .. text .. ".") return false end
    local point
    if type(UiMapPoint) == "table" and type(UiMapPoint.CreateFromCoordinates) == "function" then
        point = try(UiMapPoint.CreateFromCoordinates, id, x, y)
    end
    point = point or { uiMapID = id, position = (type(CreateVector2D) == "function" and CreateVector2D(x, y)) or { x = x, y = y } }
    local ok, set = pcall(C_Map.SetUserWaypoint, point)
    if not ok or set == false then say("the game did not set the map pin. " .. text .. ".") return false end
    if C_SuperTrack then try(C_SuperTrack.SetSuperTrackedUserWaypoint, true) end
    say("Map pin set: " .. text .. ". The arrow points to it; open the map to see it.")
    return true
end

local function stepLine(step, f, ticks, sources)
    local line = { kind = "step", id = step.id, title = step.title or "", detail = step.detail,
                   caution = Panel.CAUTION[step.tag] }
    line.where = Panel.place(step.where)
    if line.where then line.place = step.where end
    local src = step.source and type(sources) == "table" and sources[step.source] or nil
    if type(src) == "table" and src.label then
        line.source = "Source: " .. src.label
        if src.scope == "classic" and not line.caution then line.caution = Panel.CAUTION.classic end
    end
    local auto = nil
    if step.done ~= nil then auto = Panel.check(step.done, f) end   -- true, false, or nil for a rule it cannot judge
    if auto ~= nil then
        line.auto, line.done = true, auto
    else
        line.auto, line.done = false, (step.id ~= nil and ticks[step.id] == true)
    end
    return line
end

-- Bag and bank items grouped by recommended action: companion advice first, then the rules.
function Panel.items(store, adviceFor, ruleFor)
    local s = type(store) == "table" and store.snapshot or nil
    local groups, seen = {}, {}
    local function add(it, where)
        if type(it) ~= "table" or not it.name then return end
        local key = it.name
        if seen[key] then seen[key].count = seen[key].count + (tonumber(it.count) or 1) return end
        local action, note = nil, nil
        if adviceFor then action, note = adviceFor(it.name) end
        local fromRule = false
        if not action and ruleFor then action, note = ruleFor(it.name) fromRule = action ~= nil end
        if action == "keep" then action = "carry" end   -- both read "Keep in bags"
        action = action or "none"
        local e = { name = it.name, count = tonumber(it.count) or 1, note = note, rule = fromRule, where = where }
        seen[key] = e
        groups[action] = groups[action] or {}
        table.insert(groups[action], e)
    end
    for _, b in ipairs(list(type(s) == "table" and s.bags)) do
        for _, it in ipairs(list(type(b) == "table" and b.items)) do add(it, "bags") end
    end
    local bank = type(store) == "table" and store.bank or nil
    for _, b in ipairs(list(type(bank) == "table" and bank.bags)) do
        for _, it in ipairs(list(type(b) == "table" and b.items)) do add(it, "bank") end
    end
    local out = {}
    for _, action in ipairs(ITEM_ORDER) do
        if groups[action] then
            table.sort(groups[action], function(a, b) return a.name < b.name end)
            out[#out + 1] = { action = action, items = groups[action] }
        end
    end
    if groups.none then
        table.sort(groups.none, function(a, b) return a.name < b.name end)
        out[#out + 1] = { action = "none", items = groups.none }
    end
    return out
end

-- Everything the panel shows for one character, section by section.
-- plans: AICompanionPlans; store: DB.characters[charKey]; ticks: manual ticks for this character.
function Panel.model(plans, firstName, store, ticks, adviceFor, ruleFor)
    plans = type(plans) == "table" and plans or {}
    ticks = type(ticks) == "table" and ticks or {}
    local plan = type(plans.characters) == "table" and plans.characters[firstName] or nil
    local sources = plans.sources
    local f = Panel.facts(store) or Panel.facts({ snapshot = {} })
    local m = { name = firstName, asOf = plans.asOf, hasPlan = type(plan) == "table", sections = {} }
    local own = m.hasPlan and Panel.headline(plan) or nil
    m.headline = own or ("No plan for " .. tostring(firstName) .. " yet. The Items tab shows the built-in advice.")
    m.takenAt = type(store) == "table" and type(store.snapshot) == "table" and store.snapshot.takenAtText or nil
    -- where the plan was made (basedOn.zone, from the companion) and where the player is now
    local madeIn = m.hasPlan and type(plan.basedOn) == "table" and type(plan.basedOn.zone) == "string" and plan.basedOn.zone or nil
    local loc = type(store) == "table" and type(store.snapshot) == "table" and type(store.snapshot.location) == "table"
        and store.snapshot.location or nil
    local here = loc and type(loc.zone) == "string" and loc.zone ~= "" and loc.zone or nil
    if madeIn and here and madeIn:lower() ~= here:lower() then m.madeIn, m.here = madeIn, here end
    local function section(key) local t = {} m.sections[key] = t return t end
    if m.hasPlan then
        local t = section("next")
        -- steps the player put off ("Do later"): kept in the plan, listed under Later
        local later = type(store) == "table" and type(store.later) == "table" and store.later or {}
        local open, put, done = {}, {}, {}
        for i, step in ipairs(list(plan.next)) do
            if type(step) == "table" then
                local line = stepLine(step, f, ticks, sources)
                line.number = i
                line.deferrable = line.id ~= nil and not line.done
                if line.done then done[#done + 1] = line
                elseif line.id ~= nil and later[line.id] ~= nil then line.later = true put[#put + 1] = line
                else open[#open + 1] = line end
            end
        end
        m.progress = { done = #done, total = #open + #put + #done }
        if #open == 0 and #put == 0 and #done > 0 then
            -- the headline describes steps that are all done now; it no longer fits the list
            m.headline = "You have done every step in this plan. Type /aic save for your next one."
        else
            m.headlineIsPlan = own ~= nil
        end
        if m.madeIn then
            t[#t + 1] = { kind = "text", title = ("You are in %s now; this plan was made in %s. Type /aic save for a plan from here.")
                :format(m.here, m.madeIn) }
        end
        if m.progress.total > 0 then
            t[#t + 1] = { kind = "progress", title = ("%d of %d done"):format(#done, m.progress.total) }
        end
        if open[1] then open[1].isNext = true end
        for _, l in ipairs(open) do t[#t + 1] = l end
        if #put > 0 then
            t[#t + 1] = { kind = "divider", title = "Later" }
            for _, l in ipairs(put) do t[#t + 1] = l end
        end
        if #done > 0 then
            t[#t + 1] = { kind = "divider", title = "Done" }
            for _, l in ipairs(done) do t[#t + 1] = l end
        end
        t = section("questing")
        for _, group in ipairs(list(plan.questing)) do
            if type(group) == "table" then
                t[#t + 1] = { kind = "heading", title = group.title or "", detail = group.note }
                for _, step in ipairs(list(group.steps)) do
                    if type(step) == "table" then t[#t + 1] = stepLine(step, f, ticks, sources) end
                end
            end
        end
        t = section("professions")
        local names = {}
        for name in pairs(list(plan.professions)) do names[#names + 1] = name end
        table.sort(names)
        for _, name in ipairs(names) do
            local p = plan.professions[name]
            if type(p) == "table" then
                local sk = f.skills[name]
                local line = { kind = "heading", title = name .. (sk and (" " .. sk.rank .. "/" .. sk.max) or ""), detail = p.status }
                t[#t + 1] = line
                if p.next then
                    local nl = stepLine({ title = "Next: " .. p.next, tag = p.tag, source = p.source }, f, ticks, sources)
                    nl.kind = "note"
                    t[#t + 1] = nl
                end
            end
        end
        t = section("gear")
        for _, step in ipairs(list(plan.gear)) do
            if type(step) == "table" then t[#t + 1] = stepLine(step, f, ticks, sources) end
        end
        t = section("talents")
        local tp = plan.talents
        if type(tp) == "table" then
            if tp.note then t[#t + 1] = { kind = "text", title = tp.note } end
            if tp.suggestion then
                local nl = stepLine({ title = tp.suggestion, tag = tp.tag, source = tp.source }, f, ticks, sources)
                nl.kind = "note"
                t[#t + 1] = nl
            end
        end
        if type(plan.bags) == "string" then m.bagsNote = plan.bags end
        m.blindspots = {}
        for _, b in ipairs(list(plan.blindspots)) do
            if type(b) == "table" and b.text then
                local done = nil
                if b.done ~= nil then done = Panel.check(b.done, f) end
                if done ~= true then m.blindspots[#m.blindspots + 1] = b.text end
            end
        end
    end
    if m.hasPlan then
        -- the bags note and what the companion cannot see yet close the Do next tab
        local t = m.sections.next
        if m.bagsNote then
            t[#t + 1] = { kind = "heading", title = "Bags" }
            t[#t + 1] = { kind = "text", title = m.bagsNote }
        end
        if #m.blindspots > 0 then
            t[#t + 1] = { kind = "heading", title = "I can't see yet" }
            for _, b in ipairs(m.blindspots) do t[#t + 1] = { kind = "text", title = b } end
        end
    end
    m.sections.items = Panel.items(store, adviceFor, ruleFor)
    return m
end

-------------------------------------------------------------------------------
-- Display: a native game window (the client's ButtonFrameTemplate with its tabs along the
-- bottom edge, as on the character sheet), with a plain frame as the fallback.
-------------------------------------------------------------------------------

local FRAME_NAME = "AICompanionPanel"
local DEFAULT_W, MIN_W, MIN_H, MAX_DEFAULT_H = 780, 560, 360, 700
local MAX_W, MAX_H = 1600, 1200
local TAB_LEFT, TAB_GAP, FALLBACK_TAB_W = 11, 3, 104   -- tabs start 11 in and sit 3 apart, as on the character sheet
local function clamp(v, lo, hi) return math.min(math.max(v, lo), hi) end
local MARGIN = 14                 -- one left margin for banner, rows, headings and footer
local ROW_H = 26                  -- even row height for one-line rows
-- Fonts: step titles large; headings in the normal heading font, never larger than a title.
local FONT_TITLE, FONT_HEADING, FONT_TEXT = "GameFontHighlightLarge", "GameFontNormal", "GameFontHighlight"
local DETAIL_GREY, DONE_GREY = 0.85, 0.55
local LIST_HIGHLIGHT = "Interface\\QuestFrame\\UI-QuestTitleHighlight"
-- The row arrow: points right when the step is closed, down when it is open (the same art, turned).
local ARROWS = { "Interface\\ChatFrame\\ChatFrameExpandArrow", "Interface\\Buttons\\UI-SpellbookIcon-NextPage-Up" }
local DOT = " \194\183 "   -- " · " as UTF-8, which the game's fonts draw

local frame, body, scroll, content, bar, pool = nil, nil, nil, nil, nil, {}
local tabs = {}
local current, expanded = "next", nil
local refreshTicker
local render   -- defined below; rows refer to it when clicked

local function panelDB()
    local DB = core().db and core().db()
    if type(DB) ~= "table" then return nil end
    DB.panel = type(DB.panel) == "table" and DB.panel or {}
    DB.panel.ticks = type(DB.panel.ticks) == "table" and DB.panel.ticks or {}
    return DB.panel
end

local function firstName()
    local key = core().charKey and core().charKey()
    return key and (tostring(key):match("^([^@]+)")) or nil, key
end

local function currentModel()
    local DB = core().db and core().db()
    local name, key = firstName()
    if type(DB) ~= "table" or not key then return nil end
    local pdb = panelDB()
    pdb.ticks[key] = type(pdb.ticks[key]) == "table" and pdb.ticks[key] or {}
    local store = type(DB.characters) == "table" and DB.characters[key] or nil
    local plans = type(AICompanionPlans) == "table" and AICompanionPlans or nil
    return Panel.model(plans, name, store, pdb.ticks[key], core().adviceFor, core().ruleFor), pdb.ticks[key]
end
Panel.currentModel = currentModel

-- Puts a Do next step off (on = true) or brings it back. Saved with the character as
-- later[id] = { title, atText }, so the companion sees what the player put off.
function Panel.setLater(id, title, on)
    local DB = core().db and core().db()
    local _, key = firstName()
    if type(DB) ~= "table" or not key or id == nil then return end
    DB.characters = type(DB.characters) == "table" and DB.characters or {}
    local store = type(DB.characters[key]) == "table" and DB.characters[key] or {}
    DB.characters[key] = store
    store.later = type(store.later) == "table" and store.later or {}
    if on then
        store.later[id] = { title = title, atText = date("%Y-%m-%d %H:%M:%S") }
    else
        store.later[id] = nil
        if next(store.later) == nil then store.later = nil end
    end
end

local function hasFile(path)
    local id = type(GetFileIDFromPath) == "function" and GetFileIDFromPath(path) or nil
    return type(id) == "number" and id > 0
end

local function actionLabel(action)
    if action == "none" then return "No advice yet" end
    local L = core().ADVICE_LABEL and core().ADVICE_LABEL[action]
    return L and L[1] or action
end

-- A section of the model as display rows.
-- Row: { key, text, style = "step"|"heading"|"divider"|"progress"|"text", sub, check, done, isNext, expandable }
function Panel.rows(m, key, open)
    local rows = {}
    local function add(r) rows[#rows + 1] = r end
    if key == "items" then
        for gi, g in ipairs(m.sections.items or {}) do
            add({ key = "g" .. gi, text = actionLabel(g.action), style = "heading" })
            for _, it in ipairs(g.items) do
                local rkey = "item:" .. it.name
                local sub
                if open == rkey then
                    sub = it.note
                    if it.where == "bank" then sub = (sub and sub .. " " or "") .. "In the bank." end
                end
                add({ key = rkey, text = it.name .. (it.count > 1 and (" x" .. it.count) or ""), style = "step", sub = sub,
                      expandable = it.note ~= nil or it.where == "bank" })
            end
        end
        if #rows == 0 then add({ key = "empty", text = "No snapshot of your bags yet. Type /aic to take one.", style = "text" }) end
        return rows
    end
    if not m.hasPlan then
        add({ key = "noplan", text = "No plan for this character yet.", style = "text" })
        return rows
    end
    for i, l in ipairs(m.sections[key] or {}) do
        local rkey = l.id or (key .. ":" .. i)
        if l.kind == "heading" then
            add({ key = rkey, text = l.title, style = "heading", sub = l.detail })
        elseif l.kind == "divider" or l.kind == "progress" or l.kind == "text" then
            add({ key = rkey, text = l.title, style = l.kind })
        else
            local more = {}
            if l.detail and l.detail ~= "" then more[#more + 1] = l.detail end
            if l.where then more[#more + 1] = l.where end
            if l.caution then more[#more + 1] = l.caution end
            if l.source then more[#more + 1] = l.source end
            add({ key = rkey, text = (l.number and (l.number .. ". ") or "") .. l.title, style = "step",
                  sub = (open == rkey and #more > 0) and table.concat(more, "\n") or nil,
                  expandable = #more > 0 or l.deferrable == true,
                  defer = (open == rkey and l.deferrable) and { id = l.id, title = l.title, later = l.later == true } or nil,
                  check = l.kind == "step" and { id = l.id, done = l.done, auto = l.auto } or nil,
                  place = (open == rkey) and l.place or nil,
                  done = l.done, isNext = l.isNext })
        end
    end
    if #rows == 0 then add({ key = "nothing", text = "Nothing planned here yet.", style = "text" }) end
    return rows
end

-- "Snapshot today 17:44 · Plan Nov 14" (or the snapshot's date when it is not today).
function Panel.footer(takenAtText, asOf, today)
    local parts = {}
    if type(takenAtText) == "string" then
        local day, hm = takenAtText:match("^(%d+%-%d+%-%d+) (%d+:%d+)")
        if day then
            parts[#parts + 1] = "Snapshot " .. (day == today and "today" or day) .. " " .. hm
        else
            parts[#parts + 1] = "Snapshot " .. takenAtText
        end
    else
        parts[#parts + 1] = "No snapshot yet"
    end
    if type(asOf) == "string" and asOf ~= "" then parts[#parts + 1] = "Plan " .. asOf end
    return table.concat(parts, DOT)
end

-- Used only when the client cannot say whether a line was cut off (no FontString:IsTruncated).
local TITLE_PX_PER_CHAR = 10

local function textHeight(fs, default)
    local h = fs.GetStringHeight and fs:GetStringHeight()
    return (type(h) == "number" and h > 0) and h or default
end

local function rowFrame(i)
    local r = pool[i]
    if r then return r end
    r = CreateFrame("Button", nil, content)
    r.bg = r:CreateTexture(nil, "BACKGROUND")            -- the next step's highlight
    r.bg:SetAllPoints(r)
    r.hl = r:CreateTexture(nil, "HIGHLIGHT")             -- hover
    r.hl:SetAllPoints(r)
    if hasFile(LIST_HIGHLIGHT) then
        r.bg:SetTexture(LIST_HIGHLIGHT) r.bg:SetBlendMode("ADD")
        r.hl:SetTexture(LIST_HIGHLIGHT) r.hl:SetBlendMode("ADD") r.hl:SetAlpha(0.5)
    else
        r.bg:SetColorTexture(1, 0.82, 0, 0.12)
        r.hl:SetColorTexture(1, 1, 1, 0.07)
    end
    r.arrow = r:CreateTexture(nil, "ARTWORK")
    r.arrow:SetSize(14, 14)
    r.nextTag = r:CreateFontString(nil, "OVERLAY", FONT_TEXT)   -- the small "Next" label
    r.nextTag:SetText("Next")
    r.nextTag:SetTextColor(1, 0.82, 0)
    r.check = CreateFrame("CheckButton", nil, r, "UICheckButtonTemplate")
    r.check:SetSize(24, 24)
    r.title = r:CreateFontString(nil, "OVERLAY", FONT_TITLE)
    r.title:SetJustifyH("LEFT")
    r.sub = r:CreateFontString(nil, "OVERLAY", FONT_TEXT)
    r.sub:SetJustifyH("LEFT")
    r.sub:SetWordWrap(true)
    r.sub:SetTextColor(DETAIL_GREY, DETAIL_GREY, DETAIL_GREY)
    r.waypoint = CreateFrame("Button", nil, r, "UIPanelButtonTemplate")   -- issue #45
    r.waypoint:SetSize(90, 20)
    r.waypoint:SetText("Waypoint")
    r.waypoint:Hide()
    r.defer = CreateFrame("Button", nil, r, "UIPanelButtonTemplate")      -- Do later / Do now
    r.defer:SetSize(90, 20)
    r.defer:Hide()
    r.line = r:CreateTexture(nil, "ARTWORK")             -- the "Done" divider rule
    r.line:SetHeight(1)
    r.line:SetColorTexture(1, 1, 1, 0.15)
    pool[i] = r
    return r
end

local function listHeight()
    local h = scroll and scroll:GetHeight()
    if type(h) == "number" and h > 0 then return h end
    return (frame:GetHeight() or MAX_DEFAULT_H) - 170
end

local function updateBar()
    if not (scroll and bar) then return end
    local range = math.max(0, (content.fullHeight or 0) - listHeight())
    bar:SetMinMaxValues(0, range)
    if range <= 0 then bar:Hide() scroll:SetVerticalScroll(0) bar:SetValue(0) else bar:Show() end
    if (bar:GetValue() or 0) > range then bar:SetValue(range) end
end

-- Lay the rows out; returns the list's full height.
local function layout(rows, width, ticks)
    local y = 0
    for i, r in ipairs(rows) do
        local f = rowFrame(i)
        f:ClearAllPoints()
        f:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -y)
        f:SetWidth(width)
        local x = MARGIN
        local step = r.style == "step"
        f.bg:SetShown(r.isNext == true)
        f.line:Hide()
        -- A step title is one line. One too long for it is cut off by the game, so such a row
        -- always opens on click, with the whole title first, and shows it in full on hover.
        local cut = false
        if step and type(r.text) == "string" then
            f.title:SetFontObject(FONT_TITLE)
            f.title:SetWordWrap(false)
            f.title:SetWidth(width - x - (r.check and 28 or 0) - MARGIN - 20 - (r.isNext and 40 or 0))
            f.title:SetText(r.text)
            local ok, truncated = pcall(function() return f.title:IsTruncated() end)
            if ok and type(truncated) == "boolean" then cut = truncated
            else cut = #r.text * TITLE_PX_PER_CHAR > (f.title:GetWidth() or width) end
        end
        local expandable = r.expandable or cut
        f.hl:SetShown(step and expandable == true)
        local open = expandable and expanded == r.key
        local sub = r.sub
        if open and cut then sub = sub and (r.text .. "\n" .. sub) or r.text end
        -- expand arrow on the right, so it is clear the row opens: right when closed, down when open
        local right = MARGIN
        if step and expandable then
            f.arrow:ClearAllPoints()
            f.arrow:SetPoint("TOPRIGHT", f, "TOPRIGHT", -MARGIN, -7)
            local art
            for _, path in ipairs(ARROWS) do if hasFile(path) then art = path break end end
            if art then f.arrow:SetTexture(art) else f.arrow:SetColorTexture(1, 1, 1, 0.4) end
            f.arrow:SetRotation(sub ~= nil and -math.pi / 2 or 0)
            f.arrow:Show()
            right = right + 20
        else
            f.arrow:Hide()
        end
        if r.isNext then
            f.nextTag:ClearAllPoints()
            f.nextTag:SetPoint("TOPRIGHT", f, "TOPRIGHT", -right, -8)
            f.nextTag:Show()
            right = right + 40
        else
            f.nextTag:Hide()
        end
        if r.check then
            f.check:ClearAllPoints()
            f.check:SetPoint("TOPLEFT", f, "TOPLEFT", x, -1)
            f.check:SetChecked(r.check.done == true)
            f.check:SetEnabled(not r.check.auto and r.check.id ~= nil)
            f.check:SetScript("OnClick", function(btn)
                if r.check.auto or not r.check.id then return end
                ticks[r.check.id] = btn:GetChecked() and true or nil
                render()
            end)
            f.check:Show()
            x = x + 28
        else
            f.check:Hide()
        end
        local font = FONT_TITLE
        if r.style == "heading" or r.style == "divider" then font = FONT_HEADING
        elseif r.style == "text" or r.style == "progress" then font = FONT_TEXT end
        local tx = (step or r.check) and x or MARGIN
        f.title:SetFontObject(font)
        f.title:ClearAllPoints()
        f.title:SetPoint("TOPLEFT", f, "TOPLEFT", tx, -5)
        f.title:SetWidth(width - tx - right)
        f.title:SetWordWrap(not step)                    -- step titles are one line; everything else wraps
        f.title:SetText(r.text or "")
        if r.style == "heading" or r.style == "divider" then f.title:SetTextColor(1, 0.82, 0)
        elseif r.done then f.title:SetTextColor(DONE_GREY, DONE_GREY, DONE_GREY)
        elseif r.style == "progress" then f.title:SetTextColor(DETAIL_GREY, DETAIL_GREY, DETAIL_GREY)
        else f.title:SetTextColor(1, 1, 1) end
        local h = math.max(textHeight(f.title, 18) + 8, step and ROW_H or 20)
        if r.style == "divider" then
            f.line:ClearAllPoints()
            f.line:SetPoint("LEFT", f.title, "RIGHT", 8, 0)
            f.line:SetPoint("RIGHT", f, "RIGHT", -MARGIN, 0)
            f.line:Show()
        end
        if sub then
            f.sub:ClearAllPoints()
            f.sub:SetPoint("TOPLEFT", f, "TOPLEFT", x + 8, -h)    -- indented under the title
            f.sub:SetWidth(width - x - 8 - MARGIN)
            f.sub:SetText(sub)
            f.sub:Show()
            h = h + textHeight(f.sub, 14) + 8
        else
            f.sub:Hide()
        end
        -- an opened step with a place: the Waypoint button under its lines (issue #45)
        if r.place and sub then
            local place = r.place
            f.waypoint:ClearAllPoints()
            f.waypoint:SetPoint("TOPLEFT", f, "TOPLEFT", x + 8, -h)
            f.waypoint:SetScript("OnClick", function()
                local ok, err = pcall(Panel.waypoint, place)
                if not ok then say("could not set the waypoint: " .. tostring(err)) end
            end)
            f.waypoint:Show()
        else
            f.waypoint:Hide()
        end
        -- an opened Do next step: put it off to the Later group, or bring it back
        if r.defer then
            local d = r.defer
            f.defer:ClearAllPoints()
            if f.waypoint:IsShown() then f.defer:SetPoint("LEFT", f.waypoint, "RIGHT", 6, 0)
            else f.defer:SetPoint("TOPLEFT", f, "TOPLEFT", x + 8, -h) end
            f.defer:SetText(d.later and "Do now" or "Do later")
            f.defer:SetScript("OnClick", function()
                local ok, err = pcall(Panel.setLater, d.id, d.title, not d.later)
                if not ok then say("could not move the step: " .. tostring(err)) end
                expanded = nil
                render()
            end)
            f.defer:Show()
        else
            f.defer:Hide()
        end
        if f.waypoint:IsShown() or f.defer:IsShown() then h = h + 26 end
        f:SetHeight(h)
        f:SetScript("OnClick", function()
            if not expandable then return end
            expanded = (expanded ~= r.key) and r.key or nil   -- one step open at a time
            render()
        end)
        f:SetScript("OnEnter", function(self)
            if not cut or not GameTooltip then return end
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:SetText(r.text, 1, 1, 1, 1, true)
            GameTooltip:Show()
        end)
        f:SetScript("OnLeave", function() if cut and GameTooltip then GameTooltip:Hide() end end)
        f:Show()
        y = y + h + 2
    end
    for i = #rows + 1, #pool do pool[i]:Hide() end
    return y
end

render = function()
    if not frame or not frame:IsShown() then return end
    local m, ticks = currentModel()
    if not m then return end
    local title = "AI Companion" .. DOT .. tostring(m.name)
    if frame.SetTitle then frame:SetTitle(title) elseif frame.titleText then frame.titleText:SetText(title) end
    -- the plan's own headline is labelled as the player's plan, so it does not read as a stray line
    local label = m.madeIn and ("|cffffd100Your plan (made in " .. m.madeIn .. "):|r ") or "|cffffd100Your plan:|r "
    frame.headline:SetText((m.headlineIsPlan and label or "") .. (m.headline or ""))
    frame.footer:SetText(Panel.footer(m.takenAt, m.asOf, date("%Y-%m-%d")))
    if frame.reloadButton then
        local active = core().reminderActive
        if active and active() then frame.reloadButton:Show() else frame.reloadButton:Hide() end
    end
    for i, s in ipairs(Panel.SECTIONS) do
        if s.key == current then frame.selectedTabIndex = i end
    end
    if frame.nativeTabs and type(PanelTemplates_SetTab) == "function" then
        pcall(PanelTemplates_SetTab, frame, frame.selectedTabIndex or 1)
    else
        for key, tab in pairs(tabs) do
            if key == current then tab:LockHighlight() else tab:UnlockHighlight() end
        end
    end
    pcall(fitTabs, frame)
    local rows = Panel.rows(m, current, expanded)
    frame.lastRows = rows
    local width = (frame:GetWidth() or DEFAULT_W) - 2 * MARGIN - 30
    content:SetWidth(width)
    local y = layout(rows, width, ticks)
    content.fullHeight = y
    content:SetHeight(math.max(y, 10))
    updateBar()
end
Panel.render = render

local function savePosition()
    local pdb = panelDB()
    if not pdb or not frame then return end
    local point, _, relPoint, x, y = frame:GetPoint(1)
    if point then pdb.point = { point, relPoint, x, y } end
    local w, h = frame:GetWidth(), frame:GetHeight()
    if w and h then pdb.width, pdb.height = clamp(w, MIN_W, MAX_W), clamp(h, MIN_H, MAX_H) end
end

-- Default height: what the Do next tab needs, between the minimum and 700.
local CHROME_H = 200
function Panel.defaultHeight(m)
    local n = 0
    for _ in ipairs(Panel.rows(m or { sections = {} }, "next", nil)) do n = n + 1 end
    return math.min(math.max(CHROME_H + n * (ROW_H + 2), MIN_H), MAX_DEFAULT_H)
end

-- The window: the client's titled frame with an inset, or a plain frame when that template is missing.
local function makeWindow()
    local ok, f = pcall(CreateFrame, "Frame", FRAME_NAME, UIParent, "ButtonFrameTemplate")
    if ok and type(f) == "table" and f.Inset then
        if type(ButtonFrameTemplate_HidePortrait) == "function" then pcall(ButtonFrameTemplate_HidePortrait, f) end
        if type(ButtonFrameTemplate_HideButtonBar) == "function" then pcall(ButtonFrameTemplate_HideButtonBar, f) end
        return f, f.Inset, "ButtonFrameTemplate"
    end
    f = (ok and type(f) == "table") and f or CreateFrame("Frame", FRAME_NAME, UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    if f.SetBackdrop then
        f:SetBackdrop({ bgFile = "Interface\\ChatFrame\\ChatFrameBackground", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                        edgeSize = 16, insets = { left = 4, right = 4, top = 4, bottom = 4 } })
        f:SetBackdropColor(0.05, 0.05, 0.07, 0.95)
    end
    f.titleText = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.titleText:SetPoint("TOP", f, "TOP", 0, -8)
    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -2, -2)
    close:SetScript("OnClick", function() f:Hide() end)
    local inner = CreateFrame("Frame", nil, f)
    inner:SetPoint("TOPLEFT", 6, -28)
    inner:SetPoint("BOTTOMRIGHT", -6, 8)
    return f, inner, "plain"
end

-- Tabs: the client's own tab buttons along the bottom edge, or plain buttons as the fallback.
-- The tabs never run past the window's right edge: they keep their natural width when all six
-- fit, and otherwise share the width evenly. Runs whenever the panel is drawn or resized.
local function fitTabs(f)
    local w = f:GetWidth()
    if type(w) ~= "number" or #f.Tabs == 0 then return end
    local avail = w - 2 * TAB_LEFT - TAB_GAP * (#f.Tabs - 1)
    if f.nativeTabs then
        local total = 0
        for _, b in ipairs(f.Tabs) do
            pcall(PanelTemplates_TabResize, b, 0)
            total = total + (b:GetWidth() or 0)
        end
        if total > avail then
            local each = math.floor(avail / #f.Tabs)
            for _, b in ipairs(f.Tabs) do pcall(PanelTemplates_TabResize, b, 0, each) end
        end
    else
        local each = math.min(FALLBACK_TAB_W, math.floor(avail / #f.Tabs))
        for _, b in ipairs(f.Tabs) do b:SetWidth(each) end
    end
end
Panel.fitTabs = function() if frame then fitTabs(frame) end end

local function makeTabs(f)
    f.Tabs = f.Tabs or {}
    local native = true
    local prev
    for i, s in ipairs(Panel.SECTIONS) do
        local ok, b = pcall(CreateFrame, "Button", FRAME_NAME .. "Tab" .. i, f, "PanelTabButtonTemplate")
        if not (ok and type(b) == "table") then native = false break end
        b:SetID(i)
        b:SetText(s.label)
        if type(PanelTemplates_TabResize) == "function" then pcall(PanelTemplates_TabResize, b, 0) end
        b:ClearAllPoints()
        if prev then b:SetPoint("TOPLEFT", prev, "TOPRIGHT", TAB_GAP, 0) else b:SetPoint("TOPLEFT", f, "BOTTOMLEFT", TAB_LEFT, 2) end
        b:SetScript("OnClick", function() current, expanded = s.key, nil render() end)
        f.Tabs[i] = b
        tabs[s.key] = b
        prev = b
    end
    if native and type(PanelTemplates_SetNumTabs) == "function" then
        native = pcall(PanelTemplates_SetNumTabs, f, #Panel.SECTIONS)
    end
    if native then return true end
    -- fallback: a row of standard buttons inside the window
    for _, b in pairs(tabs) do b:Hide() end
    tabs, prev = {}, nil
    f.Tabs = {}
    for i, s in ipairs(Panel.SECTIONS) do
        local b = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        b:SetSize(FALLBACK_TAB_W, 24)
        if prev then b:SetPoint("LEFT", prev, "RIGHT", TAB_GAP, 0) else b:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", TAB_LEFT, 8) end
        f.Tabs[i] = b
        b:SetText(s.label)
        b:SetScript("OnClick", function() current, expanded = s.key, nil render() end)
        tabs[s.key] = b
        prev = b
    end
    return false
end

local function build()
    if frame then return frame end
    local pdb = panelDB() or {}
    local f, inner, kind = makeWindow()
    body = inner
    local m = currentModel()
    -- a size saved by an older version (other limits) is brought within today's
    local w = clamp(tonumber(pdb.width) or DEFAULT_W, MIN_W, MAX_W)
    local h = clamp(tonumber(pdb.height) or Panel.defaultHeight(m), MIN_H, MAX_H)
    if pdb.width ~= nil then pdb.width = w end
    if pdb.height ~= nil then pdb.height = h end
    f:SetSize(w, h)
    if type(pdb.point) == "table" then f:SetPoint(pdb.point[1], UIParent, pdb.point[2], pdb.point[3], pdb.point[4])
    else f:SetPoint("CENTER") end
    f:SetFrameStrata("DIALOG")
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:SetResizable(true)
    if f.SetResizeBounds then f:SetResizeBounds(MIN_W, MIN_H, MAX_W, MAX_H) end
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) self:StartMoving() end)
    f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() savePosition() end)
    if f.CloseButton then f.CloseButton:SetScript("OnClick", function() f:Hide() end) end
    -- headline banner under the title bar: a subtle band with a divider below
    local banner = CreateFrame("Frame", nil, inner)
    banner:SetPoint("TOPLEFT", inner, "TOPLEFT", 0, 0)
    banner:SetPoint("TOPRIGHT", inner, "TOPRIGHT", 0, 0)
    banner:SetHeight(50)
    local band = banner:CreateTexture(nil, "BACKGROUND")
    band:SetAllPoints(banner)
    band:SetColorTexture(1, 1, 1, 0.04)
    local rule = banner:CreateTexture(nil, "ARTWORK")
    rule:SetHeight(1)
    rule:SetPoint("BOTTOMLEFT", banner, "BOTTOMLEFT", MARGIN, 0)
    rule:SetPoint("BOTTOMRIGHT", banner, "BOTTOMRIGHT", -MARGIN, 0)
    rule:SetColorTexture(1, 0.82, 0, 0.35)
    f.headline = banner:CreateFontString(nil, "OVERLAY", FONT_TITLE)
    f.headline:SetPoint("TOPLEFT", banner, "TOPLEFT", MARGIN, -8)
    f.headline:SetPoint("BOTTOMRIGHT", banner, "BOTTOMRIGHT", -MARGIN, 6)
    f.headline:SetJustifyH("LEFT")
    f.headline:SetJustifyV("TOP")
    f.headline:SetWordWrap(true)
    if f.headline.SetMaxLines then f.headline:SetMaxLines(2) end
    f.nativeTabs = makeTabs(f)
    fitTabs(f)
    f:SetScript("OnSizeChanged", function() pcall(fitTabs, f) end)
    -- the list, with its own scroll bar (visible track and thumb) and mouse-wheel scrolling
    local bottom = f.nativeTabs and 30 or 40
    scroll = CreateFrame("ScrollFrame", nil, inner)
    scroll:SetPoint("TOPLEFT", banner, "BOTTOMLEFT", 0, -6)
    scroll:SetPoint("BOTTOMRIGHT", inner, "BOTTOMRIGHT", -20, bottom)
    content = CreateFrame("Frame", nil, scroll)
    content:SetSize(DEFAULT_W - 60, 10)
    scroll:SetScrollChild(content)
    bar = CreateFrame("Slider", nil, inner)
    bar:SetOrientation("VERTICAL")
    bar:SetWidth(10)
    bar:SetPoint("TOPRIGHT", banner, "BOTTOMRIGHT", -6, -6)
    bar:SetPoint("BOTTOMRIGHT", inner, "BOTTOMRIGHT", -6, bottom)
    local track = bar:CreateTexture(nil, "BACKGROUND")
    track:SetAllPoints(bar)
    track:SetColorTexture(0, 0, 0, 0.45)
    local thumb = bar:CreateTexture(nil, "OVERLAY")
    thumb:SetColorTexture(0.75, 0.66, 0.4, 1)
    thumb:SetSize(10, 48)
    bar:SetThumbTexture(thumb)
    bar:SetValueStep(1)
    bar:SetMinMaxValues(0, 0)
    bar:SetValue(0)
    bar:SetScript("OnValueChanged", function(_, value) scroll:SetVerticalScroll(value or 0) end)
    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", function(_, delta)
        local lo, hi = bar:GetMinMaxValues()
        local v = math.min(math.max((bar:GetValue() or 0) - (delta or 0) * 48, lo or 0), hi or 0)
        bar:SetValue(v)
        scroll:SetVerticalScroll(v)
    end)
    -- footer strip: one line at the bottom of the content area, never under the list
    local strip = inner:CreateTexture(nil, "ARTWORK")
    strip:SetHeight(1)
    strip:SetPoint("BOTTOMLEFT", inner, "BOTTOMLEFT", MARGIN, bottom - 4)
    strip:SetPoint("BOTTOMRIGHT", inner, "BOTTOMRIGHT", -MARGIN, bottom - 4)
    strip:SetColorTexture(1, 1, 1, 0.1)
    -- report a problem or share an idea: opens the add-on's own feedback window
    local fb = CreateFrame("Button", nil, inner, "UIPanelButtonTemplate")
    fb:SetSize(90, 20)
    fb:SetPoint("BOTTOMRIGHT", inner, "BOTTOMRIGHT", -MARGIN - 12, bottom - 26)
    fb:SetText("Feedback")
    fb:SetScript("OnClick", function()
        local show = core().showFeedback
        if show then local ok, err = pcall(show) if not ok then say("could not open the feedback window: " .. tostring(err)) end end
    end)
    f.feedbackButton = fb
    -- this character's main and second direction (issue #51)
    local gb = CreateFrame("Button", nil, inner, "UIPanelButtonTemplate")
    gb:SetSize(80, 20)
    gb:SetPoint("RIGHT", fb, "LEFT", -6, 0)
    gb:SetText("Goals")
    gb:SetScript("OnClick", function()
        local show = core().showGoals
        if show then local ok, err = pcall(show) if not ok then say("could not open the goals window: " .. tostring(err)) end end
    end)
    f.goalsButton = gb
    -- after /aic save: reload to load advice an automatic update may have written. The reload
    -- runs straight from this click (the player's own action), never from a timer.
    local rb = CreateFrame("Button", nil, inner, "UIPanelButtonTemplate")
    rb:SetSize(130, 20)
    rb:SetPoint("RIGHT", gb, "LEFT", -6, 0)
    rb:SetText("Load new advice")
    rb:SetScript("OnClick", function()
        local load = core().loadNewAdvice
        if load then load() end
    end)
    rb:Hide()
    f.reloadButton = rb
    f.footer = inner:CreateFontString(nil, "OVERLAY", FONT_TEXT)
    f.footer:SetPoint("BOTTOMLEFT", inner, "BOTTOMLEFT", MARGIN, bottom - 22)
    f.footer:SetPoint("RIGHT", rb, "LEFT", -8, 0)
    f.footer:SetJustifyH("LEFT")
    f.footer:SetWordWrap(false)
    f.footer:SetTextColor(0.7, 0.7, 0.7)
    local grip = CreateFrame("Button", nil, f)
    grip:SetSize(16, 16)
    grip:SetPoint("BOTTOMRIGHT", -4, 4)
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    grip:SetScript("OnMouseDown", function() f:StartSizing("BOTTOMRIGHT") end)
    grip:SetScript("OnMouseUp", function() f:StopMovingOrSizing() savePosition() render() end)
    f:SetScript("OnShow", function()
        render()
        if C_Timer and C_Timer.NewTicker and not refreshTicker then
            refreshTicker = C_Timer.NewTicker(5, function() pcall(render) end)
        end
    end)
    f:SetScript("OnHide", function()
        if refreshTicker then refreshTicker:Cancel() refreshTicker = nil end
    end)
    -- Escape closes it, like the game's own windows.
    if type(UISpecialFrames) == "table" then table.insert(UISpecialFrames, FRAME_NAME) end
    local DB = core().db and core().db()
    if type(DB) == "table" then DB.panelFrame = kind .. (f.nativeTabs and ", native tabs" or ", plain tabs") end
    f:Hide()
    frame = f
    return f
end

function Panel.toggle()
    if frame and frame:IsShown() then frame:Hide() return end
    if InCombatLockdown and InCombatLockdown() then say("the panel opens after combat.") return end
    if core().takeSnapshot then core().takeSnapshot("panel") end   -- so the ticks are current
    local ok, err = pcall(build)
    if not ok then say("could not open the panel: " .. tostring(err)) return end
    frame:Show()   -- OnShow draws it
end
Panel.isShown = function() return frame ~= nil and frame:IsShown() end

-- Key binding (Bindings.xml): Key Bindings > AddOns > "AI Companion: open or close the panel".
-- The add-on's name is in the line itself: the game showed no heading above it (16 Nov).
-- The labels are globals the Key Bindings screen reads; the binding calls the function below.
BINDING_HEADER_AICOMPANION = "AI Companion"
BINDING_NAME_AICOMPANION_TOGGLE_PANEL = "AI Companion: open or close the panel"
function AICompanion_TogglePanel()
    local ok, err = pcall(Panel.toggle)
    if not ok then say("could not open the panel: " .. tostring(err)) end
end

-- The key the player bound, as the game names it ("F8", "Shift-P"), or nil.
function Panel.boundKey()
    if type(GetBindingKey) ~= "function" then return nil end
    local key = GetBindingKey("AICOMPANION_TOGGLE_PANEL")
    if type(key) ~= "string" or key == "" then return nil end
    local text = type(GetBindingText) == "function" and GetBindingText(key) or nil
    return (type(text) == "string" and text ~= "") and text or key
end
Panel.select = function(key) current, expanded = key, nil render() end
Panel.expand = function(key) expanded = key render() end

-------------------------------------------------------------------------------
-- Minimap button: round, in the standard gold ring, like the game's own and other add-ons'.
-- Draggable around the minimap edge; position kept.
-------------------------------------------------------------------------------

-- First art file the client really has, so a missing file never shows as a blank square.
local function firstFile(list)
    for _, path in ipairs(list) do
        local id = type(GetFileIDFromPath) == "function" and GetFileIDFromPath(path) or nil
        if type(id) == "number" and id > 0 then return path end
    end
    return nil
end

Panel.LOGO = "Interface\\AddOns\\AICompanion\\media\\minimap"
Panel.ICONS = { "Interface\\Icons\\INV_Misc_Book_09", "Interface\\Icons\\INV_Misc_Book_11",
                "Interface\\Icons\\INV_Scroll_03", "Interface\\Icons\\INV_Misc_Note_01" }
local RING = "Interface\\Minimap\\MiniMap-TrackingBorder"
local RING_ATLAS = "ui-hud-minimap-button"
local BACKGROUND = "Interface\\Minimap\\UI-Minimap-Background"
local HIGHLIGHT = "Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight"
local ROUND_MASK = "Interface\\CharacterFrame\\TempPortraitAlphaMask"

local button
local function placeButton(angle)
    if not button or not Minimap then return end
    local r = ((Minimap:GetWidth() or 140) / 2) + 5
    local a = math.rad(angle or 225)
    button:ClearAllPoints()
    button:SetPoint("CENTER", Minimap, "CENTER", math.cos(a) * r, math.sin(a) * r)
end
Panel.placeButton = placeButton

local function dragUpdate()
    local mx, my = Minimap:GetCenter()
    local cx, cy = GetCursorPosition()
    local scale = (Minimap.GetEffectiveScale and Minimap:GetEffectiveScale()) or 1
    if not (mx and my and cx and cy) then return end
    local angle = math.deg(math.atan2(cy / scale - my, cx / scale - mx))
    local pdb = panelDB()
    if pdb then pdb.minimapAngle = angle end
    placeButton(angle)
end

local function buildButton()
    if button or type(Minimap) ~= "table" then return end
    local b = CreateFrame("Button", "AICompanionMinimapButton", Minimap)
    b:SetSize(31, 31)
    b:SetFrameStrata("MEDIUM")
    b:SetFrameLevel(8)
    b:RegisterForClicks("AnyUp")
    b:RegisterForDrag("LeftButton")
    b.art = {}
    local bg = b:CreateTexture(nil, "BACKGROUND")
    bg:SetSize(24, 24)
    bg:SetPoint("CENTER")
    bg:SetTexture(BACKGROUND)
    local icon = b:CreateTexture(nil, "ARTWORK")
    icon:SetSize(20, 20)
    icon:SetPoint("CENTER")
    -- The AI Companion logo (media/minimap.tga, a 64 x 64 TGA in the add-on's own folder). The game
    -- only sees a new add-on file after a full restart; until then SetTexture fails and a book stands in.
    local iconFile
    if icon:SetTexture(Panel.LOGO) ~= false then
        iconFile = Panel.LOGO
    else
        iconFile = firstFile(Panel.ICONS) or Panel.ICONS[1]
        icon:SetTexture(iconFile)
        icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)          -- trim the game icon's own border
    end
    if b.CreateMaskTexture and icon.AddMaskTexture then      -- clip the square icon to a circle
        local mask = b:CreateMaskTexture()
        mask:SetTexture(ROUND_MASK, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
        mask:SetAllPoints(icon)
        icon:AddMaskTexture(mask)
        b.art.mask = ROUND_MASK
    end
    local ring = b:CreateTexture(nil, "OVERLAY")
    if firstFile({ RING }) then
        ring:SetSize(50, 50)
        ring:SetPoint("TOPLEFT")
        ring:SetTexture(RING)
        b.art.ring = RING
    elseif C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(RING_ATLAS) then
        ring:SetSize(36, 36)
        ring:SetPoint("CENTER")
        ring:SetAtlas(RING_ATLAS)
        b.art.ring = RING_ATLAS
    end
    b:SetHighlightTexture(HIGHLIGHT, "ADD")
    b.art.icon, b.icon = iconFile, icon
    -- pressed: the icon shifts slightly, as game buttons do
    b:SetScript("OnMouseDown", function() icon:ClearAllPoints() icon:SetPoint("CENTER", 1, -1) end)
    b:SetScript("OnMouseUp", function() icon:ClearAllPoints() icon:SetPoint("CENTER") end)
    b:SetScript("OnClick", function() Panel.toggle() end)
    b:SetScript("OnDragStart", function(self) self:SetScript("OnUpdate", function() pcall(dragUpdate) end) end)
    b:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
        icon:ClearAllPoints() icon:SetPoint("CENTER")
    end)
    b:SetScript("OnEnter", function(self)
        if GameTooltip and GameTooltip.SetOwner then
            GameTooltip:SetOwner(self, "ANCHOR_LEFT")
            GameTooltip:SetText("AI Companion")
            local key = Panel.boundKey()
            GameTooltip:AddLine(key and ("Click or press " .. key .. ": open the plan") or "Click: open the plan", 1, 1, 1)
            GameTooltip:AddLine("Drag: move this button", 1, 1, 1)
            GameTooltip:Show()
        end
    end)
    b:SetScript("OnLeave", function() if GameTooltip and GameTooltip.Hide then GameTooltip:Hide() end end)
    button = b
    local pdb = panelDB()
    placeButton(pdb and pdb.minimapAngle)
end

-- The add-on menu next to the minimap. Its registration call is reported by other Forever
-- add-ons, not confirmed by an in-game dump, so it is tried quietly.
local function registerCompartment()
    local c = AddonCompartmentFrame
    if type(c) ~= "table" or type(c.RegisterAddon) ~= "function" then return false end
    return pcall(c.RegisterAddon, c, {
        text = "AI Companion",
        icon = firstFile(Panel.ICONS) or Panel.ICONS[1],
        notCheckable = true,
        func = function() Panel.toggle() end,
    })
end

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN")
events:SetScript("OnEvent", function()
    pcall(buildButton)
    local ok = registerCompartment()
    local DB = core().db and core().db()
    if type(DB) == "table" then DB.panelCompartment = ok and "registered" or "not available" end
end)
