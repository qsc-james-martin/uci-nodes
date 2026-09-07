`backButton`, `homeButton`, and entry `button` controls are event-only UCI
triggers; Menu does not read or change their Boolean or Value states.

`homeButton` is optional at every level. It returns to that menu's own root:
# UCINodes

UCINodes is a small Lua helper for Q-Sys UCI scripting. It keeps the common
"press this button, show this layer, hide the other layers" pattern in one
tidy place, so your script does not become a long list of repeated
`EventHandler` and `Uci.SetLayerVisibility` calls.

You describe the UI once:

- which button the user presses
- which UCI layer or layers should appear
- which entry should be selected first
- whether an entry owns a child nav bar or popup

UCINodes handles the layer visibility, button feedback, defaults,
transitions, nesting, and cleanup.

## The Smallest Useful Setup

Start by requiring the module and setting a default UCI page:

```lua
local UCINodes = require("UCI Nodes")
UCINodes.DefaultPage = "Page 1"
```

`DefaultPage` is the UCI page name passed to `Uci.SetLayerVisibility`. It is
the page name, not the UCI instance name.

Then create a nav bar:

```lua
local main = UCINodes.NavigationBar.New()

main:AddEntry{ button = Controls.NavHome, layers = "Home", default = true }
main:AddEntry{ button = Controls.NavAudio, layers = "Audio" }
main:AddEntry{ button = Controls.NavVideo, layers = "Video" }

main:Initialize()
```

That gives you one active section at a time. `Initialize()` clears stale
button/layer state first, then selects the default entry. Pressing
`Controls.NavAudio` hides `Home` and `Video`, shows `Audio`, and updates the
button states for you.

If one button should show more than one layer, use a table:

```lua
main:AddEntry{ button = Controls.NavAudio, layers = { "Audio", "Audio-Toolbar" } }
```

### Startup Rule

Build the whole tree first, then call one startup method on the root object.
You do not need to initialize every child nav bar or popup by hand.

If the root is a nav bar, use `Initialize()` to start on its default entry:

```lua
main:Initialize()
```

If you want to start on a specific entry instead, use `Select(index)`:

```lua
main:Select(2)
```


### A More Compact Nav Bar

If you prefer, you can put entries directly inside `NavigationBar.New()`:

```lua
local main = UCINodes.NavigationBar.New{
  page = "Page 1",
  transition = "none",
  entries = {
    { button = Controls.NavHome, layers = "Home", default = true },
    { button = Controls.NavAudio, layers = { "Audio", "Audio-Toolbar" } },
    { button = Controls.NavVideo, layers = "Video" },
  }
}

main:Initialize()
```

Constructor entries and `AddEntry()` entries use the same code path. Use
whichever style reads better for the script you are writing.

## Adding Transitions

Set a transition on the whole nav bar when every entry should move the same
way:

```lua
main.transition = { "left", "right" }
```

A string uses the same transition for showing and hiding:

```lua
main.transition = "fade"
```

One entry can override the bar transition:

```lua
main:AddEntry{ button = Controls.NavSettings, layers = "Settings", transition = "top" }
```

Transition tables can be positional or named:

```lua
main.transition = { "left", "right" }
main.transition = { on = "left", off = "right" }
```



## Child Nav Bars

A nav entry can own another nav bar. This is useful for tabs with sub-tabs or
a main menu with a smaller menu inside one section.

```lua
local audioSub = UCINodes.NavigationBar.New{
  entries = {
    { button = Controls.SubMic, layers = "Audio-Mics" },
    { button = Controls.SubPlayback, layers = "Audio-Playback", default = true },
  }
}

local main = UCINodes.NavigationBar.New{
  entries = {
    { button = Controls.NavHome, layers = "Home", default = true },
    { button = Controls.NavAudio, layers = "Audio", child = audioSub },
  }
}

main:Initialize()
```

When the user selects `NavAudio`, UCINodes shows `Audio` and shows
`audioSub`. The child bar selects its default entry the first time. If the
user later chooses another child entry, leaves Audio, and comes back, the
child bar restores where they left off.

When the user leaves the parent entry, UCINodes hides the parent layer and
anything the child nav bar was showing.

