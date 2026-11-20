--!strict
-- A `Doc` as a native view. Reports (objects) become a headline, findings, a key/value grid and
-- sections; lists become tables whose rows open a detail card; errors and confirmations become
-- cards. `ui` is `tern.ui`, passed in so the specs can run without Tern.

local json = require("./json")
local format = require("./format")
local output = require("./output")

type Value = json.Value
type Doc = output.Doc
type UI = typeof(tern.ui)

export type Opts = {
	-- Seconds since the epoch, for "3h ago".
	now: number,
	-- Selected row per table path (`data`, `data.devices`): its 1-based index.
	selected: { [string]: number? },
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

local report: (ui: UI, obj: Value, path: string, opts: Opts) -> { Node }

-- A list of objects as a selectable table; a selected row opens its detail card below.
local function tableView(ui: UI, rows: { Value }, path: string, opts: Opts): { Node }
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
	local tableRows: { TableRow } = {}
	for i = 1, math.min(#rows, MAX_ROWS) do
		local row = rows[i]
		local cells: { Cell } = {}
		for j, c in cols do
			local v = json.get(row, c.key)
			cells[j] = if v then cellOf(ui, c.key, v, opts.now) else ""
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
		table.insert(
			nodes,
			ui.card(
				ui.span(name or `Row {selected}`, "strong"),
				report(ui, row, `{path}#{selected}`, opts),
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

local function fold(node: Node, collapsed: boolean): Node
	return with(node, { collapsible = true, collapsed = collapsed })
end

local function copyable(ui: UI, command: string): Node
	return with(ui.text(ui.span(command, "code")), { actions = { click = "copy" }, title = "Copy" })
end

local function isFindings(v: Value?): boolean
	local list = items(v)
	return #list > 0 and isRowList(v :: Value) and field(list[1], "severity") ~= nil and field(list[1], "issue") ~= nil
end

local function findingNode(ui: UI, f: Value): Node
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
	if nextCommand then
		table.insert(lines, copyable(ui, nextCommand))
	end
	local label = string.upper(sev)
	label ..= string.rep(" ", math.max(0, 6 - #label))
	return with(ui.row({ ui.text(ui.span(label, format.severityTone(sev) .. " strong")), ui.lines(lines) }), {
		align = "start",
	})
end

-- Findings ranked by severity: high and medium shown, low and info folded under them.
local function findingsView(ui: UI, list: { Value }): { Node }
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
		table.insert(if rank <= 2 then problems else rest, findingNode(ui, f))
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

report = function(ui: UI, obj: Value, path: string, opts: Opts): { Node }
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
		for _, n in findingsView(ui, items(findings)) do
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

	local pairs: { { Spans } } = {}
	local sections: { Node } = {}
	for _, k in obj.keys :: { string } do
		if consumed[k] or format.hidden(k) then
			continue
		end
		local v = map[k]
		local childPath = `{path}.{k}`
		if isScalar(v) or isSmallObject(v) or (v.kind == "array" and #(v.items :: { Value }) == 0) then
			table.insert(pairs, { format.label(k) :: Spans, valueSpans(ui, k, v, opts.now) })
		elseif isRowList(v) then
			local list = v.items :: { Value }
			local section = ui.section(sectionHead(ui, k, #list), tableView(ui, list, childPath, opts))
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
			table.insert(sections, fold(ui.section(sectionHead(ui, k), report(ui, v, childPath, opts)), false))
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

local function successView(ui: UI, doc: Doc, opts: Opts): { Node }
	local data = doc.data or json.NULL
	if data.kind == "array" then
		local list = data.items :: { Value }
		if #list == 0 then
			return { ui.text(ui.span("No results", "muted")) }
		end
		local nodes: { Node } = { listHead(ui, #list, doc.meta) }
		if isRowList(data) then
			for _, n in tableView(ui, list, "data", opts) do
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
	return report(ui, data, "data", opts)
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
	if doc.details then
		for _, n in report(ui, doc.details, "error", opts) do
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
