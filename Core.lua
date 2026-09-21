-- XanaRings 0.6.0  (snippet-free build for the WoW Forever beta)
--
-- The Forever beta client cannot compile restricted-environment snippets
-- (loadstring_untainted is missing), so this version uses none:
--   * the macro /clicks a plain button that opens the ring
--   * one SecureActionButton ("commit") does the casting; its attributes and the
--     temporary override bindings are set by ordinary code, which is only legal
--     OUT OF COMBAT. Rings therefore refuse to open in combat on this build.
--
-- The beta also fails to load SavedVariables, so each ring's definition is mirrored
-- into its macro body (a no-op "/xrdata ..." line) and re-imported at login.
--
-- Rings have no fixed size: ring.slots is a plain list, the circle grows with it.
-- The only ceiling is the 255-character macro body the ring has to fit into.
--
-- Flow: macro -> ring opens -> tilt stick to highlight -> A uses it, B cancels.
--       D-pad up/right/down/left instantly uses the slot lying in that direction.
--
-- Auto rings store item TYPES instead of entries (ring.auto, a string of type letters)
-- and fill ring.slots from the player's bags each time they are opened.

local ADDON = ...

local MIN_RADIUS  = 110
local SLOT_SIZE   = 52
local SLOT_GAP    = 12
local DEADZONE    = 0.5
local MACRO_LIMIT = 255
local DPAD = {
    PADDUP    = { name = "up",    angle = 0   },
    PADDRIGHT = { name = "right", angle = 90  },
    PADDDOWN  = { name = "down",  angle = 180 },
    PADDLEFT  = { name = "left",  angle = 270 },
}

local db
local openers = {}
local openRing            -- ring currently open for use (not editing)
local warnedCombat
local function Print(msg) print("|cff66ccffXanaRings:|r " .. msg) end

-- Which of n slots lies at this angle (0 = up, clockwise). Slot 1 is always on top.
local function IndexForAngle(deg, n)
    if n < 1 then return 0 end
    local step = 360 / n
    return math.floor(((deg + step / 2) % 360) / step) + 1
end

-------------------------------------------------------------------------------
-- Auto rings: item types and the bag scan
-------------------------------------------------------------------------------
local AUTO_MAX = 16                 -- more than this is too fiddly to aim at
local CLASS_CONSUMABLE, CLASS_QUEST = 0, 12

-- `key` is the letter saved in the macro, so never reuse or reorder letters.
-- Display order is the order of this list.
local AUTO_TYPES = {
    { key = "p", label = "Potions",      words = { "potions" },  class = CLASS_CONSUMABLE, sub = 1 },
    { key = "e", label = "Elixirs",      words = { "elixirs" },  class = CLASS_CONSUMABLE, sub = 2 },
    { key = "f", label = "Flasks",       words = { "flasks" },   class = CLASS_CONSUMABLE, sub = 3 },
    { key = "d", label = "Food & Drink", words = { "food", "drinks" }, class = CLASS_CONSUMABLE, sub = 5 },
    { key = "b", label = "Bandages",     words = { "bandages" }, class = CLASS_CONSUMABLE, sub = 7 },
    { key = "s", label = "Scrolls",      words = { "scrolls" },  class = CLASS_CONSUMABLE, sub = 4 },
    { key = "q", label = "Quest items",  words = { "quest" },    class = CLASS_QUEST },
    { key = "o", label = "Other usable", words = { "other" },    class = CLASS_CONSUMABLE },   -- any other subclass
}
for i, t in ipairs(AUTO_TYPES) do t.order = i end

local function AutoTypeOf(classID, subclassID)
    local other
    for _, t in ipairs(AUTO_TYPES) do
        if t.class == classID then
            if t.sub == nil then
                other = other or t
            elseif t.sub == subclassID then
                return t
            end
        end
    end
    return other
end

