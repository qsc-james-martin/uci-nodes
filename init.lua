--[[
  UCINodes
  Three layers, each built on the one above it:
    Target        - normalizes "the thing being changed" (a Layer, or a plain Control) behind :Set(value)
    Node          - internal; a trigger (optional button) plus onSelect/onDeselect lists of {target, value}
    NavigationBar - public; a group of Nodes with enforced exclusivity and parent/child nesting
  See README.md for usage examples and the reasoning behind this layering.
]]

local UCINodes = {}

-- Uci.SetLayerVisibility's first arg is the page name, not a UCI/instance
-- identifier - there's no way to detect it from inside the script. Set this
-- as a simple fallback, or set page on nav bars, popups, or entries.
UCINodes.DefaultPage = nil

-- set true to print every Target:Set / Node select-deselect / NavigationBar
-- show-hide call to the Lua Debugger console
UCINodes.Debug = false

local function dprint(...)
  if UCINodes.Debug then print("[UCINodes]", ...) end
end

local function getControlState(control)
  if not control then return false end
  if control.Boolean ~= nil then return control.Boolean end
  return control.Value
end

local function getPage(spec)
  if not spec then return nil end
  return spec.page
end

local function describeField(owner, field)
  if owner then return owner .. "." .. field end
  return field
end

local function normalizeLayers(layers, owner)
  if layers == nil then
    return {}
  elseif type(layers) == "string" then
    return { layers }
  elseif type(layers) ~= "table" then
    error("[UCINodes] " .. describeField(owner, "layers") .. " must be a layer name string or a table of layer name strings.", 3)
  end

  for index, layerName in ipairs(layers) do
    if type(layerName) ~= "string" then
      error("[UCINodes] " .. describeField(owner, "layers") .. " item " .. tostring(index) .. " must be a string layer name.", 3)
    end
  end
  return layers
end

local function requireSpec(spec, owner)
  if type(spec) ~= "table" then
    error("[UCINodes] " .. owner .. " expects a table of options, for example " .. owner .. "{ ... }.", 3)
  end
end

-- normalizes a spec.transition value into (onTransition, offTransition):
-- nil -> (nil, nil); a string -> same transition for both; a table -> either
-- {on = ..., off = ...} or {onTransition, offTransition} positionally
local function normalizeTransition(transition)
  if transition == nil then
    return nil, nil
  elseif type(transition) == "string" then
    return transition, transition
  else
    return transition.on or transition[1], transition.off or transition[2]
  end
end

--------------------------------------------------------------------------------
-- Target: normalizes "the thing being changed" behind a common :Set(value)
--------------------------------------------------------------------------------

local Target = {}
Target.__index = Target

-- a named layer on a UCI page
function Target.Layer(layerName, page)
  if type(layerName) ~= "string" then
    error("[UCINodes] Target.Layer requires a string layer name.", 2)
  end
  return setmetatable({ kind = "layer", layer = layerName, page = page }, Target)
end

-- a plain Controls.X entry; works for Boolean or Value-style controls
function Target.Control(control)
  return setmetatable({ kind = "control", control = control }, Target)
end

function Target:Set(value, transition, page)
  if self.kind == "layer" then
    local resolvedPage = page or self.page or UCINodes.DefaultPage
    if type(resolvedPage) ~= "string" or resolvedPage == "" then
      error("[UCINodes] No UCI page is set for layer '" .. tostring(self.layer) .. "'. Set UCINodes.DefaultPage = 'Page 1', or set page = 'Page 1' on the NavigationBar, Popup, AddEntry, or Target.Layer that owns this layer.", 2)
    end
    dprint("Target.Layer", resolvedPage, self.layer, "=", value, transition)
    -- verify this signature against your Q-Sys version
    Uci.SetLayerVisibility(resolvedPage, self.layer, value, transition)
  elseif self.kind == "control" then
    dprint("Target.Control", self.control, "=", value)
    if self.control.Boolean ~= nil then
      self.control.Boolean = value
    else
      self.control.Value = value
    end
  end
end


--------------------------------------------------------------------------------
-- Node (internal): trigger -> onSelect/onDeselect Target actions.
-- Kept private for v1; NavigationBar is the only public consumer.
--------------------------------------------------------------------------------

local Node = {}
Node.__index = Node

