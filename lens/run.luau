--!strict
-- Running an action: the command line a view built, read back into the argv to start (only ever
-- tenantctl, never a shell), the input it still needs filled in, and the click that carries both.

local actions = require("./actions")
local format = require("./format")

export type Spec = {
	-- what to start: `tenantctl …`, `./bin/tenantctl …` or `bun run tenantctl …`
	argv: { string },
	-- `TENANTCTL_*=…` assignments the line started with
	env: { [string]: string },
	-- tenantctl's own arguments, for reading its output
	args: { string },
}

-- Characters a shell would read as more than a word: expansions, globs, operators, comments.
local SPECIAL = "[%$`;&|<>()*?%[%]{}~!#\\]"

-- The words of a command line as `actions.quote` writes them: bare words, '…', and "…" holding
-- only ' or \. Nil for anything a shell would read differently (expansions, operators, globs,
-- unbalanced quotes, control characters), so the words are exactly what a shell would pass.
local function words(line: string): { string }?
	if string.find(line, "%c") then
		return nil
	end
	local out: { string } = {}
	local i = 1
	local n = #line
	while i <= n do
		while i <= n and string.sub(line, i, i) == " " do
			i += 1
		end
		if i > n then
			break
		end
		local word = ""
		while i <= n and string.sub(line, i, i) ~= " " do
			local ch = string.sub(line, i, i)
			if ch == "'" then
				local close = string.find(line, "'", i + 1, true)
				if close == nil then
					return nil
				end
				word ..= string.sub(line, i + 1, close - 1)
				i = close + 1
			elseif ch == '"' then
				local close = string.find(line, '"', i + 1, true)
				local inner = if close then string.sub(line, i + 1, close - 1) else nil
				if inner == nil or not (inner == "'" or inner == "\\\\") then
					return nil
				end
				word ..= if inner == "'" then "'" else "\\"
				i = (close :: number) + 1
			elseif string.find(ch, SPECIAL) then
				return nil
			else
				word ..= ch
				i += 1
			end
		end
		table.insert(out, word)
	end
	return out
end

-- What to start for `line`, or nil when it isn't a tenantctl command: a program named tenantctl
-- (by path or on PATH) or `bun run tenantctl`, after `TENANTCTL_*=…` assignments only.
local function spec(line: string): Spec?
	local w = words(line)
	if w == nil then
		return nil
	end
	local env: { [string]: string } = {}
	local i = 1
	while w[i] do
		local name, value = string.match(w[i], "^(TENANTCTL_[%u_]+)=(.*)$")
		if name == nil then
			break
		end
		env[name :: string] = value :: string
		i += 1
	end
	local argv: { string }
	if w[i] == "bun" and w[i + 1] == "run" and w[i + 2] == "tenantctl" then
		argv = { "bun", "run", "tenantctl" }
		i += 3
	elseif w[i] == "tenantctl" or (w[i] and string.match(w[i], "/tenantctl$")) then
		argv = { w[i] }
		i += 1
	else
		return nil
	end
	local args = table.move(w, i, #w, 1, {})
	if #args == 0 then
		return nil
	end
	table.move(args, 1, #args, #argv + 1, argv)
	return { argv = argv, env = env, args = args }
end

-- The prompt's hint for what `ask` needs: `Name`, `Group`, `Options`, or the placeholder's text.
local function hint(ask: string, line: string): string
	if ask == "*" then
		return "Options, e.g. --department Sales"
	elseif ask == "<" then
		return string.match(line, "<([^>]+)>") or "Value"
	end
	return format.label((string.gsub(ask, "^%-%-", "")))
end

-- `line` with the person's `answer` to `ask` in place: a flag's value or a positional quoted on
-- the end, options appended as typed, a `<placeholder>` replaced. Nil when the answer is empty or
-- would not read as plain words.
local function complete(line: string, ask: string, answer: string): string?
	answer = string.match(answer, "^%s*(.-)%s*$") or ""
	if answer == "" then
		return nil
	end
	if ask == "*" then
		return if words(answer) then `{line} {answer}` else nil
	end
	local q = actions.quote(answer)
	if q == nil then
		return nil
	elseif ask == "<" then
		local first, last = string.find(line, "<[^>]+>")
		return if first then string.sub(line, 1, first - 1) .. q .. string.sub(line, (last :: number) + 1) else nil
	elseif string.sub(ask, 1, 2) == "--" then
		return `{line} {ask} {q}`
	end
	return `{line} {q}`
end

-- A finding's next step asks for its `<placeholder>`, if it has one.
local function askOf(line: string): string?
	return if string.find(line, "<[^>]+>") then "<" else nil
end

-- The click of an action: `run=<line>`, or `ask=<what>|<line>` when it needs input first.
local function act(line: string, ask: string?): string
	return if ask then `ask={ask}|{line}` else `run={line}`
end

-- A click's line and what it asks for, from the event's `act` and `value` (Tern splits the action
-- name at its first `=`).
local function parseAct(name: any, value: any): (string?, string?)
	if type(name) ~= "string" then
		return nil, nil
	end
	if value == nil then
		local a, v = string.match(name, "^(%a+)=(.*)$")
		name, value = a, v
	end
	if type(value) ~= "string" then
		return nil, nil
	elseif name == "run" then
		return value, nil
	elseif name == "ask" then
		local ask, line = string.match(value, "^([^|]+)|(.*)$")
		return line, ask
	end
	return nil, nil
end

return {
	words = words,
	spec = spec,
	hint = hint,
	complete = complete,
	askOf = askOf,
	act = act,
	parseAct = parseAct,
}
