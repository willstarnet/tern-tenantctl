--!strict
-- Reads tenantctl's terminal format (`--output table`, its default on a terminal) back into a
-- `Value`, so panes where TENANTCTL_OUTPUT isn't json still get a native view. The format is
-- tenantctl's `describe` (src/core/output.ts):
--
--   key        value           scalars first, keys padded, two spaces before the value
--                              then sections, each after a blank line:
--   key (N)                    a list of rows: header, dashes, rows (tables are never indented)
--   head  head
--   ----  ----
--   key                        an object of more than three fields, indented two spaces
--     key  value
--
-- Cells are cut at 60 characters and values at 120 with `…`; what was cut stays cut.

local json = require("./json")
type Value = json.Value

local function isDash(line: string?): boolean
	return line ~= nil and string.match(line, "^%-+[%- ]*$") ~= nil and string.find(line, "%-%-") ~= nil
end

local function indentOf(line: string): number
	local spaces = string.match(line, "^ *") :: string
	return #spaces
end

-- A cell or scalar as a value: empty → null, true/false, numbers (keeping their text, so
-- `02139` still reads `02139`), JSON objects and arrays that weren't cut, else a string.
local function cellValue(s: string): Value
	if s == "" then
		return json.NULL
	elseif s == "true" then
		return json.bool(true)
	elseif s == "false" then
		return json.bool(false)
	elseif string.match(s, "^%-?%d+%.?%d*$") then
		return json.num(tonumber(s) :: number, s)
	end
	local first = string.sub(s, 1, 1)
	if (first == "{" or first == "[") and string.sub(s, -3) ~= "…" then
		local v = json.decode(s)
		if v then
			return v
		end
	end
	return json.str(s)
end

-- Byte offset where character `index` (1-based) of `line` starts, or one past the end.
local function charOffset(line: string, index: number): number
	local ok, at = pcall(utf8.offset, line, index)
	if ok and at then
		return at
	end
	return #line + 1
end

-- The table whose header is `lines[pos]` (dashes on the next line): its rows as objects, and the
-- position after its last row.
local function parseTable(lines: { string }, pos: number, last: number): (Value, number)
	local header = lines[pos]
	local dash = lines[pos + 1]
	local starts: { number } = {}
	for s in string.gmatch(dash, "()%-+") do
		table.insert(starts, s :: any)
	end
	local function cells(line: string): { string }
		local out: { string } = {}
		for j, s in starts do
			local from = charOffset(line, s)
			local to = if starts[j + 1] then charOffset(line, starts[j + 1]) - 1 else #line
			local text = string.sub(line, from, to)
			out[j] = string.match(text, "^%s*(.-)%s*$") :: string
		end
		return out
	end
	local heads = cells(header)
	local rows: { Value } = {}
	local at = pos + 2
	while at <= last and lines[at] ~= "" do
		local row = json.object()
		for j, text in cells(lines[at]) do
			json.set(row, heads[j], cellValue(text))
		end
		table.insert(rows, row)
		at += 1
	end
	return json.array(rows), at
end

-- The object written at `indent` from `pos`, and where it ends; nil when a line doesn't fit.
local function parseObject(lines: { string }, pos: number, last: number, indent: number): (Value?, number)
	local obj = json.object()
	while pos <= last do
		local line = lines[pos]
		if line == "" then
			pos += 1
			continue
		end
		local lead = indentOf(line)
		if lead < indent then
			break
		elseif lead > indent then
			return nil, pos
		end
		local content = string.sub(line, indent + 1)
		local key, count = string.match(content, "^(%S+) %((%d+)%)$")
		if key and count and isDash(lines[pos + 2]) then
			local rows, after = parseTable(lines, pos + 1, last)
			json.set(obj, key, rows)
			pos = after
			continue
		end
		local only = string.match(content, "^(%S+)$")
		local nextLine = lines[pos + 1]
		if only and nextLine and nextLine ~= "" and indentOf(nextLine) == indent + 2 then
			local child, after = parseObject(lines, pos + 1, last, indent + 2)
			if child == nil then
				return nil, after
			end
			json.set(obj, only, child)
			pos = after
			continue
		end
		local k, v = string.match(content, "^(%S+)  +(.*)$")
		if k and v then
			json.set(obj, k, cellValue(v))
		elseif only then
			json.set(obj, only, json.NULL)
		else
			return nil, pos
		end
		pos += 1
	end
	return obj, pos