-- spec.button is optional: omit it to drive the node imperatively (arbitrary
-- conditions, timers, etc.) via node:Select()/node:Deselect()/node:Toggle().
-- spec.onTrigger(node, pressed) lets a caller (e.g. NavigationBar) decide what
-- a button press/release means, instead of Node always just toggling itself.
function Node.New(spec)
  local self = setmetatable({}, Node)
  self.onSelect = spec.onSelect or {}
  self.onDeselect = spec.onDeselect or {}
  self.isSelected = false
  self.button = spec.button
  self.onTrigger = spec.onTrigger or function(node, pressed)
    if pressed then node:Toggle() end
  end
  self._isUpdating = false
  self._ignoreControlValue = nil

  if self.button then
    -- fold the button's own visual state into the action lists, so "selected"
    -- styling is just a normal action instead of a special case
    table.insert(self.onSelect, { target = Target.Control(self.button), value = true })
    table.insert(self.onDeselect, { target = Target.Control(self.button), value = false })

    self.button.EventHandler = function(ctl)
      if self._isUpdating then return end -- ignore our own programmatic writes below
      local value = getControlState(ctl)
      if self._ignoreControlValue ~= nil and value == self._ignoreControlValue then
        self._ignoreControlValue = nil
        return
      end
      self.onTrigger(self, value)
    end
  end

  return self
end

local function applyActions(node, actions)
  node._isUpdating = true
  for _, action in ipairs(actions) do
    if action.target.kind == "control" then
      node._ignoreControlValue = action.value
    end
    action.target:Set(action.value, action.transition, action.page)
  end
  node._isUpdating = false
end

local function applyLayerActions(node, actions)
  for _, action in ipairs(actions) do
    if action.target.kind == "layer" then
      action.target:Set(action.value, action.transition, action.page)
    end
  end
end

local function applyControlActions(node, actions)
  node._isUpdating = true
  for _, action in ipairs(actions) do
    if action.target.kind == "control" then
      node._ignoreControlValue = action.value
      action.target:Set(action.value, action.transition, action.page)
    end
  end
  node._isUpdating = false
end

function Node:Select()
  dprint("Node:Select", self.button)
  self.isSelected = true
  applyActions(self, self.onSelect)
end

function Node:Deselect()
  dprint("Node:Deselect", self.button)
  self.isSelected = false
  applyActions(self, self.onDeselect)
end

function Node:Toggle()
  if self.isSelected then self:Deselect() else self:Select() end
end

--------------------------------------------------------------------------------
-- NavigationBar (public): mutually exclusive Nodes + parent/child nesting.
-- Delegates all actual state changes to Node/Target - no direct Uci calls here.
--------------------------------------------------------------------------------

local NavigationBar = {}
NavigationBar.__index = NavigationBar

-- opts.name (optional, dprint label only), opts.allowButtonOff (bool, default
-- false): if false, clicking the already-selected entry's button re-asserts
-- it as selected instead of letting the bar end up with nothing selected;
-- if true, that click deselects it. opts.transition (string, or
-- {on=..., off=...}/{onTransition, offTransition}, optional): the
-- Uci.SetLayerVisibility transition used for every entry in this bar; this
-- field is read fresh on every Select/Deselect, so it can be changed anytime
-- via bar.transition = ... after New(), not just at construction.
function NavigationBar.New(opts)
  opts = opts or {}
  local commonOnSelect, commonOnDeselect = {}, {}
  for _, layerName in ipairs(normalizeLayers(opts.commonLayers, "NavigationBar.New")) do
    table.insert(commonOnSelect, { target = Target.Layer(layerName), value = true })
    table.insert(commonOnDeselect, { target = Target.Layer(layerName), value = false })
  end
  local self = setmetatable({
    name = opts.name,
    entries = {},
    selectedIndex = nil,
    lastSelectedIndex = nil,
    defaultIndex = nil,
    parentEntry = nil, -- set when this bar is attached as another bar's child
    allowButtonOff = opts.allowButtonOff or false,
    transition = opts.transition,
    page = getPage(opts),
    _inheritedPage = nil,
  }, NavigationBar)
  self.commonNode = Node.New{ onSelect = commonOnSelect, onDeselect = commonOnDeselect }

  for _, entry in ipairs(opts.entries or {}) do
    self:AddEntry(entry)
  end

  return self
