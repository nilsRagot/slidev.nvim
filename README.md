# Slidev.nvim

[Slidev](https://sli.dev/) is a nodeJS tool to create slides using markdown and Vue components.

This plugin provides a simple way to run Slidev directly from Neovim to easily visualize your slides.

The motivation behind this plugin was to be able to run Slidev with a common configuration (components, themes, etc.) on any file, not necessarily in the slidev_cwd folder, in a seamless way.

## Features

### User Commands

The plugin provides the following user commands:

- `:SlidevOpen <optional-path-to-slides-file>` - launches a Slidev server on the background, opening the provided slides file or the current buffer if no path is provided. The server will be automatically killed when Neovim exits. To make the components and themes from your `slidev_cwd` folder available, the plugin will automatically add an `addon` key pointing to it in the frontmatter of the presentation.
- `:SlidevClose` - kills the Slidev server if it is running.
- `:SlidevBrowse` - Uses Telescope.nvim to browse for slidev presentations in your `slidev_cwd` folder.

### Lua API

The plugin exposes the following methods :

- `openSlidev` : function invoked by the `:SlidevOpen` command
- `closeSlidev` : function invoked by the `:SlidevClose` command
- `isSlidevRunning` : utility function to check if the Slidev server is running
- `browseSlidev` : function invoked by the `:SlidevBrowse` command
- `openSlidevPreviewInNewBrowserWindow` : function that opens the Slidev preview in a new browser window, it's the default value of the `after_open_hook` configuration option.

## Installation

Using Lazy.nvim:

```lua
return {
    "nilsRagot/slidev.nvim",
    dependencies = {
        -- Only the frontmatter parser is used from this plugin, so you can disable the plugin as long as it's installed.
        "obsidian-nvim/obsidian.nvim",
        -- Used to browse the slidev_cwd folder, if you're not using it, you can still define your own `browseSlidev` function that browses the slidev_cwd folder using your favorite file picker.
        "nvim-telescope/telescope.nvim",
    },
    opts = {
        slidev_cwd = "YOUR_SLIDEV_CWD_PATH", -- Mandatory, the path to your slidev project folder
    },
}
```

## Configuration

The configuration of Slidev.nvim allows you to:

1. attach before and after hooks to the `SlidevOpen` and `SlidevClose` commands.
2. customize the command used to launch the Slidev server.
3. customize the port on which the Slidev server will run.

Below are the default configuration values:

```lua
require("slidev").setup({
    slidev_cwd = nil, -- Must be set to the path of your slidev project folder, otherwise the plugin won't start.
    slidev_port = 3030, -- The port on which the Slidev server will run.
	slidev_command = { "npm", "run", "dev", "--", "--port", tostring(3030) },
    ---@type fun(opened_file_path: string) | fun() | nil
    before_open_hook = nil,
    ---@type fun(opened_file_path: string) | fun() | nil
    after_open_hook = M.openSlidevPreviewInNewBrowserWindow,
    ---@type fun() | nil
    before_close_hook = nil,
    ---@type fun() | nil
    after_close_hook = nil,
})
```

### Example usage of the hooks

```lua
require("slidev").setup({
    slidev_cwd = "YOUR_SLIDEV_CWD_PATH",
    after_open_hook = function(opened_file_path)
        -- launch OS commands to open the new browser window in a specific tiling window manager's workspace
        -- You can still access M.openSlidevPreviewInNewBrowserWindow() to open the preview in a new browser window, and then move it to the desired workspace using OS commands.
    end,
    after_close_hook = function()
        -- launch OS commands to close the preview browser window automatically
    end,
```
