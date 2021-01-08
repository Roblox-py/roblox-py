local Promise = require(script.Parent.Promise)
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService('ReplicatedStorage')
local HttpService = game:GetService("HttpService")
local ReplicatedFirst = game:GetService("ReplicatedFirst")

local PY = {}

-- runtime classes
PY.Promise = Promise

local Symbol
do
    Symbol = {}
    Symbol.__index = Symbol

    setmetatable(Symbol, {
        __call = function(_, desc)
            local self = setmetatable({}, Symbol)
            self.description = 'Symbol('.. (desc or '') .. ')'
            return self
        end
    })

    local symbolRegistry = setmetatable({},
		{
			__index = function(self, k)
				self[k] = Symbol(k)
				return self[k]
			end,
		}
	)

	function Symbol:toString()
		return self.description
	end

	Symbol.__tostring = Symbol.toString

	-- Symbol.for
	function Symbol.getFor(key)
		return symbolRegistry[key]
	end

	function Symbol.keyFor(goalSymbol)
		for key, symbol in pairs(symbolRegistry) do
			if symbol == goalSymbol then
				return key
			end
		end
	end
end

PY.Symbol = Symbol
PY.Symbol_iterator = Symbol("Symbol.iterator")

local function isPlugin(object)
	return RunService:IsStudio() and object:FindFirstAncestorWhichIsA("Plugin") ~= nil
end

function PY.getFramework(object, index)
    if RunService:IsRunning() and object:IsDescendantOf(ReplicatedFirst) then
		warn("roblox-py packages should not be used from ReplicatedFirst!")
    end

    local Framework = ReplicatedStorage:FindFirstChild('Framework')
    if not Framework then
        error("Could not find Framework!", 2)
    end

    --// Do _L Loop
end

-- module resolution
function PY.getModule(object, moduleName)
    if RunService:IsRunning() and object:IsDescendantOf(ReplicatedFirst) then
		warn("roblox-py packages should not be used from ReplicatedFirst!")
    end
    
    -- ensure modules have fully replicated
	if RunService:IsRunning() and RunService:IsClient() and not isPlugin(object) and not game:IsLoaded() then
		game.Loaded:Wait()
    end
    
    local globalModules = script.Parent:FindFirstChild("node_modules")
	if not globalModules then
		error("Could not find any modules!", 2)
    end
    
    repeat
		local modules = object:FindFirstChild("node_modules")
		if modules and modules ~= globalModules then
			modules = modules:FindFirstChild("@rbxpy")
		end
		if modules then
			local module = modules:FindFirstChild(moduleName)
			if module then
				return module
			end
		end
		object = object.Parent
    until object == nil or object == globalModules
    
    return globalModules:FindFirstChild(moduleName) or error("Could not find module: " .. moduleName, 2)
end

-- This is a hash which PY.import uses as a kind of linked-list-like history of [Script who Loaded] -> Library
local currentlyLoading = {}
local registeredLibraries = {}

function PY.import(caller, module, ...)
    for i = 1, select('#', ...) do
        module = module:WaitForChild((select(i, ...)))
    end

    if module:IsA('ModuleScript') then
        error("Failed to import! Expected ModuleScript, got " .. module.ClassName, 2)
    end

    currentlyLoading[caller] = module

    -- Check to see if a case like this occurs:
	-- module -> Module1 -> Module2 -> module

	-- WHERE currentlyLoading[module] is Module1
	-- and currentlyLoading[Module1] is Module2
    -- and currentlyLoading[Module2] is module
    
    local currentModule = module
	local depth = 0

	while currentModule do
		depth = depth + 1
		currentModule = currentlyLoading[currentModule]

		if currentModule == module then
			local str = currentModule.Name -- Get the string traceback

			for _ = 1, depth do
				currentModule = currentlyLoading[currentModule]
				str = str .. "  ⇒ " .. currentModule.Name
			end

			error("Failed to import! Detected a circular dependency chain: " .. str, 2)
		end
    end
    
    if not registeredLibraries[module] then
        if _G[module] then
            error("Invalid module access! Do you have two PY runtimes trying to import this? " .. module:GetFullName(), 2)
        end

        _G[module] = PY
        registeredLibraries[module] = true
    end

    local data = require(module)

	if currentlyLoading[caller] == module then -- Thread-safe cleanup!
		currentlyLoading[caller] = nil
	end

	return data
end