When a parent nav entry shows a child nav bar, the parent entry's transition is used for that show/hide.
After that, pressing child nav buttons uses the child nav's own transition
settings again.

## Main Menus

`Menu` is for drill-down UIs. Its `layers` hold the menu option buttons.
Selecting an entry hides those menu layers and shows the entry layers. A shared
back button returns one level at a time.

```lua
local advanced = UCINodes.Menu.New{
  layers = "Advanced Menu",
  homeButton = Controls.AdvancedHome,
  entries = {
    { button = Controls.Network, layers = "Network" },
    { button = Controls.Security, layers = "Security" },
  }
}

local mainMenu = UCINodes.Menu.New{
  page = "Page 1",
  layers = "Main Menu",
  backButton = Controls.Back,
  homeButton = Controls.Home,
  entries = {
    { button = Controls.Audio, layers = "Audio" },
    { button = Controls.Advanced, layers = "Advanced Shell", child = advanced },
  }
}

mainMenu:Initialize()
```

Only the top-level menu defines `backButton`. Nested main menus inherit it
through `child`, so pressing it returns from the deepest active menu first.

`homeButton` is optional at every level. It returns to that menu's own root:
`AdvancedHome` returns to `Advanced Menu`, while `Home` returns all the way to
`Main Menu`.

Main-menu callbacks receive one event table after a local state change:

```lua
mainMenu.EventHandler = function(event)
  if event.type == "select" then
    print("Selected", event.index)
  elseif event.type == "back" or event.type == "home" then
    print("Returned from", event.previousIndex)
  end
end
```

`event.type` is `"select"`, `"back"`, or `"home"`; `event.menu` is the menu
that changed. `event.index` is set for selections and `event.previousIndex` is
set for back/home actions.

## Popups

A `Popup` is for one on/off thing: a help overlay, settings panel, modal
shade, or any layer group that should toggle open and closed.

```lua
local info = UCINodes.Popup.New{
  button = Controls.InfoBtn,
  layers = "Info-Overlay"
}

info:Initialize()
```
As with Navigation Bars, `layers` can be a table of layers.

Pressing `Controls.InfoBtn` shows `Info-Overlay` and marks the button on.
Pressing it again hides the layer and marks the button off.

Popups can also be controlled entirely from code. Just leave out `button`:

```lua
local alert = UCINodes.Popup.New{ layers = "Alert" }

alert:Show()
alert:Hide()
```

Use `Initialize()` for a root-level popup that should start closed. Use
`Show()` if it should start open.

## Popups Owned By Nav Entries

A popup can be attached to a nav entry as a child:

```lua
local settingsPopup = UCINodes.Popup.New{
  button = Controls.SettingsBtn,
  layers = "Settings"
}

main:AddEntry{
  button = Controls.NavSettings,
  layers = "Settings-Backdrop",
  child = settingsPopup
}
```

The parent nav entry does not open or close the popup, and it does not change
the popup button. It only controls whether the popup's layers are allowed to
be visible inside that parent section.

So if the popup is closed, selecting `NavSettings` leaves it closed. If the
popup is open, leaving `NavSettings` hides its layers, but the popup's
open/closed state and button stay as they are. Coming back to `NavSettings`
lets the popup layers appear again.

If you would like the selecting of the parent nav entry to also open or close the popup,
use the nav bar's `EventHandler` and call the popup's `Show()` or `Hide()`
yourself.

## Nav Bars Inside Popups

You can put a nav bar inside a popup too. When the popup opens, the child nav
bar shows its default or last selected entry. When the popup closes, the
child nav bar is hidden too.

```lua
local toolsSub = UCINodes.NavigationBar.New{
  entries = {
    { button = Controls.ToolA, layers = "Tool-A", default = true },
    { button = Controls.ToolB, layers = "Tool-B" },
  }
}

local toolsPopup = UCINodes.Popup.New{
  button = Controls.ToolsBtn,
  layers = "Tools-Backdrop",
  child = toolsSub
}
```

You can nest these patterns as deeply as the UI needs: nav entry owns nav
bar, nav entry owns popup, popup owns nav bar, popup owns popup.

## Multiple UCI Pages

