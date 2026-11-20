--!strict
-- The tenantctl block: the actions a person ran from the views, newest first. Each shows its
-- command, whether it is still running, and its result drawn like a lensed run, with that
-- result's own actions. `host.luau` starts the processes; this module keeps the state and draws it.

local output = require("./output")
local render = require("./render")
local actions = require("./actions")
local run = require("./run")

type UI = typeof(tern.ui)

export type Run = {
	id: number,
	line: string,
	cwd: string?,
	-- "running" | "done" | "failed" | "approval" | "interrupted"
	status: string,
	-- seconds it took, once it ended
	took: number?,
	code: number?,
	out: string?,
	err: string?,
	-- derived from `line` and the output, never saved
	spec: run.Spec?,
	doc: output.Doc?,
	inv: actions.Invocation?,
}

export type State = {
	runs: { Run },
	next: number,
	-- selected row per table path, the path led by its run (`r3:data`)
	selected: { [string]: number? },
}

-- The outcome a finished process reports.
export type Result = { status: number, stdout: string, stderr: string, timed_out: boolean }

-- Runs kept; older ones drop off the end.
local MAX_RUNS = 20
-- Output kept per run across a restart.
local MAX_SAVED = 256 * 1024

local function new(): State
	return { runs = {}, next = 1, selected = {} }
end

local function lines(text: string, into: { string })
	for line in string.gmatch(text .. "\n", "([^\n]*)\n") do
		table.insert(into, (string.gsub(line, "\r$", "")))
	end
	while #into > 0 and into[#into] == "" do
		table.remove(into)
	end
end

