UCINodes = require('UCI Nodes')
-- UCINodes.Debug = true -- turn on if you want debug print for all the UCI changes

-- Define Nodes from lowest level up.
-- 'Menu' Node shows some buttons, and when pressed hides itself and shows the target layers
SubMenu = UCINodes.Menu.New{ 
  layers = 'MainMenuItem 4',
  entries = {
    {layers = 'SubMenu4Item 1', button = Controls.SubMenu4_1}, -- layers can be an array of layers
    {layers = 'SubMenu4Item 2', button = Controls.SubMenu4_2},
  }
}

Popup3 = UCINodes.Popup.New{ -- shows layers when button is on, hides when off.
  layers = 'Popup 3', button = Controls.Popup_3
}

-- NavigationBar = mutually exclusive toggle buttons, layers shown as per selection
NavBar1 = UCINodes.NavigationBar.New{
  transition = {'right','top'},
  entries = {
    {layers = 'NavBar 1 1', button = Controls.Nav_1_1},
    {layers = 'NavBar 1 2', button = Controls.Nav_1_2},
    {layers = 'NavBar 1 3', button = Controls.Nav_1_3},
  }
}

SettingsNav = UCINodes.NavigationBar.New{
  entries = {
    {layers = 'Settings Nav 1', button = Controls.SettingsNav_1, transition = 'left'},
    {layers = 'Settings Nav 2', button = Controls.SettingsNav_2, transition = 'right'},
  }
}

PinPad = Component.New('PIN_Pad')

-- Top level: other nodes are children of this.
MainMenu = UCINodes.Menu.New{
  backButton = Controls.MainMenu_Back, -- go back a level, tracks across child nodes
  homeButton = Controls.MainMenu_Home, -- back to top level
  commonLayers = 'Main Menu Options', -- layers that should be shown alongside any menu selection
  transition = 'none', -- optional
  layers = 'Main Menu', -- layer for the menu itself, could be an array if multiple
  page = 'Page 1', 
  entries = {
    { layers = 'MainMenuItem 1', button = Controls.MainMenu_1, child = NavBar1,name = 'Nav Bar Demo'},
    { layers = 'MainMenuItem 2', button = Controls.MainMenu_2 },
    { layers = 'MainMenuItem 3', button = Controls.MainMenu_3, child = Popup3},
    { layers = 'MainMenuItem 4', button = Controls.MainMenu_4, child = SubMenu},
    { -- pin pad and settings
      layers = 'Settings',
      child = SettingsNav,
      button = Controls.MainMenu_Settings,
      access = {
        control = PinPad['pin.match.0'], -- boolean control - true = access granted.
        accessDeniedLayers = 'Pin Pad',
        logoutButton = PinPad.logout, -- monitor this button and leave secure layer when pressed
        autoLogout = true, -- trigger logout button when leaving with back or home
      }
    }
  }
}

MainMenu:Initialize()

MainMenu.EventHandler = function(event)
  if event.type == 'select' then 
    print(event.index)
    -- do something when they navigate to a certain section
  elseif event.type == 'home' then
    -- what you want to do 
  end
end