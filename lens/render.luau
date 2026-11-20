--!strict
-- A `Doc` as a native view. Reports (objects) become a headline, findings, a key/value grid and
-- sections; lists become tables whose rows open a detail card; errors and confirmations become
-- cards. `ui` is `tern.ui`, passed in so the specs can run without Tern.

local json = require("./json")
local format = require("./format")
local output = require("./output")
local actions = require("./actions")
local records = require("./records")

type Value = json.Value
type Doc = output.Doc
type UI = typeof(tern.ui)
type Entity = actions.Entity
type Action = actions.Action
type Target = actions.Target

export type Opts = {
	-- Seconds since the epoch, for "3h ago".
	now: number,
	-- Selected row per table path (`data`, `data.devices`): its 1-based index.
	selected: { [string]: number? },
	-- How the run started tenantctl; with it records get actions that run in the pane.
	inv: actions.Invocation?,
}

-- Rows a table shows before "… N more"; the raw output keeps every row.
local MAX_ROWS = 500
-- Columns a table shows; the rest are in the row's detail card.
local MAX_COLS = 8
-- A section with a longer table starts folded.
local FOLD_ROWS = 15

-- Fields that name a row, in order of preference: the table's main column and the card's head.
local TITLE_KEYS = {
	"displayName",
	"name",
	"deviceName",
	"service",
	"command",
	"title",
	"issue",
	"app",
	"skuPartNumber",
	"userPrincipalName",
	"user",
	"section",
}

-- A finding's severity, most urgent first.
local SEVERITY_RANK: { [string]: number } = { critical = 0, high = 1, medium = 2, low = 3, info = 4 }

local function with(node: Node, props: { [string]: any }): Node
	local p: { [string]: any } = node.p or {}
	for k, v in props do
		p[k] = v
	end
	node.p = p
	return node
end

local function items(v: Value?): { Value }
	return if v and v.kind == "array" then v.items :: { Value } else {}
end

local function keys(v: Value): { string }
	return if v.kind == "object" then v.keys :: { string } else {}
end

local function field(v: Value?, key: string): string?
	local s = json.text(json.get(v, key))
	return if s and s ~= "" then s else nil
end

local function isScalar(v: Value): boolean
	return v.kind ~= "object" and v.kind ~= "array"
end

local function isRowList(v: Value): boolean
	if v.kind ~= "array" then
		return false
	end
	local list = v.items :: { Value }
	if #list == 0 then
		return false
	end
	for _, item in list do
		if item.kind ~= "object" then
			return false
		end
	end
	return true
end

-- An object small enough to read on one line: at most four fields, none nested.
local function isSmallObject(v: Value): boolean
	if v.kind ~= "object" then
		return false
	end
	local ks = v.keys :: { string }
	if #ks > 4 then
		return false
	end
	for _, k in ks do
		if not isScalar((v.map :: { [string]: Value })[k]) then
			return false
		end
	end
	return true
end

-- `serviceDegradation` → `Service degradation`; words with spaces stay as they are.
local function word(s: string): string
	if string.find(s, "%s") then
		return s
	end
	return format.label(s)
end

local BAD_WHEN_FALSE: { string } = { "enabled", "compliant", "encrypted", "registered" }
local BAD_WHEN_TRUE: { string } = { "expired", "blocked", "compromised", "atrisk" }

local function boolTone(key: string, b: boolean): string?
	local lower = string.lower(key)
	local parts: { string } = if b then BAD_WHEN_TRUE else BAD_WHEN_FALSE
	for _, part in parts do
		if string.find(lower, part, 1, true) then
			return if b then "error" else "warning"
		end
	end
	return nil
end

local function boolSpan(ui: UI, key: string, b: boolean): Span
	local tone = boolTone(key, b)
	if tone then
		return ui.span(if b then "yes" else "no", tone .. " strong")
	end
	return ui.span(if b then "yes" else "no", if b then nil else "muted")
end

