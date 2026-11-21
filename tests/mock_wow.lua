-- A stand-in for the World of Warcraft: Forever client, for testing the add-on outside the game.
--
-- It models only what the add-on relies on, and models it the way the add-on expects the
-- Forever client to behave (modern C_* interfaces, client interface 16001). Passing tests here
-- means the add-on is consistent with that model; it does not prove the real client agrees.
--
-- The harness sets the global WORLD (the character, bags, items, auction listings) before
-- running this file. Everything the add-on can observe is read from WORLD on each call, so a
-- test can change WORLD between events.

local W = WORLD
assert(type(W) == "table", "set WORLD before loading mock_wow.lua")

-- Capture what we need from the host Lua before the game sandbox removes it.
local osdate, floor, traceback = os.date, math.floor, debug.traceback

Mock = {
    now = W.startTime or 1794700800,   -- virtual clock, in seconds
    timers = {}, timerSeq = 0,
    frames = {},
    chat = {},                         -- everything the add-on printed
    errors = {},                       -- Lua errors the game would have shown
    violations = {},                   -- things the real game would refuse or misbehave on
    context = "load",                  -- what is running: load, event, timer, slash, tooltip
    reloadRequested = false,
    tooltipPostCalls = {},
    newGlobals = {},
    auction = { sent = {}, pending = nil, readyAt = 0 },
}
local M = Mock

