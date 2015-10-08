--[[
  IPyLua
  
  Copyright (c) 2015 Francisco Zamora-Martinez. Simplified, less deps and making
  it work.
  
  https://github.com/pakozm/IPyLua
  
  Original name and copyright: lua_ipython_kernel, 
  Copyright (c) 2013 Evan Wies.  All rights reserved.
  https://github.com/neomantra/lua_ipython_kernel

  Released under the MIT License, see the LICENSE file.
  
  usage: lua IPyLuaKernel.lua CONNECTION_FILENAME
--]]

if #arg ~= 1 then
  io.stderr:write(('usage: %s CONNECTION_FILENAME\n'):format(arg[0]))
  os.exit(-1)
end

local output_functions
local help_functions
local plot_functions
do
  -- Setting IPyLua in the registry allow to extend this implementation with
  -- specifications due to other Lua modules. For instance, APRIL-ANN uses this
  -- variable to configure how to encode images, plots, matrices, ... As well
  -- as introducing a sort of inline documentation.
  --
  -- To extend IPyLua output you need to stack into registry
  -- IPyLua.output_functions new functions which receive an object and return a
  -- data table as expected by IPython, that is, a data table with pairs of {
  -- [mime_type] = representation, ... } followed by the metadata table
  -- (optional).
  local reg = debug.getregistry()
  reg.IPyLua = reg.IPyLua or {}
  output_functions     = reg.IPyLua.output_functions or {}
  help_functions       = reg.IPyLua.help_functions or {}
  plot_functions       = reg.IPyLua.plot_functions or {}
  reg.IPyLua = {
    output_functions     = output_functions,
    help_functions       = help_functions,
    plot_functions       = plot_functions,
  }
end

local function lookup_function_for_object(obj, stack, ...)
  for i=#stack,1,-1 do
    local result = table.pack( pcall(stack[i], obj, ...) )
    if result[1] and result[2] then
      return table.unpack(result, 2)
    end
  end
end

local do_completion = require "IPyLua.rlcompleter".do_completion
local json = require "IPyLua.dkjson"
local zmq  = require 'lzmq'
local zmq_poller = require 'lzmq.poller'
local zthreads = require "lzmq.threads"
local z_NOBLOCK, z_POLLIN = zmq.NOBLOCK, zmq.POLL_IN
local z_RCVMORE, z_SNDMORE = zmq.RCVMORE, zmq.SNDMORE
local zassert = zmq.assert

local uuid = require 'IPyLua.uuid' -- TODO: randomseed or luasocket or something else

local HMAC = ''
local MSG_DELIM = '<IDS|MSG>'
local username = os.getenv('USER') or "unknown"

-- our kernel's state
local kernel = { execution_count=0 }

-- sockets description
local kernel_sockets

local function next_execution_count()
  kernel.execution_count = kernel.execution_count + 1
  return kernel.execution_count
end

local function current_execution_count()
  return kernel.execution_count
end

-- load connection object info from JSON file
do
  local connection_file = assert( io.open(arg[1]) )
  local connection_json = assert( connection_file:read('*a') )
  kernel.connection_obj = assert( json.decode(connection_json) )
  connection_file:close()
end

-------------------------------------------------------------------------------
-- IPython Message ("ipmsg") functions