For one-page scripts, `UCINodes.DefaultPage` is usually enough:

```lua
UCINodes.DefaultPage = "Page 1"
```

For multi-page scripts, give each root nav bar or popup its own `page`:

```lua
local page1Main = UCINodes.NavigationBar.New{ page = "Page 1" }
local page2Main = UCINodes.NavigationBar.New{ page = "Page 2" }

page1Main:AddEntry{ button = Controls.P1Home, layers = "Home", default = true }
page2Main:AddEntry{ button = Controls.P2Home, layers = "Home", default = true }
```

Both entries can use a layer named `Home` because they point at different UCI
pages.

Children inherit the parent page unless they set their own.

An individual entry can also override the page:

```lua
main:AddEntry{ button = Controls.Special, layers = "Special", page = "Page 2" }
```

Inherited pages are kept separate from explicitly set `page` fields, so a
parent can provide a page without overwriting a child that has its own.

## Callbacks

UCINodes uses each control's own `EventHandler` internally. If you want to
run your own code when a nav bar or popup changes, assign an `EventHandler`
to the UCINodes object instead of replacing the button's handler.

For nav bars, the callback receives the active entry index:

```lua
main.EventHandler = function(index)
  print("Main nav selected", index)
end
```

If `allowButtonOff = true` lets the bar turn off, the callback receives
`nil` when no entry is active.

For popups, the callback receives a boolean:

```lua
info.EventHandler = function(open)
  print("Info popup open", open)
end
```

Parent-owned popup visibility changes do not fire the popup callback, because
the parent is only hiding/showing the popup's layers. It is not changing the
popup's open/closed state.

## A Larger Example

This example combines a main nav bar, a sub-nav under Main Group 3, a popup
owned by Main Group 4, and a master show/hide popup around the whole nav
area.

```lua
UCINodes = require('UCI Nodes')
UCINodes.Debug = false

-- Sub menu that becomes a child of Main Group 3.
NavSub = UCINodes.NavigationBar.New{
  transition = {'left','right'},
  entries = {
    {button = Controls.Nav_3_1, layers = '3 Group 1', default = true},
    {button = Controls.Nav_3_2, layers = '3 Group 2'},
  }
}

-- Popup owned by Main Group 4.
Popup = UCINodes.Popup.New{
  button = Controls.Popup4,
  layers = 'Popup 4_1',
  transition = 'top'
}

-- Main NavBar.
NavMain = UCINodes.NavigationBar.New{
  transition = 'none',
  entries = {
    {button = Controls.Nav_Main_1, layers = 'Main Group 1', default = true},
    {button = Controls.Nav_Main_2, layers = 'Main Group 2'},
    {button = Controls.Nav_Main_3, layers = 'Main Group 3', child = NavSub},
    {button = Controls.Nav_Main_4, layers = 'Main Group 4', child = Popup},
  }
}

-- Wrap the whole navigation area in a master show/hide popup.
MasterShowHide = UCINodes.Popup.New{
  page = 'Page 1',
  layers = 'NavBar',
  button = Controls.Master,
  child = NavMain,
}

MasterShowHide:Show()
```

Because `page = 'Page 1'` is set on the master popup, the child nav bars,
entries, and popup inherit that page.

## Reference

### NavigationBar.New

```lua
local nav = UCINodes.NavigationBar.New{
  name = "Main",
  page = "Page 1",
  allowButtonOff = false,
  transition = "fade",
  commonLayers = "Navigation Chrome",
  entries = {}
}
```

| Field | Type | Description |
|---|---|---|
| `name` | string | Optional debug label. |
| `page` | string | Optional UCI page for this nav bar's entries. |
| `allowButtonOff` | boolean | Defaults to `false`. Set `true` to allow the selected button to turn the bar off. |
| `transition` | string or table | Optional layer transition for entries in this bar. |
| `commonLayers` | string or list of strings | Optional layers shown whenever this nav bar is visible, including while entries change. |
| `entries` | list of entry tables | Optional entries to add during construction. |
| `EventHandler` | function | Optional callback assigned after creation. Receives the active index, or `nil` when no entry is active. |

### AddEntry

