--!strict
-- tern-tenantctl's host half, the only file that touches the `tern` global:
--
-- - the `tenantctl` lens: while a command runs its raw output shows (so device-code sign-ins and
--   y/N approvals stay visible and answerable); when it ends, the output becomes a native view;
-- - a spawn filter that gives new shells TENANTCTL_OUTPUT=json, because inside a lens tenantctl
--   writes to a terminal and would otherwise print its table format, which cuts long values.

local output = require("./lens/output")
local render = require("./lens/render")

-- Output past this stays raw: parsing runs inside the host's 2-second budget.
local MAX_BYTES = 4 * 1024 * 1024

type State = {
	args: { string },
	lines: { string },
	bytes: number,
	tooLarge: boolean,
	done: boolean,
	-- the parsed output, once `parsed`; nil when it can't be read
	parsed: boolean,
	doc: output.Doc?,
	-- selected row per table path
	selected: { [string]: number? },
}

local lens: LensDef<State> = {
	open = function(run, _cx)
		return {
			args = run.args,
			lines = {},
			bytes = 0,
			tooLarge = false,
			done = false,
			parsed = false,
			doc = nil,
			selected = {},
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
		end
		local doc = state.doc
		if doc == nil then
			return nil
		end
		return render.render(tern.ui, doc, { now = os.time(), selected = state.selected })
	end,

	event = function(state, ev, _cx)
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
