--!strict
-- A `Doc` as a native view. Reports (objects) become a headline, findings, a key/value grid and
-- sections; lists become tables whose rows open a detail card; errors and confirmations become
-- cards. `ui` is `tern.ui`, passed in so the specs can run without Tern.

local json = require("./json")
local format = require("./format")
local output = require("./output")
local actions = require("./actions")
local records = require("./records")
local run = require("./run")

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
	-- Put before every selection path (`r2:data#3`), so several results in one view keep theirs apart.
	prefix: string?,
	-- Drawn inside a card (a run in the tenantctl block): errors and confirmations leave out their own.
	inline: boolean?,
	-- The open panel of each actions bar, by the path of its record (`data`, `r2:data#3`).
	opened: { [string]: string? }?,
	-- Drawn in the tenantctl block's workspace: listed records get Open and can be picked several
	-- at a time; the record the result is about has its actions in the workspace's head instead.
	workspace: boolean?,
	-- Command lines running now: their buttons spin.
	busy: { [string]: boolean }?,
	-- Tables picking several rows, by path, and the row ids picked in each.
	picking: { [string]: boolean }?,
	picked: { [string]: { string } }?,
	-- How the last action run on several rows went for each row, by row id (`r4:data#2`).
	marks: { [string]: Mark }?,
}

export type Mark = { text: string, tone: string?, title: string? }

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

-- The selection path of the part named `name` (`data`, `error`, `preview`) of this result.
local function root(opts: Opts, name: string): string
	return (opts.prefix or "") .. name
end

-- What an action's click sends: its line, and the input to ask for first if it needs any.
local function act(a: Action): string
	return run.act(a.line, a.ask)
end

-- How a bar's buttons click: `act` for one record; for the rows picked in a table, `bulk=` with the
-- table and the action's label, so each row runs its own line.
type BarStyle = { actOf: (a: Action) -> string, bulk: boolean }
local ONE: BarStyle = { actOf = act, bulk = false }

local function isBusy(opts: Opts, a: Action, style: BarStyle): boolean
	return not style.bulk and opts.busy ~= nil and opts.busy[a.line] == true
end

local function actionButton(ui: UI, a: Action, opts: Opts, style: BarStyle): Node
	return ui.button(a.label, {
		size = "sm",
		variant = if a.risk == "destructive" then "danger" else "default",
		title = a.summary,
		busy = isBusy(opts, a, style),
		actions = { click = style.actOf(a) },
	})
end

-- A panel of actions: one column per area, side by side, wrapping onto more lines in a narrow
-- pane. Each lists its actions top to bottom, destructive ones red.
local function actionColumns(ui: UI, list: { Action }, opts: Opts, style: BarStyle): Node
	local areas: { string } = {}
	local byArea: { [string]: { Node } } = {}
	for _, a in list do
		if byArea[a.domain] == nil then
			byArea[a.domain] = { ui.text(ui.span(a.domain, "muted strong")) }
			table.insert(areas, a.domain)
		end
		table.insert(
			byArea[a.domain],
			ui.button(a.label, {
				size = "sm",
				variant = if a.risk == "destructive" then "danger" else "quiet",
				title = a.summary,
				busy = isBusy(opts, a, style),
				actions = { click = style.actOf(a) },
			})
		)
	end
	local cols: { Node } = {}
	for _, area in areas do
		table.insert(cols, with(ui.col(byArea[area]), { gap = "xs", min = { w = "18ch" } }))
	end
	return ui.node("row", { gap = "lg", wrap = true, align = "start", role = "tenantctl.panel" }, cols)
end

-- The button that opens or closes one of a bar's panels; `opened` is the panel shown.
local function panelButton(ui: UI, text: string, path: string, panel: string, opened: string?, title: string?): Node
	local open = opened == panel
	return ui.button(text, {
		size = "sm",
		icon = if open then "chev" else "chev-r",
		on = open,
		title = title,
		actions = { click = `open={path}|{panel}` },
	})
end

-- One line of a record's actions: its label in a column of its own, then its buttons, wrapping
-- under each other in a narrow pane.
local function barRow(ui: UI, label: string, buttons: { Node }): Node
	return with(
		ui.row({
			with(ui.text(ui.span(label, "muted")), { basis = "content", min = { w = "8ch" } }),
			with(ui.row(buttons), { gap = "sm", wrap = true, align = "center", grow = 1, basis = 0 }),
		}),
		{ gap = "sm", align = "start", role = "tenantctl.bar-row" }
	)
