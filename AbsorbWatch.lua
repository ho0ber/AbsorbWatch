-- AbsorbWatch: show total damage absorbs on the player health bar and (optionally) raid / raid-style party frames.
--
-- Secret-value rules (Midnight/Forever): in combat, UnitGetTotalAbsorbs / UnitHealthMax can return secret values.
-- We never compare or do math on them -- we only hand them to C-side sinks (StatusBar:SetValue/SetMinMaxValues,
-- FontString:SetText, AbbreviateNumbers). Everything else (hide-at-zero, excess-only) is anchoring, clipping and
-- StatusBar ranges. Never read frame sizes either: compact frame widths can be secret.

local ADDON = ...
local UnitGetTotalAbsorbs, UnitHealthMax = UnitGetTotalAbsorbs, UnitHealthMax

local STYLE_NONE, STYLE_OVERLAY, STYLE_REVERSE = 0, 1, 2

local DEFAULTS = {
  barStyle = STYLE_REVERSE, -- 0 none, 1 overlay (from left), 2 reverse (from right)
  excess = true,            -- only show absorb beyond what Blizzard's own absorb bar can show
  edge = true,              -- bright line at the leading edge of the bar
  text = true,              -- number to the right of the player health bar
  raid = true,              -- also draw bars on raid frames and raid-style party frames
}