function PY.exportNamespace(module, ancestor)
    for key, val in pairs(module) do
        ancestor[key] = val
    end
end

-- general utility functions
function PY.instanceof(obj, class)
    -- custom Class.instanceof() check
	if type(class) == "table" and type(class.instanceof) == "function" then
		return class.instanceof(obj)
    end
    
    -- metatable check
	if type(obj) == "table" then
		obj = getmetatable(obj)
		while obj ~= nil do
			if obj == class then
				return true
			end
			local mt = getmetatable(obj)
			if mt then
				obj = mt.__index
			else
				obj = nil
			end
		end
	end

    return false
end

-- async function
function PY.async(callback)
    return function(...)
        local n = select("#", ...)
        local args = { ... }

        return Promise.new(function(resolve, reject)
            coroutine.wrap(function()
                local ok, result = pcall(callback, unpack(args, 1, n))
				if ok then
					resolve(result)
				else
					reject(result)
				end
            end)()
        end)
    end
end

-- await function
function PY.await(promise)
    if not Promise.is(promise) then
        return promise
    end

    local status, val = promise:awaitStatus()
    if status == Promise.Status.Resolved then
        return val
    elseif status == Promise.Status.Rejected then
        error(val, 2)
    else
        error("The awaited Promise was cancelled", 2)
    end
end

function PY.add(a, b)
    if type(a) == 'string' or type(b) == 'string' then
        return a .. b
    else
        return a + b
    end
end

function PY.bit_lrsh(a, b)
    local absA = math.abs(a)
    local result = bit32.rshift(absA, b)

    if a == absA then
        return result
    else
        return -result - 1
    end
end

PY.TRY_RETURN = 1
PY.TRY_BREAK = 2
PY.TRY_CONTINUE = 3

function PY.try(func, catch, finally)
    local err, traceback
	local success, exitType, returns = xpcall(
		func,
		function(errInner)
			err = errInner
			traceback = debug.traceback()
		end
	)
	if not success and catch then
		local newExitType, newReturns = catch(err, traceback)
		if newExitType then
			exitType, returns = newExitType, newReturns
		end
	end
	if finally then
		local newExitType, newReturns = finally()
		if newExitType then
			exitType, returns = newExitType, newReturns
		end
	end
	return exitType, returns
end

function PY.generator(callback)
    local co = coroutine.create(callback)
	return {
		next = function(...)
			if coroutine.status(co) == "dead" then
				return { done = true }
			else
				local success, value = coroutine.resume(co, ...)
				if success == false then
					error(value, 2)
				end
				return {
					value = value,
					done = coroutine.status(co) == "dead",
				}
			end
		end,
	}
end

-- LEGACY RUNTIME FUNCTIONS

-- utility functions
local function copy(object)
	local result = {}
	for k, v in pairs(object) do
		result[k] = v
	end
	return result
end

local function deepCopyHelper(object, encountered)
	local result = {}
	encountered[object] = result

	for k, v in pairs(object) do
		if type(k) == "table" then
			k = encountered[k] or deepCopyHelper(k, encountered)
		end

		if type(v) == "table" then
			v = encountered[v] or deepCopyHelper(v, encountered)
		end

		result[k] = v
	end

	return result
end

local function deepCopy(object)
	return deepCopyHelper(object, {})
end

local function deepEquals(a, b)
	-- a[k] == b[k]
	for k in pairs(a) do
		local av = a[k]
		local bv = b[k]
		if type(av) == "table" and type(bv) == "table" then
			local result = deepEquals(av, bv)
			if not result then
				return false
			end
		elseif av ~= bv then
			return false
		end
	end

	-- extra keys in b
	for k in pairs(b) do
		if a[k] == nil then
			return false
		end
	end

	return true
end

-- Object static functions

local function toString(data)
	return HttpService:JSONEncode(data)
end

