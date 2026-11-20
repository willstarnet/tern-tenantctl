--!strict
-- JSON text to `Value`, keeping object members in document order. `tern.json.decode` can't be
-- used: it forgets member order (tenantctl puts the verdict first and the noise last) and drops
-- null members, which the view shows as "—".

export type Value = {
	-- "object" | "array" | "string" | "number" | "boolean" | "null"
	kind: string,
	-- string: the text; number: the literal as written
	s: string?,
	n: number?,
	b: boolean?,
	-- object: member names in order, and their values
	keys: { string }?,
	map: { [string]: Value }?,
	-- array: the elements
	items: { Value }?,
}

local MAX_DEPTH = 256

local ESCAPES: { [string]: string } = {
	['"'] = '"',
	["\\"] = "\\",
	["/"] = "/",
	b = "\b",
	f = "\f",
	n = "\n",
	r = "\r",
	t = "\t",
}

local NULL: Value = table.freeze({ kind = "null" })
local TRUE: Value = table.freeze({ kind = "boolean", b = true })
local FALSE: Value = table.freeze({ kind = "boolean", b = false })

-- Decodes `src`. Returns the value, or nil and a message naming the byte where it failed.
local function decode(src: string): (Value?, string?)
	local pos = 1

	local function fail(msg: string): never
		error({ msg = `{msg} at byte {pos}` }, 0)
	end

	local function skip()
		pos = string.find(src, "[^ \t\r\n]", pos) or #src + 1
	end

	local function str(): string
		pos += 1 -- the opening quote
		local parts: { string } = {}
		local seg = pos
		while true do
			local at = string.find(src, '["\\%c]', pos)
			if at == nil then
				return fail("unterminated string")
			end
			local b = string.byte(src, at)
			if b == 34 then
				table.insert(parts, string.sub(src, seg, at - 1))
				pos = at + 1
				return table.concat(parts)
			elseif b == 92 then
				table.insert(parts, string.sub(src, seg, at - 1))
				local e = string.sub(src, at + 1, at + 1)
				if e == "u" then
					local hex = string.match(src, "^%x%x%x%x", at + 2)
					if hex == nil then
						pos = at
						return fail("\\u needs four hex digits")
					end
					local code = tonumber(hex, 16) :: number
					local after = at + 6
					if code >= 0xD800 and code <= 0xDBFF then
						local lo = string.match(src, "^\\u(%x%x%x%x)", after)
						local low = if lo then tonumber(lo, 16) :: number else 0
						if low >= 0xDC00 and low <= 0xDFFF then
							code = 0x10000 + (code - 0xD800) * 0x400 + (low - 0xDC00)
							after += 6
						else
							code = 0xFFFD
						end
					elseif code >= 0xDC00 and code <= 0xDFFF then
						code = 0xFFFD
					end
					table.insert(parts, utf8.char(code))
					pos = after
				else
					local ch = ESCAPES[e]
					if ch == nil then
						pos = at
						return fail("invalid escape")
					end
					table.insert(parts, ch)
					pos = at + 2
				end
				seg = pos
			elseif b == 127 then
				pos = at + 1
			else
				pos = at
				return fail("control character in a string")
			end
		end
	end

	local value: (depth: number) -> Value

	local function container(depth: number, object: boolean): Value
		if depth > MAX_DEPTH then
			return fail("nested too deeply")
		end
		local close = if object then 125 else 93
		pos += 1
		local keys: { string } = {}
		local map: { [string]: Value } = {}
		local items: { Value } = {}
		skip()
		if string.byte(src, pos) == close then
			pos += 1
		else
			while true do
				if object then
					skip()
					if string.byte(src, pos) ~= 34 then
						return fail("expected a member name")
					end
					local key = str()
					skip()
					if string.byte(src, pos) ~= 58 then
						return fail("expected `:`")
					end
					pos += 1
					local v = value(depth + 1)
					if map[key] == nil then
						table.insert(keys, key)
					end
					map[key] = v
				else
					table.insert(items, value(depth + 1))
				end
				skip()
				local b = string.byte(src, pos)
				pos += 1
				if b == close then
					break
				elseif b ~= 44 then
					pos -= 1
					return fail(if object then "expected `,` or `}`" else "expected `,` or `]`")
				end
			end
		end
		if object then
			return { kind = "object", keys = keys, map = map }
		end
		return { kind = "array", items = items }
	end

	value = function(depth: number): Value
		skip()
		local b = string.byte(src, pos)
		if b == 123 then
			return container(depth, true)
		elseif b == 91 then
			return container(depth, false)
		elseif b == 34 then
			return { kind = "string", s = str() }
		elseif b == 116 and string.sub(src, pos, pos + 3) == "true" then
			pos += 4
			return TRUE
		elseif b == 102 and string.sub(src, pos, pos + 4) == "false" then
			pos += 5
			return FALSE
		elseif b == 110 and string.sub(src, pos, pos + 3) == "null" then
			pos += 4
			return NULL
		end
		local _, last = string.find(src, "^%-?%d+%.?%d*[eE]?[%+%-]?%d*", pos)
		if last == nil then
			return fail(if b == nil then "unexpected end" else "unexpected character")
		end
		local text = string.sub(src, pos, last)
		local n = tonumber(text)
		if n == nil then
			return fail("invalid number")
		end
		pos = last + 1
		return { kind = "number", n = n, s = text }
	end

	local ok, result = pcall(function(): Value
		local root = value(0)
		skip()
		if pos <= #src then
			fail("text after the JSON value")
		end
		return root
	end)
	if ok then
		return result, nil
	end
	local err: any = result
	if type(err) == "table" and type(err.msg) == "string" then
		return nil, err.msg
	end
	return nil, tostring(err)
end

-- Builders, for the text and CSV readers that produce the same shape.
local function str(s: string): Value
	return { kind = "string", s = s }
end

local function num(n: number, text: string?): Value
	return { kind = "number", n = n, s = text or tostring(n) }
end

local function bool(b: boolean): Value
	return if b then TRUE else FALSE
end

local function object(): Value
	return { kind = "object", keys = {}, map = {} }
end

local function set(obj: Value, key: string, v: Value)
	local map = obj.map :: { [string]: Value }
	if map[key] == nil then
		table.insert(obj.keys :: { string }, key)
	end
	map[key] = v
end

local function array(items: { Value }?): Value
	return { kind = "array", items = items or {} }
end

-- Member `key` of an object, or nil.
local function get(v: Value?, key: string): Value?
	if v and v.kind == "object" then
		return (v.map :: { [string]: Value })[key]
	end
	return nil
end

-- The string or number text of a scalar, or nil.
local function text(v: Value?): string?
	if v == nil then
		return nil
	elseif v.kind == "string" or v.kind == "number" then
		return v.s
	elseif v.kind == "boolean" then
		return if v.b then "true" else "false"
	end
	return nil
end

return {
	decode = decode,
	NULL = NULL,
	str = str,
	num = num,
	bool = bool,
	object = object,
	set = set,
	array = array,
	get = get,
	text = text,
}