end

-- A record's actions, a line each: **Look up**, the reads about it (troubleshooting and its own
-- area's, those it leads with first; the other areas' behind **More**); **Change**, the changes
-- it leads with (destructive ones red; the rest behind **More**); **Related**, a button per record
-- it relates to (its user, its Defender machine, …) that opens a panel of that record's actions.
-- `path` keys which panel is open. `lead` goes first (Open, in the tenantctl block). A bulk bar
-- keeps to the record's own actions, and leaves out those whose input differs per record (a new
-- name).
local function actionBar(ui: UI, targets: { Target }, path: string, opts: Opts, style: BarStyle, lead: Node?): Node?
	local opened = if opts.opened then opts.opened[path] else nil
	local reads: { Node } = {}
	local changes: { Node } = {}
	local related: { Node } = {}
	local panel: Node? = nil
	for _, t in targets do
		if not t.own then
			if style.bulk then
				continue
			end
			local kind = actions.KINDS[t.kind]
			local name = if kind then kind.name else t.kind
			local id = `rel:{t.kind}`
			table.insert(related, panelButton(ui, name, path, id, opened, `{name} {t.ref}`))
			if opened == id then
				panel = ui.col({
					ui.text({ ui.span(name, "strong"), ui.span(`  {t.ref}`, "muted") }),
					actionColumns(ui, t.actions, opts, style),
				})
			end
			continue
		end
		local function usable(a: Action): boolean
			return not (style.bulk and a.ask == "--name")
		end
		local shown: { [Action]: boolean } = {}
		for _, a in t.featured do
			if usable(a) then
				shown[a] = true
				table.insert(if a.risk == "read" then reads else changes, actionButton(ui, a, opts, style))
			end
		end
		local moreReads: { Action } = {}
		local moreChanges: { Action } = {}
		for _, a in t.actions do
			if shown[a] or not usable(a) then
				continue
			end
			if a.risk ~= "read" then
				table.insert(moreChanges, a)
			elseif a.primary then
				table.insert(reads, actionButton(ui, a, opts, style))
			else
				table.insert(moreReads, a)
			end
		end
		if #moreReads > 0 then
			table.insert(reads, panelButton(ui, "More", path, "lookup", opened, "Look up more about it"))
			if opened == "lookup" then
				panel = actionColumns(ui, moreReads, opts, style)
			end
		end
		if #moreChanges > 0 then
			table.insert(changes, panelButton(ui, "More", path, "manage", opened, "Its other changes"))
			if opened == "manage" then
				panel = actionColumns(ui, moreChanges, opts, style)
			end
		end
	end
	local rows: { Node } = {}
	local parts: { { label: string, buttons: { Node } } } = {
		{ label = "Look up", buttons = reads },
		{ label = "Change", buttons = changes },
		{ label = "Related", buttons = related },
	}
	for _, part in parts do
		if #part.buttons > 0 then
			if lead and #rows == 0 then
				table.insert(part.buttons, 1, lead)
			end
			table.insert(rows, barRow(ui, part.label, part.buttons))
		end
	end
	if #rows == 0 then
		return nil
	end
	if panel then
		table.insert(rows, panel)
	end
	return with(ui.col(rows), { role = "tenantctl.actions" })
end

-- In the tenantctl block, a record listed in a result opens as its own workspace.
local function openButton(ui: UI, opts: Opts, targets: { Target }): Node?
	local own = targets[1]
	local inv = opts.inv
	if not opts.workspace or inv == nil or own == nil or not own.own then
		return nil
	end
	local line = actions.detailsLine(inv, own.kind, own.ref)
	if line == nil then
		return nil
	end
	return ui.button(
		"Open",
		{ size = "sm", variant = "primary", title = "Work on it here", actions = { click = run.act(line) } }
	)
end

-- The actions bar of `subject` at `path`, listed under `parent`; nil without an invocation to run
-- them with.
local function barFor(ui: UI, opts: Opts, path: string, subject: Entity?, parent: Entity?): Node?
	local inv = opts.inv
	if inv == nil or subject == nil then
		return nil
	end
	local targets = actions.targets(inv, subject, parent, inv.id)
	return actionBar(ui, targets, path, opts, ONE, openButton(ui, opts, targets))
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