-- A value in a key/value grid: status words colored, dates with their age, ids in mono.
local function valueSpans(ui: UI, key: string, v: Value, now: number): Spans
	if v.kind == "string" then
		local s = v.s :: string
		if s == "" then
			return ui.span("—", "dim")
		end
		local tone = format.statusTone(key, s)
		if tone then
			return ui.span(word(s), tone .. " strong")
		end
		local t = format.parseDate(s)
		if t then
			return { ui.span(format.showDate(t), "mono"), ui.span("  " .. format.age(t, now), "muted") }
		end
		if string.match(s, "^https?://%S+$") then
			return ui.link(s, s)
		end
		if format.isGuid(s) then
			return ui.span(s, "mono muted")
		end
		if string.sub(s, 1, 10) == "tenantctl " then
			return ui.span(s, "code")
		end
		return s
	elseif v.kind == "number" then
		return ui.span(v.s :: string, "mono")
	elseif v.kind == "boolean" then
		return boolSpan(ui, key, v.b == true)
	elseif v.kind == "null" then
		return ui.span("—", "dim")
	elseif v.kind == "array" and #(v.items :: { Value }) == 0 then
		return ui.span("none", "dim")
	end
	return format.summary(v, 400)
end

-- A table cell: status words as badges, dates as their age (the date in the tooltip).
local function cellOf(ui: UI, key: string, v: Value, now: number): Cell
	if v.kind == "string" then
		local s = v.s :: string
		local tone = format.statusTone(key, s)
		if tone then
			return { badge = { text = word(s), tone = tone } }
		end
		local t = format.parseDate(s)
		if t then
			return { text = format.age(t, now), title = format.showDate(t) }
		end
		if string.sub(s, 1, 10) == "tenantctl " then
			return { ui.span(s, "code") }
		end
		return (string.gsub(s, "%s+", " "))
	elseif v.kind == "number" then
		return v.s :: string
	elseif v.kind == "boolean" then
		return { boolSpan(ui, key, v.b == true) }
	elseif v.kind == "null" then
		return ""
	end
	return { ui.span(format.summary(v, 60), "muted") }
end

-- The field that names `row`, if any.
local function titleKey(row: Value): string?
	for _, k in TITLE_KEYS do
		local s = field(row, k)
		if s and not format.isGuid(s) then
			return k
		end
	end
	return nil
end

type ColInfo = { key: string, guid: boolean, date: boolean, number: boolean }

