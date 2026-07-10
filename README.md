# Slidev.nvim

[Slidev](https://sli.dev/) is a nodeJS tool to create slides using markdown and Vue components.

This plugin provides a simple way to run Slidev directly from Neovim to easily visualize your slides.

https://github.com/user-attachments/assets/59b366aa-2967-4eee-8d11-c25d09beff3d

The motivation behind this plugin was to be able to run Slidev with a common configuration (components, themes, etc.) on any file, not necessarily in the slidev_cwd folder, in a seamless way.

## Features

### User Commands

The plugin provides the following user commands:

- `:SlidevOpen <optional-path-to-slides-file>` - launches a Slidev server in the background, opening the provided slides file or the current buffer if no path is provided. To make the components and themes from your `slidev_cwd` folder available, the plugin symlinks the slides file into `slidev_cwd` and serves it from there (no changes are made to your presentation file). The server is automatically closed when the slides buffer is deleted or when Neovim quits.
- `:SlidevClose` - kills the Slidev server if it is running and removes the symlink previously created in `slidev_cwd`.
- `:SlidevBrowse` - Uses Telescope.nvim to browse for slidev presentations in your `slidev_cwd` folder.

### Lua API

The plugin exposes the following methods :

- `open(slideFilePath: string)` : full open flow invoked by `:SlidevOpen` — creates the symlink in `slidev_cwd`, launches the server, arms the auto-close autocommands, and runs the open hooks.
- `close()` : full close flow invoked by `:SlidevClose` — stops the server, removes the symlink, disarms the auto-close autocommands, and runs the close hooks.
- `openSlidevServer(slideFilePath: string)` : low-level helper that only launches the Slidev server in the background.
- `closeSlidevServer()` : low-level helper that only stops the Slidev server if it is running.
- `isSlidevRunning()` : utility function to check if the Slidev server is running.
- `browseSlidev()` : function invoked by the `:SlidevBrowse` command.
- `openSlidevPreviewInNewBrowserWindow()` : function that opens the Slidev preview in a new browser window, it's the default value of the `after_open_hook` configuration option.

## Installation

Using Lazy.nvim:

```lua
return {
    "nilsRagot/slidev.nvim",
    dependencies = {
        -- Used by `:SlidevBrowse` to browse the slidev_cwd folder. If you're not using it, you can still define your own `browseSlidev` function that browses the slidev_cwd folder using your favorite file picker.
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
    after_open_hook = require("slidev").openSlidevPreviewInNewBrowserWindow,
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
