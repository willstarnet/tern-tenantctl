--!strict
-- tern-tenantctl's host half, the only file besides window.luau that touches the `tern` global:
--
-- - the `tenantctl` lens: while a command runs its raw output shows (so device-code sign-ins and
--   y/N approvals stay visible and answerable); when it ends, the output becomes a native view;
-- - the `action` block, where the views' actions run: a click opens an action link, which
--   window.luau routes here (asking for any input first), and the block runs tenantctl and draws
--   the result;
-- - a spawn filter that gives new shells TENANTCTL_OUTPUT=json, because inside a lens tenantctl
--   writes to a terminal and would otherwise print its table format, which cuts long values.

local output = require("./lens/output")
local render = require("./lens/render")
local actions = require("./lens/actions")
local run = require("./lens/run")
local runs = require("./lens/block")

-- Output past this stays raw: parsing runs inside the host's 2-second budget.
local MAX_BYTES = 4 * 1024 * 1024
-- An action that runs longer is stopped.
local TIMEOUT_MS = 10 * 60 * 1000

-- A secret action links carry, shared with window.luau through the plugin's store: a link printed
-- in a terminal can't name it, so clicking one runs nothing.
local function newNonce(): string
	local seed = math.floor(tern.now() * 1000) + os.time()
	local address = tostring({})
	for i = 1, #address do
		seed += string.byte(address, i) * i
	end
	math.randomseed(seed)
	local parts: { string } = {}
	for _ = 1, 4 do
		table.insert(parts, string.format("%08x", math.random(0, 0x7fffffff)))
	end
	return table.concat(parts)
end

local nonce = newNonce()
tern.kv.set("nonce", nonce)

-- The link a click opens: the command line, what to ask for first and where to run it.
local function link(line: string, ask: string?, cwd: string?): string
	local payload = tern.json.encode({ nonce = nonce, line = line, ask = ask, cwd = cwd })
	return "tern-tenantctl://action/" .. tern.base64.encode(payload, { url = true })
end

type LensState = {
	program: string,
	args: { string },
	typed: string,
	line: string,
	cwd: string?,
	lines: { string },
	bytes: number,
	tooLarge: boolean,
	done: boolean,
	-- the parsed output, once `parsed`; nil when it can't be read
	parsed: boolean,
	doc: output.Doc?,
	-- how the run started tenantctl, for the actions
	inv: actions.Invocation?,
	-- selected row per table path
	selected: { [string]: number? },
	-- open actions panel per record path
	opened: { [string]: string? },
}

-- Toggles the selected row an event names (`data#3`, `r2:data.devices#1`).
local function toggleRow(selected: { [string]: number? }, ev: UiEvent)
	if (ev.ev == "select" or ev.ev == "activate") and type(ev.item) == "string" then
		local path, index = string.match(ev.item, "^(.*)#(%d+)$")
		if path and index then
			local i = tonumber(index) :: number
			selected[path] = if selected[path] == i then nil else i
		end
	end
end

-- Opens the actions panel an `open=<path>|<panel>` click names, or closes it when it is open.
-- True when the event was one.
local function togglePanel(opened: { [string]: string? }, ev: UiEvent): boolean
	if ev.ev ~= "action" or ev.act ~= "open" or type(ev.value) ~= "string" then
		return false
	end
	local path, panel = string.match(ev.value, "^(.*)|([^|]+)$")
	if path and panel then
		opened[path] = if opened[path] == panel then nil else panel
	end
	return true
end

local lens: LensDef<LensState> = {
	open = function(r, _cx)
		return {
			program = r.program,
			args = r.args,
			typed = r.typed,
			line = r.line,
			cwd = r.cwd,
			lines = {},
			bytes = 0,
			tooLarge = false,
			done = false,
			parsed = false,
			doc = nil,
			inv = nil,
			selected = {},
			opened = {},
		}
	end,

	line = function(state, l)
		if state.tooLarge then
			return
		end
		state.bytes += #l.text + 1
		if state.bytes > MAX_BYTES then
			state.tooLarge = true
			state.lines = {}
			return
		end
		table.insert(state.lines, l.text)
	end,

	finish = function(state, _status)
		state.done = true
	end,

	view = function(state)
		if not state.done or state.tooLarge then
			return nil
		end
		if not state.parsed then
			state.parsed = true
			state.doc = output.read(state.lines, state.args)
			state.lines = {}
			if state.doc then
				state.inv = actions.invocation(state.program, state.args, state.typed, state.line, state.doc.command)
			end
		end
		local doc = state.doc
		if doc == nil then
			return nil
		end
		return render.render(
			tern.ui,
			doc,
			{ now = os.time(), selected = state.selected, opened = state.opened, inv = state.inv }
		)
	end,

	event = function(state, ev, cx)
		if togglePanel(state.opened, ev) then
			return
		elseif ev.ev == "action" then
			local line, ask = run.parseAct(ev.act, ev.value)
			if line then
				cx:open(link(line, ask, state.cwd))
			end
			return
		end
		toggleRow(state.selected, ev)
	end,
}