-- The columns of `rows`: keys in first-seen order, empty and annotation columns dropped, id
-- columns last, at most MAX_COLS.
local function columnsOf(rows: { Value }): ({ ColInfo }, string?)
	local order: { string } = {}
	local info: { [string]: { nonEmpty: number, guid: number, date: number, number: number } } = {}
	for i = 1, math.min(#rows, 200) do
		local row = rows[i]
		for _, k in keys(row) do
			if format.hidden(k) then
				continue
			end
			local stats = info[k]
			if stats == nil then
				stats = { nonEmpty = 0, guid = 0, date = 0, number = 0 }
				info[k] = stats
				table.insert(order, k)
			end
			local v = (row.map :: { [string]: Value })[k]
			if not format.isEmpty(v) then
				stats.nonEmpty += 1
				if v.kind == "string" and format.isGuid(v.s :: string) then
					stats.guid += 1
				elseif v.kind == "string" and format.parseDate(v.s :: string) then
					stats.date += 1
				elseif v.kind == "number" then
					stats.number += 1
				end
			end
		end
	end
	local main: { ColInfo } = {}
	local ids: { ColInfo } = {}
	for _, k in order do
		local s = info[k]
		if s.nonEmpty > 0 then
			local named = k == "id" or (string.match(k, "%lId$") ~= nil and s.number == 0)
			local col: ColInfo = {
				key = k,
				guid = s.guid == s.nonEmpty or named,
				date = s.date == s.nonEmpty,
				number = s.number == s.nonEmpty,
			}
			table.insert(if col.guid then ids else main, col)
		end
	end
	for _, col in ids do
		table.insert(main, col)
	end
	local cols: { ColInfo } = {}
	for i = 1, math.min(#main, MAX_COLS) do
		cols[i] = main[i]
	end
	return cols, if rows[1] then titleKey(rows[1]) else nil
end

local function fold(node: Node, collapsed: boolean): Node
	return with(node, { collapsible = true, collapsed = collapsed })
end

local report: (ui: UI, obj: Value, path: string, opts: Opts, self: Entity?, bar: Node?) -> { Node }

-- What an action sends: `run=<line>` runs the line in the pane, `fill=<line>` types it there for
-- the person to finish.
local function act(a: Action): string
	return (if a.fill then "fill=" else "run=") .. a.line
end

local function actionButton(ui: UI, a: Action): Node
	return ui.button(a.label, {
		size = "sm",
		variant = if a.risk == "destructive" then "danger" else "default",
		title = a.summary,
		actions = { click = act(a) },
	})
end

local function buttonRow(ui: UI, list: { Action }): Node
	local buttons: { Node } = {}
	for _, a in list do
		table.insert(buttons, actionButton(ui, a))
	end
	return ui.node("row", { gap = "sm", wrap = true }, buttons)
end

-- A folded group of actions headed by `head`, each area on its own line when they span several.
local function actionSection(ui: UI, head: Spans, list: { Action }): Node
	local areas: { string } = {}
	local byArea: { [string]: { Action } } = {}
	for _, a in list do
		if byArea[a.domain] == nil then
			byArea[a.domain] = {}
			table.insert(areas, a.domain)
		end
		table.insert(byArea[a.domain], a)
	end
	local body: { Node } = {}
	for _, area in areas do
		if #areas > 1 then
			table.insert(body, ui.text(ui.span(area, "muted")))
		end
		table.insert(body, buttonRow(ui, byArea[area]))
	end
	return fold(ui.section(head, body), true)
end

-- A record's actions: its own changes as buttons (the destructive ones red), then folded groups:
-- what to look up about it, its changes in other areas, and each related record's actions (its
-- user, its Defender machine, …).
local function actionBar(ui: UI, targets: { Target }): Node?
	local nodes: { Node } = {}
	for _, t in targets do
		if not t.own then
			local kind = actions.KINDS[t.kind]
			local name = if kind then kind.name else t.kind
			table.insert(
				nodes,
				actionSection(ui, { ui.span(name, "strong"), ui.span(`  {t.ref}`, "muted") }, t.actions)
			)
			continue
		end
		local reads: { Action } = {}
		local buttons: { Action } = {}
		local others: { Action } = {}
		for _, a in t.actions do
			table.insert(if a.risk == "read" then reads elseif a.home then buttons else others, a)
		end
		if #buttons > 0 then
			table.insert(nodes, buttonRow(ui, buttons))
		end
		if #reads > 0 then
			table.insert(nodes, actionSection(ui, ui.span("Look up", "strong"), reads))
		end
		if #others > 0 then
			table.insert(nodes, actionSection(ui, ui.span("More actions", "strong"), others))
		end
	end
	if #nodes == 0 then
		return nil
	end
	return with(ui.col(nodes), { role = "tenantctl.actions" })
end

-- The actions bar of `subject`, listed under `parent`; nil without an invocation to run them with.
local function barFor(ui: UI, opts: Opts, subject: Entity?, parent: Entity?): Node?
	local inv = opts.inv
	if inv == nil or subject == nil then
		return nil
	end
	return actionBar(ui, actions.targets(inv, subject, parent, inv.id))
end

-- The record `v` at `path` is, when it is one; `strict` skips guessing from its fields.
local function entityAt(opts: Opts, path: string, v: Value, strict: boolean?): Entity?
	local inv = opts.inv
	local kind = if inv then records.kindAt(inv.id, path, v, strict) else nil
	return if kind then { kind = kind, value = v } else nil
end

-- Rows to choose from (an AMBIGUOUS error's candidates): the kind of record each is, and the
-- command line that runs the failed command again on it.
type Pick = { kind: (row: Value) -> string?, line: (row: Value) -> string? }

-- A list of objects as a selectable table; a selected row opens its detail card below, led by its
-- actions. `parent` is the record the list belongs to; with `pick`, each row also gets a Use button.
local function tableView(ui: UI, rows: { Value }, path: string, opts: Opts, parent: Entity?, pick: Pick?): { Node }
	local cols, title = columnsOf(rows)
	local specs: { Col } = {}
	for i, c in cols do
		local spec: Col = { id = c.key, head = format.label(c.key) }
		if c.key == title then
			spec.grow = 1
			spec.priority = 100
		elseif c.guid then
			spec.priority = -10
			spec.mono = true
			spec.truncate = "middle"
		else
			spec.priority = 50 - i
		end
		if c.number then
			spec.align = "end"
			spec.mono = true
		elseif c.date then
			spec.mono = true
		end
		specs[i] = spec
	end
	if pick then
		table.insert(specs, 1, { id = "use", head = "", priority = 200 })
	end
	local tableRows: { TableRow } = {}
	for i = 1, math.min(#rows, MAX_ROWS) do
		local row = rows[i]
		local cells: { Cell } = {}
		for j, c in cols do
			local v = json.get(row, c.key)
			cells[j] = if v then cellOf(ui, c.key, v, opts.now) else ""
		end
		if pick then
			local line = pick.line(row)
			table.insert(
				cells,
				1,
				if line then { button = { text = "Use", act = "run=" .. line, variant = "primary" } } else ""
			)
		end
		tableRows[i] = { id = `{path}#{i}`, cells = cells }
	end
	local selected = opts.selected[path]
	local nodes: { Node } = {
		ui.table(specs, tableRows, {
			selectable = true,
			selected = if selected then `{path}#{selected}` else nil,
		}),
	}
	if #rows > MAX_ROWS then
		table.insert(nodes, ui.overflow(#rows - MAX_ROWS))
	end
	local row = if selected then rows[selected] else nil
	if row then
		local name = if title then field(row, title) else nil
		local kind = if pick then pick.kind(row) else nil
		local entity = if kind then { kind = kind, value = row } else entityAt(opts, path, row)
		table.insert(
			nodes,
			ui.card(
				ui.span(name or `Row {selected}`, "strong"),
				report(ui, row, `{path}#{selected}`, opts, entity or parent, barFor(ui, opts, entity, parent)),
				{ meta = `{selected} of {#rows}` }
			)
		)
	end
	return nodes
end

local function sectionHead(ui: UI, key: string, count: number?): Spans
	if count then
		return { ui.span(format.label(key), "strong"), ui.span(`  {count}`, "muted") }
	end
	return ui.span(format.label(key), "strong")
end

local function copyable(ui: UI, command: string): Node
	return with(ui.text(ui.span(command, "code")), { actions = { click = "copy" }, title = "Copy" })
end

local function isFindings(v: Value?): boolean
	local list = items(v)
	return #list > 0 and isRowList(v :: Value) and field(list[1], "severity") ~= nil and field(list[1], "issue") ~= nil
end

local function findingNode(ui: UI, f: Value, opts: Opts): Node
	local sev = field(f, "severity") or "info"
	local issue = field(f, "issue") or ""
	local area = field(f, "area")
	local lines: { Node } = {
		ui.text({ ui.span(issue, "strong"), ui.span(if area then `  {area}` else "", "muted") }),
	}
	local detail = field(f, "detail")
	if detail then
		table.insert(lines, ui.text(ui.span(detail, "muted")))
	end
	local nextCommand = field(f, "next")
	if nextCommand and opts.inv then
		-- a `<placeholder>` is the person's to fill in
		local line = actions.relocate(nextCommand, opts.inv)
		local fill = string.find(line, "<", 1, true) ~= nil
		table.insert(
			lines,
			with(
				ui.row({
					copyable(ui, nextCommand),
					ui.button(if fill then "Edit" else "Run", {
						size = "sm",
						title = if fill then "Type it at the prompt" else "Run it",
						actions = { click = (if fill then "fill=" else "run=") .. line },
					}),
				}),
				{ align = "center" }
			)
		)
	elseif nextCommand then
		table.insert(lines, copyable(ui, nextCommand))
	end
	local label = string.upper(sev)
	label ..= string.rep(" ", math.max(0, 6 - #label))
	return with(ui.row({ ui.text(ui.span(label, format.severityTone(sev) .. " strong")), ui.lines(lines) }), {
		align = "start",
	})
end

-- Findings ranked by severity: high and medium shown, low and info folded under them.
local function findingsView(ui: UI, list: { Value }, opts: Opts): { Node }
	local sorted = table.clone(list)
	table.sort(sorted, function(a, b)
		local ra = SEVERITY_RANK[field(a, "severity") or ""] or 5
		local rb = SEVERITY_RANK[field(b, "severity") or ""] or 5
		return ra < rb
	end)
	local counts: { [string]: number } = {}
	local order: { string } = {}
	local problems: { Node } = {}
	local rest: { Node } = {}
	for _, f in sorted do
		local sev = field(f, "severity") or "info"
		if counts[sev] == nil then
			counts[sev] = 0
			table.insert(order, sev)
		end
		counts[sev] += 1
		local rank = SEVERITY_RANK[sev] or 5
		table.insert(if rank <= 2 then problems else rest, findingNode(ui, f, opts))
	end
	local badges: { Node } = { ui.text(ui.span("Findings", "strong")) }
	for _, sev in order do
		table.insert(badges, ui.badge(`{counts[sev]} {sev}`, format.severityTone(sev)))
	end
	local nodes: { Node } = { ui.row(badges) }
	if #problems > 0 and #rest > 0 then
		table.move(problems, 1, #problems, #nodes + 1, nodes)
		local head = { ui.span("Lower priority", "strong"), ui.span(`  {#rest}`, "muted") }
		table.insert(nodes, fold(ui.section(head, rest), true))
	else
		table.move(problems, 1, #problems, #nodes + 1, nodes)
		table.move(rest, 1, #rest, #nodes + 1, nodes)
	end
	return nodes
end

-- "Could not check" lines from `unavailable` (sections Graph refused).
local function unavailableView(ui: UI, list: { Value }): Node?
	if #list == 0 then
		return nil
	end
	local lines: { Node } = {}
	for _, u in list do
		local section = field(u, "section") or json.text(u) or "?"
		local err = json.get(u, "error")
		local message = field(u, "message") or field(err, "message")
		local code = field(u, "code") or field(err, "code")
		local spans: { Span | string } = { ui.span("Not checked: ", "warning"), ui.span(section, "warning strong") }
		if message then
			table.insert(spans, ui.span(`  {message}`, "muted"))
		end
		if code then
			table.insert(spans, ui.span(`  {code}`, "dim"))
		end
		table.insert(lines, ui.text(spans))
	end
	return ui.lines(lines)
end

local function verdictTone(findings: { Value }, verdict: string): string?
	local best = 5
	for _, f in findings do
		best = math.min(best, SEVERITY_RANK[field(f, "severity") or ""] or 5)
	end
	if best <= 1 then
		return "error"
	elseif best == 2 then
		return "warning"
	elseif string.find(verdict, "^No problems") then
		return "success"
	end
	return nil
end

-- `self` is the record `obj` is (its nested lists' parent); `bar` is its actions, shown under the
-- verdict and findings.
report = function(ui: UI, obj: Value, path: string, opts: Opts, self: Entity?, bar: Node?): { Node }
	if obj.kind ~= "object" then
		return { ui.text(valueSpans(ui, "", obj, opts.now)) }
	end
	local nodes: { Node } = {}
	local consumed: { [string]: boolean } = {}
	local map = obj.map :: { [string]: Value }

	local verdict = field(obj, "verdict")
	local findings = map.findings
	if verdict then
		consumed.verdict = true
		local tone = verdictTone(items(findings), verdict)
		table.insert(nodes, ui.text(ui.span(verdict, if tone then `{tone} strong` else "strong")))
	elseif field(obj, "summary") and path == "data" then
		consumed.summary = true
		table.insert(nodes, ui.text(ui.span(field(obj, "summary") :: string, "strong")))
	end
	if findings and isFindings(findings) then
		consumed.findings = true
		for _, n in findingsView(ui, items(findings), opts) do
			table.insert(nodes, n)
		end
	end
	local unavailable = map.unavailable
	if unavailable and unavailable.kind == "array" then
		consumed.unavailable = true
		local n = unavailableView(ui, items(unavailable))
		if n then
			table.insert(nodes, n)
		end
	end
	local warnings = map.warnings
	if warnings and warnings.kind == "array" then
		consumed.warnings = true
		for _, w in items(warnings) do
			local s = json.text(w)
			if s then
				table.insert(nodes, ui.text(ui.span(s, "warning")))
			end
		end
	end
	if bar then
		table.insert(nodes, bar)
	end

	local pairs: { { Spans } } = {}
	local sections: { Node } = {}
	for _, k in obj.keys :: { string } do
		if consumed[k] or format.hidden(k) then
			continue
		end
		local v = map[k]
		local childPath = `{path}.{k}`
		-- a nested record (a device's Entra object, a user's manager) gets a section and its actions
		local entity = if v.kind == "object" then entityAt(opts, childPath, v, true) else nil
		if
			entity == nil
			and (isScalar(v) or isSmallObject(v) or (v.kind == "array" and #(v.items :: { Value }) == 0))
		then
			table.insert(pairs, { format.label(k) :: Spans, valueSpans(ui, k, v, opts.now) })
		elseif isRowList(v) then
			local list = v.items :: { Value }
			local section = ui.section(sectionHead(ui, k, #list), tableView(ui, list, childPath, opts, self))
			table.insert(sections, fold(section, #list > FOLD_ROWS and opts.selected[childPath] == nil))
		elseif v.kind == "array" then
			local text = format.summary(v, 400)
			if #text <= 120 then
				table.insert(pairs, { format.label(k), text })
			else
				local section = ui.section(sectionHead(ui, k, #(v.items :: { Value })), { ui.text(text) })
				table.insert(sections, fold(section, true))
			end
		else
			local body = report(ui, v, childPath, opts, entity or self, barFor(ui, opts, entity, self))
			table.insert(sections, fold(ui.section(sectionHead(ui, k), body), false))
		end
	end
	if #pairs > 0 then
		table.insert(nodes, ui.kv(pairs))
	end
	for _, s in sections do
		table.insert(nodes, s)
	end
	return nodes
end

-- The line over a list: how many rows, and whether more exist.
local function listHead(ui: UI, count: number, meta: output.Meta?): Node
	if meta and meta.truncated then
		local hint = meta.hint or "More results exist: raise --top or pass --all."
		if string.match(hint, "^%d") then
			return ui.text(ui.span(hint, "warning"))
		end
		return ui.text({ ui.span(`{count} shown`, "strong"), ui.span(`  {hint}`, "warning") })
	end
	local total = if meta and meta.total then ` of {meta.total}` else ""
	return ui.text(ui.span(`{count}{total} result{if count == 1 then "" else "s"}`, "muted"))
end

-- The record the run is about: its first argument's kind, with the object the output gives for it
-- (`troubleshoot user`'s `user`) and what was typed for it.
local function subjectOf(doc: Doc, opts: Opts): Entity?
	local inv = opts.inv
	if inv == nil then
		return nil
	end
	local kind, arg = actions.targetOf(inv.id)
	local at = records.subjectPath(inv.id)
	local data = doc.data
	local value = if data and at == "" then data elseif data and at then json.get(data, at) else nil
	if value and value.kind ~= "object" then
		value = nil
	end
	if kind == nil and value then
		kind = records.kindAt(inv.id, "data", value)
	end
	if kind == nil then
		return nil
	end
	return { kind = kind, value = value, ref = if arg then inv.values[arg] else nil }
end

local function successView(ui: UI, doc: Doc, opts: Opts): { Node }
	local data = doc.data or json.NULL
	local subject = subjectOf(doc, opts)
	local bar = barFor(ui, opts, subject, nil)
	if data.kind == "array" then
		local list = data.items :: { Value }
		local nodes: { Node } = { listHead(ui, #list, doc.meta) }
		if #list == 0 then
			nodes = { ui.text(ui.span("No results", "muted")) }
		end
		-- the record the list belongs to (`teams members Sales`: the team) and its actions
		if bar then
			table.insert(nodes, bar)
		end
		if isRowList(data) then
			for _, n in tableView(ui, list, "data", opts, subject) do
				table.insert(nodes, n)
			end
		else
			for _, item in list do
				table.insert(nodes, ui.text(valueSpans(ui, "", item, opts.now)))
			end
		end
		local unavailable = if doc.meta then unavailableView(ui, items(doc.meta.unavailable)) else nil
		if unavailable then
			table.insert(nodes, unavailable)
		end
		return nodes
	end
	return report(ui, data, "data", opts, subject, bar)
end

-- An AMBIGUOUS error's candidates: the record kind its argument takes (a member list's rows say
-- their own) and the failed command again with the candidate's id in place of what was typed.
local function pickOf(doc: Doc, opts: Opts): Pick?
	local inv = opts.inv
	if inv == nil or doc.code ~= "AMBIGUOUS" then
		return nil
	end
	local _, typed, kind = actions.ambiguousArg(inv, doc.message or "")
	if typed == nil then
		return nil
	end
	return {
		kind = function(row: Value): string?
			local member = records.memberKind(row)
			if member then
				return member
			end
			return if kind and actions.KINDS[kind] then kind else nil
		end,
		line = function(row: Value): string?
			local id = field(row, "id")
			if id == nil then
				return nil
			end
			-- a directory object is named by its type (`device:<id>`), as `resolveMember` takes it
			local member = field(row, "type")
			local value = if member
					and records.memberKind(row)
					and member ~= "servicePrincipal"
				then `{member}:{id}`
				else id
			return actions.rerunWith(inv, typed :: string, value)
		end,
	}
end

local function errorView(ui: UI, doc: Doc, opts: Opts): { Node }
	local body: { Node } = {}
	local pairs: { { Spans } } = {}
	if doc.hint then
		table.insert(pairs, { "Hint", doc.hint })
	end
	if doc.requestId then
		table.insert(pairs, { "Request ID" :: Spans, ui.span(doc.requestId, "mono muted") })
	end
	if #pairs > 0 then
		table.insert(body, ui.kv(pairs))
	end
	local details = doc.details
	if details and isRowList(details) then
		-- the candidates of an AMBIGUOUS error, or any list of records: a table to choose from
		for _, n in tableView(ui, details.items :: { Value }, "error", opts, nil, pickOf(doc, opts)) do
			table.insert(body, n)
		end
	elseif details and details.kind == "array" then
		for _, item in details.items :: { Value } do
			table.insert(body, ui.text(valueSpans(ui, "", item, opts.now)))
		end
	elseif details then
		for _, n in report(ui, details, "error", opts) do
			table.insert(body, n)
		end
	end
	return {
		ui.card(ui.span(doc.message or "Error", "strong"), body, {
			icon = "x-circle",
			tone = "error",
			meta = doc.code,
		}),
	}
end

local function confirmView(ui: UI, doc: Doc, opts: Opts): { Node }
	local body: { Node } = {}
	if doc.preview then
		for _, n in report(ui, doc.preview, "preview", opts) do
			table.insert(body, n)
		end
	end
	if doc.rerun then
		table.insert(body, ui.text(ui.span("Approve by running", "muted")))
		table.insert(body, copyable(ui, doc.rerun))
		if opts.inv then
			table.insert(
				body,
				ui.button("Approve", {
					variant = "primary",
					size = "sm",
					title = "Run it",
					actions = { click = "run=" .. actions.relocate(doc.rerun, opts.inv) },
				})
			)
		end
	end
	local expires = if doc.expiresAt then format.parseDate(doc.expiresAt) else nil
	return {
		ui.card(ui.span(`Confirm {doc.command or "change"}`, "strong"), body, {
			icon = "shield-alert",
			tone = "warning",
			meta = if expires then `valid until {format.showDate(expires)}` else nil,
		}),
	}
end

local function notesView(ui: UI, notes: { string }): Node
	local lines: { Node } = {}
	for _, note in notes do
		table.insert(lines, ui.text(ui.span(note, "muted")))
	end
	return fold(ui.section({ ui.span("Notes", "strong"), ui.span(`  {#notes}`, "muted") }, lines), #notes > 3)
end

local function render(ui: UI, doc: Doc, opts: Opts): Node
	local nodes: { Node }
	if doc.kind == "error" then
		nodes = errorView(ui, doc, opts)
	elseif doc.kind == "confirm" then
		nodes = confirmView(ui, doc, opts)
	else
		nodes = successView(ui, doc, opts)
	end
	if #doc.notes > 0 then
		table.insert(nodes, notesView(ui, doc.notes))
	end
	if doc.format ~= "json" and doc.kind == "success" then
		table.insert(
			nodes,
			ui.text(ui.span("Long values are cut in table output; TENANTCTL_OUTPUT=json shows them whole.", "dim"))
		)
	end
	return with(ui.col(nodes), { role = "tenantctl.view" })
end

return {
	render = render,
	MAX_ROWS = MAX_ROWS,
}
