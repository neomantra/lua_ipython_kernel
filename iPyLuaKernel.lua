--[[
  iPyLua
  
  Copyright (c) 2015 Francisco Zamora-Martinez. Simplified, less deps and making
  it work.

  Original name and copyright: lua_ipython_kernel 
  Copyright (c) 2013 Evan Wies.  All rights reserved.


  Released under the MIT License, see the LICENSE file.

  https://github.com/neomantra/lua_ipython_kernel

  usage: lua ipython_kernel.lua `connection_file`
--]]

if #arg ~= 1 then
  io.stderr:write(('usage: %s CONNECTION_FILENAME\n'):format(arg[0]))
  os.exit(-1)
end

do
  -- Setting iPyLua in the registry allow to extend this implementation with
  -- specifications due to other Lua modules. For instance, APRIL-ANN uses this
  -- variable to configure how to encode images, plots, matrices, ... As well
  -- as introducing a sort of inline documentation.
  local reg = debug.getregistry()
  reg.iPyLua = true
end

local json = require "iPyLua.dkjson"

-- our kernel's state
local kernel = { execution_count=0 }

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

local HMAC = ''

local zmq = require 'lzmq'
local zmq_poller = require 'lzmq.poller'
local z_NOBLOCK, z_POLLIN = zmq.NOBLOCK, zmq.POLL_IN
local z_RCVMORE, z_SNDMORE = zmq.RCVMORE, zmq.SNDMORE
local zassert = zmq.assert

local uuid = require 'iPyLua.uuid' -- TODO: randomseed or luasocket or something else

local MSG_DELIM = '<IDS|MSG>'
local username = os.getenv('USER') or "unknown"

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

-- environment where all code is executed
local env_session
local env_parent
local env_source
local function new_environment()
  local function pubstr(str)
    local header = ipmsg_header( 'pyout' )
    local content = {
      data = { ['text/plain'] = str },
      execution_count = current_execution_count(),
      metadata = {},
    }
    ipmsg_send(kernel.iopub_sock, {
                 session = env_session,
                 parent = env_parent,
                 header = header,
                 content = content
    })
  end

  local env_G = {} for k,v in pairs(_G) do env_G[k] = v end
  env_G.args = nil
  env_G._G = nil
  local env = setmetatable({}, { __index = env_G })
  env._G = env
  env._ENV = env
  
  env_G.print = function(...)
    local str = table.concat(table.pack(...),"\t")
    pubstr(str)
  end

  env_G.io.write = function(...)
    local str = table.concat(table.pack(...))
    pubstr(str)
  end
  return env
end
local env = new_environment()

local function add_return(code)
  return code
end

-------------------------------------------------------------------------------

local function send_execute_reply(sock, parent, count)
  local session = parent.header.session
  local header = ipmsg_header( 'execute_reply' )
  local content = {
    status = 'ok',
    execution_count = count,
    payload = {},
    user_expresions = {},
  }
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
  env_parent  = parent
  env_session = session
  env_source  = code
  local f,msg = load(add_return(code), nil, nil, env)
  local out = f()
  if out then
    -- TODO: show output of the function
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

-- implemented routes
local shell_routes = {
  kernel_info_request = function(sock, parent)
    local session = parent.header.session
    local header = ipmsg_header( 'kernel_info_reply' )
    local major,minor = _VERSION:match("(%d+)%.(%d+)")
    local content = {
      protocol_version = {4, 0},
      language_version = {tonumber(major), tonumber(minor)},
      language = 'iPyLua',
    }
    ipmsg_send(sock, {
                 session=session,
                 parent=parent,
                 header=header,
                 content=content,
    })
  end,

  execute_request = function(sock, parent)
    local count = next_execution_count()
    parent.content = json.decode(parent.content)
    --
    send_busy_message(kernel.iopub_sock, parent)
    
    local out = execute_code(parent)
    send_pyin_message(kernel.iopub_sock, parent, count)
    
    send_execute_reply(sock, parent, count)
    send_idle_message(kernel.iopub_sock, parent)
  end,

  shutdown_request = function(sock, parent)
    print("SHUTDOWN")
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
}

do
  local function dummy_function() end
  setmetatable(shell_routes, {
                 __index = function(self, key)
                   return rawget(self,key) or dummy_function
                 end,
  })
end

-------------------------------------------------------------------------------
-- ZMQ Read Handlers

local function on_hb_read( sock )
  -- read the data and send a pong
  local data = zassert( sock:recv(zmq.NOBLOCK) )
  -- TODO: handle 'timeout' error
  sock:send('pong')
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

local kernel_sockets = {
  { name = 'heartbeat_sock', sock_type = zmq.REP,    port = 'hb',      handler = on_hb_read },
  { name = 'control_sock',   sock_type = zmq.ROUTER, port = 'control', handler = on_control_read },
  { name = 'stdin_sock',     sock_type = zmq.ROUTER, port = 'stdin',   handler = on_stdin_read },
  { name = 'shell_sock',     sock_type = zmq.ROUTER, port = 'shell',   handler = on_shell_read },
  { name = 'iopub_sock',     sock_type = zmq.PUB,    port = 'iopub',   handler = on_iopub_read },
}

local z_ctx = zmq.context()
local z_poller = zmq_poller(#kernel_sockets)
for _, v in ipairs(kernel_sockets) do
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

-------------------------------------------------------------------------------
-- POLL then SHUTDOWN

--print("Starting poll")
z_poller:start()

for _, v in ipairs(kernel_sockets) do
  kernel[v.name]:close()
end
z_ctx:term()