end

-- spec.button (required), spec.layers (string or list of strings),
-- spec.default (bool, optional), spec.child (NavigationBar or Popup, optional),
-- spec.transition (string, or {on=..., off=...}/{onTransition, offTransition}, optional),
-- spec.page (string, optional)
function NavigationBar:AddEntry(spec)
  requireSpec(spec, "NavigationBar:AddEntry")
  if not spec.button then
    error("[UCINodes] NavigationBar:AddEntry requires button = Controls.YourButton.", 2)
  end

  local layers = normalizeLayers(spec.layers, "NavigationBar:AddEntry")

  local onSelect, onDeselect = {}, {}
  for _, layerName in ipairs(layers) do
    table.insert(onSelect, { target = Target.Layer(layerName), value = true })
    table.insert(onDeselect, { target = Target.Layer(layerName), value = false })
  end

  local index = #self.entries + 1
  local entry = { child = spec.child, transition = spec.transition, page = getPage(spec) }
  entry.node = Node.New{
    button = spec.button,
    onSelect = onSelect,
    onDeselect = onDeselect,
    onTrigger = function(_, pressed)
      if pressed then
        self:Select(index)
      elseif self.allowButtonOff and self.selectedIndex == index then
        self:Deselect(index)
      else
        self:Select(index) -- re-assert: the button toggled itself off, but this bar doesn't allow that
      end
    end,
  }
  table.insert(self.entries, entry)

  if spec.child then
    spec.child.parentEntry = entry
    if spec.child._inheritPage then
      spec.child:_inheritPage(self:_resolvePage(entry))
    end
  end
  if spec.default then
    self.defaultIndex = index
  end

  return entry
end

-- re-reads entry.transition/bar.transition and stamps it onto entry's action
-- lists, so changing either field takes effect immediately
function NavigationBar:_resolveTransition(entry, inheritedTransition)
  if inheritedTransition ~= nil then return inheritedTransition end
  return entry.transition or self.transition
end

function NavigationBar:_resolvePage(entry, inheritedPage)
  return entry.page or self.page or inheritedPage or self._inheritedPage or UCINodes.DefaultPage
end

function NavigationBar:_inheritPage(page)
  if self.page == nil then
    self._inheritedPage = page
  end
  for _, entry in ipairs(self.entries) do
    local childPage = entry.page or self.page or self._inheritedPage or page
    if entry.child and entry.child._inheritPage then
      entry.child:_inheritPage(childPage)
    end
  end
end

function NavigationBar:_showChild(entry, transition, page)
  if not entry.child then return end
  if entry.child._isPopup then
    entry.child:SetParentVisible(true, transition, page)
  else
    entry.child:Show(transition, page)
  end
end

function NavigationBar:_hideChild(entry, transition, page)
  if not entry.child then return end
  if entry.child._isPopup then
    entry.child:SetParentVisible(false, transition, page)
  else
    entry.child:Hide(transition, page)
  end
end

function NavigationBar:_resetChild(entry, transition, page)
  if not entry.child then return end
  if entry.child._isPopup then
    entry.child:SetParentVisible(false, transition, page)
  else
    entry.child:Reset(transition, page)
  end
end

function NavigationBar:_applyPage(entry, inheritedPage)
  local page = self:_resolvePage(entry, inheritedPage)
  for _, action in ipairs(entry.node.onSelect) do
    action.page = page
  end
  for _, action in ipairs(entry.node.onDeselect) do
    action.page = page
  end
  return page
end

function NavigationBar:_applyTransition(entry, inheritedTransition, inheritedPage)
  self:_applyPage(entry, inheritedPage)
  local onTransition, offTransition = normalizeTransition(self:_resolveTransition(entry, inheritedTransition))
  for _, action in ipairs(entry.node.onSelect) do
    action.transition = onTransition
  end
  for _, action in ipairs(entry.node.onDeselect) do
    action.transition = offTransition
  end
  return onTransition, offTransition
end

function NavigationBar:_applyCommon(inheritedTransition, inheritedPage)
  local page = self:_resolvePage({ }, inheritedPage)
  local onTransition, offTransition = normalizeTransition(inheritedTransition or self.transition)
  for _, action in ipairs(self.commonNode.onSelect) do
    action.page = page
    action.transition = onTransition
  end
  for _, action in ipairs(self.commonNode.onDeselect) do
    action.page = page
    action.transition = offTransition
  end
