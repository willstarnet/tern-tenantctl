--!strict
-- The tenantctl block: a workspace per record a person works on. Opening a record (an action
-- clicked in a view, Open on a listed record) reads it whole and keeps it open in a tab; its
-- actions lead the workspace. A lookup shows its result in the workspace, in a tab of its own that
-- the next run of it refreshes in place; a change goes to the workspace's activity, then the record
-- is read again so what it shows stays current. A list (`intune devices list`) opens as a workspace
-- of its own, where several rows can be picked and one action run on each. `host.luau` starts the
-- processes; this module keeps the state and draws it.

local json = require("./json")
local output = require("./output")
local render = require("./render")
local actions = require("./actions")
local records = require("./records")
local run = require("./run")

type UI = typeof(tern.ui)
type Value = json.Value

export type Run = {
	id: number,
	line: string,
	cwd: string?,
	-- "queued" | "running" | "done" | "failed" | "approval" | "interrupted"
	status: string,
	-- the action's name (`Sync`, `Reveal LAPS password`) and its risk
	label: string,
	risk: string,
	-- the record it acted on, when not the workspace's own (a picked row, a related record)
	target: string?,
	-- the table row it ran for, when run on picked rows (`r4:data#2`)
	row: string?,
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

-- One action in a workspace's activity: on its record, or on several picked rows.
export type Entry = { id: number, label: string, runs: { number } }

export type Workspace = {
	key: string,
	-- the record's kind and what names it; nil for a list or other command
	kind: string?,
	ref: string?,
	-- other values that name the same record (its id once read, its name)
	aliases: { [string]: boolean },
	name: string,
	-- the line that opened it: its program and profile start every action; a list's command
	line: string,
	cwd: string?,
	-- a record: the run that read it whole; a command: its run
	details: number?,
	-- lookups' results, by action, in the order first run
	tabs: { { label: string, run: number } },
	tab: string?,
	-- changes, newest first
	activity: { Entry },
}

export type State = {
	spaces: { Workspace },
	current: string?,
	runs: { Run },
	next: number,
	-- selected row and open panel per path; tables picking several rows and their picks
	selected: { [string]: number? },
	opened: { [string]: string? },
	picking: { [string]: boolean },
	picked: { [string]: { string } },
}

-- Outcome of a finished process.
export type Result = { status: number, stdout: string, stderr: string, timed_out: boolean }

-- Workspaces kept; the oldest one not shown closes first.
local MAX_SPACES = 12
-- Activity entries kept per workspace.
local MAX_ENTRIES = 30
-- Output kept per run across a restart.
local MAX_SAVED = 64 * 1024
-- Runs going at once; the rest of a batch waits its turn.
local PARALLEL = 4

local DETAILS = "Details"

local function new(): State
	return { spaces = {}, runs = {}, next = 1, selected = {}, opened = {}, picking = {}, picked = {} }
end

local function runById(state: State, id: number?): Run?
	if id == nil then
		return nil
	end
	for _, r in state.runs do
		if r.id == id then
			return r
		end
	end
	return nil
end

local function space(state: State, key: string?): Workspace?
	for _, w in state.spaces do
		if w.key == key then
			return w
		end
	end
	return nil
end

-- The workspace of the record `ref` of `kind`, by any value that names it.
local function spaceOf(state: State, kind: string, ref: string): Workspace?
	for _, w in state.spaces do
		if w.kind == kind and (w.ref == ref or w.aliases[ref]) then
			return w
		end
	end
	return nil
end

local function lines(text: string, into: { string })
	for line in string.gmatch(text .. "\n", "([^\n]*)\n") do
		table.insert(into, (string.gsub(line, "\r$", "")))
	end
	while #into > 0 and into[#into] == "" do
		table.remove(into)
	end
end

-- Reads a run's output back into a result: stderr first, as the notes before the JSON.
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

-- How a workspace starts tenantctl: the invocation of the line that opened it.
local function invOf(w: Workspace): actions.Invocation?
	local spec = run.spec(w.line)
	if spec == nil then
		return nil
	end
	local rest = table.move(spec.argv, 2, #spec.argv, 1, {})
	return actions.invocation(spec.argv[1], rest, w.line, w.line)
end

-- The record a workspace is about, with its fields once it has been read.
local function entityOf(state: State, w: Workspace): actions.Entity?
	if w.kind == nil then
		return nil
	end
	local value: Value? = nil
	local r = runById(state, w.details)
	local doc = if r then r.doc else nil
	if doc and doc.kind == "success" and doc.data then
		local at = records.subjectPath(doc.command)
		local data = doc.data :: Value
		local v = if at and at ~= "" then json.get(data, at) else data
		value = if v and v.kind == "object" then v else nil
	end
	return { kind = w.kind :: string, ref = w.ref, value = value }
end

local function addRun(state: State, line: string, cwd: string?, label: string, risk: string): Run
	local r: Run = {
		id = state.next,
		line = line,
		cwd = cwd,
		status = "running",
		label = label,
		risk = risk,
		spec = run.spec(line),
	}
	state.next += 1
	if r.spec == nil then
		r.status = "failed"
		r.err = "Only tenantctl commands run here."
	end
	table.insert(state.runs, r)
	return r
end

local function setTab(w: Workspace, label: string, id: number)
	for _, t in w.tabs do
		if t.label == label then
			t.run = id
			return
		end
	end
	table.insert(w.tabs, { label = label, run = id })
end

local function addEntry(w: Workspace, label: string, ids: { number })
	table.insert(w.activity, 1, { id = ids[1], label = label, runs = ids })
	while #w.activity > MAX_ENTRIES do
		table.remove(w.activity)
	end
end

-- Drops what nothing shows any more: workspaces past the limit (never the current one), then
-- runs no workspace refers to.
local function prune(state: State)
	while #state.spaces > MAX_SPACES do
		local drop = 1
		if state.spaces[1].key == state.current then
			drop = 2
		end
		table.remove(state.spaces, drop)
	end
	local used: { [number]: boolean } = {}
	for _, w in state.spaces do
		if w.details then
			used[w.details] = true
		end
		for _, t in w.tabs do
			used[t.run] = true
		end
		for _, e in w.activity do
			for _, id in e.runs do
				used[id] = true
			end
		end
	end
	local kept: { Run } = {}
	for _, r in state.runs do
		if used[r.id] or r.status == "running" or r.status == "queued" then
			table.insert(kept, r)
		end
	end
	state.runs = kept
end

local function open(state: State, key: string, make: () -> Workspace): (Workspace, boolean)
	local w = space(state, key)
	if w then
		return w, false
	end
	local made = make()
	table.insert(state.spaces, made)
	return made, true
end

-- Reads the record of workspace `w` again; nil when its kind has no command for it.
local function refresh(state: State, w: Workspace): Run?
	local inv = invOf(w)
	if inv == nil then
		return nil
	end
	if w.kind == nil then
		local r = addRun(state, w.line, w.cwd, w.name, "read")
		w.details = r.id
		return r
	end
	local line = actions.detailsLine(inv, w.kind :: string, w.ref :: string)
	if line == nil then
		return nil
	end
	local r = addRun(state, line, w.cwd, DETAILS, "read")
	w.details = r.id
	setTab(w, DETAILS, r.id)
	return r
end

-- Approving a change (`--confirm <token>` run as `line`) settles the confirmation that asked for it.
local function approved(state: State, line: string)
	for _, r in state.runs do
		local doc, inv = r.doc, r.inv
		if r.status == "approval" and doc and doc.rerun and inv and actions.relocate(doc.rerun, inv) == line then
			r.status = "approved"
		end
	end
end

-- Takes a command line a person ran from a view and files it in a workspace. `from` is the
-- workspace it was clicked in, if any. A lookup of a record shows in that record's workspace,
-- which opens (read whole first) and comes to the front; a change made from another record's
-- workspace stays in that one's activity; a command about no record opens a workspace of its own.
-- Returns the runs to start.
local function submit(state: State, line: string, cwd: string?, from: string?): { Run }
	local spec = run.spec(line)
	if spec == nil then
		local w = space(state, from or state.current)
		local r = addRun(state, line, cwd, line, "write")
		if w then
			addEntry(w, line, { r.id })
		end
		prune(state)
		return {}
	end
	local d = actions.describe(spec.args)
	local isRead = d.risk == "read" and not d.approval
	if d.approval then
		approved(state, line)
	end
	local started: { Run } = {}
	if d.kind == nil or d.ref == nil then
		local key = "cmd|" .. table.concat(spec.args, " ")
		local w = open(state, key, function(): Workspace
			return { key = key, aliases = {}, name = d.label, line = line, cwd = cwd, tabs = {}, activity = {} }
		end)
		state.current = key
		local r = addRun(state, line, cwd, d.label, d.risk)
		if isRead then
			w.details = r.id
		else
			addEntry(w, d.label, { r.id })
		end
		table.insert(started, r)
		prune(state)
		return started
	end
	local kind, ref = d.kind :: string, d.ref :: string
	local origin = space(state, from)
	local target = spaceOf(state, kind, ref)
	-- a change to another record, clicked in this one's workspace, is part of the work here
	if origin and origin ~= target and not isRead then
		local r = addRun(state, line, cwd, d.label, d.risk)
		r.target = ref
		addEntry(origin, d.label, { r.id })
		table.insert(started, r)
		prune(state)
		return started
	end
	local w, made = target, false
	if w == nil then
		local key = `{kind}|{ref}`
		w, made = open(state, key, function(): Workspace
			return {
				key = key,
				kind = kind,
				ref = ref,
				aliases = { [ref] = true },
				name = ref,
				line = line,
				cwd = cwd,
				tabs = {},
				activity = {},
			}
		end)
	end
	local ws = w :: Workspace
	state.current = ws.key
	local inv = invOf(ws)
	local detailsLine = if inv then actions.detailsLine(inv, kind, ref) else nil
	if made and detailsLine and line ~= detailsLine then
		local first = refresh(state, ws)
		if first then
			table.insert(started, first)
		end
	end
	local r = addRun(state, line, cwd, d.label, d.risk)
	table.insert(started, r)
	if isRead then
		if line == detailsLine or d.label == DETAILS then
			ws.details = r.id
			r.label = DETAILS
		end
		setTab(ws, r.label, r.id)
		ws.tab = r.label
	else
		addEntry(ws, d.label, { r.id })
	end
	prune(state)
	return started
end

-- One row a bulk action runs on: its line, the input it still needs, the row and its name.
export type Item = { line: string, ask: string?, row: string, name: string }

-- What running the action labeled `label` on the rows picked in the table at `path` (`r4:data`,
-- `r4:data.devices`) takes: each row's own line, found among that row's actions. Rows without
-- the action (an iPhone has no LAPS) are left out.
local function bulkPlan(state: State, path: string, label: string): { Item }
	local id = tonumber(string.match(path, "^r(%d+):") or "")
	local r = runById(state, id)
	local doc = if r then r.doc else nil
	local inv = if r then r.inv else nil
	local picked = state.picked[path]
	if r == nil or doc == nil or doc.data == nil or inv == nil or picked == nil then
		return {}
	end
	local rel = records.relative(path)
	local list = if rel == "" then doc.data else json.get(doc.data, rel)
	local rows: { Value } = if list and list.kind == "array" then list.items :: { Value } else {}
	-- the workspace's record is what the rows are listed under (a group's members)
	local w: Workspace? = nil
	for _, s in state.spaces do
		if s.details == r.id then
			w = s
		end
		for _, t in s.tabs do
			if t.run == r.id then
				w = s
			end
		end
	end
	local parent = if w then entityOf(state, w) else nil
	local items: { Item } = {}
	for _, rowId in picked do
		local index = tonumber(string.match(rowId, "#(%d+)$") or "")
		local row = if index then rows[index] else nil
		local kind = if row then records.kindAt(inv.id, path, row) else nil
		if row and kind then
			local entity: actions.Entity = { kind = kind, value = row }
			for _, t in actions.targets(inv, entity, parent, nil) do
				if t.own then
					for _, a in t.actions do
						if a.label == label then
							table.insert(
								items,
								{ line = a.line, ask = a.ask, row = rowId, name = render.titleOf(row) or t.ref }
							)
							break
						end
					end
				end
			end
		end
	end
	return items
end

-- Files a bulk action in the current workspace: one activity entry, one queued run per row.
local function addBatch(state: State, label: string, items: { Item }, cwd: string?): { Run }
	local w = space(state, state.current)
	local out: { Run } = {}
	local ids: { number } = {}
	for _, it in items do
		local spec = run.spec(it.line)
		local d = if spec then actions.describe(spec.args) else nil
		if d and d.approval then
			approved(state, it.line)
		end
		local r = addRun(state, it.line, cwd or (if w then w.cwd else nil), label, if d then d.risk else "write")
		if r.status == "running" then
			r.status = "queued"
		end
		r.target = it.name
		-- an approval re-run of a single change has no row
		r.row = if it.row ~= "" then it.row else nil
		table.insert(ids, r.id)
		table.insert(out, r)
	end
	if w and #ids > 0 then
		addEntry(w, label, ids)
	end
	prune(state)
	return out
end

-- The re-run commands of an activity entry's runs that wait for approval.
local function approvals(state: State, key: string, entry: number): { Item }
	local w = space(state, key)
	local out: { Item } = {}
	if w == nil then
		return out
	end
	for _, e in w.activity do
		if e.id == entry then
			for _, id in e.runs do
				local r = runById(state, id)
				local doc = if r then r.doc else nil
				if r and r.status == "approval" and doc and doc.rerun and r.inv then
					table.insert(out, {
						line = actions.relocate(doc.rerun, r.inv :: actions.Invocation),
						row = r.row or "",
						name = r.target or "",
					})
				end
			end
		end
	end
	return out
end

-- Runs waiting their turn that can start now, oldest first.
local function due(state: State): { Run }
	local going = 0
	for _, r in state.runs do
		if r.status == "running" then
			going += 1
		end
	end
	local out: { Run } = {}
	for _, r in state.runs do
		if going >= PARALLEL then
			break
		end
		if r.status == "queued" then
			r.status = "running"
			going += 1
			table.insert(out, r)
		end
	end
	return out
end

-- Records how a run ended. Returns the runs that follow from it: once a change is done, its record
-- is read again.
local function settle(state: State, r: Run, res: Result, took: number): { Run }
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
	local follow: { Run } = {}
	for _, w in state.spaces do
		if w.details == r.id and r.status == "done" then
			local entity = entityOf(state, w)
			local value = if entity then entity.value else nil
			if value and w.kind then
				w.name = render.titleOf(value) or w.name
				w.aliases[w.name] = true
				local canonical = actions.refFor(w.kind :: string, { kind = w.kind :: string, value = value })
				if canonical then
					w.aliases[canonical] = true
				end
			end
		end
	end
	-- a change is done: read its record again, unless more of its batch are still going
	if r.status == "done" and r.risk ~= "read" and r.row == nil then
		local spec = r.spec
		local d = if spec then actions.describe(spec.args) else nil
		local w = if d and d.kind and d.ref then spaceOf(state, d.kind :: string, d.ref :: string) else nil
		if w then
			local again = refresh(state, w)
			if again then
				table.insert(follow, again)
			end
		end
	end
	return follow
end

-- The toast for a run that ended: its level, text and second line; nil for a lookup that worked.
local function summary(state: State, r: Run): (string?, string?, string?)
	if r.row then
		-- a batch toasts once, when its last run ends
		for _, w in state.spaces do
			for _, e in w.activity do
				if table.find(e.runs, r.id) then
					local done, failed, waiting = 0, 0, 0
					for _, id in e.runs do
						local x = runById(state, id)
						local s = if x then x.status else "failed"
						if s == "running" or s == "queued" then
							return nil, nil, nil
						end
						done += if s == "done" then 1 else 0
						failed += if s == "failed" or s == "interrupted" then 1 else 0
						waiting += if s == "approval" then 1 else 0
					end
					local parts: { string } = { `{done} done` }
					if failed > 0 then
						table.insert(parts, `{failed} failed`)
					end
					if waiting > 0 then
						table.insert(parts, `{waiting} to approve`)
					end
					return if failed > 0 then "error" else "success", `{e.label} finished`, table.concat(parts, ", ")
				end
			end
		end
		return nil, nil, nil
	end
	local doc = r.doc
	if r.status == "failed" then
		return "error", `{r.label} failed`, if doc and doc.message then doc.message else nil
	elseif r.status == "approval" then
		return "info", "Approval needed", r.label
	elseif r.risk ~= "read" then
		return "success", `{r.label} done`, r.target
	end
	return nil, nil, nil
end

local function with(node: Node, props: { [string]: any }): Node
	local p: { [string]: any } = node.p or {}
	for k, v in props do
		p[k] = v
	end
	node.p = p
	return node
end

local TONES: { [string]: string } =
	{ done = "success", failed = "error", approval = "warning", interrupted = "warning", running = "muted" }

local function seconds(took: number?): string
	if took == nil then
		return ""
	end
	return if took < 10 then string.format(" · %.1fs", took) else string.format(" · %ds", math.floor(took))
end

local function statusText(r: Run): string
	if r.status == "running" or r.status == "queued" or r.status == "interrupted" or r.status == "approved" then
		return r.status
	elseif r.status == "approval" then
		return "needs approval" .. seconds(r.took)
	end
	local word = if r.code and r.code ~= 0 then `exit {r.code}` elseif r.status == "done" then "done" else "failed"
	return word .. seconds(r.took)
end

-- What the view draws runs with: lines running now, picks and per-row marks.
local function common(state: State, now: number): render.Opts
	local busy: { [string]: boolean } = {}
	local marks: { [string]: render.Mark } = {}
	for _, r in state.runs do
		if r.status == "running" or r.status == "queued" then
			busy[r.line] = true
		end
		if r.row then
			local doc = r.doc
			local text = if r.status == "done"
				then r.label
				elseif r.status == "failed" then `{r.label} failed`
				elseif r.status == "approval" then "Approve"
				else r.status
			marks[r.row] = {
				text = text,
				tone = TONES[r.status],
				title = if doc and doc.message then doc.message else nil,
			}
		end
	end
	return {
		now = now,
		selected = state.selected,
		opened = state.opened,
		workspace = true,
		inline = true,
		busy = busy,
		picking = state.picking,
		picked = state.picked,
		marks = marks,
	}
end

-- A run's result: a progress bar while it runs, else what it printed, drawn like any view.
local function body(ui: UI, r: Run, base: render.Opts): Node
	if r.status == "running" or r.status == "queued" then
		return ui.progress(nil, if r.status == "queued" then "Waiting" else "Running")
	elseif r.doc then
		local opts = table.clone(base)
		opts.inv = r.inv
		opts.prefix = `r{r.id}:`
		return render.render(ui, r.doc :: output.Doc, opts)
	end
	local text = string.gsub((r.err or "") .. "\n" .. (r.out or ""), "^%s+", "")
	text = string.gsub(text, "%s+$", "")
	return if text == "" then ui.text(ui.span("No output", "muted")) else ui.code(text)
end

local function copyButton(ui: UI, line: string): Node
	return ui.button("", {
		icon = "copy",
		variant = "quiet",
		size = "sm",
		title = "Copy command",
		actions = { click = `copy={line}` },
	})
end

-- One activity entry: a line saying how it went, folding open onto its result (or, for several
-- rows, each row's outcome). The newest is open.
local function entryView(ui: UI, state: State, w: Workspace, e: Entry, newest: boolean, base: render.Opts): Node
	local runs: { Run } = {}
	for _, id in e.runs do
		local r = runById(state, id)
		if r then
			table.insert(runs, r)
		end
	end
	if #runs == 0 then
		return ui.text(ui.span(e.label, "muted"))
	end
	if #runs == 1 and runs[1].row == nil then
		local r = runs[1]
		local head: { Span } = { ui.span(e.label, "strong") }
		if r.target then
			table.insert(head, ui.span(`  {r.target}`, "muted"))
		end
		table.insert(head, ui.span(`  {statusText(r)}`, TONES[r.status] or "muted"))
		local section = ui.section(head, {
			with(ui.row({ copyButton(ui, r.line), ui.text(ui.span(r.line, "code")) }), { align = "center" }),
			body(ui, r, base),
		})
		return with(section, {
			collapsible = true,
			collapsed = not newest and r.status ~= "approval",
			key = `e{e.id}`,
			tone = TONES[r.status],
		})
	end
	local counts: { [string]: number } = {}
	for _, r in runs do
		counts[r.status] = (counts[r.status] or 0) + 1
	end
	local parts: { string } = {}
	for _, s in { "running", "queued", "done", "approval", "failed", "interrupted" } do
		if counts[s] then
			table.insert(parts, `{counts[s]} {if s == "approval" then "to approve" else s}`)
		end
	end
	local rows: { Node } = {}
	for _, r in runs do
		local doc = r.doc
		local spans: { Span } = {
			ui.span(r.target or r.line, "strong"),
			ui.span(`  {statusText(r)}`, TONES[r.status] or "muted"),
		}
		if r.status == "failed" and doc and doc.message then
			table.insert(spans, ui.span(`  {doc.message}`, "muted"))
		end
		table.insert(rows, ui.text(spans))
	end
	if counts.approval then
		table.insert(
			rows,
			ui.button("Approve all", {
				variant = "primary",
				size = "sm",
				actions = { click = `approveall={w.key}|{e.id}` },
			})
		)
	end
	local head: { Span } = {
		ui.span(e.label, "strong"),
		ui.span(`  {#runs} rows · {table.concat(parts, ", ")}`, "muted"),
	}
	return with(ui.section(head, rows), { collapsible = true, collapsed = not newest, key = `e{e.id}` })
end

-- The strip of open workspaces: one button each, the shown one pressed.
local function strip(ui: UI, state: State): Node
	local buttons: { Node } = {}
	for _, w in state.spaces do
		local kind = if w.kind then actions.KINDS[w.kind] else nil
		table.insert(
			buttons,
			ui.button(w.name, {
				size = "sm",
				variant = "quiet",
				on = w.key == state.current,
				icon = if w.kind == nil then "list" elseif string.find(w.kind, "device") then "laptop" else nil,
				title = if kind then kind.name else w.line,
				actions = { click = `space={w.key}` },
			})
		)
	end
	return with(ui.row(buttons), { gap = "xs", wrap = true, role = "tenantctl.spaces" })
end

local function workspaceView(ui: UI, state: State, w: Workspace, base: render.Opts): { Node }
	local nodes: { Node } = {}
	local kind = if w.kind then actions.KINDS[w.kind] else nil
	local details = runById(state, w.details)
	local going = details ~= nil and (details.status == "running" or details.status == "queued")
	table.insert(
		nodes,
		with(
			ui.row({
				with(
					ui.text({
						ui.span(w.name, "title strong"),
						ui.span(if kind then `  {kind.name}` else "", "muted"),
					}),
					{ grow = 1 }
				),
				ui.button("Refresh", {
					size = "sm",
					variant = "quiet",
					icon = "repeat",
					busy = going,
					title = if w.kind then "Read it again" else "Run it again",
					actions = { click = `refresh={w.key}` },
				}),
				ui.button("", {
					size = "sm",
					variant = "quiet",
					icon = "x",
					title = "Close",
					actions = { click = `close={w.key}` },
				}),
			}),
			{ align = "center" }
		)
	)
	-- the record's actions, run with the program and profile it was opened with
	local entity = entityOf(state, w)
	if entity then
		local opts = table.clone(base)
		opts.inv = invOf(w)
		local bar = render.recordBar(ui, opts, `{w.key}!bar`, entity)
		if bar then
			table.insert(nodes, bar)
		end
	end
	-- what was changed here, newest first, the latest open
	if #w.activity > 0 then
		local recent: { Node } = {}
		local older: { Node } = {}
		for i, e in w.activity do
			table.insert(if i <= 3 then recent else older, entryView(ui, state, w, e, i == 1, base))
		end
		if #older > 0 then
			table.insert(
				recent,
				with(
					ui.section({ ui.span("Earlier", "strong"), ui.span(`  {#older}`, "muted") }, older),
					{ collapsible = true, collapsed = true, key = "earlier" }
				)
			)
		end
		table.insert(nodes, with(ui.col(recent), { role = "tenantctl.activity" }))
	end
	if w.kind == nil then
		if details then
			table.insert(nodes, body(ui, details, base))
		end
		return nodes
	end
	-- lookups, one tab each; the shown one's result under them
	if #w.tabs > 0 then
		local buttons: { Node } = {}
		local shown = w.tab or w.tabs[1].label
		for _, t in w.tabs do
			local r = runById(state, t.run)
			table.insert(
				buttons,
				ui.button(t.label, {
					size = "sm",
					variant = "quiet",
					on = t.label == shown,
					busy = r ~= nil and (r.status == "running" or r.status == "queued"),
					icon = if r and r.status == "failed" then "x-circle" else nil,
					actions = { click = `tab={w.key}|{t.label}` },
				})
			)
		end
		table.insert(nodes, with(ui.row(buttons), { gap = "xs", wrap = true, role = "tenantctl.tabs" }))
		for _, t in w.tabs do
			if t.label == shown then
				local r = runById(state, t.run)
				if r then
					table.insert(nodes, body(ui, r, base))
				end
			end
		end
	end
	return nodes
end

local function view(ui: UI, state: State, now: number): Node
	local w = space(state, state.current) or state.spaces[#state.spaces]
	if w == nil then
		return with(
			ui.col({ ui.text(ui.span("Run an action from a tenantctl view to work on its record here.", "muted")) }),
			{ role = "tenantctl.runs" }
		)
	end
	local nodes: { Node } = {}
	if #state.spaces > 1 then
		table.insert(nodes, strip(ui, state))
	end
	for _, n in workspaceView(ui, state, w, common(state, now)) do
		table.insert(nodes, n)
	end
	return with(ui.col(nodes), { role = "tenantctl.runs" })
end

-- Brings a workspace to the front, shows one of its tabs, or closes it.
local function focus(state: State, key: string)
	if space(state, key) then
		state.current = key
	end
end

local function showTab(state: State, key: string, label: string)
	local w = space(state, key)
	if w then
		w.tab = label
	end
end

local function close(state: State, key: string)
	for i, w in state.spaces do
		if w.key == key then
			table.remove(state.spaces, i)
			break
		end
	end
	if state.current == key then
		local last = state.spaces[#state.spaces]
		state.current = if last then last.key else nil
	end
	prune(state)
end

-- Starts or stops picking several rows in the table at `path`.
local function togglePicking(state: State, path: string)
	if state.picking[path] then
		state.picking[path] = nil
	else
		state.picking[path] = true
	end
	state.picked[path] = nil
end

-- The rows picked in a table, as a `change` event reports them (`r4:data#2`, …); none clears
-- every table's picks.
local function setPicked(state: State, ids: { string })
	if #ids == 0 then
		state.picked = {}
		return
	end
	local path = string.match(ids[1], "^(.*)#%d+$")
	if path then
		state.picked[path] = ids
	end
end

-- What survives a restart: the workspaces, and each run's line and output; a run still going is
-- shown as interrupted, never started again.
local function save(state: State): any
	local runs = {}
	for _, r in state.runs do
		table.insert(runs, {
			id = r.id,
			line = r.line,
			cwd = r.cwd,
			status = r.status,
			label = r.label,
			risk = r.risk,
			target = r.target,
			row = r.row,
			took = r.took,
			code = r.code,
			out = if r.out then string.sub(r.out, 1, MAX_SAVED) else nil,
			err = if r.err then string.sub(r.err, 1, MAX_SAVED) else nil,
		})
	end
	local spaces = {}
	for _, w in state.spaces do
		local aliases = {}
		for a in w.aliases do
			table.insert(aliases, a)
		end
		table.insert(spaces, {
			key = w.key,
			kind = w.kind,
			ref = w.ref,
			aliases = aliases,
			name = w.name,
			line = w.line,
			cwd = w.cwd,
			details = w.details,
			tabs = w.tabs,
			tab = w.tab,
			activity = w.activity,
		})
	end
	return { version = 2, next = state.next, current = state.current, runs = runs, spaces = spaces }
end

local function restore(saved: any): State
	local state = new()
	if type(saved) ~= "table" or saved.version ~= 2 then
		return state
	end
	state.next = if type(saved.next) == "number" then saved.next else 1
	state.current = if type(saved.current) == "string" then saved.current else nil
	for _, s in if type(saved.runs) == "table" then saved.runs else {} do
		if type(s) == "table" and type(s.line) == "string" and type(s.id) == "number" then
			local going = s.status == "running" or s.status == "queued"
			local r: Run = {
				id = s.id,
				line = s.line,
				cwd = s.cwd,
				status = if going then "interrupted" else tostring(s.status),
				label = tostring(s.label or s.line),
				risk = tostring(s.risk or "write"),
				target = s.target,
				row = s.row,
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
	for _, s in if type(saved.spaces) == "table" then saved.spaces else {} do
		if type(s) == "table" and type(s.key) == "string" and type(s.line) == "string" then
			local aliases: { [string]: boolean } = {}
			for _, a in if type(s.aliases) == "table" then s.aliases else {} do
				aliases[tostring(a)] = true
			end
			table.insert(state.spaces, {
				key = s.key,
				kind = s.kind,
				ref = s.ref,
				aliases = aliases,
				name = tostring(s.name or s.key),
				line = s.line,
				cwd = s.cwd,
				details = s.details,
				tabs = if type(s.tabs) == "table" then s.tabs else {},
				tab = s.tab,
				activity = if type(s.activity) == "table" then s.activity else {},
			})
		end
	end
	return state
end

return {
	new = new,
	submit = submit,
	refresh = refresh,
	bulkPlan = bulkPlan,
	addBatch = addBatch,
	approvals = approvals,
	due = due,
	settle = settle,
	summary = summary,
	view = view,
	focus = focus,
	showTab = showTab,
	close = close,
	togglePicking = togglePicking,
	setPicked = setPicked,
	space = space,
	runById = runById,
	save = save,
	restore = restore,
	PARALLEL = PARALLEL,
}
