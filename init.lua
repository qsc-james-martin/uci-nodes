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

local accessGates = setmetatable({}, { __mode = "k" })

local function isAccessGranted(access)
  return getControlState(access.control) == true
end

local function registerAccessRequest(access, resume)
  local gate = accessGates[access.control]
  if not gate then
    gate = { requests = {}, handler = access.control.EventHandler }
    accessGates[access.control] = gate
    access.control.EventHandler = function(control)
      if gate.handler then gate.handler(control) end
      if getControlState(control) ~= true then return end

      local requests = gate.requests
      gate.requests = {}
      for _, request in ipairs(requests) do
        if not request.cancelled then request.resume() end
      end
    end
  end

  local request = { resume = resume, cancelled = false }
  table.insert(gate.requests, request)
  return request
end

local function cancelAccessRequest(request)
  if request then request.cancelled = true end
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

local function normalizeAccess(access, owner)
  if access == nil then return nil end
  if type(access) ~= "table" then
    error("[UCINodes] " .. owner .. ".access must be a table.", 3)
  end
  if not access.control then
    error("[UCINodes] " .. owner .. ".access requires control = Controls.YourAccessGrantedControl.", 3)
  end
  if access.accessDeniedLayers == nil then
    error("[UCINodes] " .. owner .. ".access requires accessDeniedLayers = 'Access Denied Layer'.", 3)
  end
  if access.autoLogout and not access.logoutButton then
    error("[UCINodes] " .. owner .. ".access autoLogout requires logoutButton.", 3)
  end
  if access.logoutButton and type(access.logoutButton.Trigger) ~= "function" then
    error("[UCINodes] " .. owner .. ".access logoutButton must provide :Trigger().", 3)
  end
  return {
    control = access.control,
    layers = normalizeLayers(access.accessDeniedLayers, owner .. ".access"),
    logoutButton = access.logoutButton,
    autoLogout = access.autoLogout == true,
  }
end

local function attachLogoutTrigger(access, action)
  if not access.logoutButton then return end
  local handler = access.logoutButton.EventHandler
  access.logoutButton.EventHandler = function(control)
    if handler then handler(control) end
    if not access.isAutoLoggingOut then action() end
  end
end

local function triggerAutoLogout(access)
  if not access or not access.autoLogout or not access.logoutButton then return end
  access.isAutoLoggingOut = true
  access.logoutButton:Trigger()
  access.isAutoLoggingOut = false
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

local function applyActions(node, actions, targetKind)
  if targetKind ~= "layer" then node._isUpdating = true end
  for _, action in ipairs(actions) do
    if targetKind == nil or action.target.kind == targetKind then
      if action.target.kind == "control" then
        node._ignoreControlValue = action.value
      end
      action.target:Set(action.value, action.transition, action.page)
    end
  end
  if targetKind ~= "layer" then node._isUpdating = false end
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

local function breadcrumbLabel(container)
  return container.name or container._breadcrumbType
end

local function breadcrumbEntry(entry)
  if entry.name then return entry.name end
  return "Item [" .. tostring(entry.index) .. "]"
end

local function appendBreadcrumbAncestors(parts, container)
  if container.parentContainer then
    appendBreadcrumbAncestors(parts, container.parentContainer)
    if container.parentEntry then
      table.insert(parts, breadcrumbEntry(container.parentEntry))
    end
  end
  table.insert(parts, breadcrumbLabel(container))
end

local function appendActiveBreadcrumbs(parts, container)
  local entry = container.selectedIndex and container.entries and container.entries[container.selectedIndex]
  if entry then
    table.insert(parts, breadcrumbEntry(entry))
    if entry.child then
      table.insert(parts, breadcrumbLabel(entry.child))
      appendActiveBreadcrumbs(parts, entry.child)
    end
  elseif container._isPopup and container.isOpen and container.child then
    table.insert(parts, breadcrumbLabel(container.child))
    appendActiveBreadcrumbs(parts, container.child)
  end
end

local function breadcrumbsFor(container)
  local parts = {}
  appendBreadcrumbAncestors(parts, container)
  appendActiveBreadcrumbs(parts, container)
  return table.concat(parts, " > ")