end

function NavigationBar:Select(index, inheritedTransition, inheritedPage)
  local entry = self.entries[index]
  assert(entry, "NavigationBar:Select - no entry at index " .. tostring(index))
  dprint("NavigationBar:Select", self.name, index)
  local childTransition = self:_resolveTransition(entry, inheritedTransition)
  local childPage = self:_applyPage(entry, inheritedPage)
  self:_applyTransition(entry, inheritedTransition, inheritedPage)

  if self.selectedIndex == index then
    entry.node:Select() -- re-assert visual/layer state (e.g. after a click toggled the button off)
    return
  end

  local previous = self.selectedIndex and self.entries[self.selectedIndex]
  if previous then
    local previousTransition = self:_resolveTransition(previous, inheritedTransition)
    local previousPage = self:_applyPage(previous, inheritedPage)
    self:_applyTransition(previous, inheritedTransition, inheritedPage)
    previous.node:Deselect()
    self:_hideChild(previous, previousTransition, previousPage)
  else
    for otherIndex, other in ipairs(self.entries) do
      if otherIndex ~= index then
        local otherTransition = self:_resolveTransition(other, inheritedTransition)
        local otherPage = self:_applyPage(other, inheritedPage)
        self:_applyTransition(other, inheritedTransition, inheritedPage)
        other.node:Deselect()
        self:_resetChild(other, otherTransition, otherPage)
      end
    end
  end

  entry.node:Select()
  self.selectedIndex = index
  self.lastSelectedIndex = index

  self:_showChild(entry, childTransition, childPage)

  if self.EventHandler then
    self.EventHandler(index)
  end
end

function NavigationBar:Navigate(index)
  self:Select(index)
end

-- deselects entry at index if it is currently selected, leaving nothing
-- selected in this bar; only reachable when allowButtonOff is true
function NavigationBar:Deselect(index)
  if self.selectedIndex ~= index then return end
  dprint("NavigationBar:Deselect", self.name, index)
  local entry = self.entries[index]
  local childTransition = self:_resolveTransition(entry)
  local childPage = self:_applyPage(entry)
  self:_applyTransition(entry)
  entry.node:Deselect()
  self:_hideChild(entry, childTransition, childPage)
  self.selectedIndex = nil -- lastSelectedIndex is kept for the next Show()
  if self.EventHandler then
    self.EventHandler(nil)
  end
end

-- called when this bar is a child and its parent entry just became selected;
-- always resets first so this is safe to call directly, without relying on
-- prior Select()/Hide() bookkeeping to know what else might be on
function NavigationBar:Show(inheritedTransition, inheritedPage)
  dprint("NavigationBar:Show", self.name)
  self:Reset(inheritedTransition, inheritedPage)
  self:_applyCommon(inheritedTransition, inheritedPage)
  self.commonNode:Select()
  local index = self.lastSelectedIndex or self.defaultIndex or 1
  if self.entries[index] then
    self:Select(index, inheritedTransition, inheritedPage)
  end
end

-- called when this bar is a child and its parent entry was just deselected;
-- lastSelectedIndex is kept so the next Show() restores where we left off
function NavigationBar:Hide(inheritedTransition, inheritedPage)
  dprint("NavigationBar:Hide", self.name)
  local entry = self.selectedIndex and self.entries[self.selectedIndex]
  if entry then
    local childTransition = self:_resolveTransition(entry, inheritedTransition)
    local childPage = self:_applyPage(entry, inheritedPage)
    self:_applyTransition(entry, inheritedTransition, inheritedPage)
    entry.node:Deselect()
    self:_hideChild(entry, childTransition, childPage)
  end
  self:_applyCommon(inheritedTransition, inheritedPage)
  self.commonNode:Deselect()
  self.selectedIndex = nil
end

-- forces every entry (and nested child bars) into the deselected state,
-- regardless of leftover button/layer state from before the script started
function NavigationBar:Reset(inheritedTransition, inheritedPage)
  self:_applyCommon(inheritedTransition, inheritedPage)
  self.commonNode:Deselect()
  for _, entry in ipairs(self.entries) do
    local childPage = self:_applyPage(entry, inheritedPage)
    self:_applyTransition(entry, inheritedTransition, inheritedPage)
    entry.node:Deselect()
    self:_resetChild(entry, inheritedTransition, childPage)
  end
  self.selectedIndex = nil
