# Live Share Plugin for Neovim

## Overview

This plugin creates a "Live Share" server in Neovim, similar to the Visual Studio Code Live Share functionality. It relies heavily on another plugin called [jbyuki/instant.nvim](https://github.com/jbyuki/instant.nvim) and [serveo.net](https://serveo.net/).

Note: This plugin is designed to work exclusively between Neovim instances and is not compatible with Visual Studio Code Live Share sessions.

## Installation

### Using Packer

```lua
use {
  'azratul/live-share.nvim',
  requires = {'jbyuki/instant.nvim'}
}
```

### Using Vim-Plug

```vim
Plug 'azratul/live-share.nvim'
Plug 'jbyuki/instant.nvim'
```

### Using Lazy

```lua
{
  "azratul/live-share.nvim",
  dependencies = {
    "jbyuki/instant.nvim",
  }
}
```

## Usage

### Commands

- `:LiveShareServer [port]`: Start a Live Share server.
    Example: `:LiveShareServer 9876`

- `:LiveShareJoin [url] [port]`: Join a Live Share session.
    Example: `:LiveShareJoin abc.serveo.net 80`

Note: The port is optional for :LiveShareServer. For :LiveShareJoin, it's recommended not to change the port as serveo.net typically uses port 80 by default.

## Basic settings

These settings are optional. You don't need to change them unless you want to customize the plugin's behavior.


```lua
require("live-share").setup({
  port_internal = 9876, -- The local port to be used for the live share connection
  max_attempts = 20, -- Maximum number of attempts to read the URL from serveo.net, every 250 ms
  serveo_url = "/tmp/serveo.url", -- Path to the file where the URL from serveo.net will be stored
  serveo_pid = "/tmp/serveo.pid" -- Path to the file where the PID of the SSH process will be stored
})
```

### Lazy Example

```lua
{
  "azratul/live-share.nvim",
  dependencies = {
    "jbyuki/instant.nvim",
  },
  config = function()
    require("live-share").setup({
      port_internal = 8765,
      max_attempts = 40 -- 10 seconds
    })
  end
}
```

## Contributing

Feel free to open issues or submit pull requests if you find any bugs or have feature requests.


## License

This project is licensed under the GPL-3.0 License.
# live-share.nvim