end

local function publicIndex(typeTable)
  return function(self, key)
    if key == "Breadcrumbs" then return breadcrumbsFor(self) end
    return typeTable[key]
  end
end

local function refreshBreadcrumbs(container)
  if container.breadcrumbsControl then
    local root = container._breadcrumbsRoot or container
    container.breadcrumbsControl.String = root.Breadcrumbs
  end
end

local function inheritBreadcrumbs(container, control, root)
  if container._breadcrumbsControlExplicit then return end
  container.breadcrumbsControl = control
  container._breadcrumbsRoot = root

  if container.entries then
    for _, entry in ipairs(container.entries) do
      if entry.child and entry.child._inheritBreadcrumbs then
        entry.child:_inheritBreadcrumbs(control, root)
      end
    end
  elseif container.child and container.child._inheritBreadcrumbs then
    container.child:_inheritBreadcrumbs(control, root)
  end
end

local function attachChild(parent, entry, child, page, transition, backTransition)
  if not child then return end
  if child.parentContainer and child.parentContainer ~= parent then
    error("[UCINodes] This child already belongs to another parent.", 3)
  end

  child.parentEntry = entry
  child.parentContainer = parent
  if child._inheritPage then child:_inheritPage(page) end
  if child._inheritTransition then child:_inheritTransition(transition) end
  if backTransition and child._inheritBackTransition then
    child:_inheritBackTransition(backTransition)
  end
  if parent.breadcrumbsControl and child._inheritBreadcrumbs then
    child:_inheritBreadcrumbs(parent.breadcrumbsControl, parent._breadcrumbsRoot or parent)
  end
end

--------------------------------------------------------------------------------
-- NavigationBar (public): mutually exclusive Nodes + parent/child nesting.
-- Delegates all actual state changes to Node/Target - no direct Uci calls here.
--------------------------------------------------------------------------------

local NavigationBar = {}
NavigationBar.__index = publicIndex(NavigationBar)

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
    _breadcrumbType = "NavigationBar",
    entries = {},
    selectedIndex = nil,
    lastSelectedIndex = nil,
    defaultIndex = nil,
    parentEntry = nil, -- set when this bar is attached as another bar's child
    allowButtonOff = opts.allowButtonOff or false,
    transition = opts.transition,
    page = getPage(opts),
    _inheritedPage = nil,
    _inheritedTransition = nil,
    _inheritedBackTransition = nil,
    parentVisible = true,
    breadcrumbsControl = opts.breadcrumbsControl,
    _breadcrumbsControlExplicit = opts.breadcrumbsControl ~= nil,
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
  local entry = {
    child = spec.child,
    name = spec.name,
    index = index,
    transition = spec.transition,
    page = getPage(spec),
  }
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
    attachChild(self, entry, spec.child, self:_resolvePage(entry), self:_resolveTransition(entry))
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
  return entry.transition or self.transition or self._inheritedTransition
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

function NavigationBar:_inheritTransition(transition)
  if self.transition == nil then
    self._inheritedTransition = transition
  end
  for _, entry in ipairs(self.entries) do
    if entry.child and entry.child._inheritTransition then
      entry.child:_inheritTransition(self:_resolveTransition(entry))
    end
  end
end

function NavigationBar:_inheritBreadcrumbs(control, root)
  inheritBreadcrumbs(self, control, root)
end

function NavigationBar:_showChild(entry, transition, page)
  if not entry.child then return end
  if entry.child.SetParentVisible then
    entry.child:SetParentVisible(true, transition, page)
  else
    entry.child:Show(transition, page)
  end
end