-- Fields holding a secret a person reveals to use elsewhere (a LAPS password, a BitLocker key): a
-- Copy button follows them.
local SECRET: { [string]: boolean } = { password = true, key = true, recoveryKey = true, secret = true }

-- The actions bar for the rows picked in a table at `path`: the first picked row's own actions,
-- each click running it on every picked row.
local function bulkBar(ui: UI, rows: { Value }, path: string, opts: Opts, parent: Entity?): Node?
	local inv = opts.inv
	local picked = if opts.picked then opts.picked[path] else nil
	if inv == nil or picked == nil or #picked == 0 then
		return nil
	end
	local index = tonumber(string.match(picked[1], "#(%d+)$") or "")
	local row = if index then rows[index] else nil
	local entity = if row then entityAt(opts, path, row) else nil
	if entity == nil then
		return nil
	end
	local style: BarStyle = {
		bulk = true,
		actOf = function(a: Action): string
			return `bulk={path}|{a.label}`
		end,
	}
	local bar = actionBar(ui, actions.targets(inv, entity, parent, nil), `{path}!bulk`, opts, style)
	if bar == nil then
		return nil
	end
	local n = #picked
	return ui.col({ ui.text(ui.span(`Run on the {n} picked row{if n == 1 then "" else "s"}`, "muted")), bar })
end