-- Reads a run's output back into a result view: stderr first, as the notes before the JSON.
local function parse(r: Run)
	local spec = r.spec
	if spec == nil or (r.out == nil and r.err == nil) then
		return
	end
	local all: { string } = {}
	lines(r.err or "", all)
	lines(r.out or "", all)
	local doc = output.read(all, spec.args)
	r.doc = doc
	if doc then
		local program = spec.argv[1]
		local rest = table.move(spec.argv, 2, #spec.argv, 1, {})
		r.inv = actions.invocation(program, rest, r.line, r.line, doc.command)
	end
end

-- Starts tracking a run of `line`: `running` when it is a tenantctl command, else `failed`.
local function add(state: State, line: string, cwd: string?): Run
	local r: Run = { id = state.next, line = line, cwd = cwd, status = "running", spec = run.spec(line) }
	state.next += 1
	if r.spec == nil then
		r.status = "failed"
		r.err = "Only tenantctl commands run here."
	end
	table.insert(state.runs, 1, r)
	while #state.runs > MAX_RUNS do
		table.remove(state.runs)
	end
	return r
end

-- Records how a run ended.
local function settle(r: Run, res: Result, took: number)
	r.took = took
	r.code = res.status
	r.out = res.stdout
	r.err = if res.timed_out then "Timed out after 10 minutes." else res.stderr
	parse(r)
	local doc = r.doc
	if doc and doc.kind == "confirm" then
		r.status = "approval"
	elseif res.status == 0 and not res.timed_out and (doc == nil or doc.kind == "success") then
		r.status = "done"
	else
		r.status = "failed"
	end
end

-- The toast for a run that ended: its level, text and second line.
local function summary(r: Run): (string, string, string?)
	local what = if r.spec then table.concat((r.spec :: run.Spec).args, " ") else r.line
	if r.status == "done" then
		return "success", "Done", what
	elseif r.status == "approval" then
		return "info", "Approval needed", what
	end
	local doc = r.doc
	return "error", "Failed", if doc and doc.message then doc.message else what
end

local ICONS: { [string]: string } =
	{ running = "clock", done = "check", failed = "x-circle", approval = "shield-alert", interrupted = "slash-circle" }
local TONES: { [string]: string } = { failed = "error", approval = "warning", interrupted = "warning" }

local function seconds(took: number?): string
	if took == nil then
		return ""
	end
	return if took < 10 then string.format(" · %.1fs", took) else string.format(" · %ds", math.floor(took))
end

local function statusText(r: Run): string
	if r.status == "running" then
		return "running"
	elseif r.status == "interrupted" then
		return "interrupted"
	elseif r.status == "approval" then
		return "needs approval" .. seconds(r.took)
	end
	local code = if r.code and r.code ~= 0 then `exit {r.code}` else if r.status == "done" then "done" else "failed"
	return code .. seconds(r.took)
end

local function with(node: Node, props: { [string]: any }): Node
	local p: { [string]: any } = node.p or {}
	for k, v in props do
		p[k] = v
	end
	node.p = p
	return node
end

local function runView(ui: UI, state: State, r: Run, latest: boolean, now: number): Node
	local spec = r.spec
	local body: { Node } = {
		with(ui.text(ui.span(r.line, "code")), { actions = { click = "copy" }, title = "Copy" }),
	}
	if r.status == "running" then
		table.insert(body, ui.progress(nil, "Running"))
		if spec and actions.riskOf(spec.args) == "destructive" then
			table.insert(
				body,
				ui.text(ui.span("tenantctl asks you to approve this before it changes anything.", "muted"))
			)
		end
	elseif r.doc then
		local opts: render.Opts = { now = now, selected = state.selected, inv = r.inv, prefix = `r{r.id}:` }
		table.insert(body, render.render(ui, r.doc :: output.Doc, opts))
	else
		local text = string.gsub((r.err or "") .. "\n" .. (r.out or ""), "^%s+", "")
		text = string.gsub(text, "%s+$", "")
		table.insert(body, if text == "" then ui.text(ui.span("No output", "muted")) else ui.code(text))
	end
	local head = if spec then table.concat(spec.args, " ") else r.line
	return with(
		ui.card(ui.span(head, "strong"), body, {
			icon = ICONS[r.status],
			meta = statusText(r),
		}),
		{ tone = TONES[r.status], collapsible = true, collapsed = not latest, key = `r{r.id}` }
	)
end

local function view(ui: UI, state: State, now: number): Node
	local nodes: { Node } = {}
	for i, r in state.runs do
		table.insert(nodes, runView(ui, state, r, i == 1, now))
	end
	if #nodes == 0 then
		table.insert(nodes, ui.text(ui.span("Actions you run from tenantctl views show here.", "muted")))
	end
	return with(ui.col(nodes), { role = "tenantctl.runs" })
end

-- What survives a restart: each run's line and output, never a run still to start.
local function save(state: State): any
	local runs = {}
	for _, r in state.runs do
		table.insert(runs, {
			id = r.id,
			line = r.line,
			cwd = r.cwd,
			status = r.status,
			took = r.took,
			code = r.code,
			out = if r.out then string.sub(r.out, 1, MAX_SAVED) else nil,
			err = if r.err then string.sub(r.err, 1, MAX_SAVED) else nil,
		})
	end
	return { next = state.next, runs = runs }
end

-- The state `save` kept; a run that was still going is shown as interrupted, never started again.
local function restore(saved: any): State
	local state = new()
	if type(saved) ~= "table" or type(saved.runs) ~= "table" then
		return state
	end
	state.next = if type(saved.next) == "number" then saved.next else 1
	for _, s in saved.runs do
		if type(s) == "table" and type(s.line) == "string" and type(s.id) == "number" then
			local r: Run = {
				id = s.id,
				line = s.line,
				cwd = s.cwd,
				status = if s.status == "running" then "interrupted" else tostring(s.status),
				took = s.took,
				code = s.code,
				out = s.out,
				err = s.err,
				spec = run.spec(s.line),
			}
			parse(r)
			table.insert(state.runs, r)
		end
	end
	return state
end

return {
	new = new,
	add = add,
	settle = settle,
	summary = summary,
	view = view,
	save = save,
	restore = restore,
}