function NavigationBar:_hideChild(entry, transition, page)
  if not entry.child then return end
  if entry.child.SetParentVisible then
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
    if entry.child.SetParentVisible then
      entry.child:SetParentVisible(false, transition, page)
    end
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

  if not self.parentVisible then
    local previous = self.selectedIndex and self.entries[self.selectedIndex]
    if previous and previous ~= entry then
      previous.node.isSelected = false
      applyActions(previous.node, previous.node.onDeselect, "control")
      self:_hideChild(previous, inheritedTransition, inheritedPage)
    end
    entry.node.isSelected = true
    applyActions(entry.node, entry.node.onSelect, "control")
    self.selectedIndex = index
    self.lastSelectedIndex = index
    self:_hideChild(entry, inheritedTransition, inheritedPage)
    if self.EventHandler then self.EventHandler(index) end
    refreshBreadcrumbs(self)
    return
  end

  if self.selectedIndex == index then
    entry.node:Select() -- re-assert visual/layer state (e.g. after a click toggled the button off)
    self:_showChild(entry, childTransition, childPage)
    refreshBreadcrumbs(self)
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
  refreshBreadcrumbs(self)
end

function NavigationBar:Navigate(index)
  self:Select(index)
end

function NavigationBar:SetParentVisible(isVisible, inheritedTransition, inheritedPage)
  self.parentVisible = isVisible
  if isVisible then
    self:Show(inheritedTransition, inheritedPage)
  else
    self:Hide(inheritedTransition, inheritedPage)
  end
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
  refreshBreadcrumbs(self)
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
  refreshBreadcrumbs(self)
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
  refreshBreadcrumbs(self)
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
  refreshBreadcrumbs(self)
end

-- call on the root bar once, after building the whole tree, to set initial UI state
function NavigationBar:Initialize()
  self:Show()
end

--------------------------------------------------------------------------------
-- Menu (public): drill-down menu states with nested child menus.
--------------------------------------------------------------------------------

local Menu = {}
Menu.__index = publicIndex(Menu)

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
    _breadcrumbType = "Menu",
    entries = {},
    selectedIndex = nil,
    lastSelectedIndex = nil,
    parentEntry = nil,
    transition = opts.transition,
    backTransition = opts.backTransition,
    page = getPage(opts),
    _inheritedPage = nil,
    _inheritedTransition = nil,
    parentVisible = true,
    breadcrumbsControl = opts.breadcrumbsControl,
    _breadcrumbsControlExplicit = opts.breadcrumbsControl ~= nil,
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
  local access = normalizeAccess(spec.access, "Menu:AddEntry")
  local index = #self.entries + 1
  local entry = {
    child = spec.child,
    name = spec.name,
    index = index,
    transition = spec.transition,
    backTransition = spec.backTransition,
    page = getPage(spec),
    access = access,
  }
  entry.node = Node.New{
    onSelect = onSelect,
    onDeselect = onDeselect,
  }
  entry.button = spec.button
  if access then
    local deniedOnSelect, deniedOnDeselect = menuActions(access.layers)
    access.node = Node.New{ onSelect = deniedOnSelect, onDeselect = deniedOnDeselect }
    attachLogoutTrigger(access, function()
      if self.selectedIndex == index then self:Back() end
    end)
  end
  attachMenuTrigger(entry.button, function() self:Select(index) end)
  table.insert(self.entries, entry)

  if entry.child then
    attachChild(self, entry, entry.child, self:_resolvePage(entry), self:_resolveTransition(entry), self:_resolveBackTransition(entry))
    if entry.child._isMenu then
      entry.child:_adoptBackController(self._backController)
    end
  end

  return entry
end

function Menu:_hideAccessDenied(entry, inheritedTransition, inheritedPage)
  local access = entry and entry.access
  if not access or not access.node then return end
  self:_applyNode(access.node, entry, inheritedTransition, inheritedPage)
  access.node:Deselect()
  cancelAccessRequest(access.request)
  access.request = nil
end

function Menu:_clearAccessDenied(inheritedTransition, inheritedPage)
  for _, entry in ipairs(self.entries) do
    self:_hideAccessDenied(entry, inheritedTransition, inheritedPage)
  end
end

function Menu:_releaseAccess(entry)
  local access = entry and entry.access
  if not access or not access.active then return end
  access.active = false
  if self.AccessHandler then
    self.AccessHandler({ type = "released", target = self, access = access, index = entry.index })
  end
end