local db
local playerDisplay
local raidDisplays = setmetatable({}, { __mode = "k" }) -- [compact unit frame] = display (kept off Blizzard's tables)
local text -- { frame, fs, gate }

------------------------------------------------------------------------------------------------
-- Widget construction
------------------------------------------------------------------------------------------------
local TEX = "Interface\\TargetingFrame\\UI-StatusBar"

local function FindPlayerHealthBar()
  if PlayerFrame then
    if PlayerFrame.healthbar then return PlayerFrame.healthbar end
    local c = PlayerFrame.PlayerFrameContent
    local hb = c and c.PlayerFrameContentMain and c.PlayerFrameContentMain.HealthBarsContainer
    if hb and (hb.HealthBar or hb.healthBar) then return hb.HealthBar or hb.healthBar end
  end
  return _G.PlayerFrameHealthBar
end

-- A frame/clip that exactly covers a StatusBar's fill texture: children are only visible inside the fill.
local function MakeFillClip(parent, fill)
  local clip = CreateFrame("Frame", nil, parent)
  clip:SetPoint("TOPLEFT", fill, "TOPLEFT")
  clip:SetPoint("BOTTOMRIGHT", fill, "BOTTOMRIGHT")
  clip:SetClipsChildren(true)
  return clip
end

local function MakeBar(parent, reverse)
  local sb = CreateFrame("StatusBar", nil, parent)
  sb:SetStatusBarTexture(TEX)
  sb:SetStatusBarColor(0.7, 0.9, 1, 0.55)
  sb:SetMinMaxValues(0, 1)
  sb:SetValue(0)
  sb:SetReverseFill(reverse)

  -- Edge line at the leading edge of the fill, clipped to the fill so it vanishes at zero absorb.
  local fill = sb:GetStatusBarTexture()
  local edgeClip = MakeFillClip(sb, fill)
  local edge = edgeClip:CreateTexture(nil, "OVERLAY")
  edge:SetColorTexture(1, 1, 1, 0.9)
  edge:SetWidth(2)
  local side = reverse and "LEFT" or "RIGHT"
  edge:SetPoint("TOP" .. side, fill, "TOP" .. side)
  edge:SetPoint("BOTTOM" .. side, fill, "BOTTOM" .. side)

  return { bar = sb, edge = edgeClip }
end

-- A "display" = overlay + reverse bars attached to one health bar, for one unit.
--   getUnit: returns the unit token to read (or nil for an empty frame)
--   levelOffset: frame levels above the health bar
local function CreateDisplay(hb, getUnit, levelOffset)
  local d = { hb = hb, getUnit = getUnit, level = levelOffset, bars = {} }
  d.bars[STYLE_OVERLAY] = MakeBar(hb, false)
  d.bars[STYLE_REVERSE] = MakeBar(hb, true)
  d.fill = hb:GetStatusBarTexture()
  return d
end

local canExcess = UnitHealthMissing ~= nil

-- Excess-only: Blizzard's native absorb fills the missing-health area, so the overflow is (absorb - missing).
-- We lay the bar over just the *current health* part of the health bar (width = W*health/max) and give it the
-- range [missing, max]. Its fill is then W*(health/max) * (absorb-missing)/(max-missing) = W*(absorb-missing)/max
-- pixels -- exactly the overflow -- and clamps to 0 when absorb <= missing. No math on secrets, no widths.
local function LayoutDisplay(d)
  local target = (db.excess and canExcess) and d.fill or d.hb
  for _, b in pairs(d.bars) do
    b.bar:ClearAllPoints()
    b.bar:SetAllPoints(target)
    b.bar:SetFrameLevel(d.hb:GetFrameLevel() + d.level)
  end
end

local function ShowDisplay(d, enabled)
  for style, b in pairs(d.bars) do
    b.bar:SetShown(enabled and db.barStyle == style)
    b.edge:SetShown(db.edge and true or false)
  end
end

local function UpdateDisplay(d)
  local b = d.bars[db.barStyle]
  if not b or not b.bar:IsShown() then return end
  local unit = d.getUnit()
  if not unit then b.bar:SetValue(0); return end
  if db.excess and canExcess then
    b.bar:SetMinMaxValues(UnitHealthMissing(unit), UnitHealthMax(unit))
  else
    b.bar:SetMinMaxValues(0, UnitHealthMax(unit))
  end
  b.bar:SetValue(UnitGetTotalAbsorbs(unit) or 0)
end

-- Hide-at-zero without comparing a secret: an invisible 0..1 StatusBar gets the absorb as its value, so its
-- fill texture is 0 px wide at 0 absorb and full width at >= 1. The text lives in a clip over that fill.
local function MakeGatedText(parent, font, point)
  local gate = CreateFrame("StatusBar", nil, parent)
  gate:SetAllPoints(parent)
  gate:SetStatusBarTexture(TEX)
  gate:SetStatusBarColor(0, 0, 0, 0)
  gate:SetMinMaxValues(0, 1)
  gate:SetValue(0)
  local clip = MakeFillClip(gate, gate:GetStatusBarTexture())
  local fs = clip:CreateFontString(nil, "OVERLAY", font)
  fs:SetPoint(point, parent, point, 0, 0)
  return fs, gate
end

------------------------------------------------------------------------------------------------
-- Raid / raid-style party frames
------------------------------------------------------------------------------------------------
local function TrackCompactFrame(frame)
  if not db or not db.raid or not frame or raidDisplays[frame] then return end
  if frame.IsForbidden and frame:IsForbidden() then return end -- nameplates etc.
  local name = frame.GetName and frame:GetName()
  if not name or not (name:find("^CompactRaid") or name:find("^CompactParty")) or name:find("Pet") then return end
  local hb = frame.healthBar
  if not hb or not hb.GetStatusBarTexture then return end

  local d = CreateDisplay(hb, function() return frame.displayedUnit or frame.unit end, 1)
  raidDisplays[frame] = d
  LayoutDisplay(d)
  ShowDisplay(d, true)
  UpdateDisplay(d)
end

local function ScanCompactFrames()
  if not db or not db.raid then return end
  for i = 1, 5 do TrackCompactFrame(_G["CompactPartyFrameMember" .. i]) end
  for i = 1, 40 do TrackCompactFrame(_G["CompactRaidFrame" .. i]) end
  for g = 1, 8 do
    for i = 1, 5 do TrackCompactFrame(_G["CompactRaidGroup" .. g .. "Member" .. i]) end
  end
end

------------------------------------------------------------------------------------------------
-- Update / refresh
------------------------------------------------------------------------------------------------
local function SetTextSafe(fs, v)
  local ok, s = pcall(AbbreviateNumbers, v)
  if ok and pcall(fs.SetText, fs, s) then return end -- don't test s: comparing a secret would error
  if pcall(fs.SetText, fs, v) then return end
  fs:SetText("?")
end

local function Update()
  if not db then return end
  if playerDisplay then UpdateDisplay(playerDisplay) end
  for _, d in pairs(raidDisplays) do UpdateDisplay(d) end
  if db.text then
    local absorb = UnitGetTotalAbsorbs("player") or 0
    SetTextSafe(text.fs, absorb)
    if not pcall(text.gate.SetValue, text.gate, absorb) then text.gate:SetValue(1) end
  end
end

local function Refresh()
  if not db then return end
  ScanCompactFrames()
  if playerDisplay then
    LayoutDisplay(playerDisplay)
    ShowDisplay(playerDisplay, true)
  end
  for _, d in pairs(raidDisplays) do
    LayoutDisplay(d)
    ShowDisplay(d, db.raid)
  end
  text.frame:SetShown(db.text and true or false)
  Update()
end

local function Build()
  local hb = FindPlayerHealthBar()
  if hb and hb.GetStatusBarTexture then
    playerDisplay = CreateDisplay(hb, function() return "player" end, 5)
  end

  local host = hb or UIParent
  local tf = CreateFrame("Frame", nil, host)
  tf:SetSize(100, 20)
  tf:SetFrameLevel(host:GetFrameLevel() + 7)
  if hb then
    tf:SetPoint("LEFT", hb, "RIGHT", 6, 0)
  else
    tf:SetPoint("CENTER", UIParent, "CENTER", 0, -135)
  end
  local fs, gate = MakeGatedText(tf, "GameFontNormal", "LEFT")
  fs:SetTextColor(1, 0.85, 0.3)
  text = { frame = tf, fs = fs, gate = gate }

  -- Pick up compact frames as Blizzard assigns units to them (covers frames created later, e.g. joining a raid).
  if CompactUnitFrame_SetUnit then
    hooksecurefunc("CompactUnitFrame_SetUnit", function(frame) TrackCompactFrame(frame) end)
  end
end

------------------------------------------------------------------------------------------------
-- Settings panel (Esc > Options > AddOns > AbsorbWatch)
------------------------------------------------------------------------------------------------
local function RegisterSettings()
  if not (Settings and Settings.RegisterVerticalLayoutCategory) then return end
  local category = Settings.RegisterVerticalLayoutCategory("AbsorbWatch")

  local function Add(key, name, tooltip, options)
    local setting = Settings.RegisterAddOnSetting(category, "AbsorbWatch_" .. key, key, AbsorbWatchDB,
      type(DEFAULTS[key]), name, DEFAULTS[key])
    setting:SetValueChangedCallback(Refresh)
    if options then
      Settings.CreateDropdown(category, setting, options, tooltip)
    else
      Settings.CreateCheckbox(category, setting, tooltip)
    end
  end

  Add("barStyle", "Health bar display", "How absorbs are drawn on top of health bars.", function()
    local c = Settings.CreateControlTextContainer()
    c:Add(STYLE_REVERSE, "Fill from right")
    c:Add(STYLE_OVERLAY, "Fill from left")
    c:Add(STYLE_NONE, "Off")
    return c:GetData()
  end)
  Add("excess", "Only show absorb beyond Blizzard's bar",
    "Blizzard's absorb bar can only fill missing health. When enabled, only the part of the absorb that doesn't fit there is drawn.")
  Add("edge", "Show edge line", "Draw a bright line at the leading edge of the absorb fill.")
  Add("raid", "Show on raid frames",
    "Also draw absorbs on raid frames and raid-style party frames.")
  Add("text", "Show absorb amount", "Show your total absorb as a number to the right of your health bar. Hidden when you have no absorb.")

  Settings.RegisterAddOnCategory(category)
end

------------------------------------------------------------------------------------------------
-- Events
------------------------------------------------------------------------------------------------
local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:SetScript("OnEvent", function(self, event, arg1)
  if event == "ADDON_LOADED" then
    if arg1 ~= ADDON then return end
    AbsorbWatchDB = AbsorbWatchDB or {}
    db = AbsorbWatchDB
    for k, v in pairs(DEFAULTS) do if db[k] == nil then db[k] = v end end

    Build()
    RegisterSettings()
    self:RegisterEvent("PLAYER_ENTERING_WORLD")
    self:RegisterEvent("GROUP_ROSTER_UPDATE")
    self:RegisterEvent("UNIT_ABSORB_AMOUNT_CHANGED")
    self:RegisterEvent("UNIT_MAXHEALTH")
    self:RegisterEvent("UNIT_HEALTH") -- excess-only range depends on missing health
    -- Safety net in case an event is missed (or a frame's unit changes without one).
    C_Timer.NewTicker(0.25, Update)
    Refresh()
    return
  end
  if event == "PLAYER_ENTERING_WORLD" or event == "GROUP_ROSTER_UPDATE" then
    Refresh()
  else
    Update()
  end
end)