local function ipmsg_to_table(parts)
  local msg = { ids = {}, blobs = {} }

  local i = 1
  while i <= #parts and parts[i] ~= MSG_DELIM do
    msg.ids[#msg.ids + 1] = parts[i]
    i = i + 1
  end
  i = i + 1
  msg.hmac          = parts[i] ; i = i + 1 
  msg.header        = parts[i] ; i = i + 1 
  msg.parent_header = parts[i] ; i = i + 1 
  msg.metadata      = parts[i] ; i = i + 1 
  msg.content       = parts[i] ; i = i + 1 

  while i <= #parts do
    msg.blobs[#msg.blobs + 1] = parts[i]
    i = i + 1
  end
  
  return msg
end

local session_id = uuid.new()
local function ipmsg_header(msg_type)
  return {
    msg_id = uuid.new(),   -- TODO: randomness warning: uuid.new()
    msg_type = msg_type,
    username = username,
    session = session_id,
    version = '5.0',
    date = os.date("%Y-%m-%dT%H:%M:%S"),
  }
end


local function ipmsg_send(sock, params)
  local parent  = params.parent or {header={}}
  local ids     = parent.ids or {}
  local hdr     = json.encode(assert( params.header ))
  local meta    = json.encode(params.meta or {})
  local content = json.encode(params.content or {})
  local blobs   = params.blob
  -- print("IPMSG_SEND")
  -- print("\tHEADER", hdr)
  -- print("\tCONTENT", content)
  --
  local hmac  = HMAC
  local p_hdr = json.encode(parent.header)
  --
  if type(ids) == 'table' then
    for _, v in ipairs(ids) do
      sock:send(v, z_SNDMORE)
    end
  else
    sock:send(ids, z_SNDMORE)
  end
  sock:send(MSG_DELIM, z_SNDMORE)
  sock:send(hmac,  z_SNDMORE)
  sock:send(hdr,   z_SNDMORE)
  sock:send(p_hdr, z_SNDMORE)
  sock:send(meta,  z_SNDMORE)
  if blobs then
    sock:send(content, z_SNDMORE)
    if type(blobs) == 'table' then
      for i, v in ipairs(blobs) do
        if i == #blobs then
          sock:send(v)
        else
          sock:send(v, z_SNDMORE)
        end
      end
    else
      sock:send(blobs)
    end
  else
    sock:send(content)
  end
end



-------------------------------------------------------------------------------
local stringfy = function(v,use_quotes)
  local v_str = tostring(v)
  if type(v) == "string" and use_quotes then v_str = ("%q"):format(v) end
  return not v_str:find("\n") and v_str or type(v)
end

-- environment where all code is executed
local new_environment
local env_session
local env_parent
local env_source
do
  local pyout = function(data, metadata)
    local header = ipmsg_header( 'pyout' )
    local content = {
      data = assert( data ),
      execution_count = current_execution_count(),
      metadata = metadata or {},
    }
    ipmsg_send(kernel.iopub_sock, {
                 session = env_session,
                 parent = env_parent,
                 header = header,
                 content = content
    })
  end
  
  local MAX = 10
  local basic_output_function = function(obj, MAX)
    local tt,footer = type(obj)
    if tt == "table" then
      local tbl = { "{" }
      do
        local max = false
        for k,v in ipairs(obj) do
          table.insert(tbl, ("\t[%d] = %s,"):format(k,stringfy(v,true)))
          if k >= MAX then max=true break end
        end
        if max then table.insert(tbl, "\t...") end
      end
      do
        local max = false
        local keys = {}
        for k,v in pairs(obj) do
          if type(k) ~= "number" then keys[#keys+1] = k end
        end
        table.sort(keys, function(a,b) return tostring(a) < tostring(b) end)
        for i,k in ipairs(keys) do
          table.insert(tbl, ("\t[%s] = %s,"):format(stringfy(k,true),
                                                    stringfy(obj[k],true)))
          if i >= MAX then max=true break end
        end
        if max then table.insert(tbl, "\t...") end
        footer = ("-- %s with %d array part, %d hash part"):format(tostring(obj), #obj, #keys)
      end
      table.insert(tbl, "}")
      table.insert(tbl, footer)
      local str = table.concat(tbl, "\n")
      return {
        ["text/plain"]=str.."\n",
        ["text/html"]=('<pre id="ipylua_static_code">%s</pre>'):format(str),
      }
    else
      local str = tostring(obj)
      return {
        ["text/plain"]=str.."\n",
        ["text/html"]=('<pre>%s</pre>'):format(str),
      }
    end
  end
  table.insert(output_functions, 1, basic_output_function)
  
  local basic_help_function = function(obj, verbosity)
    local html = {
      "<h3>IPyLua help</h3>",
      "<table style=\"border:0px\">",
      "<tr><th>Key</th><th>Value</th></tr>",
      ("<tr><td style=\"margin-right:4px\">LuaType</td><td>%s</td></tr>"):format(type(obj)),
    }

    local plain = {
      ("LuaType:   %s\n"):format(type(obj)),
    }
    
    if type(obj) == "function" then
      local definition = {}
      local info = debug.getinfo(obj)
      if info.what == "Lua" and info.source and info.linedefined then
        local source = info.source
        local first  = info.linedefined
        local last   = info.lastlinedefined
        local iterator
        if source:sub(1,1) == "@" then
          iterator = table.pack( io.lines(source:sub(2)) )
        else
          iterator = table.pack( source:gmatch("([^\r\n]+)") )
        end
        local k=1
        for line in table.unpack( iterator ) do
          if first == k then definition = line break end
          k=k+1
        end
      end
      
      if #definition == 0 then
        definition = {"... = funcname","("}
        if info.isvararg then
          table.insert(definition, "...")
        else
          local args = {}
          for i=1,info.nparams do table.insert(args, "arg"..i) end
          table.insert(definition, table.concat(args,","))
        end
        table.insert(definition, ")")
        definition = table.concat(definition)
      end

      table.insert(html, ("<tr><td style=\"margin-right:4px\">Def.</td><td>%s</td></tr>"):format(definition))
      table.insert(html, ("<tr><td style=\"margin-right:4px\">NumParams</td><td>%s</td></tr>"):format(info.isvararg and "..." or info.nparams))
      table.insert(html, ("<tr><td style=\"margin-right:4px\">What</td><td>%s</td></tr>"):format(info.what))
      table.insert(html, ("<tr><td style=\"margin-right:4px\">Nups</td><td>%s</td></tr>"):format(info.nups))

      table.insert(plain, ("Def.:      %s\n"):format(definition))
      table.insert(plain, ("NumParams: %s\n"):format(info.isvararg and "..." or info.nparams))
      table.insert(plain, ("What:      %s\n"):format(info.what))
      table.insert(plain, ("Nups:      %s\n"):format(info.nups))
      
    elseif type(obj) == "table" then
      table.insert(html, ("<tr><td style=\"margin-right:4px\">Length</td><td>%d</td></tr>"):format(#obj))
      table.insert(plain, ("Length:    %d\n"):format(#obj))
      
    else
      table.insert(html, ("<tr><td style=\"margin-right:4px\">ToString</td><td><pre>%s</pre></td></tr>"):format(tostring(obj)))
      table.insert(plain, ("ToString:  %s\n"):format(tostring(obj)))
    end

    table.insert(html, "</table>")
    local data = {
      ["text/html"]  = table.concat(html),
      ["text/plain"] = table.concat(plain),
    }
    return data
  end
  table.insert(help_functions, 1, basic_help_function)
  
  local function pcall_wrap(func,...)
    local ok,msg = xpcall(func,debug.traceback,...)
    if not ok then print(msg) return false end
    return true
  end
  
  local function draw(...)
    local result = {}
    local args = table.pack(...)
    for i=1,#args do
      local v = args[i]
      v.x = lookup_function_for_object( (assert(v.x, "Needs x field")),
                                        plot_functions )
      v.y = lookup_function_for_object( (assert(v.y, "Needs y field")),
                                        plot_functions )
      
    end
  end
  
  local function show_obj(obj, MAX)
    local data,metadata = lookup_function_for_object(obj, output_functions, MAX)
    if data then return pcall_wrap(pyout,data,metadata) end
    return false
  end

  local function help(obj, ...)
    local data,metadata = lookup_function_for_object(obj, help_functions, ...)
    if data then
      if pcall_wrap(pyout,data,metadata) then return end
    end
    pyout({ ["text/plain"] = "No documentation found" })
  end
  
  function new_environment()
    local env_G,env = {},{}
    for k,v in pairs(_G) do env_G[k] = v end
    env_G.args = nil
    env_G._G   = env_G
    env_G._ENV = env
    local env_G = setmetatable(env_G, { __index = _G })
    local env = setmetatable(env, { __index = env_G })
    
    env_G.pyout = function(data,metadata)
      metadata = metadata or {}
      assert(type(data) == "table", "Needs a table as first argument")
      assert(type(metadata) == "table", "Needs nil or table as second argument")
      pyout(data,metadata)
    end
    
    env_G.pyget = function(obj)
      return lookup_function_for_object(obj, output_functions, MAX)
    end
    
    env_G.pystr = function(...)
      local args = table.pack(...)
      for i=1,#args do args[i]=stringfy(args[i]) end
      local str = table.concat(args,"\t")
      pyout({ ["text/plain"] = str.."\n" })
    end
      
    env_G.show = function(...)
      if select('#',...) == 1 then
        if show_obj(..., MAX) then return end
      end
      local args = table.pack(...)
      local html = { "<div>" }
      for i=1,#args do
        if args[i] == "\n" then
          table.insert(html, '<br style="clear: left;" />')
        else
          local component
          local data = env_G.pyget(args[i])
          -- TODO: add more mime-types
          if data["text/html"] then
            component = data["text/html"]
          elseif data["image/png"] then
            component = ('<img src="data:image/png;base64,%s">'):format(data["image/png"])
          else
            component = ("<pre>%s</pre>"):format(data["text/plain"])
          end
          table.insert(html, ('<div style="float:left;margin:4px;">%s</div>'):format(component))
        end
        -- for text/plain output
        args[i]=stringfy(args[i])
      end
      table.insert(html, "</div>")
      local str = table.concat(args,"\t")
      pyout({
          ["text/plain"] = str.."\n",
          ["text/html"] = table.concat(html)
      })
    end
    
    env_G.print = function(...)
      local args = table.pack(...)
      for i=1,#args do args[i]=tostring(args[i]) end
      local str = table.concat(args,"\t")
      pyout({ ["text/plain"] = str.."\n" })
    end
    
    env_G.io.write = function(...)
      local args = table.pack(...)
      for i=1,#args do args[i]=tostring(args[i]) end
      local str = table.concat(table.pack(...))
      pyout({ ["text/plain"] = str.."\n" })
    end
    
    env_G.vars = function()
      show_obj(env, math.huge)
    end

    env_G.help = help
    
    env_G["%quickref"] = function()
      local tbl = {
        "?            -> Introduction and overview.",
        "%quickref    -> This guide.",
        "help(object) -> Help about a given object.",
        "object?      -> Help about a given object.",
        "show(...)    -> Show using a list of objects by columns (fancy output).",
        "pyout(data)  -> Allow low-level print to IPython",
        "vars()       -> Shows all global variables declared by the user.",
      }
      show_obj(table.concat(tbl,"\n"))
    end

    env_G["%guiref"] = function()
      local tbl = {
        "GUI reference not written.",
      }
    end
    
    return env,env_G
  end
end
local env,env_G = new_environment()

local function add_return(code)
  return code
end

-------------------------------------------------------------------------------

local function send_execute_reply(sock, parent, count, status, err)
  local session = parent.header.session
  local header = ipmsg_header( 'execute_reply' )
  local content = {
    status = status or 'ok',
    execution_count = count,
    payload = {},
    user_expresions = {},
  }
  if status=="error" then
    content.ename = err
    content.evalue = ''
    content.traceback = {err}
  end
  ipmsg_send(sock, {
               session = session,
               parent = parent,
               header = header,
               content = content,
  })
end

local function send_busy_message(sock, parent)
  local session = parent.header.session
  local header  = ipmsg_header( 'status' )
  local content = { execution_state='busy' }
  ipmsg_send(sock, {
               session = session,
               parent = parent,
               header = header,
               content = content,
  })
end

local function send_idle_message(sock, parent)
  local session = parent.header.session
  local header  = ipmsg_header( 'status' )
  local content = { execution_state='idle' }
  ipmsg_send(sock, {
               session = session,
               parent = parent,
               header = header,
               content = content,
  })
end

local function execute_code(parent)
  local session = parent.header.session
  local code = parent.content.code
  if not code or #code==0 then return end
  env_parent  = parent
  env_session = session
  env_source  = code
  if code:find("%?+\n?$") or code:find("^%?+") then
    local x = load("return "..code:match("^%?*([^?\n]*)%?*\n?$"), nil, nil, env)
    if x then x = x() end
    env.help(x)
    return true
  else
    if code:sub(1,1) == "%" then
      code = ("_G[%q]()"):format(code:gsub("\n",""))
    end
    if code:sub(1,1) == "=" then code = "return " .. code:sub(2) end
    local ok,err = true,nil
    -- TODO: reimplement it to be Lua 5.1 compatible 
    local f,msg = load(code, nil, nil, env)
    if f then
      local out = table.pack(xpcall(f, debug.traceback))
      if not out[1] then
        ok,err = nil,out[2]
      elseif #out > 1 then
        env.show(table.unpack(out, 2))
      end
    else
      ok,err = nil,msg
    end
    collectgarbage("collect")
    return ok,err
  end
end

local function send_pyin_message(sock, parent, count)
  local session = parent.header.session
  local header  = ipmsg_header( 'pyin' )
  local content = { code=parent.content.code,
                    execution_count = count, }
  ipmsg_send(sock, {
               session = session,
               parent = parent,
               header = header,
               content = content,
  }) 
end

local function send_pyerr_message(sock, parent, count, err)
  local session = parent.header.session
  local header  = ipmsg_header( 'pyerr' )
  local content = { ename = err, evalue = '', traceback = {err},
                    execution_count = count, }
  ipmsg_send(sock, {
               session = session,
               parent = parent,
               header = header,
               content = content,
  }) 
end

-- implemented routes
local shell_routes = {
  kernel_info_request = function(sock, parent)
    local session = parent.header.session
    local header = ipmsg_header( 'kernel_info_reply' )
    local major,minor = _VERSION:match("(%d+)%.(%d+)")
    local content = {
      protocol_version = {4, 0},
      language_version = {tonumber(major), tonumber(minor)},
      language = 'lua',
    }
    ipmsg_send(sock, {
                 session=session,
                 parent=parent,
                 header=header,
                 content=content,
    })
  end,

  execute_request = function(sock, parent)
    parent.content = json.decode(parent.content)
    local count
    if parent.content.store_history then
      count = next_execution_count()
    else
      count = current_execution_count()
    end
    --
    send_busy_message(kernel.iopub_sock, parent)
    
    local ok,err = execute_code(parent)
    send_pyin_message(kernel.iopub_sock, parent, count)
    if ok then
      send_execute_reply(sock, parent, count)
    else
      err = err or "Unknown error"
      send_pyerr_message(kernel.iopub_sock, parent, count, err)
      send_execute_reply(sock, parent, count, "error", err)
    end
    send_idle_message(kernel.iopub_sock, parent)
  end,

  shutdown_request = function(sock, parent)
    parent.content = json.decode(parent.content)
    --
    send_busy_message(sock, parent)
    local session = parent.header.session
    local header  = ipmsg_header( 'shutdown_reply' )
    local content = parent.content
    ipmsg_send(sock, {
                 session=session,
                 parent=parent,
                 header=header,
                 content=content,
    })
    send_idle_message(kernel.iopub_sock, parent)
    for _, v in ipairs(kernel_sockets) do
      kernel[v.name]:close()
    end
    os.exit()
  end,

  complete_request = function(sock, parent)
    parent.content = json.decode(parent.content)
    local ok,content = pcall(do_completion,
                             parent.content.code or parent.content.line,
                             parent.content.text,
                             parent.content.cursor_pos,
                             env_G, env, _ENV)
    if not ok then
      print("Error at do_completion")
      print(content)
    else
      local session = parent.header.session
      local header = ipmsg_header( 'complete_reply' )
      ipmsg_send(sock, {
                   session=session,
                   parent=parent,
                   header=header,
                 content=content,
      })
    end
  end,

  history_request = function(sock, parent)
    print("history_requested but not implemented")
  end,

  comm_open = function(sock, parent)
    print("comm_open but not implemented")
  end,
  
  object_info_request = function(sock, parent)
    parent.content = json.decode(parent.content)
    local session = parent.header.session
    local header = ipmsg_header( 'object_info_reply' )
    local oname = parent.content.oname
    -- TODO: handle detail_level
    local len
    local x = load("return "..oname, nil, nil, env)
    if x then
      ok,x = pcall(x)
      if not ok then x = nil end
      ok,len = pcall(function() return #x end)
      if not ok then len = nil end
    end
    local definition
    local argspec
    if type(x) == "function" then
      local info = debug.getinfo(x)
      if info.what == "Lua" and info.source and info.linedefined then
        local source = info.source
        local first  = info.linedefined
        local iterator
        if source:sub(1,1) == "@" then
          iterator = table.pack( io.lines(source:sub(2)) )
        else
          iterator = table.pack( source:gmatch("([^\r\n]+)") )
        end
        local k=1
        for line in table.unpack( iterator ) do
          if first == k then definition = {line} break end
          k=k+1
        end
      else
        definition = {"... = ",oname,"("}
        
        argspec = { args = {} }
        if info.isvararg then
          argspec.args[1] = "..."
          table.insert(definition, "...")
        else
          local args = {}
          for i=1,info.nparams do
            args[i] = "arg"..i
          end
          table.insert(definition, table.concat(args,","))
        end
        table.insert(definition, ")")
      end
    end
    local content = {
      oname = oname,
      found = (x~=nil),
      ismagic = false,
      isalias = false,
      namespace = 'global',
      type_name = type(x),
      string_form = stringfy(x),
      length = len,
      argspec = argspec,
      definition = definition and table.concat(definition) or nil,
    }
    if x then
      local data = lookup_function_for_object(x, help_functions)
      if data then content.docstring = data["text/plain"] end
    end
    ipmsg_send(sock, {
                 session=session,
                 parent=parent,
                 header=header,
                 content=content,
    })
  end,  
}

do
  local function dummy_function() end
  setmetatable(shell_routes, {
                 __index = function(self, key)
                   print(key)
                   return rawget(self,key) or dummy_function
                 end,
  })
end

-------------------------------------------------------------------------------
-- ZMQ Read Handlers

local function on_hb_read( sock )

end

local function on_control_read( sock )
  local data = zassert( sock:recv(zmq.NOBLOCK) )
  -- TODO: handle 'timeout' error
end

local function on_stdin_read( sock )
  local data = zassert( sock:recv(zmq.NOBLOCK) )
  -- TODO: handle 'timeout' error
end

local function on_shell_read( sock )
  -- TODO: error handling
  local ipmsg = zassert( sock:recv_all() )  
  local msg = ipmsg_to_table(ipmsg)
  -- for k, v in pairs(msg) do print(k,v) end
  msg.header = json.decode(msg.header)
  -- print("REQUEST FOR KEY", msg.header.msg_type)
  shell_routes[msg.header.msg_type](sock, msg)
end

-------------------------------------------------------------------------------
-- SETUP

kernel_sockets = {
  -- { name = 'heartbeat_sock', sock_type = zmq.REP,    port = 'hb',      handler = on_hb_read },
  { name = 'control_sock',   sock_type = zmq.ROUTER, port = 'control', handler = on_control_read },
  { name = 'stdin_sock',     sock_type = zmq.ROUTER, port = 'stdin',   handler = on_stdin_read },
  { name = 'shell_sock',     sock_type = zmq.ROUTER, port = 'shell',   handler = on_shell_read },
  { name = 'iopub_sock',     sock_type = zmq.PUB,    port = 'iopub',   handler = on_iopub_read },
}

local z_ctx = zmq.context()
local z_poller = zmq_poller(#kernel_sockets)
for _, v in ipairs(kernel_sockets) do
  if v.name ~= "heartbeat_sock" then
    -- TODO: error handling in here
    local sock = zassert( z_ctx:socket(v.sock_type) )

    local conn_obj = kernel.connection_obj
    local addr = string.format('%s://%s:%s',
                               conn_obj.transport,
                               conn_obj.ip,
                               conn_obj[v.port..'_port'])

    zassert( sock:bind(addr) )
    
    if v.name ~= 'iopub_sock' then -- avoid polling from iopub
      z_poller:add(sock, zmq.POLLIN, v.handler)
    end

    kernel[v.name] = sock
  end
end

-- heartbeat is controlled through an independent thread, allowing the main
-- thread to manage interactive commands given by the IPython
local thread = zthreads.run(z_ctx,
                            function(conn_obj)
                              local zmq   = require "lzmq"
                              local z_ctx = require"lzmq.threads".get_parent_ctx()
                              local zassert = zmq.assert
                              local v = {
                                name = 'heartbeat_sock',
                                sock_type = zmq.REP,
                                port = 'hb',
                              }
                              local sock = zassert( z_ctx:socket(v.sock_type) )
                              local addr = string.format('%s://%s:%s',
                                                         conn_obj.transport,
                                                         conn_obj.ip,
                                                         conn_obj[v.port..'_port'])
                              zassert( sock:bind(addr) )
                              while true do
                                -- read the data and send a pong
                                local data,msg = sock:recv()
                                if msg ~= "timeout" then
                                  if not data then break end
                                  -- TODO: handle 'timeout' error
                                  sock:send('pong')
                                end
                              end
                            end,
                            kernel.connection_obj)
thread:start(true,true)

-------------------------------------------------------------------------------
-- POLL then SHUTDOWN

--print("Starting poll")
z_poller:start()

for _, v in ipairs(kernel_sockets) do
  kernel[v.name]:close()
end
z_ctx:term()
thread:join()
