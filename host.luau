--!strict
-- tern-tenantctl's host half, the only file that touches the `tern` global:
--
-- - the `tenantctl` lens: while a command runs its raw output shows (so device-code sign-ins and
--   y/N approvals stay visible and answerable); when it ends, the output becomes a native view
--   whose actions type tenantctl commands into the pane;
-- - a spawn filter that gives new shells TENANTCTL_OUTPUT=json, because inside a lens tenantctl
--   writes to a terminal and would otherwise print its table format, which cuts long values.

local output = require("./lens/output")
local render = require("./lens/render")
local actions = require("./lens/actions")

-- Output past this stays raw: parsing runs inside the host's 2-second budget.
local MAX_BYTES = 4 * 1024 * 1024
-- How long a lens waits to hear which pane its command started in.
local MATCH_MS = 2000
-- After typing a command, how long its pane counts as busy before the shell reports it started.
local SENT_MS = 1500

type State = {
	program: string,
	args: { string },
	typed: string,
	line: string,
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
	-- the pane the command ran in, once the shell said so
	pane: number?,
}

local function trim(s: string): string
	return (string.gsub(string.gsub(s, "^%s+", ""), "%s+$", ""))
end

-- Which pane each running command line is in, from the shell's reports, so a lens knows where to
-- type its actions. A lens may open before or after its command's report arrives.
local running: { [string]: number } = {}
local waiting: { [string]: { state: State, at: number } } = {}
-- Panes running a command (typing into one would answer its prompt), and when an action was typed.
local busy: { [number]: boolean } = {}
local sent: { [number]: number } = {}

tern.on("command_started", function(ev: CommandStartedEvent, _cx: EffectCx)
	local line = trim(ev.line)
	busy[ev.pane] = true
	sent[ev.pane] = nil
	running[line] = ev.pane
	local now = tern.now()
	for key, w in waiting do
		if key == line and now - w.at < MATCH_MS then
			w.state.pane = ev.pane
		end
		if key == line or now - w.at >= MATCH_MS then
			waiting[key] = nil
		end
	end
end)

tern.on("command_finished", function(ev: CommandFinishedEvent, _cx: EffectCx)
	busy[ev.pane] = nil
	local line = trim(ev.line)
	if running[line] == ev.pane then
		running[line] = nil
	end
end)

tern.on("pane_exited", function(ev: PaneExitedEvent, _cx: EffectCx)
	busy[ev.pane] = nil
	sent[ev.pane] = nil
	for line, pane in running do
		if pane == ev.pane then
			running[line] = nil
		end
	end
end)

-- Types `line` at the prompt of the pane the view is in, and runs it unless `run` is false. Without
-- a pane to type into (one that is busy, or a view restored after a reload) it goes on the clipboard.
local function send(state: State, line: string, run: boolean, cx: EffectCx)
	-- the view built this line; a control character would let a shell read more than one line
	if string.find(line, "%c") then
		return
	end
	local pane = state.pane
	local typing = pane and sent[pane] and tern.now() - (sent[pane] :: number) < SENT_MS
	if pane == nil or busy[pane] or typing then
		cx:copy(line)
		cx:toast("info", "Command copied", if pane then "The pane is busy" else "Paste it at the prompt")
		return
	end
	-- Ctrl-E Ctrl-U (5, 21) first: whatever was typed at the prompt goes, so the line runs alone
	tern.pane.write(pane, "\5\21" .. line .. (if run then "\r" else ""))
	if run then
		sent[pane] = tern.now()
	end
end

local lens: LensDef<State> = {
	open = function(run, _cx)
		local state: State = {
			program = run.program,
			args = run.args,
			typed = run.typed,
			line = run.line,
			lines = {},
			bytes = 0,
			tooLarge = false,
			done = false,
			parsed = false,
			doc = nil,
			inv = nil,
			selected = {},
			pane = nil,
		}
		local typed = trim(run.typed)
		state.pane = running[typed] or running[trim(run.line)]
		if state.pane == nil then
			waiting[typed] = { state = state, at = tern.now() }
		end
		return state
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
		return render.render(tern.ui, doc, { now = os.time(), selected = state.selected, inv = state.inv })
	end,

	event = function(state, ev, cx)
		if ev.ev == "action" then
			-- `run=<line>` / `fill=<line>`: Tern splits the name at `=`; split it here when it didn't
			local act, value = ev.act, ev.value
			if value == nil and type(act) == "string" then
				local a, v = string.match(act, "^(%a+)=(.*)$")
				if a then
					act, value = a, v
				end
			end
			if (act == "run" or act == "fill") and type(value) == "string" then
				send(state, value, act == "run", cx)
			end
			return
		end
		if (ev.ev == "select" or ev.ev == "activate") and type(ev.item) == "string" then
			local path, index = string.match(ev.item, "^(.*)#(%d+)$")
			if path and index then
				local i = tonumber(index) :: number
				state.selected[path] = if state.selected[path] == i then nil else i
			end
		end
	end,
}

tern.lens.define("tenantctl", lens)

tern.on("spawn", function(spec: SpawnSpec): SpawnSpec?
	-- A value the user set (login environment or this filter's predecessors) wins.
	if tern.getenv("TENANTCTL_OUTPUT") ~= nil or spec.env.TENANTCTL_OUTPUT ~= nil then
		return nil
	end
	spec.env.TENANTCTL_OUTPUT = "json"
	return spec
end)
