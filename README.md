# Live Share Plugin for Neovim

[![total lines](https://tokei.rs/b1/github/azratul/live-share.nvim)](https://github.com/XAMPPRocky/tokei)
![GitHub code size in bytes](https://img.shields.io/github/languages/code-size/azratul/live-share.nvim)
![GitHub repo size](https://img.shields.io/github/repo-size/azratul/live-share.nvim)

<a href="https://dotfyle.com/plugins/azratul/live-share.nvim">
	<img src="https://dotfyle.com/plugins/azratul/live-share.nvim/shield?style=flat-square" />
</a>

## Overview

This plugin creates a "Live Share" server in Neovim, similar to the Visual Studio Code Live Share functionality. It relies heavily on another plugin called [jbyuki/instant.nvim](https://github.com/jbyuki/instant.nvim) and reverse tunneling services like [serveo.net](https://serveo.net/) and [localhost.run](https://localhost.run/).

Note: This plugin is designed to work exclusively between Neovim instances and is not compatible with Visual Studio Code Live Share sessions.

### Requirements

- **SSH**: You must have SSH installed on your system. This is required for tunneling with services like serveo.net or localhost.run.
- **Tested Environments**: This plugin has been tested on **Linux** and **OpenBSD** distributions. It has not been tested or officially supported on **macOS** or **Windows**(Windows compatibility only with GitBash).

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

After starting the server, wait for the message indicating the URL has been copied. This URL is copied to the clipboard and should be shared with the client who wants to connect to the session.

Note: The port is optional for :LiveShareServer. For :LiveShareJoin, it's recommended not to change the port as serveo.net and localhost.run typically uses port 80 by default.

### Preview

![Live Share Preview](https://raw.githubusercontent.com/azratul/azratul/86d27acdbe36f0d4402a21e13b79fafbaec1ffc9/live-share.gif)

## Basic settings

These settings are optional. You don't need to change them unless you want to customize the plugin's behavior.


```lua
require("live-share").setup({
  port_internal = 9876, -- The local port to be used for the live share connection
  max_attempts = 20, -- Maximum number of attempts to read the URL from service(serveo.net or localhost.run), every 250 ms
  service_url = "/tmp/service.url", -- Path to the file where the URL from serveo.net will be stored
  service = "nokey@localhost.run", -- Service to use, options are serveo.net or localhost.run
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
    vim.g.instant_username = "your-username"
    require("live-share").setup({
      port_internal = 8765,
      max_attempts = 40, -- 10 seconds
      service = "serveo.net"
    })
  end
}
```

## Contributing

Feel free to open issues or submit pull requests if you find any bugs or have feature requests.


## Credits

[instant.nvim](https://github.com/jbyuki/instant.nvim) - No longer maintained.


## License

This project is licensed under the GPL-3.0 License.
# live-share.nvim