-- A list of objects as a selectable table; a selected row opens its detail card below, led by its
-- actions. `parent` is the record the list belongs to; with `pick`, each row also gets a Use button.
-- In the tenantctl block a list of records can switch to picking several rows, to run one action
-- on all of them; each row then shows how its last such run went.
local function tableView(ui: UI, rows: { Value }, path: string, opts: Opts, parent: Entity?, pick: Pick?): { Node }
	local cols, title = columnsOf(rows)
	local specs: { Col } = {}
	local secrets: { [number]: boolean } = {}
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
		secrets[i] = SECRET[c.key] == true
		if secrets[i] then
			spec.mono = true
			spec.priority = 95
		end
		table.insert(specs, spec)
		if secrets[i] then
			table.insert(specs, { id = `{c.key}.copy`, head = "", priority = 94 })
		end
	end
	local marked = false
	for i = 1, math.min(#rows, MAX_ROWS) do
		marked = marked or (opts.marks ~= nil and opts.marks[`{path}#{i}`] ~= nil)
	end
	if marked then
		table.insert(specs, if title then 2 else 1, { id = "mark", head = "Last action", priority = 90 })
	end
	if pick then
		table.insert(specs, 1, { id = "use", head = "", priority = 200 })
	end
	local tableRows: { TableRow } = {}
	for i = 1, math.min(#rows, MAX_ROWS) do
		local row = rows[i]
		local id = `{path}#{i}`
		local cells: { Cell } = {}
		for j, c in cols do
			local v = json.get(row, c.key)
			table.insert(cells, if v then cellOf(ui, c.key, v, opts.now) else "")
			if secrets[j] then
				local s = json.text(v)
				table.insert(
					cells,
					if s and s ~= "" then { button = { text = "Copy", icon = "copy", act = `copy={s}` } } else ""
				)
			end
		end
		if marked then
			local mark = if opts.marks then opts.marks[id] else nil
			table.insert(
				cells,
				if title then 2 else 1,
				if mark then { badge = { text = mark.text, tone = mark.tone, title = mark.title } } else ""
			)
		end
		if pick then
			local line = pick.line(row)
			table.insert(
				cells,
				1,
				if line then { button = { text = "Use", act = run.act(line), variant = "primary" } } else ""
			)
		end
		tableRows[i] = { id = id, cells = cells }
	end
	-- picking several rows: offered in the block, for rows that are records
	local canPick = opts.workspace == true and pick == nil and rows[1] ~= nil and entityAt(opts, path, rows[1]) ~= nil
	local picking = canPick and opts.picking ~= nil and opts.picking[path] == true
	local selected = if picking then nil else opts.selected[path]
	local tbl = ui.table(specs, tableRows, {
		selectable = true,
		selected = if selected then `{path}#{selected}` else nil,
	})
	local nodes: { Node } = {}
	if canPick then
		table.insert(
			nodes,
			ui.button(if picking then "Done picking" else "Pick several", {
				size = "sm",
				variant = "quiet",
				icon = "list-checks",
				on = picking,
				title = "Run one action on several rows",
				actions = { click = `pick={path}` },
			})
		)
	end
	if picking then
		local p = tbl.p :: { [string]: any }
		p.multi = true
		p.picked = if opts.picked then opts.picked[path] or {} else {}
		p.bar = {}
		p.hint = "Esc clears"
	end
	table.insert(nodes, tbl)
	if #rows > MAX_ROWS then
		table.insert(nodes, ui.overflow(#rows - MAX_ROWS))
	end
	if picking then
		local bar = bulkBar(ui, rows, path, opts, parent)
		if bar then
			table.insert(nodes, bar)
		end
		return nodes
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
				report(
					ui,
					row,
					`{path}#{selected}`,
					opts,
					entity or parent,
					barFor(ui, opts, `{path}#{selected}`, entity, parent)
				),
				-- in a run's card, no second ring
				{ meta = `{selected} of {#rows}`, variant = if opts.inline then "bare" else nil }
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
		local ask = run.askOf(line)
		table.insert(
			lines,
			with(
				ui.row({
					ui.button(if ask then "Run…" else "Run", {
						size = "sm",
						title = "Run it",
						actions = { click = run.act(line, ask) },
					}),
					copyable(ui, nextCommand),
				}),
				-- the button first, so a long command wraps under itself in a narrow pane
				{ align = "start" }
			)
		)
	elseif nextCommand then
		table.insert(lines, copyable(ui, nextCommand))
	end
	local label = string.upper(sev)
	label ..= string.rep(" ", math.max(0, 6 - #label))
	-- the severity keeps its width; the text beside it wraps
	local sevNode = with(ui.text(ui.span(label, format.severityTone(sev) .. " strong")), { basis = "content" })
	return with(ui.row({ sevNode, with(ui.lines(lines), { grow = 1, basis = 0 }) }), { align = "start" })
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
	elseif field(obj, "summary") and path == root(opts, "data") then
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
	-- ids go last, as in tables: what the record is reads first
	local idPairs: { { Spans } } = {}
	-- secrets (a password, a key) also get a line with a Copy button
	local secretRows: { Node } = {}
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
			local s = json.text(v)
			local isId = (v.kind :: string) == "string"
				and (k == "id" or string.match(k, "%lId$") ~= nil or format.isGuid(s or ""))
			table.insert(if isId then idPairs else pairs, { format.label(k) :: Spans, valueSpans(ui, k, v, opts.now) })
			if SECRET[k] and s and s ~= "" then
				table.insert(
					secretRows,
					with(
						ui.row({
							ui.button("Copy", { size = "sm", icon = "copy", actions = { click = `copy={s}` } }),
							ui.text({ ui.span(format.label(k), "muted"), ui.span(`  {s}`, "mono") }),
						}),
						{ align = "center" }
					)
				)
			end
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
			local body = report(ui, v, childPath, opts, entity or self, barFor(ui, opts, childPath, entity, self))
			table.insert(sections, fold(ui.section(sectionHead(ui, k), body), false))
		end
	end
	table.move(idPairs, 1, #idPairs, #pairs + 1, pairs)
	if #pairs > 0 then
		table.insert(nodes, ui.kv(pairs))
	end
	for _, s in secretRows do
		table.insert(nodes, s)
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
	-- in the block's workspace the record's actions lead the workspace already
	local bar = if opts.workspace then nil else barFor(ui, opts, root(opts, "data"), subject, nil)
	if data.kind == "array" then
		local list = data.items :: { Value }
		local nodes: { Node } = { listHead(ui, #list, doc.meta) }
		if #list == 0 then
			nodes = { ui.text(ui.span("No results", "muted")) }
		end
		-- a list of records goes to the tenantctl block, where several can be acted on at once
		local inv = opts.inv
		local line = if inv
				and not opts.workspace
				and isRowList(data)
				and entityAt(opts, root(opts, "data"), list[1])
			then actions.lineOf(inv)
			else nil
		if line then
			nodes[1] = with(
				ui.row({
					nodes[1],
					ui.button("Work on these", {
						size = "sm",
						icon = "list-checks",
						title = "Open this list in the tenantctl panel to act on several at once",
						actions = { click = run.act(line) },
					}),
				}),
				{ align = "center", wrap = true }
			)
		end
		-- the record the list belongs to (`teams members Sales`: the team) and its actions
		if bar then
			table.insert(nodes, bar)
		end
		if isRowList(data) then
			for _, n in tableView(ui, list, root(opts, "data"), opts, subject) do
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
	return report(ui, data, root(opts, "data"), opts, subject, bar)
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

-- An error or confirmation as its card; inside a run's card (`inline`) its head becomes the first
-- line instead, so cards never nest.
local function resultCard(ui: UI, opts: Opts, head: string, body: { Node }, props: { [string]: any }): { Node }
	if not opts.inline then
		return { ui.card(ui.span(head, "strong"), body, props) }
	end
	local spans: { Span } = { ui.span(head, `{props.tone} strong`) }
	if props.meta then
		table.insert(spans, ui.span(`  {props.meta}`, "muted"))
	end
	local out: { Node } = { ui.text(spans) }
	table.move(body, 1, #body, 2, out)
	return out
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
		for _, n in tableView(ui, details.items :: { Value }, root(opts, "error"), opts, nil, pickOf(doc, opts)) do
			table.insert(body, n)
		end
	elseif details and details.kind == "array" then
		for _, item in details.items :: { Value } do
			table.insert(body, ui.text(valueSpans(ui, "", item, opts.now)))
		end
	elseif details then
		for _, n in report(ui, details, root(opts, "error"), opts) do
			table.insert(body, n)
		end
	end
	return resultCard(ui, opts, doc.message or "Error", body, { icon = "x-circle", tone = "error", meta = doc.code })
end

local function confirmView(ui: UI, doc: Doc, opts: Opts): { Node }
	local body: { Node } = {}
	if doc.preview then
		for _, n in report(ui, doc.preview, root(opts, "preview"), opts) do
			table.insert(body, n)
		end
	end
	if doc.rerun then
		local line: { Node } = { copyable(ui, doc.rerun) }
		if opts.inv then
			table.insert(
				line,
				1,
				ui.button("Approve", {
					variant = "primary",
					size = "sm",
					title = "Run it",
					actions = { click = run.act(actions.relocate(doc.rerun, opts.inv)) },
				})
			)
		end
		table.insert(body, with(ui.row(line), { align = "start" }))
	end
	local expires = if doc.expiresAt then format.parseDate(doc.expiresAt) else nil
	return resultCard(ui, opts, `Confirm {doc.command or "change"}`, body, {
		icon = "shield-alert",
		tone = "warning",
		meta = if expires then `valid until {format.showDate(expires)}` else nil,
	})
end

local function notesView(ui: UI, notes: { string }): Node
	local lines: { Node } = {}
	for _, note in notes do
		table.insert(lines, ui.text(ui.span(note, "muted")))
	end
	return fold(ui.section({ ui.span("Notes", "strong"), ui.span(`  {#notes}`, "muted") }, lines), #notes > 3)
end

-- Tern draws its view switch (tenantctl · Native · Raw · copy) over the top-right corner of a
-- selected lens block: the view's first line keeps that much width clear, so nothing on it hides
-- under the switch. Its other lines use the full width.
local CORNER = "30ch"

local function clearCorner(ui: UI, node: Node): Node
	local spacer = with(ui.row({}), { basis = CORNER, min = { w = CORNER }, role = "tenantctl.corner" })
	local p = node.p :: any
	local first = if p and p.role == "tenantctl.actions" and node.c then node.c[1] else nil
	if first and first.c then
		-- an actions bar: its first line's buttons wrap before the corner
		table.insert(first.c, spacer)
		return node
	end
	return with(ui.row({ with(node, { grow = 1, basis = 0 }), spacer }), { align = "start" })
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
	-- the tenantctl block draws no switch over its runs
	if not opts.workspace and nodes[1] then
		nodes[1] = clearCorner(ui, nodes[1])
	end
	return with(ui.col(nodes), { role = "tenantctl.view" })
end

-- The actions bar of the record a workspace is about: every action on it, the reads included.
local function recordBar(ui: UI, opts: Opts, path: string, entity: Entity): Node?
	local inv = opts.inv
	if inv == nil then
		return nil
	end
	return actionBar(ui, actions.targets(inv, entity, nil, nil), path, opts, ONE)
end

-- The name of a record: its first naming field that isn't an id.
local function titleOf(v: Value?): string?
	local key = if v then titleKey(v) else nil
	return if key then field(v, key) else nil
end

return {
	render = render,
	recordBar = recordBar,
	titleOf = titleOf,
	MAX_ROWS = MAX_ROWS,
}