function PY.Object_keys(object)
    local result = {}
	for key in pairs(object) do
		result[#result + 1] = key
	end
	return result
end

function PY.Object_values(object)
    local result = {}
	for _, value in pairs(object) do
		result[#result + 1] = value
	end
	return result
end

function PY.Object_entries(object)
    local result = {}
	for key, value in pairs(object) do
		result[#result + 1] = { key, value }
	end
	return result
end

function PY.Object_assign(toObj, ...)
    for i = 1, select("#", ...) do
		local arg = select(i, ...)
		if type(arg) == "table" then
			for key, value in pairs(arg) do
				toObj[key] = value
			end
		end
	end
	return toObj 
end

PY.Object_copy = copy
PY.Object_deepCopy = deepCopy
PY.Object_deepEquals = deepEquals
PY.Object_toString = toString

-- string macro functions
function PY.string_find_wrap(a, b, ...)
	if a then
		return a - 1, b - 1, ...
	end
end

-- array macro functions
local function array_copy(list)
	local result = {}
	for i = 1, #list do
		result[i] = list[i]
	end
	return result
end

PY.array_copy = array_copy

function PY.array_entries(list)
	local result = {}
	for key = 1, #list do
		result[key] = { key - 1, list[key] }
	end
	return result
end

function PY.array_forEach(list, callback)
	for i = 1, #list do
		callback(list[i], i - 1, list)
	end
end

local function array_map(list, callback)
	local result = {}
	for i = 1, #list do
		result[i] = callback(list[i], i - 1, list)
	end
	return result
end

PY.array_map = array_map

function PY.array_mapFiltered(list, callback)
	local new = {}
	local index = 1

	for i = 1, #list do
		local result = callback(list[i], i - 1, list)

		if result ~= nil then
			new[index] = result
			index = index + 1
		end
	end

	return new
end

local function getArraySizeSlow(list)
	local result = 0
	for index in pairs(list) do
		if index > result then
			result = index
		end
	end
	return result
end

function PY.array_filterUndefined(list)
	local length = 0
	local result = {}
	for i = 1, getArraySizeSlow(list) do
		local value = list[i]
		if value ~= nil then
			length = length + 1
			result[length] = value
		end
	end
	return result
end

function PY.array_filter(list, callback)
	local result = {}
	for i = 1, #list do
		local v = list[i]
		if callback(v, i - 1, list) == true then
			result[#result + 1] = v
		end
	end
	return result
end

function PY.array_sort(list, callback)
	table.sort(list, callback)
	return list
end

PY.array_toString = toString

function PY.array_slice(list, startI, endI)
	local length = #list

	if startI == nil then startI = 0 end
	if endI == nil then endI = length end

	if startI < 0 then startI = length + startI end
	if endI < 0 then endI = length + endI end

	local result = {}

	for i = startI + 1, endI do
		result[i - startI] = list[i]
	end

	return result
end

function PY.array_splice(list, start, deleteCount, ...)
	local len = #list
	local actualStart
	if start < 0 then
		actualStart = len + start
		if actualStart < 0 then
			actualStart = 0
		end
	else
		if start < len then
			actualStart = start
		else
			actualStart = len
		end
	end
	local items = { ... }
	local itemCount = #items
	local actualDeleteCount
	if start == nil then
		actualDeleteCount = 0
	elseif deleteCount == nil then
		actualDeleteCount = len - actualStart
	else
		if deleteCount < 0 then
			deleteCount = 0
		end
		actualDeleteCount = len - actualStart
		if deleteCount < actualDeleteCount then
			actualDeleteCount = deleteCount
		end
	end
	local out = {}
	local k = 0
	while k < actualDeleteCount do
		local from = actualStart + k
		if list[from + 1] then
			out[k + 1] = list[from + 1]
		end
		k = k + 1
	end
	if itemCount < actualDeleteCount then
		k = actualStart
		while k < len - actualDeleteCount do
			local from = k + actualDeleteCount
			local to = k + itemCount
			if list[from + 1] then
				list[to + 1] = list[from + 1]
			else
				list[to + 1] = nil
			end
			k = k + 1
		end
		k = len
		while k > len - actualDeleteCount + itemCount do
			list[k] = nil
			k = k - 1
		end
	elseif itemCount > actualDeleteCount then
		k = len - actualDeleteCount
		while k > actualStart do
			local from = k + actualDeleteCount
			local to = k + itemCount
			if list[from] then
				list[to] = list[from]
			else
				list[to] = nil
			end
			k = k - 1
		end
	end
	k = actualStart
	for i = 1, #items do
		list[k + 1] = items[i]
		k = k + 1
	end
	k = #list
	while k > len - actualDeleteCount + itemCount do
		list[k] = nil
		k = k - 1
	end
	return out
end

function PY.array_some(list, callback)
	for i = 1, #list do
		if callback(list[i], i - 1, list) == true then
			return true
		end
	end
	return false
end