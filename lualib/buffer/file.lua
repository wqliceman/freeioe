local class = require 'middleclass'
local skynet = require 'skynet'
local zlib_loaded, zlib = pcall(require, 'zlib')
local cjson = require 'cjson.safe'

local fb = class("File_Buffer_Utils")

function fb:initialize(file_path, data_count_per_file, max_file_count)
	self._file_path = file_path
	self._data_count_per_file = data_count_per_file
	self._max_file_count = max_file_count
	self._files = {} -- file list that already in disk
	self._buffer = {} -- data buffer list
	self._fire_buffer = {}
	self._fire_offset = 1 -- buffer offset. 
	self._fire_index = nil -- file index. nil means there is no fire_buffer (file or buffer)
	self._stop = false
end

function fb:push(...)
	if #self._files == 0 and #self._buffer == 0 then
		if self._callback(...) then
			return true
		end
	end
	self:_push(...)
	return false
end

-- callback that return true/false
function fb:start(data_callback, batch_callback)
	assert(data_callback)
	self._callback = data_callback
	skynet.fork(function()
		while not self._stop and self._callback do
			if self:_empty() then
				--- Sleep one second
				skynet.sleep(100)
			end

			if batch_callback then
				self:_try_fire_data_batch(batch_callback)
			else
				self:_try_fire_data()
			end

			if not self:_empty() then
				skynet.sleep(100)
			end
		end
	end)
end

function fb:stop()
	if not self._stop then
		self._stop = true
		-- TODO:
	end
end

--- check if buffer empty
function fb:_empty()
	return #self._files == 0 and #self._buffer == 0 and #self._fire_buffer == 0
end

--- Create buffer file path
function fb:_make_file_path(index)
	return self._file_path.."."..index
end