function Menu:_denyAccess(entry, inheritedTransition, inheritedPage)
  local access = entry.access
  self:_clearAccessDenied(inheritedTransition, inheritedPage)
  local previous = self.selectedIndex and self.entries[self.selectedIndex]
  if previous then
    local previousTransition = self:_resolveTransition(previous, inheritedTransition)
    local _, _, previousPage = self:_applyNode(previous.node, previous, inheritedTransition, inheritedPage)
    previous.node:Deselect()
    self:_hideChild(previous, previousTransition, previousPage)
    self.selectedIndex = nil
    self.lastSelectedIndex = nil
    self:_hideCommon(previous, inheritedTransition, inheritedPage)
  else
    self:_hideRoot(entry, inheritedTransition, inheritedPage)
  end

  self:_showCommon(entry, inheritedTransition, inheritedPage)
  self:_applyNode(access.node, entry, inheritedTransition, inheritedPage)
  access.node:Select()
  cancelAccessRequest(access.request)
  access.request = registerAccessRequest(access, function()
    self:_hideAccessDenied(entry)
    if self.AccessHandler then
      self.AccessHandler({ type = "granted", target = self, access = access, index = entry.index })
    end
    self:Select(entry.index)
  end)
  if self.AccessHandler then
    self.AccessHandler({ type = "denied", target = self, access = access, index = entry.index })
  end
  refreshBreadcrumbs(self)
end

function Menu:_resolveTransition(entry, inheritedTransition)
  if inheritedTransition ~= nil then return inheritedTransition end
  return (entry and entry.transition) or self.transition or self._inheritedTransition
end

function Menu:_resolveBackTransition(entry, inheritedTransition)
  if inheritedTransition ~= nil then return inheritedTransition end
  return (entry and entry.backTransition) or self.backTransition or self._inheritedBackTransition or self:_resolveTransition(entry)
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

function Menu:_inheritTransition(transition)
  if self.transition == nil then
    self._inheritedTransition = transition
  end
  for _, entry in ipairs(self.entries) do
    if entry.child and entry.child._inheritTransition then
      entry.child:_inheritTransition(self:_resolveTransition(entry))
    end
  end
end

function Menu:_inheritBackTransition(transition)
  if self.backTransition == nil then
    self._inheritedBackTransition = transition
  end
  for _, entry in ipairs(self.entries) do
    if entry.child and entry.child._inheritBackTransition then
      entry.child:_inheritBackTransition(self:_resolveBackTransition(entry))
    end
  end
end

function Menu:_inheritBreadcrumbs(control, root)
  inheritBreadcrumbs(self, control, root)
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

function Menu:_showRoot(entry, inheritedTransition, inheritedPage)
  self:_applyNode(self.rootNode, entry, inheritedTransition, inheritedPage)
  self.rootNode:Select()
end

function Menu:_hideRoot(entry, inheritedTransition, inheritedPage)
  self:_applyNode(self.rootNode, entry, inheritedTransition, inheritedPage)
  self.rootNode:Deselect()
end

function Menu:_showCommon(entry, inheritedTransition, inheritedPage)
  self:_applyNode(self.commonNode, entry, inheritedTransition, inheritedPage)
  self.commonNode:Select()
end

function Menu:_hideCommon(entry, inheritedTransition, inheritedPage)
  self:_applyNode(self.commonNode, entry, inheritedTransition, inheritedPage)
  self.commonNode:Deselect()
end

function Menu:_showChild(entry, transition, page)
  if not entry.child then return end
  if entry.child.SetParentVisible then
    entry.child:SetParentVisible(true, transition, page)
  else
    entry.child:Show(transition, page)
  end
end

function Menu:_hideChild(entry, transition, page)
  if not entry.child then return end
  if entry.child.SetParentVisible then
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
    if entry.child.SetParentVisible then
      entry.child:SetParentVisible(false, transition, page)
    end
  end
end

