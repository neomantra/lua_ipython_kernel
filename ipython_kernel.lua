--[[
lua_ipython_kernel
 
Copyright (c) 2013 Evan Wies.  All rights reserved.

Released under the MIT License, see the LICENSE file.

https://github.com/neomantra/lua_ipython_kernel

usage: lua ipython_kernel.lua `connection_file`
]]


if #arg ~= 1 then
	io.stderr:write('usage: ipython_kernel.lua `connection_filename`\n')
	os.exit(-1)
end

local json = require 'dkjson'

-- our kernel's state
local kernel = {}

-- load connection object info from JSON file
do
	local connection_file = io.open(arg[1])
	if not connection_file then
		io.stderr:write('couldn not open connection file "', arg[1], '")": ', err, '\n')
		os.exit(-1)
	end

	local connection_json, err = connection_file:read('*a')
	if not connection_json then
		io.stderr:write('couldn not read connection file "', arg[1], '")": ', err, '\n')
		os.exit(-1)
	end

	kernel.connection_obj = json.decode(connection_json)
	if not kernel.connection_obj then
		io.stderr:write('connection file is missing connection object\n')
		os.exit(-1)
	end
	connection_file:close()
end


local zmq = require 'zmq'
local zmq_poller = require 'zmq/poller'
local z_NOBLOCK, z_POLLIN = zmq.NOBLOCK, zmq.POLL_IN
local z_RCVMORE, z_SNDMORE = zmq.RCVMORE, zmq.SNDMORE

local uuid = require 'uuid'
-- TODO: randomseed or luasocket or something else

local username = os.getenv('USER')



-------------------------------------------------------------------------------
-- IPython Message ("ipmsg") functions

local function ipmsg_to_table(parts)
	local ipmsg = { ids = {}, blobs = {} }

	local i = 1
	while i <= #parts and parts[i] ~= '<IDS|MSG>' do
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
		msg_id = uuid.new(),   -- TODO: randomness warning
		username = username,
		date = os.date('%Y-%m-%dT%h:%M:%s.000000'),  -- TODO milliseconds
		session = session,
		msg_type = msg_type,
	})
end


local function ipmsg_recv(sock)
	-- TODO: error handling
	local parts, err = {}
	parts[1], err = sock:recv()
	while sock:getopt(z_RCVMORE) == 1 do
		parts[#parts + 1], err = sock:recv()
	end
	return parts, err
end


local function ipmsg_send(sock, ids, hmac, hdr, p_hdr, meta, content, blobs)
	if type(ids) == 'table' then
		for _, v in ipairs(ids) do
			sock:send(v, z_SNDMORE)
		end
	else
		sock:send(ids, z_SNDMORE)
	end
	sock:send('<IDS|MSG>', z_SNDMORE)
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
-- ZMQ Read Handlers

local function on_hb_read( sock )
	-- read the data and send a pong
	local data, err = sock:recv(zmq.NOBLOCK)
    if not data then
        assert(err == 'timeout', 'Bad error on zmq socket.')
        -- TODO return sock_blocked(on_sock_recv, z_POLLIN)
        assert(false, "bad hb_read_data")
    end
    sock:send('pong')
end

local function on_control_read( sock )
	-- read the data and send a pong
	local data, err = sock:recv(zmq.NOBLOCK)
    if not data then
        assert(err == 'timeout', 'Bad error on zmq socket.')
        -- TODO return sock_blocked(on_sock_recv, z_POLLIN)
        assert(false, "bad hb_read_data")
    end
--    print('control', data)
end

local function on_stdin_read( sock )
	-- read the data and send a pong
	local data, err = sock:recv(zmq.NOBLOCK)
    if not data then
        assert(err == 'timeout', 'Bad error on zmq socket.')
        -- TODO return sock_blocked(on_sock_recv, z_POLLIN)
        assert(false, "bad hb_read_data")
    end
--    print('stdin', data)
end



local function on_shell_read( sock )

	local ipmsg, err = ipmsg_recv(sock)
	local msg = ipmsg_to_table(ipmsg)

	for k, v in pairs(msg) do print(k,v) end

	local header_obj = json.decode(msg.header)
	if header_obj.msg_type == 'kernel_info_request' then
		local header = ipmsg_header( header_obj.session, 'kernel_info_reply' )
		local content = json.encode({
			protocol_version = {4, 0},
			language_version = {5, 1},
			language = 'lua',
		})

		ipmsg_send(sock, header_obj.session, '', header, msg.header, '{}', content)

	elseif header_obj.msg_type == 'execute_request' then

		local header = ipmsg_header( header_obj.session, 'execute_reply' )
		kernel.execution_count = kernel.execution_count + 1
		local content = json.encode({
			status = 'ok',
			execution_count = kernel.execution_count,
		})

		ipmsg_send(sock, header_obj.session, '', header, msg.header, '{}', content)

	end

end

local function on_iopub_read( sock )
	-- read the data and send a pong
	local data, err = sock:recv(zmq.NOBLOCK)
    if not data then
        assert(err == 'timeout', 'Bad error on zmq socket.')
        -- TODO return sock_blocked(on_sock_recv, z_POLLIN)
        assert(false, "bad hb_read_data")
    end
--    print('iopub', data)

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

local z_ctx = zmq.init()
local z_poller = zmq_poller(#kernel_sockets)
for _, v in ipairs(kernel_sockets) do
	-- TODO: error handling in here
	local sock = z_ctx:socket(v.sock_type)

	local conn_obj = kernel.connection_obj
	local addr = string.format('%s://%s:%s',
		conn_obj.transport,
		conn_obj.ip,
		conn_obj[v.port..'_port'])

--	io.stderr:write(string.format('binding %s to %s\n', v.name, addr))
	sock:bind(addr)

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