end

-- `describe` output in `lines[first..last]` as a value, or nil when it isn't that format.
local function body(lines: { string }, first: number, last: number): Value?
	while first <= last and lines[first] == "" do
		first += 1
	end
	while last >= first and lines[last] == "" do
		last -= 1
	end
	if first > last then
		return nil
	end
	if first == last and lines[first] == "(none)" then
		return json.array()
	end
	if isDash(lines[first + 1]) and indentOf(lines[first]) == 0 then
		local rows, after = parseTable(lines, first, last)
		while after <= last and lines[after] == "" do
			after += 1
		end
		return if after > last then rows else nil
	end
	local obj, after = parseObject(lines, first, last, 0)
	if obj == nil or after <= last or #(obj.keys :: { string }) == 0 then
		return nil
	end
	return obj
end

export type Footer = { count: number?, total: number?, truncated: boolean, hint: string? }

-- The count line tenantctl prints under a list (`3 results`, `3 of 57 shown: raise --top or pass
-- --all.`, `5 shown; More results exist: …`), or nil.
local function footer(line: string): Footer?
	local n = string.match(line, "^(%d+) results?$")
	if n then
		return { count = tonumber(n), truncated = false }
	end
	if not string.find(line, "raise --top or pass --all", 1, true) then
		return nil
	end
	local shown, total = string.match(line, "^(%d+) of (%d+) shown")
	if shown then
		return { count = tonumber(shown), total = tonumber(total), truncated = true, hint = line }
	end
	local count, hint = string.match(line, "^(%d+) shown; (.*)$")
	return { count = if count then tonumber(count) else nil, truncated = true, hint = hint or line }
end

-- RFC 4180 CSV (tenantctl's `--csv`): the header row's names as keys, one object per row.
local function csv(lines: { string }): Value?
	local text = table.concat(lines, "\n")
	local records: { { string } } = {}
	local record: { string } = {}
	local field: { string } = {}
	local i, n = 1, #text
	local quoted = false
	while i <= n do
		local c = string.sub(text, i, i)
		if quoted then
			if c == '"' then
				if string.sub(text, i + 1, i + 1) == '"' then
					table.insert(field, '"')
					i += 1
				else
					quoted = false
				end
			else
				table.insert(field, c)
			end
		elseif c == '"' then
			quoted = true
		elseif c == "," then
			table.insert(record, table.concat(field))
			field = {}
		elseif c == "\n" or c == "\r" then
			if c == "\r" and string.sub(text, i + 1, i + 1) == "\n" then
				i += 1
			end
			table.insert(record, table.concat(field))
			table.insert(records, record)
			record, field = {}, {}
		else
			table.insert(field, c)
		end
		i += 1
	end
	if #field > 0 or #record > 0 then
		table.insert(record, table.concat(field))
		table.insert(records, record)
	end
	local head = records[1]
	if head == nil or #head == 0 then
		return nil
	end
	local rows: { Value } = {}
	for r = 2, #records do
		local cells = records[r]
		if #cells == 1 and cells[1] == "" then
			continue
		end
		if #cells ~= #head then
			return nil
		end
		local row = json.object()
		for j, name in head do
			json.set(row, name, cellValue(cells[j]))
		end
		table.insert(rows, row)
	end
	return json.array(rows)
end

return {
	body = body,
	footer = footer,
	csv = csv,
	cellValue = cellValue,
	isDash = isDash,
}