function Menu:Select(index, inheritedTransition, inheritedPage)
  local entry = self.entries[index]
  assert(entry, "Menu:Select - no entry at index " .. tostring(index))
  dprint("Menu:Select", self.name, index)
  if entry.access and not isAccessGranted(entry.access) then
    self:_denyAccess(entry, inheritedTransition, inheritedPage)
    return
  end
  self:_hideAccessDenied(entry, inheritedTransition, inheritedPage)
  local childTransition = self:_resolveTransition(entry, inheritedTransition)
  local _, _, childPage = self:_applyNode(entry.node, entry, inheritedTransition, inheritedPage)

  if not self.parentVisible then
    local previous = self.selectedIndex and self.entries[self.selectedIndex]
    if previous and previous ~= entry then
      self:_hideChild(previous, inheritedTransition, inheritedPage)
    end
    self.selectedIndex = index
    self.lastSelectedIndex = index
    self:_hideChild(entry, inheritedTransition, inheritedPage)
    self:_emit("select", index, previous and previous.index or nil)
    refreshBreadcrumbs(self)
    return
  end

  if self.selectedIndex == index then
    entry.node:Select()
    self:_showChild(entry, childTransition, childPage)
    refreshBreadcrumbs(self)
    return
  end

  local previousIndex = self.selectedIndex
  local previous = previousIndex and self.entries[previousIndex]
  if previous then
    local previousTransition = self:_resolveTransition(previous, inheritedTransition)
    local _, _, previousPage = self:_applyNode(previous.node, previous, inheritedTransition, inheritedPage)
    previous.node:Deselect()
    self:_hideChild(previous, previousTransition, previousPage)
    self:_releaseAccess(previous)
  else
    self:_hideRoot(entry, inheritedTransition, inheritedPage)
    self:_showCommon(entry, inheritedTransition, inheritedPage)
    for otherIndex, other in ipairs(self.entries) do
      if otherIndex ~= index then
        local otherTransition = self:_resolveTransition(other, inheritedTransition)
        local _, _, otherPage = self:_applyNode(other.node, other, inheritedTransition, inheritedPage)
        other.node:Deselect()
        self:_resetChild(other, otherTransition, otherPage)
      end
    end
  end

  entry.node:Select()
  self.selectedIndex = index
  self.lastSelectedIndex = index
  if entry.access then entry.access.active = true end
  self:_showChild(entry, childTransition, childPage)
  self:_emit("select", index, previousIndex)
  refreshBreadcrumbs(self)
end

function Menu:Navigate(index)
  self:Select(index)
end

function Menu:SetParentVisible(isVisible, inheritedTransition, inheritedPage)
  self.parentVisible = isVisible
  if isVisible then
    self:Show(inheritedTransition, inheritedPage)
  else
    self:Hide(inheritedTransition, inheritedPage)
  end
end

function Menu:_returnToRoot(eventType, inheritedTransition, inheritedPage)
  local previousIndex = self.selectedIndex
  if not previousIndex then
    self:_clearAccessDenied(inheritedTransition, inheritedPage)
    self:_hideCommon(nil, inheritedTransition, inheritedPage)
    self:_showRoot(nil, inheritedTransition, inheritedPage)
    refreshBreadcrumbs(self)
    return false
  end
  local entry = self.entries[previousIndex]
  triggerAutoLogout(entry.access)
  local backTransition = self:_resolveBackTransition(entry, inheritedTransition)
  local _, _, childPage = self:_applyNode(entry.node, entry, backTransition, inheritedPage)
  entry.node:Deselect()
  self:_hideChild(entry, backTransition, childPage)
  self:_releaseAccess(entry)
  if eventType == "home" and entry.child and entry.child._isMenu then
    entry.child.lastSelectedIndex = nil
  end
  self.selectedIndex = nil
  self.lastSelectedIndex = nil
  self:_hideCommon(entry, backTransition, inheritedPage)
  self:_showRoot(entry, backTransition, inheritedPage)
  self:_emit(eventType, nil, previousIndex)
  refreshBreadcrumbs(self)
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
  self:_showRoot(nil, inheritedTransition, inheritedPage)
  local index = self.lastSelectedIndex
  if index and self.entries[index] then
    self:Select(index, inheritedTransition, inheritedPage)
  end
  refreshBreadcrumbs(self)
end