end

-- call on the root bar once, after building the whole tree, to set initial UI state
function NavigationBar:Initialize()
  self:Show()
end

--------------------------------------------------------------------------------
-- Menu (public): drill-down menu states with nested child menus.
--------------------------------------------------------------------------------

local Menu = {}
Menu.__index = Menu

local function menuActions(layers)
  local onSelect, onDeselect = {}, {}
  for _, layerName in ipairs(layers) do
    table.insert(onSelect, { target = Target.Layer(layerName), value = true })
    table.insert(onDeselect, { target = Target.Layer(layerName), value = false })
  end
  return onSelect, onDeselect
end

local function attachMenuTrigger(control, action)
  control.EventHandler = function()
    action()
  end
end

-- opts.layers (required) contains the layers that hold this menu's option
-- buttons. opts.backButton is supplied only by the top-level menu; nested
-- menus inherit it through child =. opts.homeButton is optional at any level.
function Menu.New(opts)
  opts = opts or {}
  requireSpec(opts, "Menu.New")
  if opts.layers == nil then
    error("[UCINodes] Menu.New requires layers = 'Menu Layer' (or a table of layer names).", 2)
  end

  local rootOnSelect, rootOnDeselect = menuActions(normalizeLayers(opts.layers, "Menu.New"))
  local commonOnSelect, commonOnDeselect = menuActions(normalizeLayers(opts.commonLayers, "Menu.New"))
  local self = setmetatable({
    name = opts.name,
    entries = {},
    selectedIndex = nil,
    parentEntry = nil,
    transition = opts.transition,
    page = getPage(opts),
    _inheritedPage = nil,
    _isMenu = true,
    _backController = nil,
    _ownsBackController = false,
  }, Menu)

  self.rootNode = Node.New{ onSelect = rootOnSelect, onDeselect = rootOnDeselect }
  self.commonNode = Node.New{ onSelect = commonOnSelect, onDeselect = commonOnDeselect }

  if opts.homeButton then
    self.homeButton = opts.homeButton
    attachMenuTrigger(self.homeButton, function() self:Home() end)
  end

  if opts.backButton then
    local controller = { root = self }
    controller.button = opts.backButton
    attachMenuTrigger(controller.button, function() controller.root:_backDeepest() end)
    self._backController = controller
    self._ownsBackController = true
  end

  for _, entry in ipairs(opts.entries or {}) do
    self:AddEntry(entry)
  end

  return self
end

function Menu:_emit(eventType, index, previousIndex)
  if self.EventHandler then
    self.EventHandler({
      type = eventType,
      menu = self,
      index = index,
      previousIndex = previousIndex,
    })
  end
end

function Menu:_adoptBackController(controller)
  if self._ownsBackController and self._backController ~= controller then
    error("[UCINodes] A nested Menu cannot define backButton; it inherits the top-level menu's back button.", 3)
  end
  self._backController = controller
  for _, entry in ipairs(self.entries) do
    if entry.child and entry.child._isMenu then
      entry.child:_adoptBackController(controller)
    end
  end
end

function Menu:AddEntry(spec)
  requireSpec(spec, "Menu:AddEntry")
  if not spec.button then
    error("[UCINodes] Menu:AddEntry requires button = Controls.YourButton.", 2)
  end

  local onSelect, onDeselect = menuActions(normalizeLayers(spec.layers, "Menu:AddEntry"))
  local index = #self.entries + 1
  local entry = { child = spec.child, transition = spec.transition, page = getPage(spec) }
  entry.node = Node.New{
    onSelect = onSelect,
    onDeselect = onDeselect,
  }
  entry.button = spec.button
  attachMenuTrigger(entry.button, function() self:Select(index) end)
  table.insert(self.entries, entry)

  if entry.child then
    entry.child.parentEntry = entry
    if entry.child._inheritPage then
      entry.child:_inheritPage(self:_resolvePage(entry))
    end
    if entry.child._isMenu then
      entry.child:_adoptBackController(self._backController)
    end
  end

  return entry
