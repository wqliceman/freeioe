local skynet = require "skynet"
local rs232 = require "rs232"

-- channel support auto reconnect , and capture serial error in request/response transaction
-- { port = "", opt = {}, auth = function(so) , response = function(so) session, data }

local serial_channel = {}
local channel = {}
local channel_serial = {}
local channel_meta = { __index = channel }
local channel_serial_meta = {
	__index = channel_serial,
	__gc = function(cs)
		local fd = cs[1]
		cs[1] = false
		if fd then
			fd:close()
		end
	end
}

local serial_error = setmetatable({}, {__tostring = function() return "[Error: Serial]" end })	-- alias for error object
serial_channel.error = serial_error

local function map_serial_opt(opt)
	return {
		baud = '_'..(opt.baudrate or 9600),
		data_bits = '_'..(opt.bytesize or 8),
		parity = string.upper(opt.parity or "NONE"),
		stop_bits = '_'..(opt.stopbits or 1),
		flow_control = string.upper(opt.flowcontrol or "OFF")
	}
end

function serial_channel.channel(desc)
	local c = {
		__port = assert(desc.port),
		__opt = assert(desc.opt),
		__backup = desc.backup,
		__auth = desc.auth,
		__response = desc.response,	-- It's for session mode
		__request = {},	-- request seq { response func or session }	-- It's for order mode
		__thread = {}, -- coroutine seq or session->coroutine map
		__result = {}, -- response result { coroutine -> result }
		__result_data = {},
		__connecting = {},
		__serial = false,
		__closed = false,
		__authcoroutine = false,
	}

	return setmetatable(c, channel_meta)
end

local function close_channel_serial(self)
	if self.__serial then
		local so = self.__serial
		self.__serial = false
		-- never raise error
		pcall(so[1].close,so[1])
	end
end

local function wakeup_all(self, errmsg)
	if self.__response then
		for k,co in pairs(self.__thread) do
			self.__thread[k] = nil
			self.__result[co] = serial_error
			self.__result_data[co] = errmsg
			skynet.wakeup(co)
		end
	else
		for i = 1, #self.__request do
			self.__request[i] = nil
		end
		for i = 1, #self.__thread do
			local co = self.__thread[i]
			self.__thread[i] = nil
			if co then	-- ignore the close signal
				self.__result[co] = serial_error
				self.__result_data[co] = errmsg
				skynet.wakeup(co)
			end
		end
	end
end

local function exit_thread(self)
	local co = coroutine.running()
	if self.__dispatch_thread == co then
		self.__dispatch_thread = nil
		local connecting = self.__connecting_thread
		if connecting then
			skynet.wakeup(connecting)
		end
	end
end

local function dispatch_by_session(self)
	local response = self.__response
	-- response() return session
	while self.__serial do
		local ok , session, result_ok, result_data, padding = pcall(response, self.__serial)
		if ok and session then
			local co = self.__thread[session]
			if co then
				if padding and result_ok then
					-- If padding is true, append result_data to a table (self.__result_data[co])
					local result = self.__result_data[co] or {}
					self.__result_data[co] = result
					table.insert(result, result_data)
				else
					self.__thread[session] = nil
					self.__result[co] = result_ok
					if result_ok and self.__result_data[co] then
						table.insert(self.__result_data[co], result_data)
					else
						self.__result_data[co] = result_data
					end
					skynet.wakeup(co)
				end
			else
				self.__thread[session] = nil
				skynet.error("serial: unknown session :", session)
			end
		else
			close_channel_serial(self)
			local errormsg
			if session ~= serial_error then
				errormsg = session
			end
			wakeup_all(self, errormsg)
		end
	end
	exit_thread(self)
end

local function pop_response(self)
	while true do
		local func,co = table.remove(self.__request, 1), table.remove(self.__thread, 1)
		if func then
			return func, co
		end
		self.__wait_response = coroutine.running()
		skynet.wait(self.__wait_response)
	end
end

local function push_response(self, response, co)
	if self.__response then
		-- response is session
		self.__thread[response] = co
	else
		-- response is a function, push it to __request
		table.insert(self.__request, response)
		table.insert(self.__thread, co)
		if self.__wait_response then
			skynet.wakeup(self.__wait_response)
			self.__wait_response = nil
		end
	end
end

local function dispatch_by_order(self)
	while self.__serial do
		local func, co = pop_response(self)
		if not co then
			-- close signal
			wakeup_all(self, "channel_closed")
			break
		end
		local ok, result_ok, result_data, padding = pcall(func, self.__serial)
		if ok then
			if padding and result_ok then
				-- if padding is true, wait for next result_data
				-- self.__result_data[co] is a table
				local result = self.__result_data[co] or {}
				self.__result_data[co] = result
				table.insert(result, result_data)
			else
				self.__result[co] = result_ok
				if result_ok and self.__result_data[co] then
					table.insert(self.__result_data[co], result_data)
				else
					self.__result_data[co] = result_data
				end
				skynet.wakeup(co)
			end
		else
			close_channel_serial(self)
			local errmsg
			if result_ok ~= serial_error then
				errmsg = result_ok
			end
			self.__result[co] = serial_error
			self.__result_data[co] = errmsg
			skynet.wakeup(co)
			wakeup_all(self, errmsg)
		end
	end
	exit_thread(self)
end

local function dispatch_function(self)
	if self.__response then
		return dispatch_by_session
	else
		return dispatch_by_order
	end
end

local function open_rs232(port, opt)
	local port, err = rs232.port(port, map_serial_opt(opt))
	if not port then
		return nil, err
	end
	local ok, err = port:open()
	if not ok then
		return nil, tostring(err)
	end
	return port