local function violation(text) M.violations[#M.violations + 1] = text end
local function lerror(where, err) M.errors[#M.errors + 1] = where .. ": " .. tostring(err) end

local function run(context, where, fn, ...)
    local prev = M.context
    M.context = context
    local args, n = { ... }, select("#", ...)
    local ok, err = xpcall(function() return fn(unpack(args, 1, n)) end, traceback)
    M.context = prev
    if not ok then lerror(where, err) end
    return ok
end

-------------------------------------------------------------------------------
-- Clock and timers
-------------------------------------------------------------------------------

function time() return floor(M.now) end
function date(fmt, t) return osdate(fmt or "%c", t or floor(M.now)) end
function GetTime() return M.now end

local function schedule(delay, fn, owner)
    M.timerSeq = M.timerSeq + 1
    local t = { at = M.now + math.max(delay or 0, 0), fn = fn, seq = M.timerSeq, owner = owner }
    M.timers[#M.timers + 1] = t
    return t
end

C_Timer = {}
function C_Timer.After(delay, fn)
    if type(fn) ~= "function" then error("C_Timer.After: callback is not a function") end
    schedule(delay, fn)
end
function C_Timer.NewTicker(interval, fn, iterations)
    if type(fn) ~= "function" then error("C_Timer.NewTicker: callback is not a function") end
    local ticker = { cancelled = false, left = iterations }
    function ticker:Cancel() self.cancelled = true end
    function ticker:IsCancelled() return self.cancelled end
    local function tick()
        if ticker.cancelled then return end
        fn(ticker)
        if ticker.left then
            ticker.left = ticker.left - 1
            if ticker.left <= 0 then return end
        end
        schedule(interval, tick, ticker)
    end
    schedule(interval, tick, ticker)
    return ticker
end
C_Timer.NewTimer = function(delay, fn) return C_Timer.NewTicker(delay, fn, 1) end

-- Move the clock forward, running every timer that falls due, in order.
function M.advance(seconds)
    local target = M.now + seconds
    while true do
        local best, bi
        for i, t in ipairs(M.timers) do
            if t.at <= target and (not best or t.at < best.at or (t.at == best.at and t.seq < best.seq)) then best, bi = t, i end
        end
        if not best then break end
        table.remove(M.timers, bi)
        M.now = best.at
        run("timer", "timer", best.fn)
    end
    M.now = target
end

-------------------------------------------------------------------------------
-- Frames, events, chat, slash commands
-------------------------------------------------------------------------------

local function noop() end
local Widget = {}
-- A game frame add-on frames must not hang from or anchor to: any game-owned frame except
-- UIParent and those marked allowChildren (the minimap, which add-on buttons sit on by design).
local function isGuarded(f)
    return type(f) == "table" and rawget(f, "blizzard") == true and rawget(f, "allowChildren") ~= true and f ~= rawget(_G, "UIParent")
end
local function isBagWindow(f) return isGuarded(f) end
-- Like the client: an unknown method name does nothing, an unknown field (a child frame
-- such as .Inset or .CloseButton, a flag) is nil.
local METHOD = { "^Set", "^Get", "^Is", "^Has", "^Can", "^Enable", "^Disable", "^Register", "^Unregister",
    "^Create", "^Clear", "^Lock", "^Unlock", "^Start", "^Stop", "^Add", "^Hook", "^Play", "^Raise",
    "^Lower", "^Highlight", "^Adjust", "^Update", "^Reset", "^Toggle" }
Widget.__index = function(_, k)
    local m = Widget[k]
    if m ~= nil then return m end
    if type(k) == "string" then
        for _, pat in ipairs(METHOD) do if k:find(pat) then return noop end end
    end
    return nil
end
function Widget:SetScript(name, fn) self.scripts[name] = fn end
function Widget:GetScript(name) return self.scripts[name] end
function Widget:HookScript(name, fn)
    local old = self.scripts[name]
    self.scripts[name] = function(...) if old then old(...) end fn(...) end
end
function Widget:RegisterEvent(e) self.events[e] = true end
function Widget:UnregisterEvent(e) self.events[e] = nil end
function Widget:IsEventRegistered(e) return self.events[e] == true end
function Widget:SetText(t) self.text = t end
function Widget:GetText() return rawget(self, "text") end
function Widget:Show()
    if self.shown then return end
    self.shown = true
    if self.scripts.OnShow then self.scripts.OnShow(self) end
end
function Widget:Hide()
    if not self.shown then return end
    self.shown = false
    if self.scripts.OnHide then self.scripts.OnHide(self) end
end
function Widget:SetShown(v) if v then self:Show() else self:Hide() end end
function Widget:SetSize(w, h) self.width, self.height = w, h end
function Widget:SetWidth(w) self.width = w end
function Widget:SetHeight(h) self.height = h end
function Widget:GetWidth() return rawget(self, "width") end
function Widget:GetHeight() return rawget(self, "height") end
function Widget:SetPoint(...) self.point = { ... } end
function Widget:ClearAllPoints() self.point = nil end
function Widget:GetPoint() if self.point then
    local p = self.point
    if type(p[2]) == "table" then return p[1], p[2], p[3], p[4], p[5] end
    return p[1], nil, p[1], p[2], p[3]
end end
function Widget:GetCenter() return 700, 500 end
function Widget:GetEffectiveScale() return 1 end
function Widget:SetChecked(v) self.checked = v == true end
function Widget:GetChecked() return self.checked == true end
function Widget:SetEnabled(v) self.enabled = v ~= false end
function Widget:IsEnabled() return self.enabled ~= false end
function Widget:IsShown() return self.shown == true end
M.regions = {}
local function region(kind, parent, layer, template)
    local r = M.widget(kind)
    r.parent, r.layer, r.template, r.font = parent, layer, template, kind == "FontString" and template or nil
    M.regions[#M.regions + 1] = r
    return r
end
function Widget:CreateFontString(name, layer, font) return region("FontString", self, layer, font) end
function Widget:CreateTexture(name, layer) return region("Texture", self, layer) end
function Widget:CreateMaskTexture() return region("MaskTexture", self) end
function Widget:SetFontObject(font) self.font = font end
-- Like the client: false when the file is not there (a new add-on file needs a full restart).
function Widget:SetTexture(t)
    if type(t) == "string" and (W.missingFiles or {})[t] then return false end
    self.texture = t
    return true
end
function Widget:SetAtlas(a) self.atlas = a return true end
function Widget:GetTexture() return rawget(self, "texture") end
function Widget:AddMaskTexture(m) self.mask = m end
function Widget:SetNormalTexture(t) self.normalTexture = t end
function Widget:SetHighlightTexture(t) self.highlightTexture = t end
function Widget:SetPushedTexture(t) self.pushedTexture = t end
function Widget:SetMinMaxValues(lo, hi) self.min, self.max = lo, hi end
function Widget:GetMinMaxValues() return rawget(self, "min") or 0, rawget(self, "max") or 0 end
function Widget:SetValue(v)
    self.value = v
    if self.scripts.OnValueChanged then self.scripts.OnValueChanged(self, v) end
end
function Widget:GetValue() return rawget(self, "value") or 0 end
function Widget:SetMaxLines(n) self.maxLines = n end
function Widget:SetWordWrap(v) self.wordWrap = v end
function Widget:SetRotation(r) self.rotation = r end
function Widget:SetScrollChild(c) self.scrollChild = c end
function Widget:SetFrameStrata(s) self.strata = s end
function Widget:SetVerticalScroll(v) self.scrollY = v end
function Widget:GetVerticalScroll() return rawget(self, "scrollY") or 0 end
function Widget:Click() local f = self.scripts.OnClick if f then run("slash", "OnClick", f, self, "LeftButton") end end
function Widget:SetPoint(...)
    local args = { ... }
    if not M.mockBusy then
        for _, a in ipairs(args) do
            if isBagWindow(a) then violation("add-on anchored a frame to the game's frame " .. tostring(rawget(a, "name"))) end
        end
        if rawget(self, "blizzard") then violation("add-on moved the game's frame " .. tostring(rawget(self, "name"))) end
    end
    rawset(self, "point", args)
end
function Widget:GetName() return rawget(self, "name") end
function Widget:GetLeft() local r = rawget(self, "rect") return r and r.left end
function Widget:GetBottom() local r = rawget(self, "rect") return r and r.bottom end
function Widget:GetRight() local r = rawget(self, "rect") return r and (r.left + r.width) end
function Widget:GetTop() local r = rawget(self, "rect") return r and (r.bottom + r.height) end
function Widget:GetEffectiveScale() return 1 end
function Widget:SetID(id) self.id = id end
function Widget:GetID() return self.id or 0 end

function M.widget(kind, name)
    local w = setmetatable({ kind = kind, name = name, scripts = {}, events = {}, shown = true }, Widget)
    if name then rawset(_G, name, w) end
    return w
end

-- Frames the game owns. The real client blocks protected actions (using an item from the bags)
-- once add-on code has tainted the frames involved. The stand-in cannot model taint, so it
-- refuses the patterns that cause it: an add-on child of, or anchor on, a bag window, and any
-- value the add-on writes onto a game-owned frame.
function M.blizzard(w, isBag)
    rawset(w, "blizzard", true)
    rawset(w, "bagWindow", isBag == true)
    return w
end
local MOCK_FIELDS = {}
for _, k in ipairs({ "kind", "name", "scripts", "events", "shown", "text", "point", "width", "height", "id",
    "parent", "template", "checked", "enabled", "texture", "value", "min", "max", "scrollY", "scrollChild",
    "owner", "lines", "rect", "font", "atlas", "mask", "normalTexture", "highlightTexture", "pushedTexture",
    "maxLines", "strata", "wordWrap" }) do MOCK_FIELDS[k] = true end
Widget.__newindex = function(t, k, v)
    if rawget(t, "blizzard") and not M.mockBusy and not MOCK_FIELDS[k] then
        violation("add-on wrote " .. tostring(k) .. " onto the game's frame " .. tostring(rawget(t, "name")))
    end
    rawset(t, k, v)
end


-- Templates the client provides, as far as the add-on uses them. W.noFrameTemplates makes
-- them missing, as on a client without them (CreateFrame then raises an error).
local TEMPLATES = {}
function CreateFrame(kind, name, parent, template)
    if isBagWindow(parent) and not M.mockBusy then
        violation("add-on created a frame inside the game's frame " .. tostring(rawget(parent, "name")))
    end
    if template and TEMPLATES[template] and W.noFrameTemplates then
        error("CreateFrame: Couldn't find inherited node \"" .. template .. "\"")
    end
    local f = M.widget(kind or "Frame", name)
    f.parent, f.template = parent, template
    M.frames[#M.frames + 1] = f
    if template and TEMPLATES[template] then TEMPLATES[template](f) end
    return f
end

TEMPLATES.ButtonFrameTemplate = function(f)
    f.Inset = CreateFrame("Frame", nil, f)
    f.CloseButton = CreateFrame("Button", nil, f)
    f.portraitShown = true
    function f:SetTitle(t) self.title = t end
end
TEMPLATES.PanelTabButtonTemplate = function(b)
    b.Text = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall2")
    b.Text.fromTemplate = true          -- the client's own font, not the add-on's choice
    b.Left, b.Right = b:CreateTexture(), b:CreateTexture()
    local parent = b.parent
    parent.Tabs = parent.Tabs or {}
    table.insert(parent.Tabs, b)       -- parentArray="Tabs"
end
function ButtonFrameTemplate_HidePortrait(f) f.portraitShown = false end
function ButtonFrameTemplate_HideButtonBar(f) f.buttonBar = false end
-- A tab is as wide as its text plus its sides, unless given an absolute width (as the client does).
function PanelTemplates_TabResize(tab, padding, absoluteSize)
    local text = rawget(tab, "text") or ""
    tab.width = absoluteSize or (#text * (W.tabCharWidth or 7) + 20 + (padding or 0))
end
function PanelTemplates_SetNumTabs(f, n) f.numTabs = n end
function PanelTemplates_SetTab(f, id)
    f.selectedTab = id
    for i = 1, f.numTabs or 0 do f.Tabs[i].selected = (i == id) end
end

M.mockBusy = true
UIParent = M.blizzard(M.widget("Frame", "UIParent"))
Minimap = M.blizzard(M.widget("Frame", "Minimap"))
rawset(Minimap, "allowChildren", true)   -- minimap buttons sit on the minimap by design
Minimap:SetSize(140, 140)
UISpecialFrames = {}
M.cursorX, M.cursorY = 700, 600
function GetCursorPosition() return M.cursorX, M.cursorY end

-- Art files and atlases. W.missingFiles lists paths the client lacks.
function GetFileIDFromPath(path)
    if (W.missingFiles or {})[path] then return nil end
    return 100000 + #tostring(path)
end
C_Texture = {
    GetAtlasInfo = function(atlas) if (W.missingFiles or {})[atlas] then return nil end return { width = 32, height = 32 } end,
}

GameTooltip = M.blizzard(M.widget("GameTooltip", "GameTooltip"))
GameTooltip.shown = false
function GameTooltip:SetOwner(owner) self.owner, self.lines = owner, {} end
function GameTooltip:SetText(t) self.lines = { t } end
function GameTooltip:AddLine(t) self.lines[#self.lines + 1] = t end
M.mockBusy = false

function M.fire(event, ...)
    for _, f in ipairs(M.frames) do
        if f.events[event] and f.scripts.OnEvent then
            run("event", event, f.scripts.OnEvent, f, event, ...)
        end
    end
end

function print(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    M.chat[#M.chat + 1] = table.concat(parts, " ")
end

SlashCmdList = {}
function M.slash(text)
    local cmd, rest = text:match("^(/%S+)%s*(.-)$")
    for key, fn in pairs(SlashCmdList) do
        for i = 1, 9 do
            local alias = rawget(_G, "SLASH_" .. key .. i)
            if alias == nil then break end
            if alias:lower() == cmd:lower() then return run("slash", text, fn, rest) end
        end
    end
    error("no slash command " .. tostring(cmd))
end

function ReloadUI()
    -- The real client only reloads from a key press, click or typed command.
    if M.context ~= "slash" then violation("ReloadUI called from " .. M.context .. "; the game ignores it") return end
    M.reloadRequested = true
end

function InCombatLockdown() return W.inCombat == true end

-- Key bindings. The harness registers each <Binding> of an add-on's Bindings.xml; W.bindings maps a
-- binding name to the key the player chose in the Key Bindings screen.
M.bindings = {}
function M.addBinding(name, header, category, body) M.bindings[name] = { header = header, category = category, body = body } end
function M.pressBinding(name)
    local b = M.bindings[name]
    if not b then error("no binding " .. tostring(name)) end
    local chunk, err = loadstring(b.body, "binding " .. name)
    if not chunk then lerror("binding " .. name, err) return end
    run("binding", "binding " .. name, chunk)
end
function GetBindingKey(action) return (W.bindings or {})[action] end
function GetBindingText(key) return key and (key:gsub("SHIFT%-", "Shift-")) end

-- hooksecurefunc(name, fn) or hooksecurefunc(table, name, fn): run fn after the original.
M.hooks = {}
function hooksecurefunc(a, b, c)
    local t, name, fn = _G, a, b
    if type(a) == "table" then t, name, fn = a, b, c end
    local orig = t[name]
    M.hooks[#M.hooks + 1] = tostring(name)
    t[name] = function(...) local r = { orig(...) } fn(...) return unpack(r) end
end

-- Bag windows. W.bagFrames: nil (none), "login" (exist when add-ons load) or "late" (made
-- the first time the bags are opened, as a client may do).
M.bagWindows = {}
local function makeBagWindows()
    if #M.bagWindows > 0 then return end
    M.mockBusy = true
    local combined = M.blizzard(M.widget("Frame", "ContainerFrameCombinedBags"), true)
    combined:SetID(0)
    combined.shown = false
    combined.rect = { left = 1180, bottom = 120, width = 420, height = 480 }   -- screen position, in UI units
    M.bagWindows[1] = combined
    for i = 1, 6 do
        local f = M.blizzard(M.widget("Frame", "ContainerFrame" .. i), true)
        f:SetID(i - 1)
        f.shown = false
        f.rect = { left = 1400, bottom = 120 + (i - 1) * 200, width = 200, height = 190 }
        M.bagWindows[#M.bagWindows + 1] = f
    end
    M.mockBusy = false
end
if W.bagFrames == "login" then makeBagWindows() end
function ContainerFrameUtil_EnumerateContainerFrames() return ipairs(M.bagWindows) end
function OpenAllBags() makeBagWindows() M.bagWindows[1]:Show() end
function ToggleAllBags() makeBagWindows() local f = M.bagWindows[1] if f.shown then f:Hide() else f:Show() end end

-- Values the client hides from add-ons. Only defined when a test lists some, like a client
-- without the feature.
if W.secrets then
    function issecretvalue(v) return type(v) == "string" and W.secrets[v] == true end
end

-------------------------------------------------------------------------------
-- Items
-------------------------------------------------------------------------------

local ITEMS = setmetatable({}, { __index = function(_, k) return (W.items or {})[k] end })
local QUALITY_COLOR = { [0] = "9d9d9d", "ffffff", "1eff00", "0070dd", "a335ee", "ff8000" }

local function itemIDOf(x)
    if type(x) == "number" then return x end
    if type(x) == "string" then return tonumber(x:match("item:(%d+)")) or (function()
        for id, it in pairs(W.items or {}) do if it.name == x then return id end end
    end)() end
end

function M.link(id)
    local it = ITEMS[id]
    if not it then return nil end
    return ("|cff%s|Hitem:%d::::::::|h[%s]|h|r"):format(QUALITY_COLOR[it.quality or 1] or "ffffff", id, it.name)
end

local function getItemInfo(x)
    local id = itemIDOf(x)
    local it = id and ITEMS[id]
    if not it then return nil end
    return it.name, M.link(id), it.quality or 1, it.itemLevel or 1, it.requiredLevel or 0, it.type or "Miscellaneous",
           it.subType or "Junk", it.maxStack or 1, it.equipLoc or "", 134400, it.sellPrice or 0
end

C_Item = {
    GetItemInfo = getItemInfo,
    GetItemNameByID = function(id) local it = ITEMS[itemIDOf(id)] return it and it.name end,
}

local function tooltipData(id)
    local it = ITEMS[id]
    if not it then return nil end
    local lines = { { leftText = M.link(id) and it.name } }
    for _, l in ipairs(it.tooltip or {}) do
        if type(l) == "table" then lines[#lines + 1] = { leftText = l[1], rightText = l[2] }
        else lines[#lines + 1] = { leftText = l } end
    end
    return { id = id, type = 0, lines = lines }
end

-------------------------------------------------------------------------------
-- Character
-------------------------------------------------------------------------------

local C = setmetatable({}, { __index = function(_, k) return (W.character or {})[k] end })
local function unloaded() return W.characterDataUnloaded == true end

function UnitName(unit)
    if unit == "player" then return C.name end
    if unit == "npc" then return W.npc end
    if unit == "target" then return W.target end
    if unit == "pet" then return W.pet end
end
function UnitFullName(unit) if unit == "player" then return C.name, C.realm end end
function GetRealmName() return C.realm end
function UnitClass(unit) if unit == "player" then return C.className, C.class, C.classID or 3 end end
-- A class's specializations, as the game names them (issue #51). W.specs replaces the hunter's.
local function SPECS()
    if W.noSpecs then return {} end
    return W.specs or { { id = 253, name = "Beast Mastery", role = "DAMAGER" },
                        { id = 254, name = "Marksmanship", role = "DAMAGER" },
                        { id = 255, name = "Survival", role = "DAMAGER" } }
end
-- The class's talent trees as Forever's talent system names them (issue #51, v2): one class tree
-- whose display groups are the trees (Discipline, Holy, Shadow for a priest). W.talentTrees = false
-- means talents are not unlocked yet.
C_ClassTalents = { GetActiveConfigID = function() if W.talentTrees == false then return nil end return 7001 end }
C_Traits = {
    GetConfigInfo = function(id) if id == 7001 then return { name = "Talents", type = 1, treeIDs = { 801 } } end end,
    GetGroupDisplayInfoByTreeID = function(treeID)
        if treeID ~= 801 or W.talentTrees == false then return {} end
        local names = W.talentTrees or { "Beast Mastery", "Marksmanship", "Survival" }
        local out = {}
        for i = #names, 1, -1 do        -- not in display order, as the game need not return it in order
            out[#out + 1] = { groupID = 900 + i, treeID = 801, skillLineID = 0, orderIndex = i - 1, displayName = names[i], icon = 0 }
        end
        return out
    end,
}
-- The group roles this class can fill (a hunter: damage only).
function UnitGetAvailableRoles(unit)
    local r = W.roles or { tank = false, heal = false, dps = true }
    return r.tank == true, r.heal == true, r.dps == true
end
C_SpecializationInfo = {
    GetNumSpecializationsForClassID = function(classID) if classID == (C.classID or 3) then return #SPECS() end return 0 end,
    GetSpecializationInfo = function(i, isInspect, isPet, target, sex, group, classID)
        local sp = SPECS()[i]
        if sp then return sp.id, sp.name, "", 0, sp.role end
    end,
}
function UnitRace(unit) if unit == "player" then return C.race, C.race end end
function UnitFactionGroup(unit) if unit == "player" then return C.faction, C.faction end end
function UnitSex(unit) if unit == "player" then return C.sex end end
function UnitLevel(unit) if unit == "player" then return C.level end end
function UnitXP() return C.xp or 0 end
function UnitXPMax() return C.xpMax or 1000 end
function GetXPExhaustion() return C.rested end
function IsResting() return C.resting == true end
function GetMoney() if unloaded() then return 0 end return C.money or 0 end
function UnitExists(unit)
    return unit == "player" or (unit == "npc" and W.npc ~= nil) or (unit == "pet" and W.pet ~= nil)
         or (unit == "target" and W.target ~= nil)
end
function UnitIsDeadOrGhost() return false end
function GetRealZoneText() return W.zone end
function GetZoneText() return W.zone end
function GetSubZoneText() return W.subZone end
function GetBindLocation() return W.hearth end
function GetBuildInfo() return "1.16.1", "99999", "Nov 1 2026", 16001 end
function GetLocale() return "enUS" end

function GetProfessions()
    local p = C.professions or {}
    local idx = {}
    for i = 1, #p do idx[i] = i end
    return unpack(idx)
end
function GetProfessionInfo(i)
    local p = (C.professions or {})[i]
    if not p then return nil end
    return p.name, 0, p.rank, p.max, 0, 0, p.skillLine or 0
end

-- Armor and weapon proficiencies, read by the rules (category 8 = armor, 6 = weapons).
C_SkillInfo = {
    GetNumSkillLines = function() return #(C.skills or {}) end,
    GetSkillLineInfo = function(i)
        local s = (C.skills or {})[i]
        if not s then return nil end
        return { name = s[1], skillLineCategoryID = s[2], isHeader = false }
    end,
}

-------------------------------------------------------------------------------
-- Bags, bank and equipment
-------------------------------------------------------------------------------

NUM_TOTAL_EQUIPPED_BAG_SLOTS = 4
local BAGS = setmetatable({}, { __index = function(_, k) return (W.bags or {})[k] end })

local function bag(b)
    if unloaded() then return nil end
    if b < 0 or b > NUM_TOTAL_EQUIPPED_BAG_SLOTS then
        if not W.bankOpen then return nil end
        return (W.bank or {})[b]
    end
    return BAGS[b]
end

C_Container = {}
function C_Container.GetContainerNumSlots(b) local x = bag(b) return x and x.slots or 0 end
function C_Container.GetBagName(b) local x = bag(b) return x and x.name end
function C_Container.GetContainerNumFreeSlots(b)
    local x = bag(b)
    if not x then return 0, 0 end
    local used = 0
    for s = 1, x.slots do if x.items and x.items[s] then used = used + 1 end end
    return x.slots - used, x.family or 0
end
function C_Container.GetContainerItemInfo(b, s)
    local x = bag(b)
    local slot = x and x.items and x.items[s]
    if not slot then return nil end
    local it = ITEMS[slot.id] or {}
    return {
        hyperlink = M.link(slot.id), stackCount = slot.count or 1, itemID = slot.id, itemName = it.name,
        isBound = slot.bound == true, hasNoValue = (it.sellPrice or 0) == 0, quality = it.quality,
        isLocked = slot.locked == true,
    }
end

local EQUIP = setmetatable({}, { __index = function(_, k) return (W.equipment or {})[k] end })
function GetInventoryItemLink(unit, slot)
    if unit ~= "player" or unloaded() then return nil end
    return EQUIP[slot] and M.link(EQUIP[slot])
end
function GetInventoryItemCount() return 1 end
function GetInventoryItemDurability() return nil end

C_TooltipInfo = {
    GetBagItem = function(b, s)
        local x = bag(b)
        local slot = x and x.items and x.items[s]
        return slot and tooltipData(slot.id)
    end,
    GetInventoryItem = function(unit, slot) return EQUIP[slot] and tooltipData(EQUIP[slot]) end,
}


-------------------------------------------------------------------------------
-- Cursor and item moves, as the client does them:
-- picking up an item and putting it on an empty slot moves it; on a different item, swaps;
-- on the same stackable item, merges the stacks. A special bag (family ~= 0) only takes items
-- of its kind.
-- Like the real client, a move is not applied at once. Both slots lock straight away; the
-- server confirms later. Each slot's contents change at its own moment (moveConfirm, plus
-- moveSkew for the second slot), and the locks clear at moveUnlock, which may be before the
-- contents change. Events: ITEM_LOCK_CHANGED on each lock change, BAG_UPDATE per slot, then
-- BAG_UPDATE_DELAYED.
-------------------------------------------------------------------------------

local MOVE_CONFIRM = W.moveConfirm or 0.25
local MOVE_SKEW = W.moveSkew or 0.1
local MOVE_UNLOCK = W.moveUnlock or 0.15
M.cursor = nil
M.moves = 0

local function slotRef(b, s)
    local x = bag(b)
    if not x or s < 1 or s > x.slots then return nil end
    x.items = x.items or {}
    return x
end

local function setLock(x, s, on, b)
    local it = x.items[s]
    if it then it.locked = on or nil end
    M.fire("ITEM_LOCK_CHANGED", b, s)
end

C_Container.PickupContainerItem = function(b, s)
    if InCombatLockdown() then violation("item moved in combat") end
    if W.forbidMoves then M.fire("ADDON_ACTION_FORBIDDEN", "AICompanion", "PickupContainerItem()") return end
    local x = slotRef(b, s)
    if not x then return end
    local here = x.items[s]
    if here and here.locked then violation("picked up a locked item at " .. b .. "/" .. s) return end
    if not M.cursor then
        if here then M.cursor = { bag = b, slot = s, x = x } end
        return
    end
    if W.refusePlace then return end   -- the client keeps the item on the cursor
    local from = M.cursor
    local fx, fs, fb = from.x, from.slot, from.bag
    local moving = fx.items[fs]
    M.cursor = nil
    if fx == x and fs == s then return end
    if (x.family or 0) ~= 0 and not (ITEMS[moving.id] and ITEMS[moving.id].family == x.family) then
        violation("put an item into a special bag that does not take it") M.cursor = from return
    end
    if here and (fx.family or 0) ~= 0 and not (ITEMS[here.id] and ITEMS[here.id].family == fx.family) then
        violation("swapped an item into a special bag that does not take it") M.cursor = from return
    end
    M.moves = M.moves + 1
    -- what each slot will hold once the server confirms
    local destAfter, srcAfter
    if here and here.id == moving.id and (ITEMS[here.id] and (ITEMS[here.id].maxStack or 1) > 1) then
        local max = ITEMS[here.id].maxStack
        local total = (here.count or 1) + (moving.count or 1)
        destAfter = { id = here.id, count = math.min(total, max) }
        srcAfter = total > max and { id = moving.id, count = total - max } or nil
    else
        destAfter = { id = moving.id, count = moving.count, bound = moving.bound }
        srcAfter = here and { id = here.id, count = here.count, bound = here.bound } or nil
    end
    setLock(x, s, true, b)
    setLock(fx, fs, true, fb)
    local function apply(bx, bs, bb, after)
        if after then after.locked = bx.items[bs] and bx.items[bs].locked or nil end
        bx.items[bs] = after
        M.fire("BAG_UPDATE", bb)
    end
    schedule(MOVE_UNLOCK, function() setLock(x, s, false, b) setLock(fx, fs, false, fb) end)
    schedule(MOVE_CONFIRM, function() apply(x, s, b, destAfter) end)
    schedule(MOVE_CONFIRM + MOVE_SKEW, function()
        apply(fx, fs, fb, srcAfter)
        M.fire("BAG_UPDATE_DELAYED")
    end)
end

function ClearCursor() M.cursor = nil end
function CursorHasItem() return M.cursor ~= nil end
function GetCursorInfo()
    if not M.cursor then return nil end
    local it = M.cursor.x.items[M.cursor.slot]
    return "item", it and it.id, it and M.link(it.id)
end

-------------------------------------------------------------------------------
-- Quests
-------------------------------------------------------------------------------

local function QUESTS() return W.quests or {} end
C_QuestLog = {
    GetNumQuestLogEntries = function() if unloaded() then return 0 end return #QUESTS() end,
    GetInfo = function(i)
        local q = QUESTS()[i]
        if not q then return nil end
        return { title = q.title, questID = q.id, level = q.level, isHeader = q.header == true }
    end,
    IsComplete = function(id) for _, q in ipairs(QUESTS()) do if q.id == id then return q.complete == true end end return false end,
    GetQuestObjectives = function(id)
        for _, q in ipairs(QUESTS()) do if q.id == id then return q.objectives end end
    end,
    GetAllCompletedQuestIDs = function() return W.completedQuests or {} end,
    GetTitleForQuestID = function(id) return (W.questTitles or {})[id] end,
    RequestLoadQuestByID = function() end,
    -- The quest tracker (objectives at the right of the screen), in the order the game holds it.
    GetNumQuestWatches = function() return #(W.questWatches or {}) end,
    GetQuestIDForQuestWatchIndex = function(i) local w = (W.questWatches or {})[i] return w and w.id end,
    GetDistanceSqToQuest = function(id)
        for _, w in ipairs(W.questWatches or {}) do if w.id == id then return w.distSq, w.onContinent end end
    end,
    GetNextWaypoint = function(id)
        for _, w in ipairs(W.questWatches or {}) do
            if w.id == id and w.waypoint then return w.waypoint[1], w.waypoint[2], w.waypoint[3] end
        end
    end,
    GetNextWaypointForMap = function(id, mapID)
        local p = mapID == W.mapID and (W.waypointsForMap or {})[id]
        if p then return p[1], p[2] end
    end,
}
-- Changing the tracker is the player's business: the add-on only reads it (issue #39).
M.trackerChanges = {}
local function trackerChange(what)
    return function(...)
        M.trackerChanges[#M.trackerChanges + 1] = what
        violation("add-on changed the quest tracker: " .. what)
    end
end
C_QuestLog.SortQuestWatches = trackerChange("SortQuestWatches")
C_QuestLog.AddQuestWatch = trackerChange("AddQuestWatch")
C_QuestLog.RemoveQuestWatch = trackerChange("RemoveQuestWatch")
C_SuperTrack = {
    GetSuperTrackedQuestID = function() return W.superTracked end,
    SetSuperTrackedQuestID = trackerChange("SetSuperTrackedQuestID"),
}
C_Map = C_Map or {}
C_Map.GetBestMapForUnit = C_Map.GetBestMapForUnit or function() return W.mapID end

-- The world map, for finding a zone's map from its name (issue #45). W.maps lists
-- { mapID, name, mapType, parentMapID }; the game's own map pin is recorded in M.userWaypoint.
local function MAPS()
    return W.maps or {
        { mapID = 1429, name = "Elwynn Forest", mapType = 3, parentMapID = 1415 },
        { mapID = 1453, name = "Stormwind City", mapType = 3, parentMapID = 1415 },
        { mapID = 1415, name = "Eastern Kingdoms", mapType = 2, parentMapID = 947 },
    }
end
C_Map.GetFallbackWorldMapID = function() return 947 end
C_Map.GetMapChildrenInfo = function(id, mapType, all)
    local out = {}
    for _, m in ipairs(MAPS()) do
        if (all or m.parentMapID == id) and (mapType == nil or m.mapType == mapType) then
            out[#out + 1] = { mapID = m.mapID, name = m.name, mapType = m.mapType, parentMapID = m.parentMapID }
        end
    end
    return out
end
C_Map.GetMapInfo = function(id)
    for _, m in ipairs(MAPS()) do if m.mapID == id then return { mapID = m.mapID, name = m.name, mapType = m.mapType, parentMapID = m.parentMapID } end end
end
C_Map.CanSetUserWaypointOnMap = function(id) return not (W.noPinMaps or {})[id] end
C_Map.SetUserWaypoint = function(point)
    if not (type(point) == "table" and point.uiMapID and point.position) then error("SetUserWaypoint: bad UiMapPoint") end
    M.userWaypoint = { mapID = point.uiMapID, x = point.position.x, y = point.position.y }
    return true
end
C_SuperTrack.SetSuperTrackedUserWaypoint = function(on) M.userWaypointTracked = on == true end
function CreateVector2D(x, y) return { x = x, y = y } end
-- A stand-in TomTom (W.tomtom = "ok" or "fails"), used only through its AddWaypoint function.
if W.tomtom then
    TomTom = { waypoints = {} }
    function TomTom:AddWaypoint(mapID, x, y, opts)
        if W.tomtom == "fails" then error("TomTom broke") end
        self.waypoints[#self.waypoints + 1] = { mapID = mapID, x = x, y = y, title = opts and opts.title, from = opts and opts.from }
        return { mapID, x, y }
    end
end

-------------------------------------------------------------------------------
-- Trainer window (only while open). W.trainerWindow = { type = TrainerType, services = {...} }.
-- The hunter's Beast Training uses the same window with type 3 (Pet) and no NPC (issue #46).
-------------------------------------------------------------------------------

local function TW() return W.trainerWindow end
function GetNumTrainerServices() return TW() and #TW().services or 0 end
function GetTrainerServiceInfo(i)
    local s = TW() and TW().services[i]
    if s then return s.name, s.rank, s.category or "available", false end
end
function GetTrainerServiceCost(i) local s = TW() and TW().services[i] return s and s.cost end
function GetTrainerServiceLevelReq(i) local s = TW() and TW().services[i] return s and s.level end
function GetTrainerServiceSkillReq() return nil end
C_Trainer = { GetTrainerType = function() return TW() and TW().type end }
C_PetInfo = { GetPetTrainingPoints = function() if W.petTraining then return W.petTraining.total, W.petTraining.used end end }

-------------------------------------------------------------------------------
-- Trade skill window (only while open)
-------------------------------------------------------------------------------

C_TradeSkillUI = {
    GetAllRecipeIDs = function()
        if not W.tradeSkill then return nil end
        local ids = {}
        for _, r in ipairs(W.tradeSkill.recipes) do ids[#ids + 1] = r.id end
        return ids
    end,
    GetBaseProfessionInfo = function() return W.tradeSkill and { professionName = W.tradeSkill.profession } end,
    GetRecipeInfo = function(id)
        for _, r in ipairs((W.tradeSkill or {}).recipes or {}) do
            if r.id == id then return { name = r.name, learned = true, relativeDifficulty = r.difficulty or 0, craftable = true, numAvailable = r.available or 0 } end
        end
    end,
}

-------------------------------------------------------------------------------
-- Tooltips
-------------------------------------------------------------------------------

Enum = {
    TooltipDataType = { Item = 0, Spell = 1, Unit = 2 },
    SpellBookSpellBank = { Player = 0, Pet = 1 },
    AuctionHouseSortOrder = { Price = 0, Name = 1, Level = 2, Bid = 3, Buyout = 4 },
    -- Values as the Forever client has them (tests/forever/api_names.json).
    AuctionHouseFilter = {
        None = 0, UncollectedOnly = 1, UsableOnly = 2, CurrentExpansionOnly = 3, UpgradesOnly = 4, ExactMatch = 5,
        PoorQuality = 6, CommonQuality = 7, UncommonQuality = 8, RareQuality = 9, EpicQuality = 10,
        LegendaryQuality = 11, ArtifactQuality = 12, LegendaryCraftedItemOnly = 13,
    },
}

TooltipDataProcessor = {
    AddTooltipPostCall = function(kind, fn)
        M.tooltipPostCalls[kind] = M.tooltipPostCalls[kind] or {}
        table.insert(M.tooltipPostCalls[kind], fn)
    end,
}

-- Show an item tooltip and return the lines the add-on added to it.
function M.hover(id)
    local tip = { added = {} }
    function tip:AddLine(text, r, g, b, wrap) self.added[#self.added + 1] = { left = text, wrap = wrap } end
    function tip:AddDoubleLine(l, rt) self.added[#self.added + 1] = { left = l, right = rt } end
    for _, fn in ipairs(M.tooltipPostCalls[Enum.TooltipDataType.Item] or {}) do
        run("tooltip", "tooltip", fn, tip, tooltipData(id) or { id = id })
    end
    return tip.added
end

-------------------------------------------------------------------------------
-- Auction house
-- Modelled rules: a browse query with no quality filter matches nothing; a query sent while
-- the throttle is not ready is dropped; one query is answered at a time.
-------------------------------------------------------------------------------

local A = M.auction
local THROTTLE = W.auctionThrottle or 1.0
local ANSWER_DELAY = W.auctionAnswerDelay or 0.3

C_AuctionHouse = {}
function C_AuctionHouse.IsThrottledMessageSystemReady() return M.now >= A.readyAt end
function C_AuctionHouse.SendBrowseQuery(q)
    if not W.auctionOpen then violation("auction query sent with the auction window closed") return end
    if M.now < A.readyAt then violation("auction query sent while throttled: " .. tostring(q.searchString)) return end
    if A.pending then violation("auction query sent before the previous one was answered: " .. tostring(q.searchString)) end
    A.readyAt = M.now + THROTTLE
    local filters = {}
    for _, f in ipairs(q.filters or {}) do filters[f] = true end
    local F = Enum.AuctionHouseFilter
    local anyQuality = filters[F.PoorQuality] or filters[F.CommonQuality] or filters[F.UncommonQuality]
        or filters[F.RareQuality] or filters[F.EpicQuality]
    local results = {}
    if anyQuality then
        for name, listing in pairs(W.auctionListings or {}) do
            local match = (filters[F.ExactMatch] and name == q.searchString)
                or (not filters[F.ExactMatch] and name:lower():find(q.searchString:lower(), 1, true))
            if match then
                results[#results + 1] = { itemKey = { itemID = itemIDOf(name) or 0 }, minPrice = listing.price, totalQuantity = listing.quantity }
            end
        end
    end
    A.sent[#A.sent + 1] = { search = q.searchString, at = M.now, filters = #(q.filters or {}), qualityFilters = anyQuality == true }
    local silent = (W.auctionSilent or {})[q.searchString]
    if silent then return end
    local token = {}
    A.pending = token
    schedule(ANSWER_DELAY, function()
        if A.pending ~= token then return end
        A.pending = nil
        A.results = results
        M.fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
    end)
    schedule(THROTTLE, function() M.fire("AUCTION_HOUSE_THROTTLED_SYSTEM_READY") end)
end
function C_AuctionHouse.GetBrowseResults() return A.results or {} end
function C_AuctionHouse.GetItemKeyInfo(key)
    local it = ITEMS[key.itemID]
    return it and { itemName = it.name }
end

function M.openAuction()
    W.auctionOpen = true
    if not AuctionHouseFrame then
        M.mockBusy = true
        AuctionHouseFrame = M.blizzard(M.widget("Frame", "AuctionHouseFrame"))
        AuctionHouseFrame.rect = { left = 300, bottom = 200, width = 800, height = 540 }
        M.mockBusy = false
    end
    AuctionHouseFrame.shown = true
    M.fire("AUCTION_HOUSE_SHOW")
end
function M.closeAuction()
    W.auctionOpen = false
    if AuctionHouseFrame then rawset(AuctionHouseFrame, "shown", false) end
    M.fire("AUCTION_HOUSE_CLOSED")
end

-------------------------------------------------------------------------------
-- Game sandbox: the client has no os, io or module loading, and add-ons should not
-- create globals beyond the ones they declare.
-------------------------------------------------------------------------------

os, io, require, dofile, loadfile, package, module, debug = nil, nil, nil, nil, nil, nil, nil, nil
python = nil

function M.trackGlobals(allowed)
    setmetatable(_G, {
        __newindex = function(t, k, v)
            if not allowed[k] then M.newGlobals[#M.newGlobals + 1] = tostring(k) end
            rawset(t, k, v)
        end,
    })
end

-- Run one add-on file as the game does: with the add-on name and a private table as "...".
function M.loadFile(addon, path, source, ns)
    local chunk, err = loadstring(source, "@" .. path)
    if not chunk then lerror(path, err) return false end
    return run("load", path, chunk, addon, ns)
end

-------------------------------------------------------------------------------
-- SavedVariables: what the game writes to disk on /reload or logout.
-- Only strings, numbers, booleans and tables survive; anything else is a fault.
-------------------------------------------------------------------------------

function M.serialize(name, value)
    local out, seen = {}, {}
    local function emit(v, indent, path)
        local t = type(v)
        if t == "string" then out[#out + 1] = ("%q"):format(v)
        elseif t == "number" then
            if v ~= v or v == math.huge or v == -math.huge then violation("saved value is not a finite number at " .. path) out[#out + 1] = "0"
            elseif v == floor(v) and math.abs(v) < 2^53 then out[#out + 1] = ("%d"):format(v)
            else out[#out + 1] = ("%.17g"):format(v) end
        elseif t == "boolean" then out[#out + 1] = tostring(v)
        elseif t == "table" then
            if seen[v] then violation("saved table refers to itself at " .. path) out[#out + 1] = "nil" return end
            seen[v] = true
            out[#out + 1] = "{\n"
            local keys = {}
            for k in pairs(v) do keys[#keys + 1] = k end
            table.sort(keys, function(a, b)
                if type(a) == type(b) and (type(a) == "number" or type(a) == "string") then return a < b end
                return type(a) < type(b)
            end)
            for _, k in ipairs(keys) do
                local kt = type(k)
                if kt ~= "string" and kt ~= "number" then
                    violation("saved key of type " .. kt .. " at " .. path)
                else
                    out[#out + 1] = indent .. "\t[" .. (kt == "string" and ("%q"):format(k) or tostring(k)) .. "] = "
                    emit(v[k], indent .. "\t", path .. "." .. tostring(k))
                    out[#out + 1] = ",\n"
                end
            end
            out[#out + 1] = indent .. "}"
            seen[v] = nil
        else
            violation("saved value of type " .. t .. " at " .. path)
            out[#out + 1] = "nil"
        end
    end
    out[#out + 1] = "\n" .. name .. " = "
    emit(value, "", name)
    out[#out + 1] = "\n"
    return table.concat(out)
end