---
function fb:_dump_buffer_to_file(buffer)
	local str, err = cjson.encode(buffer)
	if not str then
		return nil, err
	end

	local index = ((self._fire_index or 1) + #self._files) % 0xFFFFFFFF
	local f, err = io.open(self:_make_file_path(index), "w+")
	if not f then
		return nil, err
	end

	--print('dump', index, str)

	f:write(str)
	f:close()

	self._files[#self._files + 1] = index

	--- Set proper fire stuff
	if not self._fire_index then
		self._fire_index = index
		self._fire_buffer = buffer
		self._fire_offset = 1
	end

	--- remove the too old files
	if #self._files > self._max_file_count then
		--print('drop '..self._fire_index)
		--- load index and buffer
		self._fire_buffer = self:_load_next_file()
		--- reset offset
		self._fire_offset = 1
	end
end

function fb:_push(...)
	--- append to buffer
	self._buffer[#self._buffer + 1] = {...}

	--- dump to file if data count reach
	if #self._buffer >= self._data_count_per_file then
		self:_dump_buffer_to_file(self._buffer)
		self._buffer = {}
	end
end

function fb:_load_next_file()
	--- pop fired file
	if self._fire_index and self._files[1] == self._fire_index then
		table.remove(self._files, 1)
	end

	-- until we got one correct file
	while #self._files > 0 do
		-- get first index
		local index = self._files[1]

		-- Open file
		--print('load ', index)
		local f, err = io.open(self:_make_file_path(index))
		if f then
			--- read all file
			local str = f:read('a')
			f:close()

			--- if previous reading file then remove it
			if self._fire_index then
				os.remove(self:_make_file_path(self._fire_index))
			end

			--- set the current index
			self._fire_index = index

			if str then
				--- if read ok decode content
				local buffer, err = cjson.decode(str)
				if buffer then
					--- if decode ok return
					return buffer
				else
					print('decode error ', index)
				end
			else
				print('read error ', index)
			end
		end
		
		-- continue with next file
		table.remove(self._files, 1)
	end

	-- no next file
	self._fire_index = nil
	return {}
end

function fb:_pop(first)
	--- increase offset
	if not first then
		self._fire_offset = self._fire_offset  + 1
	end

	--- if fire_buffer already done
	if #self._fire_buffer < self._fire_offset then
		self._fire_buffer = self:_load_next_file()
		self._fire_offset = 1
	end

	--- load empty then check current buffer
	if #self._fire_buffer == 0 then
		if #self._buffer == 0 then
			self._fire_offset = 1
			--- no more data
			return nil
		else
			--- pop not dumped buffer
			self._fire_buffer = self._buffer
			self._fire_offset = 1
			self._buffer = {}
		end
	end

	return self._fire_buffer[self._fire_offset]
end

function fb:_try_fire_data()
	local callback = self._callback
	local first = true

	while true do
		local data = self:_pop(first)
		if not data then
			assert(self._fire_index == nil)
			assert(self._fire_offset == 1)
			assert(#self._fire_buffer == 0)
			assert(#self._files == 0)
			assert(#self._buffer == 0)
			--- Finished fire
			break
		end

		local r, done, err = pcall(callback, table.unpack(data))
		if not r then
			print('Code bug', done, err)
			break
		end

		if not done then
			--- Fire not available
			break
		end

		first = false
	end
end

--- Fire data in batch array.
function fb:_try_fire_data_batch(callback)
	while not self:_empty() do
		--- Make sure fire_buffer not changed
		local working_index = self._fire_index

		local r, done, err = pcall(callback, self._fire_buffer, self._fire_offset)
		if not r then
			print('Code bug', done, err)
			break
		end

		if not done then
			--- Fire not available
			break
		end

		--print('done', done, ' from offset', self._fire_offset)

		if working_index == self._fire_index then
			self._fire_offset = self._fire_offset + tonumber(done)

			--- if fire_buffer already done
			if #self._fire_buffer < self._fire_offset then
				self._fire_buffer = self:_load_next_file()
				self._fire_offset = 1
			end

			--- swap buffer
			if #self._fire_buffer == 0 then
				if #self._buffer ~= 0 then
					self._fire_buffer = self._buffer
					self._fire_offset = 1
					self._buffer = {}
				end
			end
		end
	end
end

function fb:__test_a()
	local o = fb:new('/tmp/aaaaa', 10, 10)

	local callback_ok = true
	local callback_check = 0
	local callback = function(data)
		assert(callback_check == data, "callback_check: "..callback_check.." data: "..data)
		if callback_ok then
			callback_check = callback_check + 1
			--print(data)
			return true
		end
		return false
	end
	o:start(callback)
	local data = 0
	--- push 200 data, ok done
	print('work', data)
	while data < 200 do
		o:push(data)
		data = data + 1
	end

	print('enter sleep')
	print(callback_check)
	skynet.sleep(10)
	assert(callback_check == 200)
	print('after sleep')

	--- push 200 data, lost 100
	callback_ok = false
	print('work', data)
	while data < 401 do
		o:push(data)
		data = data + 1
	end

	print('enter sleep')
	print(callback_check)
	skynet.sleep(10)
	assert(callback_check == 200)
	print('after sleep')

	--- callback ok
	callback_check = 300
	callback_ok = true
	skynet.sleep(200)
	assert(callback_check == 401)

	--- push another 200 data
	print('work', data)
	while data < 700 do
		o:push(data)
		data = data + 1
	end

	print('enter sleep')
	print(callback_check)
	skynet.sleep(10)
	assert(callback_check == 700)
	print('after sleep')

	o:stop()
end

function fb:__test_b()
	local o = fb:new('/tmp/aaaaa', 10, 10)

	local callback_ok = true
	local callback_check = 0
	local callback = function(data)
		assert(callback_check == data, "callback_check: "..callback_check.." data: "..data)
		if callback_ok then
			print('single:', data)

			callback_check = callback_check + 1
			return true
		end
		return false
	end

	local callback_batch = function(data, offset)
		local first_val = data[offset][1]
		assert(callback_check == first_val, "callback_check: "..callback_check.." data: "..first_val)
		if callback_ok then
			print('batch:', cjson.encode(data))

			local left = #data - offset + 1
			print('batch start:', callback_check, 'left:', left)
			assert(left > 0, "left zero data cout: "..#data.." offset: "..offset)
			left = left < 3 and left or 3
			callback_check = callback_check + left
			print('batch check', callback_check)
			return left
		end
		return nil
	end
	o:start(callback, callback_batch)
	local data = 0
	--- push 200 data, ok done
	print('work', data)
	while data < 200 do
		o:push(data)
		data = data + 1
	end

	print('enter sleep')
	print(callback_check)
	skynet.sleep(10)
	assert(callback_check == 200, "callback_check: "..callback_check.." data: 200")
	print('after sleep')

	--- push 200 data, lost 100
	callback_ok = false
	print('work', data)
	while data < 401 do
		o:push(data)
		data = data + 1
	end

	print('enter sleep')
	print(callback_check)
	skynet.sleep(10)
	assert(callback_check == 200, "callback_check: "..callback_check.." data: 200")
	print('after sleep')

	--- callback ok
	callback_check = 300
	callback_ok = true
	skynet.sleep(200)
	assert(callback_check == 401, "callback_check: "..callback_check.." data: 401")

	--- push another 200 data
	print('work', data)
	while data < 700 do
		o:push(data)
		data = data + 1
	end

	print('enter sleep')
	print(callback_check)
	skynet.sleep(10)
	assert(callback_check == 700, "callback_check: "..callback_check.." data: 700")
	print('after sleep')

	o:stop()
end

function fb:__test()
	self:__test_a()
	self:__test_b()
end

return fb