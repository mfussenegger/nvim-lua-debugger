# UNMAINTAINED

This was a prototype that never made it into a workable state.
There is now [lua-debug.nvim](https://github.com/jbyuki/lua-debug.nvim) which can be used instead.


# Neovim Lua Debug Adapter


`nvim-lua-debugger` is a Debug Adapter that allows debugging lua plugins written for Neovim.
It is the server component in the [Debug Adapter Protocol][1].

To use the debugger you'll need a client implementing the Debug Adapter Protocol:

- [vimspector][2]
- [nvim-dap][3]


## MVP TODO

- [ ] initialization parts of the protocol
- [ ] setting breakpoints
- [ ] stopped event
- [ ] threads request handling
- [ ] stackTrace request handling
- [ ] scopes request handling
- [ ] variables request handling


## Installation

- Requires [Neovim HEAD/nightly][4]
- nvim-lua-debugger is a plugin. Install it like any other Vim plugin.
- Call `:packadd nvim-lua-debugger` if you install `nvim-lua-debugger` to `'packpath'`.


## Usage with nvim-dap

Add a new adapter entry:

```lua
local dap = require('dap')
dap.adapters.neovim = function(callback)
  local server = require('lua_debugger').launch()
  callback({ type = 'server'; host = server.host; port = server.port; })
end
```

Add a new configuration entry:

```lua
local dap = require('dap')
dap.configurations.lua = {
  {
    type = 'neovim';
    request = 'attach';
    name = "Attach to running neovim instance";
  },
}
```

Then edit a ``lua`` file within Neovim and call `:lua require'dap'.continue()` to start debugging.


[1]: https://microsoft.github.io/debug-adapter-protocol/overview
[2]: https://github.com/puremourning/vimspector
[3]: https://github.com/mfussenegger/nvim-dap
[4]: https://github.com/neovim/neovim/releases/tag/nightly