end

local function connect_backup(self)
	if self.__backup then
		for _, addr in ipairs(self.__backup) do
			local port, opt 
			if type(addr) == "table" then
				port, opt = addr.port, addr.opt
			else
				port = addr
				opt = self.__opt
			end
			skynet.error("serial: connect to backup serial port", port, opt)
			local fd = open_rs232(port, opt)
			if fd then
				self.__port = port 
				self.__opt = opt 
				return fd
			end
		end
	end
end

local function connect_once(self)
	if self.__closed then
		return false
	end
	assert(not self.__serial and not self.__authcoroutine)
	local fd, err = open_rs232(self.__port, self.__opt)
	if not fd then
		fd = connect_backup(self)
		if not fd then
			return false, err
		end
	end

	self.__serial = setmetatable( {fd} , channel_serial_meta )
	self.__dispatch_thread = skynet.fork(dispatch_function(self), self)

	if self.__auth then
		self.__authcoroutine = coroutine.running()
		local ok , message = pcall(self.__auth, self)
		if not ok then
			close_channel_serial(self)
			if message ~= serial_error then
				self.__authcoroutine = false
				skynet.error("serial: auth failed", message)
			end
		end
		self.__authcoroutine = false
		if ok and not self.__serial then
			-- auth may change port, so connect again
			return connect_once(self)
		end
		return ok
	end

	return true
end

local function try_connect(self , once)
	local t = 0
	while not self.__closed do
		local ok, err = connect_once(self)
		if ok then
			if not once then
				skynet.error("serial: connect to", self.__port)
			end
			return
		elseif once then
			return err
		else
			skynet.error("serial: connect", err)
		end
		if t > 1000 then
			skynet.error("serial: try to reconnect", self.__port)
			skynet.sleep(t)
			t = 0
		else
			skynet.sleep(t)
		end
		t = t + 100
	end
end

local function check_connection(self)
	if self.__serial then
		local authco = self.__authcoroutine
		if not authco then
			return true
		end
		if authco == coroutine.running() then
			-- authing
			return true
		end
	end
	if self.__closed then
		return false
	end
end

local function block_connect(self, once)
	local r = check_connection(self)
	if r ~= nil then
		return r
	end
	local err

	if #self.__connecting > 0 then
		-- connecting in other coroutine
		local co = coroutine.running()
		table.insert(self.__connecting, co)
		skynet.wait(co)
	else
		self.__connecting[1] = true
		err = try_connect(self, once)
		self.__connecting[1] = nil
		for i=2, #self.__connecting do
			local co = self.__connecting[i]
			self.__connecting[i] = nil
			skynet.wakeup(co)
		end
	end

	r = check_connection(self)
	if r == nil then
		skynet.error(string.format("Connect to %s failed (%s)", self.__port, err))
		error(serial_error)
	else
		return r
	end
end

function channel:connect(once)
	if self.__closed then
		if self.__dispatch_thread then
			-- closing, wait
			assert(self.__connecting_thread == nil, "already connecting")
			local co = coroutine.running()
			self.__connecting_thread = co
			skynet.wait(co)
			self.__connecting_thread = nil
		end
		self.__closed = false
	end

	return block_connect(self, once)
end

local function wait_for_response(self, response)
	local co = coroutine.running()
	push_response(self, response, co)
	skynet.wait(co)

	local result = self.__result[co]
	self.__result[co] = nil
	local result_data = self.__result_data[co]
	self.__result_data[co] = nil

	if result == serial_error then
		if result_data then
			error(result_data)
		else
			error(serial_error)
		end
	else
		assert(result, result_data)
		return result_data
	end
end

local function sock_err(self)
	close_channel_serial(self)
	wakeup_all(self)
	error(serial_error)
end

function channel:request(request, response, padding)
	assert(block_connect(self, true))	-- connect once
	local fd = self.__serial[1]

	if padding then
		-- padding may be a table, to support multi part request
		if not fd:write(request) then
			sock_err(self)
		end
		for _,v in ipairs(padding) do
			if not fd:write(v) then
				sock_err(self)
			end
		end
	else
		if not fd:write(request) then
			sock_err(self)
		end
	end

	if response == nil then
		-- no response
		return
	end

	return wait_for_response(self, response)
end

function channel:response(response)
	assert(block_connect(self))

	return wait_for_response(self, response)
end

function channel:close()
	if not self.__closed then
		local thread = self.__dispatch_thread
		self.__closed = true
		close_channel_serial(self)
		if not self.__response and self.__dispatch_thread == thread and thread then
			-- dispatch by order, send close signal to dispatch thread
			push_response(self, true, false)	-- (true, false) is close signal
		end
	end
end

function channel:change_port(port, opt)
	self.__port = port 
	if opt then
		self.__opt = opt
	end
	if not self.__closed then
		close_channel_serial(self)
	end
end

function channel:changebackup(backup)
	self.__backup = backup
end

channel_meta.__gc = channel.close

local function wrapper_serial_function(f)
	return function(self, ...)
		local result = f(self[1], ...)
		if not result then
			error(serial_error)
		else
			return result
		end
	end
end

local function rs232_read(port, len)
	while true do
		local ilen, err = port:in_queue()
		if not ilen then
			return nil, err
		end
		if ilen and ilen >= len then
			return port:read(len, 10)
		end
		skynet.sleep(1)
	end
end

channel_serial.read = wrapper_serial_function(function(port, ...)
	return rs232_read(port, ...)
end)

channel_serial.write = wrapper_serial_function(function(port, ...)
	return port:write(...)
end)

channel_serial.close = wrapper_serial_function(function(port, ...)
	return port:close(...)
end)

return serial_channel