end

function Menu:_resolveTransition(entry, inheritedTransition)
  if inheritedTransition ~= nil then return inheritedTransition end
  return (entry and entry.transition) or self.transition
end

function Menu:_resolvePage(entry, inheritedPage)
  return (entry and entry.page) or self.page or inheritedPage or self._inheritedPage or UCINodes.DefaultPage
end

function Menu:_inheritPage(page)
  if self.page == nil then
    self._inheritedPage = page
  end
  for _, entry in ipairs(self.entries) do
    local childPage = entry.page or self.page or self._inheritedPage or page
    if entry.child and entry.child._inheritPage then
      entry.child:_inheritPage(childPage)
    end
  end
end

function Menu:_applyNode(node, entry, inheritedTransition, inheritedPage)
  local page = self:_resolvePage(entry, inheritedPage)
  local onTransition, offTransition = normalizeTransition(self:_resolveTransition(entry, inheritedTransition))
  for _, action in ipairs(node.onSelect) do
    action.page = page
    action.transition = onTransition
  end
  for _, action in ipairs(node.onDeselect) do
    action.page = page
    action.transition = offTransition
  end
  return onTransition, offTransition, page
end

function Menu:_showRoot(inheritedTransition, inheritedPage)
  self:_applyNode(self.rootNode, nil, inheritedTransition, inheritedPage)
  self.rootNode:Select()
end

function Menu:_hideRoot(inheritedTransition, inheritedPage)
  self:_applyNode(self.rootNode, nil, inheritedTransition, inheritedPage)
  self.rootNode:Deselect()
end

function Menu:_showCommon(inheritedTransition, inheritedPage)
  self:_applyNode(self.commonNode, nil, inheritedTransition, inheritedPage)
  self.commonNode:Select()
end

function Menu:_hideCommon(inheritedTransition, inheritedPage)
  self:_applyNode(self.commonNode, nil, inheritedTransition, inheritedPage)
  self.commonNode:Deselect()
end

function Menu:_showChild(entry, transition, page)
  if not entry.child then return end
  if entry.child._isPopup then
    entry.child:SetParentVisible(true, transition, page)
  else
    entry.child:Show(transition, page)
  end
end

function Menu:_hideChild(entry, transition, page)
  if not entry.child then return end
  if entry.child._isPopup then
    entry.child:SetParentVisible(false, transition, page)
  else
    entry.child:Hide(transition, page)
  end
end

function Menu:_resetChild(entry, transition, page)
  if not entry.child then return end
  if entry.child._isPopup then
    entry.child:SetParentVisible(false, transition, page)
  else
    entry.child:Reset(transition, page)
  end
end

function Menu:Select(index, inheritedTransition, inheritedPage)
  local entry = self.entries[index]
  assert(entry, "Menu:Select - no entry at index " .. tostring(index))
  dprint("Menu:Select", self.name, index)
  local childTransition, _, childPage = self:_applyNode(entry.node, entry, inheritedTransition, inheritedPage)

  if self.selectedIndex == index then
    entry.node:Select()
    return
  end

  local previousIndex = self.selectedIndex
  local previous = previousIndex and self.entries[previousIndex]
  if previous then
    local previousTransition, _, previousPage = self:_applyNode(previous.node, previous, inheritedTransition, inheritedPage)
    previous.node:Deselect()
    self:_hideChild(previous, previousTransition, previousPage)
  else
    self:_hideRoot(inheritedTransition, inheritedPage)
    self:_showCommon(inheritedTransition, inheritedPage)
    for otherIndex, other in ipairs(self.entries) do
      if otherIndex ~= index then
        local otherTransition, _, otherPage = self:_applyNode(other.node, other, inheritedTransition, inheritedPage)
        other.node:Deselect()
        self:_resetChild(other, otherTransition, otherPage)
      end
    end
  end

  entry.node:Select()
  self.selectedIndex = index
  self:_showChild(entry, childTransition, childPage)
  self:_emit("select", index, previousIndex)
end

function Menu:Navigate(index)
  self:Select(index)
end

