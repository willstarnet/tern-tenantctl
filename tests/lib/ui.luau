--!strict
-- A stand-in for `tern.ui` under Lune: the builders return the same `{k, p, c}` nodes Tern's do
-- (as documented in the UI Builders reference), plus helpers to search a rendered tree.

export type Node = { k: string, p: { [string]: any }?, c: { Node }? }

local function node(k: string, p: { [string]: any }?, c: { Node }?): Node
	return { k = k, p = p, c = c }
end

local ui = {}

function ui.span(t: string, s: string?): any
	return { t = t, s = s }
end
function ui.link(t: string, href: string, s: string?): any
	return { t = t, s = s, href = href }
end
function ui.text(spans: any): Node
	return node("text", { spans = spans })
end
function ui.col(children: { Node }): Node
	return node("col", nil, children)
end
function ui.lines(children: { Node }): Node
	return node("lines", nil, children)
end
function ui.row(children: { Node }): Node
	return node("row", nil, children)
end
function ui.card(head: any, children: { Node }, props: { [string]: any }?): Node
	local p: { [string]: any } = { head = head }
	for k, v in props or {} do
		p[k] = v
	end
	return node("card", p, children)
end
function ui.section(head: any, children: { Node }): Node
	return node("section", { head = head }, children)
end
function ui.badge(t: string, tone: string): Node
	return node("badge", { text = t, tone = tone })
end
function ui.kv(items: { { any } }): Node
	local out = {}
	for _, pair in items do
		table.insert(out, { k = pair[1], v = pair[2] })
	end
	return node("kv", { items = out })
end
function ui.table(cols: { any }, rows: { any }, opts: { [string]: any }?): Node
	local p: { [string]: any } = { cols = cols, rows = rows }
	for k, v in opts or {} do
		p[k] = v
	end
	return node("table", p)
end
function ui.overflow(hidden: number): Node
	return node("overflow", { hidden = hidden })
end

-- Every node of kind `k` in `root`, depth first.
local function find(root: Node, k: string, into: { Node }?): { Node }
	local out = into or {}
	if root.k == k then
		table.insert(out, root)
	end
	for _, child in root.c or {} do
		find(child, k, out)
	end
	return out
end

-- The plain text of spans: a string, a span or a list of either.
local function spanText(spans: any): string
	if type(spans) == "string" then
		return spans
	elseif type(spans) ~= "table" then
		return ""
	elseif spans.t then
		return spans.t
	end
	local parts = {}
	for _, s in spans do
		table.insert(parts, spanText(s))
	end
	return table.concat(parts)
end

-- The span tokens of the first span in `spans`.
local function spanStyle(spans: any): string?
	if type(spans) ~= "table" then
		return nil
	elseif spans.t then
		return spans.s
	end
	return spanStyle(spans[1])
end

-- Every text node's text, in order.
local function texts(root: Node): { string }
	local out = {}
	for _, n in find(root, "text") do
		table.insert(out, spanText((n.p :: any).spans))
	end
	return out
end

return {
	ui = ui,
	find = find,
	spanText = spanText,
	spanStyle = spanStyle,
	texts = texts,
}
