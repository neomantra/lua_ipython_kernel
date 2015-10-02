# Lua IPython Kernel

This is a kernel to support Lua with [IPython](http://ipython.org).  It is pure Lua and should work with both Lua and LuaJIT.


## Requirements

The following Lua libraries are required:

 * [zeromq](http://zeromq.org/bindings:lua)
 * [dkjson](http://dkolf.de/src/dkjson-lua.fsl/home)
 * [uuid](https://github.com/Tieske/uuid)

Here's how to install via [LuaRocks](http://luarocks.org/):
    
```
# You need zeromq... on OSX I use Homebrew:
# brew install zeromq
# On Ubuntu:
# sudo apt-get install libzmq-dev

# The LuaRocks
sudo luarocks install https://raw.github.com/Neopallium/lua-zmq/master/rockspecs/lua-zmq-scm-1.rockspec
sudo luarocks install dkjson
sudo luarocks install uuid
```

Of course you also need to [install IPython](http://ipython.org/install.html)... 


## Installation

The installation process is janky right now.

 * Install the Requirements above

 * Create a profile with IPython

```
ipython profile create lua
```

 * Modify the profile's `ipython_config.py` to use lua_ipython_kernel.  This
 will be at either `~/.config/ipython/profile_lua/ipython_config.py` or
 `~/.ipython/profile_lua/ipython_config.py`:

```
# Configuration file for ipython.
   
c = get_config()
   
c.KernelManager.kernel_cmd = [
    "luajit",              # select your Lua interpreter here
    "ipython_kernel.lua",  # probably need full path
    "{connection_file}"
]
   
# Disable authentication.
c.Session.key = b''
c.Session.keyfile = b''
```

 * Invoke IPython with this Lua kernel:

```
ipython console --profile lua
# or 
ipython notebook --profile lua
```

## TODO

 * Get the execute side of things working
 * Go through all the TODOs in the source file
 * Make a luarock spec
 * Make an installer
 * HMAC 


## Acknowledgements

Thanks to Andrew Gibiansky for his [IHaskell article](http://andrew.gibiansky.com/blog/ipython/ipython-kernels/) that inspired this.  

Thanks to the makers of the dependencies of this library, who made this pretty easy to create: [Robert Jakabosky](https://github.com/Neopallium), [David Kolf](http://dkolf.de/src/dkjson-lua.fsl/home), and [Thijs Schreijer](https://github.com/Tieske).  

And of course thanks to the [IPython folks ](http://ipython.org/citing.html).


## LICENSE

**lua_ipython_kernel** is distributed under the [MIT License](http://opensource.org/licenses/mit-license.php).

> lua_ipython_kernel
> 
> Copyright (c) 2013 Evan Wies.  All rights reserved.
> 
> Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:
> 
> The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.
> 
> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
