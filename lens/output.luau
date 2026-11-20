--!strict
-- What a tenantctl run printed, read into a `Doc`: a result, an error or a confirmation request,
-- plus the notes it wrote to stderr. JSON (the envelope `--output json` prints) is read first; the
-- terminal table format and `--csv` are read when there is no JSON. Anything else (help,
-- `--version`, a crash) gives nil and the lens shows the raw output.

local json = require("./json")
local text = require("./text")
type Value = json.Value

export type Meta = {
	count: number?,
	total: number?,
	truncated: boolean,
	hint: string?,
	unavailable: Value?,
}

export type Doc = {
	-- "success" | "error" | "confirm"
	kind: string,
	-- "json" | "table" | "csv": table and csv values may be cut
	format: string,
	-- success: the result
	data: Value?,
	meta: Meta?,
	-- error
	code: string?,
	message: string?,
	hint: string?,
	details: Value?,
	requestId: string?,
	-- confirm
	command: string?,
	preview: Value?,
	rerun: string?,
	expiresAt: string?,
	-- lines outside the result: stderr progress and warnings
	notes: { string },
}

-- Lines worth keeping as notes: not blank, in order.
local function notesOf(lines: { string }, from: number, to: number, into: { string }?): { string }
	local out = into or {}
	for i = from, to do
		if string.match(lines[i], "%S") then
			table.insert(out, lines[i])
		end
	end
	return out
end

-- How the user asked for output, from argv: "json", "table", "csv" or nil (the default).
local function requestedFormat(args: { string }): string?
	local format: string? = nil
	local i = 1
	while i <= #args do
		local a = args[i]
		if a == "--" then
			break
		elseif a == "--json" then
			format = "json"
		elseif a == "--csv" then
			format = "csv"
		elseif (a == "-o" or a == "--output") and args[i + 1] then
			format = args[i + 1]
			i += 1
		elseif string.sub(a, 1, 9) == "--output=" then
			format = string.sub(a, 10)
		end
		i += 1
	end
	return format
end

-- Help, version and bare runs print prose for people; leave them raw.
local function isHelp(args: { string }): boolean
	if #args == 0 or args[1] == "help" then
		return true
	end
	for _, a in args do
		if a == "--" then
			break
		elseif a == "--help" or a == "-h" or a == "--version" or a == "-V" then
			return true
		end
	end
	return false
end

local function metaOf(v: Value?): Meta?
	if v == nil or v.kind ~= "object" then
		return nil
	end
	local count = json.get(v, "count")
	local total = json.get(v, "total")
	local truncated = json.get(v, "truncated")
	local hint = json.get(v, "hint")
	return {
		count = if count and count.kind == "number" then count.n else nil,
		total = if total and total.kind == "number" then total.n else nil,
		truncated = truncated ~= nil and truncated.kind == "boolean" and truncated.b == true,
		hint = json.text(hint),
		unavailable = json.get(v, "unavailable"),
	}
end

local function fromEnvelope(env: Value, notes: { string }): Doc
	local ok = json.get(env, "ok")
	if env.kind == "object" and ok and ok.kind == "boolean" then
		if ok.b then
			return {
				kind = "success",
				format = "json",
				data = json.get(env, "data"),
				meta = metaOf(json.get(env, "meta")),
				notes = notes,
			}
		end
		local confirm = json.get(env, "confirm")
		if confirm then
			return {
				kind = "confirm",
				format = "json",
				command = json.text(json.get(env, "command")),
				preview = json.get(env, "preview"),
				rerun = json.text(json.get(confirm, "rerun")),
				expiresAt = json.text(json.get(confirm, "expiresAt")),
				notes = notes,
			}
		end
		local err = json.get(env, "error")
		if err then
			return {
				kind = "error",
				format = "json",
				code = json.text(json.get(err, "code")),
				message = json.text(json.get(err, "message")),
				hint = json.text(json.get(err, "hint")),
				details = json.get(err, "details"),
				requestId = json.text(json.get(err, "requestId")),
				notes = notes,
			}
		end
	end
	-- JSON without tenantctl's envelope: show it as the result.
	return { kind = "success", format = "json", data = env, notes = notes }