tern.lens.define("tenantctl", lens)

-- Starts `line` in the block: tenantctl itself, through the login shell so it is found on the same
-- PATH as in a terminal, its words passed as arguments (never read as shell code).
local function start(state: runs.State, cx: BlockCx, line: string, cwd: string?)
	local r = runs.add(state, line, cwd)
	local spec = r.spec
	if spec == nil then
		return
	end
	local shell = tern.getenv("SHELL") or "/bin/sh"
	local argv = if string.match(shell, "fish$")
		then { shell, "-lc", "exec $argv" }
		else { shell, "-lc", 'exec "$@"', "tenantctl" }
	table.move(spec.argv, 1, #spec.argv, #argv + 1, argv)
	local env = table.clone(spec.env)
	env.TENANTCTL_OUTPUT = "json"
	local began = tern.now()
	local ok, err = pcall(
		tern.process.run :: any,
		argv,
		{ cwd = cwd or tern.getenv("HOME"), env = env, timeout_ms = TIMEOUT_MS },
		function(res: ProcessResult)
			runs.settle(r, res, (tern.now() - began) / 1000)
			cx:render()
			cx:save()
			local level, text, sub = runs.summary(r)
			cx:toast(level :: ToastLevel, text, sub)
		end
	)
	if not ok then
		runs.settle(r, { status = -1, stdout = "", stderr = tostring(err), timed_out = false }, 0)
	end
end

-- An action link's payload, when it carries this plugin's secret.
local function decode(text: any): { line: string, cwd: string? }?
	if type(text) ~= "string" then
		return nil
	end
	local ok, payload = pcall(tern.json.decode, text)
	if not ok or type(payload) ~= "table" or payload.nonce ~= nonce or type(payload.line) ~= "string" then
		return nil
	end
	return { line = payload.line, cwd = if type(payload.cwd) == "string" then payload.cwd else nil }
end

local block: BlockDef<runs.State> = {
	init = function(cx, args, saved)
		if saved ~= nil then
			return runs.restore(saved)
		end
		local state = runs.new()
		local payload = decode(args[1])
		if payload then
			start(state, cx, payload.line, payload.cwd)
		end
		-- saved at once, so a restart shows this run instead of starting it again
		cx:save()
		return state
	end,

	view = function(state, _cx)
		return { main = runs.view(tern.ui, state, os.time()) }
	end,

	title = function(_state)
		return "tenantctl"
	end,

	event = function(state, ev, cx)
		if ev.ev == "action" and ev.act == "enqueue" then
			-- an action routed here by window.luau
			local payload = decode(ev.value)
			if payload then
				start(state, cx, payload.line, payload.cwd)
			end
			return
		elseif ev.ev == "action" and ev.act == "copy" and type(ev.value) == "string" then
			cx:copy(ev.value)
			cx:toast("success", "Copied")
			return
		elseif togglePanel(state.opened, ev) then
			return
		elseif ev.ev == "action" then
			local line, ask = run.parseAct(ev.act, ev.value)
			if line then
				local cwd = if state.runs[1] then state.runs[1].cwd else nil
				if ask then
					cx:open(link(line, ask, cwd))
				else
					start(state, cx, line, cwd)
				end
			end
			return
		end
		toggleRow(state.selected, ev)
	end,

	save = runs.save,
	font = "sans",
}

tern.block.define("action", block)

tern.on("spawn", function(spec: SpawnSpec): SpawnSpec?
	-- A value the user set (login environment or this filter's predecessors) wins.
	if tern.getenv("TENANTCTL_OUTPUT") ~= nil or spec.env.TENANTCTL_OUTPUT ~= nil then
		return nil
	end
	spec.env.TENANTCTL_OUTPUT = "json"
	return spec
end)
