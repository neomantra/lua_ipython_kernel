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

local json = require "iPyLua.dkjson"

-- our kernel's state
local kernel = {}

-- load connection object info from JSON file
do
  local connection_file = assert( io.open(arg[1]) )
  local connection_json = assert( connection_file:read('*a') )
  kernel.connection_obj = assert( json.decode(connection_json) )
  connection_file:close()
end

local zmq = require 'lzmq'
local zmq_poller = require 'lzmq.poller'
local z_NOBLOCK, z_POLLIN = zmq.NOBLOCK, zmq.POLL_IN
local z_RCVMORE, z_SNDMORE = zmq.RCVMORE, zmq.SNDMORE

local uuid = require 'iPyLua.uuid' -- TODO: randomseed or luasocket or something else

local MSG_DELIM = '<IDS|MSG>'
local username = os.getenv('USER') or "unknown"

-------------------------------------------------------------------------------
-- IPython Message ("ipmsg") functions

local function ipmsg_to_table(parts)
  local ipmsg = { ids = {}, blobs = {} }

  local i = 1
  while i <= #parts and parts[i] ~= MSG_DELIM do
    ipmsg.ids[#ipmsg.ids + 1] = parts[i]
    i = i + 1
  end
  i = i + 1
  ipmsg.hmac          = parts[i] ; i = i + 1 
  ipmsg.header        = parts[i] ; i = i + 1 
  ipmsg.parent_header = parts[i] ; i = i + 1 
  ipmsg.metadata      = parts[i] ; i = i + 1 
  ipmsg.content       = parts[i] ; i = i + 1 

  while i <= #parts do
    ipmsg.blobs[#ipmsg.blobs + 1] = parts[i]
    i = i + 1
  end
  
  return ipmsg
end


local function ipmsg_header(session, msg_type)
  return json.encode({
      msg_id = uuid.new(),   -- TODO: randomness warning: uuid.new()
      username = username,
      session = session,
      msg_type = msg_type,
      version = '5.0',
  })
end


local function ipmsg_send(sock, ids, hmac, hdr, p_hdr, meta, content, blobs)
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
local env_header
local env_source
local function pubstr(str)
  print("PUBPUB", str)
  local header = ipmsg_header( env_session, 'display_data' )
  local content = json.encode{
    source = env_source,
    data = { ['text/plain'] = str },
    -- metadata = { ['text/plain'] = {} },
  }
  print("CONTENT", content)
  ipmsg_send(kernel.iopub_sock, env_session, '', header, env_header, '{}', content)
end
local env = {}
for k,v in pairs(_G) do env[k] = v end
env.args = nil
env.print = function(...)
  local str = table.concat(table.pack(...),"\t")
  pubstr(str)
end
env.io.write = function(...)
  local str = table.concat(table.pack(...))
  pubstring(str)
end

local function add_return(code)
  return code
end

-------------------------------------------------------------------------------
-- ZMQ Read Handlers

local function on_hb_read( sock )
  -- read the data and send a pong
  local data = assert( sock:recv(zmq.NOBLOCK) )
  -- TODO: handle 'timeout' error
  sock:send('pong')
end

local function on_control_read( sock )
  local data = assert( sock:recv(zmq.NOBLOCK) )
  -- TODO: handle 'timeout' error
  print("CTRL", data)
end

local function on_stdin_read( sock )
  local data = assert( sock:recv(zmq.NOBLOCK) )
  -- TODO: handle 'timeout' error
  print("STDIN", data)
end

local function on_shell_read( sock )
  -- TODO: error handling
  local ipmsg = assert( sock:recv_all() )
  
  local msg = ipmsg_to_table(ipmsg)

  for k, v in pairs(msg) do print(k,v) end

  local header_obj = json.decode(msg.header)
  if header_obj.msg_type == 'kernel_info_request' then
    local header = ipmsg_header( header_obj.session, 'kernel_info_reply' )
    local major,minor = _VERSION:match("(%d+)%.(%d+)")
    local content = json.encode({
        protocol_version = {4, 0},
        language_version = {tonumber(major), tonumber(minor)},
        language = 'lua',
    })

    ipmsg_send(sock, header_obj.session, '', header, msg.header, '{}', content)

  elseif header_obj.msg_type == 'execute_request' then

    local header = ipmsg_header( header_obj.session, 'execute_reply' )
    kernel.execution_count = kernel.execution_count + 1
    local content = json.encode({
        status = 'ok',
        execution_count = kernel.execution_count,
        payload = {},
        user_expresions = {},
    })

    ipmsg_send(sock, header_obj.session, '', header, msg.header, '{}', content)
    
    local header = ipmsg_header( header_obj.session, 'status' )
    local content = json.encode{ execution_state='busy' }
    ipmsg_send(kernel.iopub_sock, header_obj.session, '',
               header, '{}', '{}', content)
    local msg_content = json.decode(msg.content)
    local code = msg_content.code
    env_header  = msg.header
    env_session = header_obj.session
    env_source  = code
    local f = load(add_return(code), nil, nil, env)
    local out = f()
    if out then
      -- TODO: show output of the function
    end
    
    local content = json.encode{ execution_state='idle' }
    ipmsg_send(kernel.iopub_sock, header_obj.session, '',
               header, '{}', '{}', content)
  end

end

local function on_iopub_read( sock )
  -- read the data and send a pong
  local data = assert( sock:recv(zmq.NOBLOCK) )
  -- TODO: handle timeout error
  print("PUB", data)
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
  local sock = assert( z_ctx:socket(v.sock_type) )

  local conn_obj = kernel.connection_obj
  local addr = string.format('%s://%s:%s',
                             conn_obj.transport,
                             conn_obj.ip,
                             conn_obj[v.port..'_port'])

  assert( sock:bind(addr) )

  z_poller:add(sock, zmq.POLLIN, v.handler)

  kernel[v.name] = sock
end

kernel.execution_count = 0


-------------------------------------------------------------------------------
-- POLL then SHUTDOWN

--print("Starting poll")
z_poller:start()

for _, v in ipairs(kernel_sockets) do
  kernel[v.name]:close()
end
z_ctx:term()