function Menu:Hide(inheritedTransition, inheritedPage)
  dprint("Menu:Hide", self.name)
  self:_clearAccessDenied(inheritedTransition, inheritedPage)
  local entry = self.selectedIndex and self.entries[self.selectedIndex]
  if entry then
    local childTransition = self:_resolveTransition(entry, inheritedTransition)
    local _, _, childPage = self:_applyNode(entry.node, entry, inheritedTransition, inheritedPage)
    entry.node:Deselect()
    self:_hideChild(entry, childTransition, childPage)
    self:_releaseAccess(entry)
    self.lastSelectedIndex = self.selectedIndex
    self.selectedIndex = nil
  else
    self:_hideRoot(nil, inheritedTransition, inheritedPage)
  end
  self:_hideCommon(entry, inheritedTransition, inheritedPage)
  refreshBreadcrumbs(self)
end

function Menu:Reset(inheritedTransition, inheritedPage)
  self:_clearAccessDenied(inheritedTransition, inheritedPage)
  self:_hideRoot(nil, inheritedTransition, inheritedPage)
  self:_hideCommon(nil, inheritedTransition, inheritedPage)
  for _, entry in ipairs(self.entries) do
    local childTransition = self:_resolveTransition(entry, inheritedTransition)
    local _, _, childPage = self:_applyNode(entry.node, entry, inheritedTransition, inheritedPage)
    entry.node:Deselect()
    self:_resetChild(entry, childTransition, childPage)
    self:_releaseAccess(entry)
  end
  self.selectedIndex = nil
  refreshBreadcrumbs(self)
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
Popup.__index = publicIndex(Popup)

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
  local access = normalizeAccess(spec.access, "Popup.New")

  local onSelect, onDeselect = {}, {}
  for _, layerName in ipairs(layers) do
    table.insert(onSelect, { target = Target.Layer(layerName), value = true })
    table.insert(onDeselect, { target = Target.Layer(layerName), value = false })
  end

  local self = setmetatable({
    name = spec.name,
    _breadcrumbType = "Popup",
    child = spec.child,
    transition = spec.transition,
    page = getPage(spec),
    _inheritedPage = nil,
    _inheritedTransition = nil,
    access = access,
    breadcrumbsControl = spec.breadcrumbsControl,
    _breadcrumbsControlExplicit = spec.breadcrumbsControl ~= nil,
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
  if access then
    local deniedOnSelect, deniedOnDeselect = menuActions(access.layers)
    access.node = Node.New{ onSelect = deniedOnSelect, onDeselect = deniedOnDeselect }
    attachLogoutTrigger(access, function()
      if self.isOpen or access.request then self:Hide() end
    end)
  end
  attachChild(self, nil, self.child, self:_resolvePage(), self.transition)
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

function Popup:_inheritTransition(transition)
  if self.transition == nil then
    self._inheritedTransition = transition
  end
  if self.child and self.child._inheritTransition then
    self.child:_inheritTransition(self.transition or self._inheritedTransition)
  end
end

function Popup:_inheritBreadcrumbs(control, root)
  inheritBreadcrumbs(self, control, root)
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
  local onTransition, offTransition = normalizeTransition(inheritedTransition or self.transition or self._inheritedTransition)
  for _, action in ipairs(self.node.onSelect) do
    action.transition = onTransition
  end
  for _, action in ipairs(self.node.onDeselect) do
    action.transition = offTransition
  end
  return onTransition, offTransition
end

function Popup:_applyAccessDenied(visible, inheritedTransition, inheritedPage)
  local access = self.access
  if not access or not access.node then return end
  local page = self:_resolvePage(inheritedPage)
  local onTransition, offTransition = normalizeTransition(inheritedTransition or self.transition or self._inheritedTransition)
  for _, action in ipairs(access.node.onSelect) do
    action.page = page
    action.transition = onTransition
  end
  for _, action in ipairs(access.node.onDeselect) do
    action.page = page
    action.transition = offTransition
  end
  if visible then
    access.node.isSelected = true
    applyActions(access.node, access.node.onSelect, "layer")
  else
    access.node.isSelected = false
    applyActions(access.node, access.node.onDeselect, "layer")
  end
end

function Popup:_denyAccess(inheritedTransition, inheritedPage)
  local access = self.access
  self.isOpen = false
  self.node.isSelected = false
  applyActions(self.node, self.node.onDeselect, "control")
  self:_applyAccessDenied(self.parentVisible, inheritedTransition, inheritedPage)
  cancelAccessRequest(access.request)
  access.request = registerAccessRequest(access, function()
    self:_applyAccessDenied(false)
    if self.AccessHandler then
      self.AccessHandler({ type = "granted", target = self, access = access })
    end
    self:Show()
  end)
  if self.AccessHandler then
    self.AccessHandler({ type = "denied", target = self, access = access })
  end
end

function Popup:_clearAccessDenied(inheritedTransition, inheritedPage)
  if not self.access then return end
  self:_applyAccessDenied(false, inheritedTransition, inheritedPage)
  cancelAccessRequest(self.access.request)
  self.access.request = nil
end

function Popup:_showChild(inheritedTransition, inheritedPage)
  if self.child then
    local childTransition = inheritedTransition or self.transition or self._inheritedTransition
    local childPage = self:_resolvePage(inheritedPage)
    self.child:Show(childTransition, childPage)
  end
end

function Popup:_hideChild(inheritedTransition, inheritedPage)
  if self.child then
    local childTransition = inheritedTransition or self.transition or self._inheritedTransition
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
    if self.access and self.access.request then
      self:_applyAccessDenied(true, inheritedTransition, inheritedPage)
    elseif self.isOpen then
      applyActions(self.node, self.node.onSelect, "layer")
      self:_showChild(inheritedTransition, inheritedPage)
    end
  else
    if self.access and self.access.request then
      self:_applyAccessDenied(false, inheritedTransition, inheritedPage)
    end
    applyActions(self.node, self.node.onDeselect, "layer")
    self:_hideChild(inheritedTransition, inheritedPage)
  end
  refreshBreadcrumbs(self)
end

-- opens the popup; if it has a child, that child shows too
function Popup:Show(inheritedTransition, inheritedPage)
  dprint("Popup:Show", self.name)
  if self.access and not isAccessGranted(self.access) then
    self:_denyAccess(inheritedTransition, inheritedPage)
    return
  end
  self:_clearAccessDenied(inheritedTransition, inheritedPage)
  local wasOpen = self.isOpen
  self:_applyTransition(inheritedTransition, inheritedPage)
  self.isOpen = true
  if self.access then self.access.active = true end
  if self.parentVisible then
    self.node:Select()
    self:_showChild(inheritedTransition, inheritedPage)
  else
    self.node.isSelected = true
    applyActions(self.node, self.node.onSelect, "control")
  end
  if not wasOpen and self.EventHandler then
    self.EventHandler(true)
  end
  refreshBreadcrumbs(self)
end

-- closes the popup; if it has a child, that child hides too
function Popup:Hide(inheritedTransition, inheritedPage)
  dprint("Popup:Hide", self.name)
  self:_clearAccessDenied(inheritedTransition, inheritedPage)
  local wasOpen = self.isOpen
  self:_applyTransition(inheritedTransition, inheritedPage)
  self.isOpen = false
  if self.parentVisible then
    self.node:Deselect()
    self:_hideChild(inheritedTransition, inheritedPage)
  else
    self.node.isSelected = false
    applyActions(self.node, self.node.onDeselect, "control")
  end
  if wasOpen and self.EventHandler then
    self.EventHandler(false)
  end
  if wasOpen and self.access and self.access.active then
    self.access.active = false
    if self.AccessHandler then
      self.AccessHandler({ type = "released", target = self, access = self.access })
    end
  end
  refreshBreadcrumbs(self)
end

-- forces this popup (and any nested child) closed, regardless of leftover state
function Popup:Reset(inheritedTransition, inheritedPage)
  local hadAccess = self.access and self.access.active
  self:_clearAccessDenied(inheritedTransition, inheritedPage)
  self:_applyTransition(inheritedTransition, inheritedPage)
  self.node:Deselect()
  if self.child then
    self.child:Reset(inheritedTransition, self:_resolvePage(inheritedPage))
  end
  self.isOpen = false
  self.parentVisible = true
  if hadAccess then
    self.access.active = false
    if self.AccessHandler then
      self.AccessHandler({ type = "released", target = self, access = self.access })
    end
  end
  refreshBreadcrumbs(self)
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