```lua
nav:AddEntry{
  button = Controls.NavHome,
  layers = "Home",
  default = true,
  child = nil,
  transition = "fade",
  page = "Page 1"
}
```

| Field | Type | Description |
|---|---|---|
| `button` | Control | Required. The Q-Sys control the user presses. |
| `layers` | string or list of strings | Required. The layer or layers to show when selected. |
| `default` | boolean | Optional first selected entry. If none is marked, the first entry is used. |
| `child` | NavigationBar or Popup | Optional child UI owned by this entry. |
| `transition` | string or table | Optional transition override for this entry. |
| `page` | string | Optional page override for this entry. |

### NavigationBar Methods

```lua
nav:Initialize()
nav:Select(2)
nav:Show()
nav:Hide()
nav:Reset()
```

Indexes are 1-based, in the order entries were added.

### Menu.New

```lua
local menu = UCINodes.Menu.New{
  name = "Settings",
  page = "Page 1",
  transition = "fade",
  layers = "Settings Menu",
  commonLayers = "Settings Chrome",
  backButton = Controls.Back,
  homeButton = Controls.Home,
  entries = {}
}
```

| Field | Type | Description |
|---|---|---|
| `name` | string | Optional debug label. |
| `page` | string | Optional UCI page for this menu. |
| `transition` | string or table | Optional layer transition for this menu and its entries. |
| `layers` | string or list of strings | Required root/menu layers containing the option buttons. |
| `commonLayers` | string or list of strings | Optional layers shown while one of this menu's entries is selected; hidden at the menu's root. |
| `backButton` | Control | Supply on the top-level menu only; nested menus inherit it. |
| `homeButton` | Control | Optional. Returns this menu to its own root layers. |
| `entries` | list of entry tables | Optional entries to add during construction. |
| `EventHandler` | function | Optional callback receiving a Menu event table. |

### Menu Methods

```lua
menu:Initialize()
menu:Select(2)
menu:Back()
menu:Home()
menu:Show()
menu:Hide()
menu:Reset()
```

`AddEntry()` uses the same `button`, `layers`, `child`, `transition`, and
`page` fields as `NavigationBar:AddEntry`.

### Popup.New

```lua
local popup = UCINodes.Popup.New{
  button = Controls.InfoBtn,
  layers = "Info-Overlay",
  child = nil,
  name = "Info",
  page = "Page 1",
  transition = "fade"
}
```

| Field | Type | Description |
|---|---|---|
| `button` | Control | Optional. Leave it out for a popup controlled only from code. |
| `layers` | string or list of strings | Required. The layer or layers shown while open. |
| `child` | NavigationBar or Popup | Optional child UI shown while this popup is open. |
| `name` | string | Optional debug label. |
| `page` | string | Optional UCI page for this popup's layers. |
| `transition` | string or table | Optional layer transition. |
| `EventHandler` | function | Optional callback assigned after creation. Receives `true` on open and `false` on close. |

### Popup Methods

```lua
popup:Initialize()
popup:Show()
popup:Hide()
popup:Reset()
```

## Button Feedback

UCINodes updates each button's selected state for you. When an entry or popup
is on, its button gets `.Boolean = true`. When it is off, the button gets
`.Boolean = false`.

If a control does not have `.Boolean`, UCINodes writes `.Value` instead.

## Friendly Errors

UCINodes tries to stop early with a clear message when something important is
missing. For example, if a layer is about to be shown but no UCI page has
been set, you will see a message like this:

```text
[UCINodes] No UCI page is set for layer 'Home'. Set UCINodes.DefaultPage = 'Page 1', or set page = 'Page 1' on the NavigationBar, Popup, AddEntry, or Target.Layer that owns this layer.
```

That means UCINodes did not know which UCI page to send to
`Uci.SetLayerVisibility`. Fix it by setting one of these:

```lua
UCINodes.DefaultPage = "Page 1"
local nav = UCINodes.NavigationBar.New{ page = "Page 1" }
local popup = UCINodes.Popup.New{ page = "Page 1", layers = "Help" }
```

You will also get UCINodes-flavored messages for common setup mistakes, like
forgetting the `button` field on a nav entry or giving `layers` something
other than a string or table of strings.