end

-- The pretty-printed JSON document in `lines`: tenantctl writes it as one `{` line through the
-- first unindented `}` line. Everything around it is a note.
local function readJson(lines: { string }): Doc?
	local first, last
	for i, line in lines do
		if first == nil then
			if line == "{" then
				first = i
			end
		elseif line == "}" then
			last = i
			break
		end
	end
	if first == nil or last == nil then
		return nil
	end
	local doc = json.decode(table.concat(lines, "\n", first, last))
	if doc == nil then
		return nil
	end
	local notes = notesOf(lines, 1, first - 1)
	notesOf(lines, last + 1, #lines, notes)
	return fromEnvelope(doc, notes)
end

local function readError(lines: { string }): Doc?
	for i, line in lines do
		local code, message = string.match(line, "^Error %[([%u_]+)%]: (.*)$")
		if code and message then
			local doc: Doc = {
				kind = "error",
				format = "table",
				code = code,
				message = message,
				notes = notesOf(lines, 1, i - 1),
			}
			local rest = i + 1
			local hint = lines[rest] and string.match(lines[rest], "^Hint: (.*)$")
			if hint then
				doc.hint = hint
				rest += 1
			end
			local last = #lines
			while last >= rest and lines[last] == "" do
				last -= 1
			end
			local request = lines[last] and string.match(lines[last], "^Graph request id: (.*)$")
			if request then
				doc.requestId = request
				last -= 1
			end
			if last >= rest then
				doc.details = text.body(lines, rest, last)
				if doc.details == nil then
					notesOf(lines, rest, last, doc.notes)
				end
			end
			return doc
		end
	end
	return nil
end

local function readConfirm(lines: { string }): Doc?
	for i, line in lines do
		local command = string.match(line, "^Confirmation required for: (.*)$")
		if command then
			for j = i + 1, #lines do
				local expires = string.match(lines[j], "^To proceed %(valid until (.*)%):$")
				if expires then
					return {
						kind = "confirm",
						format = "table",
						command = command,
						preview = text.body(lines, i + 1, j - 1),
						expiresAt = expires,
						rerun = if lines[j + 1] then string.match(lines[j + 1], "^%s*(.-)%s*$") else nil,
						notes = notesOf(lines, 1, i - 1),
					}
				end
			end
			return nil
		end
	end
	return nil
end

local function readTable(lines: { string }): Doc?
	local last = #lines
	while last >= 1 and lines[last] == "" do
		last -= 1
	end
	if last == 0 then
		return nil
	end
	local foot = text.footer(lines[last])
	local bodyLast = if foot then last - 1 else last
	for first = 1, bodyLast do
		if lines[first] ~= "" then
			local data = text.body(lines, first, bodyLast)
			if data then
				local meta: Meta? = nil
				if foot then
					meta = { count = foot.count, total = foot.total, truncated = foot.truncated, hint = foot.hint }
				end
				return {
					kind = "success",
					format = "table",
					data = data,
					meta = meta,
					notes = notesOf(lines, 1, first - 1),
				}
			end
		end
	end
	return nil
end

-- Reads one run's output lines, given its arguments.
local function read(lines: { string }, args: { string }): Doc?
	if isHelp(args) then
		return nil
	end
	local fromJson = readJson(lines)
	if fromJson then
		return fromJson
	end
	local err = readError(lines)
	if err then
		return err
	end
	local confirm = readConfirm(lines)
	if confirm then
		return confirm
	end
	if requestedFormat(args) == "csv" then
		local data = text.csv(lines)
		return if data then { kind = "success", format = "csv", data = data, notes = {} } else nil
	end
	return readTable(lines)
end

return {
	read = read,
	requestedFormat = requestedFormat,
	isHelp = isHelp,
}