function Menu:_returnToRoot(eventType, inheritedTransition, inheritedPage)
  local previousIndex = self.selectedIndex
  if not previousIndex then return false end
  local entry = self.entries[previousIndex]
  local childTransition, _, childPage = self:_applyNode(entry.node, entry, inheritedTransition, inheritedPage)
  entry.node:Deselect()
  self:_hideChild(entry, childTransition, childPage)
  self.selectedIndex = nil
  self:_hideCommon(inheritedTransition, inheritedPage)
  self:_showRoot(inheritedTransition, inheritedPage)
  self:_emit(eventType, nil, previousIndex)
  return true
end

function Menu:Back(inheritedTransition, inheritedPage)
  dprint("Menu:Back", self.name)
  return self:_returnToRoot("back", inheritedTransition, inheritedPage)
end

function Menu:Home(inheritedTransition, inheritedPage)
  dprint("Menu:Home", self.name)
  return self:_returnToRoot("home", inheritedTransition, inheritedPage)
end

function Menu:_backDeepest()
  local entry = self.selectedIndex and self.entries[self.selectedIndex]
  if entry and entry.child and entry.child._isMenu and entry.child:_backDeepest() then
    return true
  end
  return self:Back()
end

function Menu:Show(inheritedTransition, inheritedPage)
  dprint("Menu:Show", self.name)
  self:Reset(inheritedTransition, inheritedPage)
  self:_showRoot(inheritedTransition, inheritedPage)
end

function Menu:Hide(inheritedTransition, inheritedPage)
  dprint("Menu:Hide", self.name)
  local entry = self.selectedIndex and self.entries[self.selectedIndex]
  if entry then
    local childTransition, _, childPage = self:_applyNode(entry.node, entry, inheritedTransition, inheritedPage)
    entry.node:Deselect()
    self:_hideChild(entry, childTransition, childPage)
    self.selectedIndex = nil
  else
    self:_hideRoot(inheritedTransition, inheritedPage)
  end
  self:_hideCommon(inheritedTransition, inheritedPage)
end

function Menu:Reset(inheritedTransition, inheritedPage)
  self:_hideRoot(inheritedTransition, inheritedPage)
  self:_hideCommon(inheritedTransition, inheritedPage)
  for _, entry in ipairs(self.entries) do
    local childTransition, _, childPage = self:_applyNode(entry.node, entry, inheritedTransition, inheritedPage)
    entry.node:Deselect()
    self:_resetChild(entry, childTransition, childPage)
  end
  self.selectedIndex = nil
end

function Menu:Initialize()
  self:Show()
end

--------------------------------------------------------------------------------
-- Popup (public): a single button that opens/closes its own layer(s).
-- Implements the same Show/Hide/Reset interface as NavigationBar, so a Popup
-- can be a NavigationBar entry's child and vice versa, either way.
--------------------------------------------------------------------------------

local Popup = {}
Popup.__index = Popup

-- spec.button (optional), spec.layers (string or list of strings),
-- spec.child (NavigationBar or Popup, optional),
-- spec.name (optional, dprint label only)
-- spec.transition (string, or {on=..., off=...}/{onTransition, offTransition}, optional),
-- spec.page (string, optional);
-- read fresh on every Show/Hide, so it can be changed anytime via popup.transition = ...
function Popup.New(spec)
  spec = spec or {}
  requireSpec(spec, "Popup.New")

  local layers = normalizeLayers(spec.layers, "Popup.New")

  local onSelect, onDeselect = {}, {}
  for _, layerName in ipairs(layers) do
    table.insert(onSelect, { target = Target.Layer(layerName), value = true })
    table.insert(onDeselect, { target = Target.Layer(layerName), value = false })
  end

  local self = setmetatable({
    name = spec.name,
    child = spec.child,
    transition = spec.transition,
    page = getPage(spec),
    _inheritedPage = nil,
    isOpen = getControlState(spec.button) == true,
    parentVisible = true,
    _isPopup = true,
  }, Popup)
  self.node = Node.New{
    button = spec.button,
    onSelect = onSelect,
    onDeselect = onDeselect,
    onTrigger = function(_, pressed)
      if pressed then self:Show() else self:Hide() end
    end,
  }
  if self.child and self.child._inheritPage then
    self.child:_inheritPage(self:_resolvePage())
  end
  return self
end

function Popup:_resolvePage(inheritedPage)
  return self.page or inheritedPage or self._inheritedPage or UCINodes.DefaultPage
end

