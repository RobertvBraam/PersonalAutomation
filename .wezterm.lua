-- WezTerm Configuration
-- Migrated from Cmder (ConEmu) — CmderConfig.xml
-- Place at: C:\Users\Robert\.wezterm.lua
--   or at:  C:\Users\Robert\.config\wezterm\wezterm.lua

local wezterm = require 'wezterm'
local config = wezterm.config_builder()

-- =============================================================================
-- Appearance
-- =============================================================================

-- Monokai theme — matches the Cmder color palette exactly
config.color_scheme = 'Monokai (terminal.sexy)'

-- Font — Consolas 16pt (from Cmder)
config.font = wezterm.font('Consolas')
config.font_size = 16.0

-- Window opacity: 97% active, 93% inactive (FadeInactive was enabled in Cmder)
config.window_background_opacity = 0.97
config.inactive_pane_hsb = {
  saturation = 1.0,
  brightness = 0.93,
}

-- Window size: 120 columns x 30 rows (from Cmder ConWnd settings)
config.initial_cols = 120
config.initial_rows = 30

-- Window padding
config.window_padding = {
  left = 4,
  right = 4,
  top = 4,
  bottom = 4,
}

-- =============================================================================
-- Tab Bar
-- =============================================================================

-- Tab bar at bottom (TabsLocation=01 in Cmder)
config.tab_bar_at_bottom = true
config.use_fancy_tab_bar = false

-- Show tab index in title (Multi.UseNumbers=01 in Cmder)
config.show_tab_index_in_tab_bar = true

-- Max tab title length (TabLenMax=20 in Cmder)
config.tab_max_width = 20

-- =============================================================================
-- Shell Profiles (Cmder Tasks)
-- =============================================================================

config.default_prog = { 'pwsh.exe', '-NoLogo' }

config.launch_menu = {
  { label = 'PowerShell',       args = { 'pwsh.exe', '-NoLogo' } },
  { label = 'PowerShell (ISE)', args = { 'powershell.exe', '-NoLogo' } },
  { label = 'CMD',              args = { 'cmd.exe' } },
  { label = 'Git Bash',         args = { 'C:\\Program Files\\Git\\bin\\bash.exe', '-i', '-l' } },
  { label = 'WSL',              args = { 'wsl.exe' } },
}

-- =============================================================================
-- Keybindings
-- =============================================================================

config.keys = {
  { key = 'c', mods = 'CTRL', action = wezterm.action.CopyTo 'Clipboard' },
  { key = 'v', mods = 'CTRL', action = wezterm.action.PasteFrom 'Clipboard' },

  -- Ctrl+F: find (FindTextKey in Cmder)
  {
    key = 'f',
    mods = 'CTRL',
    action = wezterm.action.Search { CaseInSensitiveString = '' },
  },

  -- Ctrl+W: close current tab (Multi.Close in Cmder)
  {
    key = 'w',
    mods = 'CTRL',
    action = wezterm.action.CloseCurrentTab { confirm = true },
  },

  -- Alt+1-8: switch to tab by index (KeyMacro01-08 in Cmder)
  { key = '1', mods = 'ALT', action = wezterm.action.ActivateTab(0) },
  { key = '2', mods = 'ALT', action = wezterm.action.ActivateTab(1) },
  { key = '3', mods = 'ALT', action = wezterm.action.ActivateTab(2) },
  { key = '4', mods = 'ALT', action = wezterm.action.ActivateTab(3) },
  { key = '5', mods = 'ALT', action = wezterm.action.ActivateTab(4) },
  { key = '6', mods = 'ALT', action = wezterm.action.ActivateTab(5) },
  { key = '7', mods = 'ALT', action = wezterm.action.ActivateTab(6) },
  { key = '8', mods = 'ALT', action = wezterm.action.ActivateTab(7) },

  -- Alt+Enter: toggle fullscreen (ForcedFullScreen in Cmder)
  {
    key = 'Enter',
    mods = 'ALT',
    action = wezterm.action.ToggleFullScreen,
  },

  -- Ctrl+Shift+T: new tab
  {
    key = 't',
    mods = 'CTRL|SHIFT',
    action = wezterm.action.SpawnTab 'CurrentPaneDomain',
  },

  -- Keyboard text selection mode (replaces mouse-only selection for keyboard users)
  -- Press Ctrl+Shift+X to enter CopyMode, then use Shift+Arrow to select text,
  -- then Enter or y to copy, Escape to exit.
  {
    key = 'x',
    mods = 'CTRL|SHIFT',
    action = wezterm.action.ActivateCopyMode,
  },
}

-- =============================================================================
-- Mouse
-- =============================================================================

-- Shift+LeftClick drag: extend/start selection (standard Windows terminal behaviour)
-- This is the default in WezTerm — listed here for documentation.
-- Left click drag          → select text
-- Shift + left click       → extend selection
-- Double-click             → select word
-- Triple-click             → select line
-- After selecting: Ctrl+C  → copy (see keybinding above)

-- =============================================================================
-- Miscellaneous
-- =============================================================================

-- Suppress terminal bell (SuppressBells=01 in Cmder)
config.audible_bell = 'Disabled'

-- True colour support (TrueColorerSupport=01 in Cmder)
-- WezTerm supports true colour by default — no config needed.

return config