local function AutoLabels(auto)
    local labels = {}
    for _, t in ipairs(AUTO_TYPES) do
        if auto:find(t.key, 1, true) then labels[#labels + 1] = t.label end
    end
    return #labels > 0 and table.concat(labels, ", ") or "nothing yet"
end

local BagSlotCount    =(C_Container and C_Container.GetContainerNumSlots) or GetContainerNumSlots
local GetBagItemID    = (C_Container and C_Container.GetContainerItemID) or GetContainerItemID
local ItemInfoInstant = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
local ItemSpell       = (C_Item and C_Item.GetItemSpell) or GetItemSpell
local ItemCount       = (C_Item and C_Item.GetItemCount) or GetItemCount

local function ItemName(id)
    return (C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(id))
        or (GetItemInfo and GetItemInfo(id)) or ""
end

-- Every usable item in the bags whose type is in `auto`, one entry per item ID.
local function ScanBags(auto)
    local seen, list = {}, {}
    for bag = 0, NUM_BAG_SLOTS or 4 do
        for bagSlot = 1, BagSlotCount(bag) or 0 do
            local id = GetBagItemID(bag, bagSlot)
            if id and not seen[id] then
                seen[id] = true
                local classID, subclassID = select(6, ItemInfoInstant(id))
                local t = AutoTypeOf(classID, subclassID)
                if t and auto:find(t.key, 1, true) and ItemSpell(id) then
                    list[#list + 1] = { kind = "item", id = id, order = t.order,
                                        name = ItemName(id), count = ItemCount(id) }
                end
            end
        end
    end
    table.sort(list, function(a, b)
        if a.order ~= b.order then return a.order < b.order end
        if a.name ~= b.name then return a.name < b.name end
        return a.id < b.id
    end)
    for i = #list, AUTO_MAX + 1, -1 do list[i] = nil end
    return list
end

local function Rescan(ring)
    if ring.auto then ring.slots = ScanBags(ring.auto) end
end

-------------------------------------------------------------------------------
-- The one secure button
-------------------------------------------------------------------------------
local commit = CreateFrame("Button", "XanaRingsCommit", UIParent, "SecureActionButtonTemplate")
commit:RegisterForClicks("AnyDown", "AnyUp")

local cancel = CreateFrame("Button", "XanaRingsCancel", UIParent)
cancel:RegisterForClicks("AnyDown", "AnyUp")

-- suffix ""                 -> what A uses (the stick-highlighted slot)
-- suffix "-up" / "-right".. -> what that D-pad direction uses
local function SetCommitSlot(suffix, slot)
    local kind = slot and slot.kind or (suffix ~= "" and "none" or nil)
    commit:SetAttribute("type" .. suffix, kind)
    commit:SetAttribute("spell" .. suffix, (slot and slot.kind == "spell") and slot.id or nil)
    commit:SetAttribute("item" .. suffix, (slot and slot.kind == "item") and ("item:" .. slot.id) or nil)
end

-------------------------------------------------------------------------------
-- Visible ring
-------------------------------------------------------------------------------
local ui = CreateFrame("Frame", "XanaRingsFrame", UIParent)
ui:SetPoint("CENTER")
ui:SetFrameStrata("DIALOG")
ui:Hide()
ui.slots = {}

ui.title = ui:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
ui.title:SetPoint("CENTER", 0, 8)
ui.hint = ui:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
ui.hint:SetPoint("TOP", ui, "BOTTOM", 0, -4)

local function GetIcon(slot)
    if slot.kind == "spell" then
        return (C_Spell and C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(slot.id))
            or (GetSpellTexture and GetSpellTexture(slot.id))
    elseif slot.kind == "item" then
        return (C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(slot.id))
            or (GetItemIcon and GetItemIcon(slot.id))
    end
end

local SlotDrop            -- defined in the editing section

local function GetSlotButton(i)
    local btn = ui.slots[i]
    if btn then return btn end
    btn = CreateFrame("Button", nil, ui)
    btn.index = i
    btn:SetSize(SLOT_SIZE, SLOT_SIZE)
    btn.icon = btn:CreateTexture(nil, "ARTWORK")
    btn.icon:SetAllPoints()
    btn.plus = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
    btn.plus:SetPoint("CENTER")
    btn.plus:SetText("+")
    btn.count = btn:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
    btn.count:SetPoint("BOTTOMRIGHT", -3, 3)
    btn.glow = btn:CreateTexture(nil, "OVERLAY")
    btn.glow:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
    btn.glow:SetBlendMode("ADD")
    btn.glow:SetPoint("CENTER")
    btn.glow:SetSize(SLOT_SIZE * 1.75, SLOT_SIZE * 1.75)
    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    btn:SetScript("OnClick", function(self, mouseButton) SlotDrop(self, mouseButton) end)
    btn:SetScript("OnReceiveDrag", function(self) SlotDrop(self) end)
    ui.slots[i] = btn
    return btn
end

-- Place `count` buttons evenly on a circle that grows so icons never overlap.
local function Layout(count)
    local radius = math.max(MIN_RADIUS, count * (SLOT_SIZE + SLOT_GAP) / (2 * math.pi))
    local size = radius * 2 + SLOT_SIZE + 40
    ui:SetSize(size, size)
    for i = 1, count do
        local btn = GetSlotButton(i)
        local a = math.rad((i - 1) * 360 / count)          -- slot 1 on top, clockwise
        btn:ClearAllPoints()
        btn:SetPoint("CENTER", ui, "CENTER", math.sin(a) * radius, math.cos(a) * radius)
        btn:Show()
    end
    for i = count + 1, #ui.slots do ui.slots[i]:Hide() end
end

local function Refresh()
    local ring = ui.ring
    if not ring then return end
    ui.title:SetText(ring.name)
    local n = #ring.slots
    local adding = ui.editing and not ring.auto            -- auto rings are filled from the bags
    local count = adding and n + 1 or n                   -- the editor shows one extra "+" slot
    Layout(count)
    for i = 1, count do
        local btn, slot = ui.slots[i], ring.slots[i]
        btn:EnableMouse(adding)
        btn.count:SetText((slot and slot.count and slot.count > 1) and slot.count or "")
        if slot then
            btn.icon:SetTexture(GetIcon(slot) or 134400)
        else
            btn.icon:SetColorTexture(0, 0, 0, 0.45)
        end
        btn.plus:SetShown(not slot)
        btn.glow:SetShown(not ui.editing and i == ui.selected)
    end
end

local function ShowRing(ring, editing)
    ui.ring, ui.editing, ui.selected = ring, editing, 0
    ui.done:SetShown(editing)
    ui.autoPanel:SetShown(editing and ring.auto ~= nil)
    if ui.EnableGamePadStick then ui:EnableGamePadStick(not editing) end
    if editing and ring.auto then
        Rescan(ring)
        ui.autoPanel:Sync()
        ui.hint:SetText("Tick the item types to include. The ring shows what is in your bags right now.")
    elseif editing then
        ui.hint:SetText("Drop a spell or item on + to add it, or on an icon to replace it. Right-click removes.")
    elseif #ring.slots == 0 and ring.auto then
        ui.hint:SetText(("Nothing in your bags matches this ring. Press B, or /xrings edit %s"):format(ring.name))
    elseif #ring.slots == 0 then
        ui.hint:SetText(("This ring is empty. Press B, then type /xrings edit %s"):format(ring.name))
    else
        ui.hint:SetText("Stick + A to use.  D-pad = quick pick.  B cancels.")
    end
    Refresh()
    ui:Show()
end

-------------------------------------------------------------------------------
-- Open / close (out of combat only)
-------------------------------------------------------------------------------
local function CloseRing()
    if not openRing then return end
    openRing = nil
    commit.armed, cancel.armed = nil, nil
    if not InCombatLockdown() then ClearOverrideBindings(ui) end
    ui:Hide()
end

local function OpenRing(ring)
    if InCombatLockdown() then
        if not warnedCombat then
            warnedCombat = true
            Print("Rings can't open in combat on this beta build (Blizzard's secure snippet compiler is missing).")
        end
        return
    end
    if ui.editing and ui:IsShown() then ui:Hide() end
    Rescan(ring)
    openRing = ring
    commit.armed, cancel.armed = nil, nil
    SetCommitSlot("", nil)
    SetOverrideBindingClick(ui, true, "PAD1", "XanaRingsCommit", "LeftButton")
    SetOverrideBindingClick(ui, true, "PAD2", "XanaRingsCancel", "LeftButton")
    SetOverrideBindingClick(ui, true, "ESCAPE", "XanaRingsCancel", "LeftButton")
    local n = #ring.slots
    for key, dir in pairs(DPAD) do
        SetCommitSlot("-" .. dir.name, ring.slots[IndexForAngle(dir.angle, n)])
        SetOverrideBindingClick(ui, true, key, "XanaRingsCommit", dir.name)
    end
    ShowRing(ring, false)
end

local function ToggleRing(ring)
    if openRing == ring then CloseRing() else CloseRing() OpenRing(ring) end
end

-- "armed" = we saw the key go down while the ring was open. It ignores the stray key-UP
-- that arrives if the macro itself is bound to A / B / the D-pad.
commit:SetScript("PreClick", function(self, _, down) if down then self.armed = true end end)
commit:SetScript("PostClick", function(self, _, down)
    if not down and self.armed then CloseRing() end
end)
cancel:SetScript("OnClick", function(self, _, down)
    if down then self.armed = true elseif self.armed then CloseRing() end
end)

ui:SetScript("OnGamePadStick", function(self, stick, x, y, len)
    if self.editing or not openRing or len < DEADZONE or InCombatLockdown() then return end
    local index = IndexForAngle(math.deg(math.atan2(x, y)), #openRing.slots)
    if index > 0 and index ~= self.selected then
        self.selected = index
        SetCommitSlot("", openRing.slots[index])
        Refresh()
    end
end)

-------------------------------------------------------------------------------
-- Ring storage: SavedVariables + a copy inside each ring's macro
-------------------------------------------------------------------------------
-- Older versions stored 8 fixed slots with gaps; squeeze those into a plain list.
local function Compact(ring)
    local keys, list = {}, {}
    for k in pairs(ring.slots or {}) do
        if type(k) == "number" then keys[#keys + 1] = k end
    end
    table.sort(keys)
    for _, k in ipairs(keys) do list[#list + 1] = ring.slots[k] end
    ring.slots = list
end

-- Entries: "s<spellID>,i<itemID>,...".  Auto rings: "@" followed by their type letters.
local function Serialize(ring)
    local name = ring.name:gsub("[|,\n]", "")
    if ring.auto then return ("%d|%s|@%s"):format(ring.id, name, ring.auto) end
    local parts = {}
    for i, s in ipairs(ring.slots) do
        parts[i] = (s.kind == "spell" and "s" or "i") .. s.id
    end
    return ("%d|%s|%s"):format(ring.id, name, table.concat(parts, ","))
end

local function MacroBody(ring)
    return "/click XanaRingsOpen" .. ring.id .. "\n/xrdata " .. Serialize(ring)
end

-- Rings live in character-specific macros only. General (account) macros fill
-- indexes 1..numAccount with no gaps and character macros come after them, so
-- anything past numAccount is a character macro. The scan end just needs to be
-- beyond the last possible macro index on any client.
local MACRO_SCAN_END = 300

local function CharacterMacros()
    local list = {}
    for i = (GetNumMacros() or 0) + 1, MACRO_SCAN_END do
        local name, _, body = GetMacroInfo(i)
        if name then list[#list + 1] = { index = i, body = body or "" } end
    end
    return list
end

local function FindRingMacro(id)
    local needle, legacy = "/xrdata " .. id .. "|", "/rrdata " .. id .. "|"
    for _, m in ipairs(CharacterMacros()) do
        if m.body:find(needle, 1, true) or m.body:find(legacy, 1, true) then return m.index end
    end
end

local QUESTION_MARK = 134400

local function RingIcon(ring)
    return ring.slots[1] and GetIcon(ring.slots[1]) or QUESTION_MARK
end

-- The macro's icon follows the ring's first entry, unless the player picked their own:
-- anything other than the question mark, the icon we last set, or one of the ring's icons.
local function OwnsIcon(ring, icon)
    if icon == nil or icon == QUESTION_MARK or icon == ring.macroIcon then return true end
    for _, slot in ipairs(ring.slots) do
        if GetIcon(slot) == icon then return true end
    end
    return false
end

local function UpdateMacro(ring)
    if InCombatLockdown() then return end
    local index = FindRingMacro(ring.id)
    if not index then return end
    local _, icon = GetMacroInfo(index)
    local newIcon = OwnsIcon(ring, icon) and RingIcon(ring) or nil
    if newIcon then ring.macroIcon = newIcon end
    EditMacro(index, nil, newIcon, MacroBody(ring))
end

local function CreateRingMacro(ring)
    local icon = RingIcon(ring)
    local ok, index = pcall(CreateMacro, ("XR " .. ring.name):sub(1, 16), icon, MacroBody(ring), true)
    if ok and index and index > 0 then
        ring.macroIcon = icon
        return index
    end
    Print(("Couldn't create the macro for '%s' (are this character's macro slots full?). "
        .. "Free a slot, then run /xrings macro %s"):format(ring.name, ring.name))
end

local function FindRingById(id)
    for index, ring in ipairs(db.rings) do
        if ring.id == id then return ring, index end
    end
end

local function CreateOpener(ring)
    if openers[ring.id] then openers[ring.id].ring = ring return end
    local b = CreateFrame("Button", "XanaRingsOpen" .. ring.id, UIParent)
    b:RegisterForClicks("AnyDown", "AnyUp")
    b.ring = ring
    b:SetScript("OnClick", function(self) if self.ring then ToggleRing(self.ring) end end)
    openers[ring.id] = b
end

-- Fills ring.auto / ring.slots from the data part of a Serialize() string.
local function ApplyRingData(ring, data)
    ring.auto = data:match("^@(%a*)$")
    ring.slots = {}
    for _, field in ipairs(ring.auto and {} or { strsplit(",", data) }) do
        local kind, num = field:match("^([si])(%d+)$")
        if kind then
            ring.slots[#ring.slots + 1] = { kind = kind == "s" and "spell" or "item", id = tonumber(num) }
        end
    end
end

-- Rebuild any ring that exists as a macro but not in the DB.
local function ImportFromMacros()
    if not db then return end
    for _, m in ipairs(CharacterMacros()) do
        local i, body = m.index, m.body
        -- "/rrdata" is the data line written by the addon's old name (RadialRings)
        local id, name, data = body:match("/[xr]rdata (%d+)|([^|]*)|([^\n]*)")
        id = tonumber(id)
        if id and not FindRingById(id) then
            local ring = { id = id, name = name ~= "" and name or ("Ring " .. id) }
            ApplyRingData(ring, data)
            db.rings[#db.rings + 1] = ring
            if id >= db.nextId then db.nextId = id + 1 end
            CreateOpener(ring)
        end
        -- Rewrite old-name macros so they /click the renamed opener button.
        if id and body:find("/rrdata ", 1, true) and not InCombatLockdown() then
            EditMacro(i, nil, nil, MacroBody(FindRingById(id)))
        end
    end
end

-------------------------------------------------------------------------------
-- Editing
-------------------------------------------------------------------------------
local function PutSlot(ring, i, kind, id)
    if InCombatLockdown() then Print("Can't edit rings in combat.") return end
    local n = #ring.slots
    if i > n then i = n + 1 end
    local previous = ring.slots[i]
    ring.slots[i] = { kind = kind, id = id }
    if #MacroBody(ring) > MACRO_LIMIT then
        ring.slots[i] = previous                            -- nil again if this was an append
        Print(("'%s' is full: its %d entries are all that fit in a 255-character macro."):format(ring.name, n))
        return
    end
    UpdateMacro(ring)
    Refresh()
end

local function RemoveSlot(ring, i)
    if InCombatLockdown() then Print("Can't edit rings in combat.") return end
    if not ring.slots[i] then return end
    table.remove(ring.slots, i)                             -- later entries shift down
    UpdateMacro(ring)
    Refresh()
end

local function FindRingByName(name)
    name = strlower(strtrim(name or ""))
    for index, ring in ipairs(db.rings) do
        if strlower(ring.name) == name then return ring, index end
    end
end

local function AutoMacroName(prefix, ringName) return (prefix .. ringName):sub(1, 16) end

local function RenameRing(ring, newName)
    if InCombatLockdown() then Print("Can't rename rings in combat.") return end
    local cleaned = (newName or ""):gsub("[|,\n]", "")       -- characters the data line can't hold
    newName = strtrim(cleaned)                                -- (gsub's 2nd return must not reach strtrim)
    if newName == "" then Print("The new name can't be empty.") return end
    if newName == ring.name then return end
    local clash = FindRingByName(newName)
    if clash and clash ~= ring then Print(("There is already a ring called '%s'."):format(clash.name)) return end

    local oldName = ring.name
    ring.name = newName
    if #MacroBody(ring) > MACRO_LIMIT then
        ring.name = oldName
        Print("That name is too long for this ring: name and entries share one 255-character macro.")
        return
    end

    -- Keep the macro in step. Only retitle it if it still has the name we gave it,
    -- so a macro the player renamed by hand is left alone.
    local index = FindRingMacro(ring.id)
    if index then
        local macroName = GetMacroInfo(index)
        local retitle = (macroName == AutoMacroName("XR ", oldName) or macroName == AutoMacroName("RR ", oldName))
        EditMacro(index, retitle and AutoMacroName("XR ", newName) or nil, nil, MacroBody(ring))
    end
    Print(("Renamed '%s' to '%s'."):format(oldName, newName))
    if ui.ring == ring then Refresh() end
end

local function SetAutoType(ring, key, on)
    if InCombatLockdown() then Print("Can't edit rings in combat.") ui.autoPanel:Sync() return end
    local keys = {}
    for _, t in ipairs(AUTO_TYPES) do
        local has
        if t.key == key then has = on else has = ring.auto:find(t.key, 1, true) end
        if has then keys[#keys + 1] = t.key end
    end
    ring.auto = table.concat(keys)
    Rescan(ring)                                            -- before UpdateMacro, which picks the icon
    UpdateMacro(ring)
    if ui.ring == ring and ui:IsShown() then Refresh() end
end

-- "potion, food & drink, quest" -> "pdq".  Returns nil plus the word it didn't know.
local function ParseAutoTypes(text)
    local keys = ""
    for token in (text or ""):gmatch("[^,]+") do
        token = strlower(strtrim(token))
        if token == "all" then
            for _, t in ipairs(AUTO_TYPES) do keys = keys .. t.key end
        elseif token ~= "none" and token ~= "" then
            local found
            for _, t in ipairs(AUTO_TYPES) do
                if token == strlower(t.label) then found = t end
                for _, word in ipairs(t.words) do
                    if #token >= 3 and word:sub(1, #token) == token then found = t end
                end
            end
            if not found then return nil, token end
            keys = keys .. found.key
        end
    end
    local ordered = {}
    for _, t in ipairs(AUTO_TYPES) do
        if keys:find(t.key, 1, true) then ordered[#ordered + 1] = t.key end
    end
    return table.concat(ordered)
end

function SlotDrop(btn, mouseButton)
    if not ui.editing or ui.ring.auto then return end
    if mouseButton == "RightButton" then RemoveSlot(ui.ring, btn.index) return end
    local kind, a, _, c = GetCursorInfo()
    if kind == "spell" then
        PutSlot(ui.ring, btn.index, "spell", c or a)
        ClearCursor()
    elseif kind == "item" then
        PutSlot(ui.ring, btn.index, "item", a)
        ClearCursor()
    end
end

ui.done = CreateFrame("Button", nil, ui, "UIPanelButtonTemplate")
ui.done:SetSize(80, 22)
ui.done:SetPoint("CENTER", 0, -18)
ui.done:SetText(DONE or "Done")
ui.done:SetScript("OnClick", function() ui:Hide() end)

-- Type checkboxes shown beside the ring while editing an auto ring.
local panel = CreateFrame("Frame", nil, ui)
panel:SetPoint("LEFT", ui, "RIGHT", 8, 0)
panel:SetSize(190, 44 + #AUTO_TYPES * 26)
panel:Hide()
panel.bg = panel:CreateTexture(nil, "BACKGROUND")
panel.bg:SetAllPoints()
panel.bg:SetColorTexture(0, 0, 0, 0.6)
panel.header = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
panel.header:SetPoint("TOPLEFT", 12, -12)
panel.header:SetText("Include from your bags:")
panel.checks = {}
for i, t in ipairs(AUTO_TYPES) do
    local cb = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
    cb:SetSize(24, 24)
    cb:SetPoint("TOPLEFT", 10, -32 - (i - 1) * 26)
    cb.label = cb:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    cb.label:SetPoint("LEFT", cb, "RIGHT", 4, 0)
    cb.label:SetText(t.label)
    cb.autoType = t
    cb:SetScript("OnClick", function(self) SetAutoType(ui.ring, self.autoType.key, self:GetChecked()) end)
    panel.checks[i] = cb
end
function panel:Sync()
    local auto = ui.ring and ui.ring.auto or ""
    for _, cb in ipairs(self.checks) do cb:SetChecked(auto:find(cb.autoType.key, 1, true) ~= nil) end
end
ui.autoPanel = panel


-------------------------------------------------------------------------------
-- Macros
-------------------------------------------------------------------------------
local PLACE_HINT = "Drag it from the macro window (/macro, the tab with your character's name) onto an action bar."

-- Rings get their macro when created; this recreates a lost one or resets its icon.
local function MakeMacro(ring)
    if InCombatLockdown() then Print("Can't create macros in combat.") return end
    Rescan(ring)
    local index = FindRingMacro(ring.id)
    if index then
        ring.macroIcon = RingIcon(ring)
        EditMacro(index, nil, ring.macroIcon, MacroBody(ring))
        Print(("Refreshed the macro for '%s'."):format(ring.name))
    elseif CreateRingMacro(ring) then
        Print(("Created the macro for '%s'. %s"):format(ring.name, PLACE_HINT))
    end
end

-- Characters a ring name can't contain (the macro data line uses them as separators).
local function CleanName(name)
    return strtrim(((name or ""):gsub("[|,\n]", "")))      -- extra parens drop gsub's count
end

-- auto: nil for a normal ring, a string of type letters for an auto ring.
local function AddRing(name, auto)
    local ring = { id = db.nextId, name = name, slots = {}, auto = auto }
    db.nextId = db.nextId + 1
    db.rings[#db.rings + 1] = ring
    CreateOpener(ring)
    return ring
end

-------------------------------------------------------------------------------
-- Export / import strings: "XR1:" + base64 of one "name|data" line per ring.
-- Base64 keeps "|" out of the edit box, where WoW would read it as an escape code.
-------------------------------------------------------------------------------
local EXPORT_PREFIX = "XR1:"
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local function Base64Encode(s)
    local out = {}
    for i = 1, #s, 3 do
        local a, b, c = s:byte(i, i + 2)
        local n = a * 65536 + (b or 0) * 256 + (c or 0)
        local d1, d2 = math.floor(n / 262144) % 64, math.floor(n / 4096) % 64
        local d3, d4 = math.floor(n / 64) % 64, n % 64
        out[#out + 1] = B64:sub(d1 + 1, d1 + 1) .. B64:sub(d2 + 1, d2 + 1)
            .. (b and B64:sub(d3 + 1, d3 + 1) or "=") .. (c and B64:sub(d4 + 1, d4 + 1) or "=")
    end
    return table.concat(out)
end

-- Returns nil for anything that isn't valid base64.
local function Base64Decode(s)
    s = s:gsub("%s", "")
    if #s % 4 ~= 0 then return nil end
    local out = {}
    for i = 1, #s, 4 do
        local n, pad = 0, 0
        for j = i, i + 3 do
            local ch = s:sub(j, j)
            local v = B64:find(ch, 1, true)
            if ch == "=" and j >= i + 2 then
                pad, n = pad + 1, n * 64
            elseif v and pad == 0 then
                n = n * 64 + v - 1
            else
                return nil
            end
        end
        out[#out + 1] = string.char(math.floor(n / 65536) % 256)
            .. (pad < 2 and string.char(math.floor(n / 256) % 256) or "")
            .. (pad < 1 and string.char(n % 256) or "")
    end
    return table.concat(out)
end

local function ExportString(rings)
    local lines = {}
    for i, ring in ipairs(rings) do lines[i] = Serialize(ring):match("^%d+|(.*)$") end
    return EXPORT_PREFIX .. Base64Encode(table.concat(lines, "\n"))
end

local function KnowsSpell(id)
    if IsPlayerSpell then return IsPlayerSpell(id) end
    if IsSpellKnown then return IsSpellKnown(id) end
    return true
end

-- Rings whose name already exists here are overwritten; the rest are created.
-- Returns true if the string was valid.
local function ImportRings(text)
    if InCombatLockdown() then Print("Can't import rings in combat.") return false end
    text = strtrim(text or "")
    local payload = text:sub(1, #EXPORT_PREFIX) == EXPORT_PREFIX and Base64Decode(text:sub(#EXPORT_PREFIX + 1))
    if not payload or payload == "" then Print("That isn't a XanaRings export string.") return false end

    CloseRing()
    ui:Hide()
    local added, replaced, unknownSpells = 0, 0, 0
    for line in payload:gmatch("[^\n]+") do
        local name, data = line:match("^([^|]*)|(.*)$")
        name = CleanName(name)
        if name ~= "" then
            local ring = FindRingByName(name)
            local isNew = not ring
            ring = ring or AddRing(name)
            ApplyRingData(ring, data)
            -- Spells this character doesn't have would only be dead slots.
            local kept = {}
            for _, slot in ipairs(ring.slots) do
                if slot.kind ~= "spell" or KnowsSpell(slot.id) then
                    kept[#kept + 1] = slot
                else
                    unknownSpells = unknownSpells + 1
                end
            end
            ring.slots = kept
            -- This character's ring ID may be longer than the exporter's.
            while #MacroBody(ring) > MACRO_LIMIT and #ring.slots > 0 do ring.slots[#ring.slots] = nil end
            Rescan(ring)
            if FindRingMacro(ring.id) then UpdateMacro(ring) else CreateRingMacro(ring) end
            if isNew then added = added + 1 else replaced = replaced + 1 end
        end
    end
    Print(("Imported %d new and %d existing ring(s)."):format(added, replaced))
    if unknownSpells > 0 then
        Print(("Left out %d spell(s) this character doesn't know."):format(unknownSpells))
    end
    if added > 0 then Print("New rings' macros are in /macro, on the tab with your character's name.") end
    return true
end

-- Window with one text box: shows an export string to copy, or takes one to import.
local dialog = CreateFrame("Frame", "XanaRingsDialog", UIParent)
dialog:SetSize(480, 130)
dialog:SetPoint("CENTER", 0, 150)
dialog:SetFrameStrata("FULLSCREEN_DIALOG")
dialog:EnableMouse(true)
dialog:Hide()
tinsert(UISpecialFrames, "XanaRingsDialog")                 -- Escape closes it
dialog.bg = dialog:CreateTexture(nil, "BACKGROUND")
dialog.bg:SetAllPoints()
dialog.bg:SetColorTexture(0, 0, 0, 0.85)
dialog.title = dialog:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
dialog.title:SetPoint("TOP", 0, -12)
dialog.hint = dialog:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
dialog.hint:SetPoint("TOP", 0, -36)

dialog.box = CreateFrame("EditBox", nil, dialog, "InputBoxTemplate")
dialog.box:SetSize(440, 24)
dialog.box:SetPoint("TOP", 0, -56)
dialog.box:SetAutoFocus(false)
dialog.box:SetMaxLetters(0)

dialog.action = CreateFrame("Button", nil, dialog, "UIPanelButtonTemplate")
dialog.action:SetSize(100, 22)
dialog.action:SetPoint("BOTTOM", -56, 14)
dialog.action:SetText("Import")
dialog.action:SetScript("OnClick", function()
    if ImportRings(dialog.box:GetText()) then dialog:Hide() end
end)

dialog.close = CreateFrame("Button", nil, dialog, "UIPanelButtonTemplate")
dialog.close:SetSize(100, 22)
dialog.close:SetText(CLOSE or "Close")
dialog.close:SetScript("OnClick", function() dialog:Hide() end)

dialog.box:SetScript("OnEscapePressed", function() dialog:Hide() end)
dialog.box:SetScript("OnEnterPressed", function()
    if dialog.mode == "import" then dialog.action:Click() end
end)
dialog.box:SetScript("OnTextChanged", function(self, userInput)
    -- An export string stays as it is, whatever gets typed into it.
    if userInput and dialog.mode == "export" then
        self:SetText(dialog.exportText)
        self:HighlightText()
    end
end)

function dialog:Open(mode, title, hint, text)
    self.mode, self.exportText = mode, text
    self.title:SetText(title)
    self.hint:SetText(hint)
    self.action:SetShown(mode == "import")
    self.close:ClearAllPoints()
    self.close:SetPoint("BOTTOM", mode == "import" and 56 or 0, 14)
    self.box:SetText(text or "")
    self:Show()
    self.box:SetFocus()
    self.box:HighlightText()
end

-------------------------------------------------------------------------------
-- Slash commands
-------------------------------------------------------------------------------
local FindRing = FindRingByName

local commands = {}

local function CreateRing(name, auto, usage)
    name = CleanName(name)
    if name == "" then Print(usage) return end
    if FindRing(name) then Print("A ring with that name already exists.") return end
    if InCombatLockdown() then Print("Can't create rings in combat.") return end
    local ring = AddRing(name, auto)
    local what = auto and "auto ring" or "ring"
    if CreateRingMacro(ring) then
        Print(("Created %s '%s' and its macro. %s"):format(what, name, PLACE_HINT))
    else
        Print(("Created %s '%s'."):format(what, name))
    end
    CloseRing()
    ShowRing(ring, true)
end

function commands.new(name) CreateRing(name, nil, "Usage: /xrings new <name>") end
function commands.auto(name) CreateRing(name, "", "Usage: /xrings auto <name>") end

function commands.types(args)
    local name, list = (args or ""):match("^(.-)%s*>%s*(.*)$")
    if list == "" then list = nil end                     -- "types Pots >" just shows the types
    local ring = FindRing(name or args)
    if not ring then Print("Usage: /xrings types <name> > potions, food, quest ...") return end
    if not ring.auto then
        Print(("'%s' is a normal ring. Types only apply to auto rings (/xrings auto <name>)."):format(ring.name))
        return
    end
    if list then
        if InCombatLockdown() then Print("Can't edit rings in combat.") return end
        local keys, bad = ParseAutoTypes(list)
        if not keys then
            local words = {}
            for _, t in ipairs(AUTO_TYPES) do words[#words + 1] = t.words[1] end
            Print(("Unknown type '%s'. Types: %s, all, none"):format(bad, table.concat(words, ", ")))
            return
        end
        ring.auto = keys
        Rescan(ring)                                        -- before UpdateMacro, which picks the icon
        UpdateMacro(ring)
        if ui.ring == ring and ui:IsShown() then
            if ui.editing then ui.autoPanel:Sync() end
            Refresh()
        end
    end
    Print(("'%s' offers: %s"):format(ring.name, AutoLabels(ring.auto)))
end

function commands.edit(name)
    local ring = FindRing(name)
    if not ring then Print("No ring with that name. Try /xrings list") return end
    if InCombatLockdown() then Print("Can't edit rings in combat.") return end
    CloseRing()
    ShowRing(ring, true)
end

function commands.macro(name)
    local ring = FindRing(name)
    if not ring then Print("No ring with that name. Try /xrings list") return end
    MakeMacro(ring)
end

function commands.rename(args)
    local oldName, newName = (args or ""):match("^(.-)%s*>%s*(.+)$")
    if not oldName then Print("Usage: /xrings rename <old name> > <new name>") return end
    local ring = FindRing(oldName)
    if not ring then Print("No ring with that name. Try /xrings list") return end
    RenameRing(ring, newName)
end

function commands.delete(name)
    local ring, index = FindRing(name)
    if not ring then Print("No ring with that name.") return end
    if InCombatLockdown() then Print("Can't delete rings in combat.") return end
    CloseRing()
    if ui.ring == ring then ui:Hide() end
    local macro = FindRingMacro(ring.id)   -- must go too, or the ring re-imports at next login
    if macro then DeleteMacro(macro) end
    if openers[ring.id] then openers[ring.id].ring = nil end
    table.remove(db.rings, index)
    Print(("Deleted '%s' and its macro."):format(ring.name))
end

function commands.export(name)
    local rings, what
    if strtrim(name or "") == "" then
        rings, what = db.rings, "all rings"
        if #rings == 0 then Print("No rings to export yet.") return end
    else
        local ring = FindRing(name)
        if not ring then Print("No ring with that name. Try /xrings list") return end
        rings, what = { ring }, ("'%s'"):format(ring.name)
    end
    dialog:Open("export", "Export " .. what,
        "Press Ctrl+C to copy, then paste it into /xrings import on another character.", ExportString(rings))
end

function commands.import()
    if InCombatLockdown() then Print("Can't import rings in combat.") return end
    dialog:Open("import", "Import rings",
        "Paste an export string with Ctrl+V. Rings with the same name are overwritten.")
end

function commands.list()
    if #db.rings == 0 then Print("No rings yet. Create one with /xrings new <name>") return end
    for _, ring in ipairs(db.rings) do
        local contents = ring.auto and ("auto: " .. AutoLabels(ring.auto)) or (#ring.slots .. " entries")
        Print(("%s  (%s%s)"):format(ring.name, contents,
            FindRingMacro(ring.id) and "" or ", |cffff6666no macro - won't survive a relog, run /xrings macro " .. ring.name .. "|r"))
    end
end

SLASH_XANARINGS1 = "/xrings"
SLASH_XANARINGS2 = "/xanarings"
SlashCmdList.XANARINGS = function(msg)
    local cmd, rest = strtrim(msg or ""):match("^(%S*)%s*(.-)$")
    local fn = commands[strlower(cmd or "")]
    if fn then
        fn(rest)
    else
        Print("Commands: new <name>, auto <name>, edit <name>, types <name> > <types>, "
            .. "rename <old> > <new>, macro <name>, delete <name>, list, export [name], import")
    end
end

-- Data carrier line inside ring macros. Deliberately does nothing.
SLASH_XANARINGSDATA1 = "/xrdata"
SLASH_XANARINGSDATA2 = "/rrdata"
SlashCmdList.XANARINGSDATA = function() end

-------------------------------------------------------------------------------
-- Events
-------------------------------------------------------------------------------
local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:RegisterEvent("PLAYER_LOGIN")
loader:RegisterEvent("UPDATE_MACROS")
loader:RegisterEvent("PLAYER_REGEN_DISABLED")
loader:RegisterEvent("BAG_UPDATE_DELAYED")
loader:SetScript("OnEvent", function(self, event, name)
    if event == "ADDON_LOADED" then
        if name ~= ADDON then return end
        XanaRingsDB = XanaRingsDB or {}
        db = XanaRingsDB
        db.rings  = db.rings or {}
        db.nextId = db.nextId or 1
        for _, ring in ipairs(db.rings) do
            Compact(ring)
            CreateOpener(ring)
        end
    elseif event == "PLAYER_REGEN_DISABLED" then
        -- Fires just before combat lockdown: last chance to release our bindings.
        CloseRing()
    elseif event == "BAG_UPDATE_DELAYED" then
        -- Keep an open auto ring editor's preview in step with the bags.
        if ui:IsShown() and ui.editing and ui.ring and ui.ring.auto then
            Rescan(ui.ring)
            Refresh()
        end
    else
        ImportFromMacros()
    end
end)
