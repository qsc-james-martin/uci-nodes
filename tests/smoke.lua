package.loaded["init"] = nil

local calls = {}
Uci = {
  SetLayerVisibility = function(page, layer, value, transition)
    if page == nil then error("nil page for " .. tostring(layer)) end
    table.insert(calls, { page = page, layer = layer, value = value, transition = transition })
  end
}

local UCINodes = require("init")

local function control(initial)
  return { Boolean = initial == true }
end

local function trigger()
  return {}
end

local function assertEqual(actual, expected, message)
  if actual ~= expected then
    error(message .. " expected " .. tostring(expected) .. " got " .. tostring(actual), 2)
  end
end

local function assertTruthy(value, message)
  if not value then
    error(message, 2)
  end
end

local function sawCall(layer, value)
  for _, call in ipairs(calls) do
    if call.layer == layer and call.value == value then return true end
  end
  return false
end

local function expectError(label, fn, expected)
  local ok, message = pcall(fn)
  if ok then error(label .. " did not error", 2) end
  if not string.find(tostring(message), expected, 1, true) then
    error(label .. " wrong error: " .. tostring(message), 2)
  end
end

UCINodes.DefaultPage = "Default Page"

local buttonlessEvents = {}
local buttonless = UCINodes.Popup.New{ layers = "Overlay" }
buttonless.EventHandler = function(open) table.insert(buttonlessEvents, open) end
buttonless:Show()
buttonless:Hide()
assertEqual(buttonlessEvents[1], true, "buttonless popup show callback")
assertEqual(buttonlessEvents[2], false, "buttonless popup hide callback")