function Popup:_inheritPage(page)
  if self.page == nil then
    self._inheritedPage = page
  end
  if self.child and self.child._inheritPage then
    self.child:_inheritPage(self:_resolvePage(page))
  end
end

function Popup:_applyPage(inheritedPage)
  local page = self:_resolvePage(inheritedPage)
  for _, action in ipairs(self.node.onSelect) do
    action.page = page
  end
  for _, action in ipairs(self.node.onDeselect) do
    action.page = page
  end
  return page
end

-- re-reads popup.transition/page and stamps them onto the node's action
-- lists, so changing either field after New() takes effect immediately
function Popup:_applyTransition(inheritedTransition, inheritedPage)
  self:_applyPage(inheritedPage)
  local onTransition, offTransition = normalizeTransition(inheritedTransition or self.transition)
  for _, action in ipairs(self.node.onSelect) do
    action.transition = onTransition
  end
  for _, action in ipairs(self.node.onDeselect) do
    action.transition = offTransition
  end
  return onTransition, offTransition
end

function Popup:_showChild(inheritedTransition, inheritedPage)
  if self.child then
    local childTransition = inheritedTransition or self.transition
    local childPage = self:_resolvePage(inheritedPage)
    self.child:Show(childTransition, childPage)
  end
end

function Popup:_hideChild(inheritedTransition, inheritedPage)
  if self.child then
    local childTransition = inheritedTransition or self.transition
    local childPage = self:_resolvePage(inheritedPage)
    if self.child._isPopup then
      self.child:SetParentVisible(false, childTransition, childPage)
    else
      self.child:Hide(childTransition, childPage)
    end
  end
end

-- parent containers use this to hide/show popup layers without changing the
-- popup's open state, button state, or user callbacks
function Popup:SetParentVisible(isVisible, inheritedTransition, inheritedPage)
  dprint("Popup:SetParentVisible", self.name, isVisible)
  self.parentVisible = isVisible
  self:_applyTransition(inheritedTransition, inheritedPage)
  if isVisible then
    if self.isOpen then
      applyLayerActions(self.node, self.node.onSelect)
      self:_showChild(inheritedTransition, inheritedPage)
    end
  else
    applyLayerActions(self.node, self.node.onDeselect)
    self:_hideChild(inheritedTransition, inheritedPage)
  end
end

-- opens the popup; if it has a child, that child shows too
function Popup:Show(inheritedTransition, inheritedPage)
  dprint("Popup:Show", self.name)
  local wasOpen = self.isOpen
  self:_applyTransition(inheritedTransition, inheritedPage)
  self.isOpen = true
  if self.parentVisible then
    self.node:Select()
    self:_showChild(inheritedTransition, inheritedPage)
  else
    self.node.isSelected = true
    applyControlActions(self.node, self.node.onSelect)
  end
  if not wasOpen and self.EventHandler then
    self.EventHandler(true)
  end
end

-- closes the popup; if it has a child, that child hides too
function Popup:Hide(inheritedTransition, inheritedPage)
  dprint("Popup:Hide", self.name)
  local wasOpen = self.isOpen
  self:_applyTransition(inheritedTransition, inheritedPage)
  self.isOpen = false
  if self.parentVisible then
    self.node:Deselect()
    self:_hideChild(inheritedTransition, inheritedPage)
  else
    self.node.isSelected = false
    applyControlActions(self.node, self.node.onDeselect)
  end
  if wasOpen and self.EventHandler then
    self.EventHandler(false)
  end
end

-- forces this popup (and any nested child) closed, regardless of leftover state
function Popup:Reset(inheritedTransition, inheritedPage)
  self:_applyTransition(inheritedTransition, inheritedPage)
  self.node:Deselect()
  if self.child then
    self.child:Reset(inheritedTransition, self:_resolvePage(inheritedPage))
  end
  self.isOpen = false
  self.parentVisible = true
end

-- call once, after building this popup's whole tree, if it isn't nested as
-- someone else's child (a nested popup gets Reset() via its parent instead)
function Popup:Initialize()
  self:Reset()
end

UCINodes.NavigationBar = NavigationBar
UCINodes.Menu = Menu
UCINodes.Popup = Popup
UCINodes.Target = { Layer = Target.Layer, Control = Target.Control }

return UCINodes