local navEvents = {}
local bar = UCINodes.NavigationBar.New{ transition = "fade", page = "Page 1" }
bar.EventHandler = function(index) table.insert(navEvents, index) end
bar:AddEntry{ button = control(), layers = "A" }
bar:AddEntry{ button = control(), layers = "B", transition = "left", page = "Page 2" }
bar:Navigate(2)
assertEqual(bar.selectedIndex, 2, "Navigate selected index")
assertEqual(navEvents[1], 2, "Navigate callback")
assertEqual(calls[#calls].transition, "left", "entry transition override")
assertEqual(calls[#calls].page, "Page 2", "entry page override")

local child = UCINodes.NavigationBar.New{ transition = "none" }
child:AddEntry{ button = control(), layers = "Child", default = true }
local parent = UCINodes.NavigationBar.New{ transition = { "fadeIn", "fadeOut" }, page = "Parent Page" }
parent:AddEntry{ button = control(), layers = "Parent", child = child, default = true }
parent:AddEntry{ button = control(), layers = "Other" }
parent:Initialize()
parent:Navigate(2)
local childShowTransition
local childHideTransition
local childPage
for _, call in ipairs(calls) do
  if call.layer == "Child" and call.value == true then
    childShowTransition = call.transition
    childPage = call.page
  elseif call.layer == "Child" and call.value == false then
    childHideTransition = call.transition
  end
end
assertEqual(childShowTransition, "fadeIn", "inherited child show transition")
assertEqual(childHideTransition, "fadeOut", "inherited child hide transition")
assertEqual(childPage, "Parent Page", "child nav page inheritance")

local popupButton = control(false)
local popupEvents = {}
local popup = UCINodes.Popup.New{ button = popupButton, layers = "PopupLayer" }
popup.EventHandler = function(open) table.insert(popupEvents, open) end
local popupParent = UCINodes.NavigationBar.New{ transition = { "showParent", "hideParent" }, page = "Popup Parent Page" }
popupParent:AddEntry{ button = control(), layers = "PopupParent", child = popup, default = true }
popupParent:AddEntry{ button = control(), layers = "PopupOther" }
popupParent:Initialize()
assertEqual(popup.isOpen, false, "parent initialize should not open popup")
assertEqual(popupButton.Boolean, false, "parent initialize should not turn popup button on")
assertEqual(#popupEvents, 0, "parent initialize should not fire popup callback")
popup:Show()
popupParent:Navigate(2)
assertEqual(popup.isOpen, true, "parent hide should preserve popup state")
assertEqual(popupButton.Boolean, true, "parent hide should preserve popup button")
assertEqual(#popupEvents, 1, "parent hide should not fire popup callback")
popupParent:Navigate(1)
assertEqual(popup.isOpen, true, "parent show should preserve popup state")
assertEqual(popupButton.Boolean, true, "parent show should preserve popup button")
assertEqual(#popupEvents, 1, "parent show should not fire popup callback")
local popupPage
for _, call in ipairs(calls) do
  if call.layer == "PopupLayer" and call.value == true then popupPage = call.page end
end
assertEqual(popupPage, "Popup Parent Page", "child popup page inheritance")

local initialOn = UCINodes.Popup.New{ button = control(true), layers = "InitialOn", page = "Popup Page" }
local parent2 = UCINodes.NavigationBar.New()
parent2:AddEntry{ button = control(), layers = "Parent2", child = initialOn, default = true }
parent2:Initialize()
local restored = false
local restoredPage
for _, call in ipairs(calls) do
  if call.layer == "InitialOn" and call.value == true then
    restored = true
    restoredPage = call.page
  end
end
assertEqual(initialOn.isOpen, true, "initial button state should set popup open")
assertEqual(restored, true, "parent should restore initially-open popup layer")
assertEqual(restoredPage, "Popup Page", "popup page should override inherited/global page")

local fallbackPopup = UCINodes.Popup.New{ layers = "Fallback Popup" }
fallbackPopup:Show()
assertEqual(calls[#calls].page, "Default Page", "DefaultPage fallback should remain")

local constructorChild = UCINodes.NavigationBar.New{
  entries = {
    { button = control(), layers = "Constructor Child A", default = true },
    { button = control(), layers = "Constructor Child B" },
  }
}
local constructorNav = UCINodes.NavigationBar.New{
  page = "Constructor Page",
  transition = "fade",
  entries = {
    { button = control(), layers = "Constructor Home", default = true },
    { button = control(), layers = "Constructor Audio", transition = "left", child = constructorChild },
  }
}
assertEqual(#constructorNav.entries, 2, "constructor should add nav entries")
assertEqual(constructorNav.defaultIndex, 1, "constructor entries should set default")
assertEqual(#constructorChild.entries, 2, "constructor should add child entries")
assertEqual(constructorChild.page, nil, "constructor child should not mutate explicit page")
assertEqual(constructorChild._inheritedPage, "Constructor Page", "constructor child should track inherited parent page")
constructorNav:Initialize()
constructorNav:Navigate(2)
assertEqual(constructorNav.selectedIndex, 2, "Navigate should select constructor entry")
assertEqual(calls[#calls].transition, "left", "constructor entry transition should apply")
assertEqual(calls[#calls].page, "Constructor Page", "constructor entry page should apply")

local nav1 = control(false)
local nav2 = control(true)
local nav3 = control(true)
local nav4 = control(true)
local sub1 = control(true)
local sub2 = control(true)
local stalePopupButton = control(true)
local NavSub = UCINodes.NavigationBar.New()
NavSub:AddEntry{button = sub1, layers = "3 Group 1", default = true}
NavSub:AddEntry{button = sub2, layers = "3 Group 2"}
local Popup = UCINodes.Popup.New{ button = stalePopupButton, layers = "Popup 4_1", transition = "top" }
local NavMain = UCINodes.NavigationBar.New{
  transition = "none",
  page = "Page 1",
  entries = {
    {button = nav1, layers = "Main Group 1", default = true},
    {button = nav2, layers = "Main Group 2"},
    {button = nav3, layers = "Main Group 3", child = NavSub},
    {button = nav4, layers = "Main Group 4", child = Popup},
  }
}
NavMain:Navigate(1)
assertEqual(nav1.Boolean, true, "entry 1 button should be on")
assertEqual(nav2.Boolean, false, "entry 2 button should be off")
assertEqual(nav3.Boolean, false, "entry 3 button should be off")
assertEqual(nav4.Boolean, false, "entry 4 button should be off")
assertEqual(sub1.Boolean, false, "child nav button 1 should be off")
assertEqual(sub2.Boolean, false, "child nav button 2 should be off")
local hidden = {}
local shown = {}
for _, call in ipairs(calls) do
  if call.value == false then hidden[call.layer] = true end
  if call.value == true then shown[call.layer] = true end
end
assertEqual(shown["Main Group 1"], true, "Navigate should show target layer")
assertEqual(hidden["Main Group 2"], true, "Navigate should hide stale group 2")
assertEqual(hidden["Main Group 3"], true, "Navigate should hide stale group 3")
assertEqual(hidden["Main Group 4"], true, "Navigate should hide stale group 4")
assertEqual(hidden["3 Group 1"], true, "Navigate should hide stale child nav default layer")
assertEqual(hidden["3 Group 2"], true, "Navigate should hide stale child nav second layer")
assertEqual(hidden["Popup 4_1"], true, "Navigate should hide stale child popup layer")
assertEqual(Popup.isOpen, true, "parent cleanup should preserve popup open state")
assertEqual(stalePopupButton.Boolean, true, "parent cleanup should preserve popup button state")

local delayed1 = control(false)
local delayed2 = control(false)
local delayed3 = control(false)
local delayedNav = UCINodes.NavigationBar.New{
  page = "Page 1",
  entries = {
    {button = delayed1, layers = "Delayed 1"},
    {button = delayed2, layers = "Delayed 2"},
    {button = delayed3, layers = "Delayed 3", default = true},
  }
}
delayedNav:Initialize()
delayed1.EventHandler(delayed1)
assertEqual(delayedNav.selectedIndex, 3, "delayed programmatic false event should not reselect entry 1")

local commonNav = UCINodes.NavigationBar.New{
  page = "Common Page",
  commonLayers = "Nav Chrome",
  entries = {
    { button = control(), layers = "Common Nav A", default = true },
    { button = control(), layers = "Common Nav B" },
  }
}
commonNav:Initialize()
commonNav:Select(2)
assertTruthy(sawCall("Nav Chrome", true), "nav common layers should show with the bar")
assertEqual(commonNav.commonNode.isSelected, true, "nav common layers should remain selected while switching entries")
commonNav:Hide()
assertTruthy(sawCall("Nav Chrome", false), "nav common layers should hide with the bar")

local mainMenuBack = trigger()
local mainMenuHome = trigger()
local nestedMenuHome = trigger()
local mainMenuEntry = trigger()
local nestedMenuEntry = trigger()
local menuEvents = {}
local nestedMenu = UCINodes.Menu.New{
  layers = "Nested Menu",
  homeButton = nestedMenuHome,
  entries = {
    { button = nestedMenuEntry, layers = "Nested Content" },
  }
}
local mainMenu = UCINodes.Menu.New{
  page = "Menu Page",
  transition = { "menuIn", "menuOut" },
  layers = "Main Menu",
  commonLayers = "Menu Chrome",
  backButton = mainMenuBack,
  homeButton = mainMenuHome,
  entries = {
    { button = mainMenuEntry, layers = "Main Content", child = nestedMenu },
  }
}
mainMenu.EventHandler = function(event) table.insert(menuEvents, event) end
mainMenu:Initialize()
assertEqual(mainMenu.selectedIndex, nil, "main menu should initialize at its root")
assertEqual(calls[#calls].layer, "Main Menu", "main menu initialize should show root layers")
assertEqual(calls[#calls].value, true, "main menu initialize should show root layers")
assertEqual(mainMenu.commonNode.isSelected, false, "main menu common layers should stay hidden at its root")
mainMenuEntry.EventHandler(mainMenuEntry)
assertEqual(mainMenu.selectedIndex, 1, "main menu entry should select")
assertEqual(calls[#calls].layer, "Nested Menu", "main menu entry should show nested menu root")
assertEqual(mainMenu.commonNode.isSelected, true, "main menu common layers should remain visible after selection")
assertTruthy(sawCall("Menu Chrome", true), "main menu common layers should show with selected content")
assertEqual(menuEvents[1].type, "select", "main menu select event type")
assertEqual(menuEvents[1].index, 1, "main menu select event index")
nestedMenuEntry.EventHandler(nestedMenuEntry)
assertEqual(nestedMenu.selectedIndex, 1, "nested menu entry should select")
assertEqual(calls[#calls].layer, "Nested Content", "nested menu entry should show content")
mainMenuBack.EventHandler(mainMenuBack)
assertEqual(nestedMenu.selectedIndex, nil, "shared back should return deepest menu to its root")
assertEqual(mainMenu.selectedIndex, 1, "shared back should leave parent menu selected")
assertEqual(calls[#calls].layer, "Nested Menu", "back should restore nested menu root")
nestedMenuEntry.EventHandler(nestedMenuEntry)
nestedMenuHome.EventHandler(nestedMenuHome)
assertEqual(nestedMenu.selectedIndex, nil, "nested home should return only its own menu to root")
assertEqual(mainMenu.selectedIndex, 1, "nested home should not return to top-level root")
mainMenuHome.EventHandler(mainMenuHome)
assertEqual(mainMenu.selectedIndex, nil, "top-level home should return to top-level root")
assertEqual(calls[#calls].layer, "Main Menu", "top-level home should restore top-level root layers")
assertEqual(menuEvents[#menuEvents].type, "home", "top-level home event type")
assertEqual(mainMenu.commonNode.isSelected, false, "main menu common layers should hide on return to root")
mainMenu:Hide()
assertTruthy(sawCall("Menu Chrome", false), "main menu common layers should hide with the menu")

expectError("missing nav button", function()
  local nav = UCINodes.NavigationBar.New()
  nav:AddEntry{ layers = "Layer" }
end, "NavigationBar:AddEntry requires button")
expectError("missing main menu layers", function()
  UCINodes.Menu.New{ backButton = control() }
end, "Menu.New requires layers")
expectError("nested main menu back button", function()
    local childMenu = UCINodes.Menu.New{ layers = "Child Menu", backButton = trigger() }
  UCINodes.Menu.New{
    layers = "Parent Menu",
      backButton = trigger(),
      entries = { { button = trigger(), layers = "Parent Content", child = childMenu } },
  }
end, "nested Menu cannot define backButton")
expectError("bad nav layers", function()
  local nav = UCINodes.NavigationBar.New()
  nav:AddEntry{ button = control(), layers = 123 }
end, "layers must be a layer name string")
expectError("missing page", function()
  UCINodes.DefaultPage = nil
  local nav = UCINodes.NavigationBar.New()
  nav:AddEntry{ button = control(), layers = "Layer", default = true }
  nav:Initialize()
end, "No UCI page is set for layer")
expectError("bad target layer", function()
  UCINodes.Target.Layer(nil)
end, "Target.Layer requires a string layer name")

assertTruthy(true, "smoke complete")
print("smoke ok")
