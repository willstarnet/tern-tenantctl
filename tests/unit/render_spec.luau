--!strict
local t = require("../lib/test")
local fixtures = require("../lib/fixtures")
local fake = require("../lib/ui")
local output = require("../../lens/output")
local render = require("../../lens/render")
local format = require("../../lens/format")

local describe, it, expect = t.describe, t.it, t.expect
local ui, find, texts, spanText, spanStyle = fake.ui, fake.find, fake.texts, fake.spanText, fake.spanStyle

-- 2026-11-20 12:00 UTC: the fixtures' dates are a few hours or days before it.
local NOW = format.parseDate("2026-11-20T12:00:00Z") :: number

local function view(name: string, args: { string }, selected: { [string]: number? }?): fake.Node
	local doc = output.read(fixtures.lines(name), args)
	assert(doc, `{name} not read`)
	return (render.render :: any)(ui, doc, { now = NOW, selected = selected or {} })
end

local function textNode(root: fake.Node, text: string): fake.Node?
	for _, n in find(root, "text") do
		if spanText((n.p :: any).spans) == text then
			return n
		end
	end
	return nil
end

local function sectionNamed(root: fake.Node, name: string): fake.Node?
	for _, s in find(root, "section") do
		if string.sub(spanText((s.p :: any).head), 1, #name) == name then
			return s
		end
	end
	return nil
end

local USER = { "troubleshoot", "user", "jane@contoso.com" }

describe("render report", function()
	it("leads with the verdict, colored by the worst finding", function()
		local root = view("troubleshoot-user.json", USER)
		local first = texts(root)[1]
		expect(first).toContain("2 problems for jane@contoso.com")
		local verdict = textNode(root, first) :: fake.Node
		expect(spanStyle((verdict.p :: any).spans)).toBe("error strong")
	end)

	it("shows problems in full and folds low and info findings", function()
		local root = view("troubleshoot-user.json", USER)
		local all = texts(root)
		expect(all).toContain("The mailbox is soft-deleted 30 days after the last plan is removed.")
		local lower = sectionNamed(root, "Lower priority") :: fake.Node
		expect((lower.p :: any).collapsed).toBe(true)
		expect(texts(lower)).toContain("tenantctl entra signin-error 50126")
		expect(texts(lower)).notToContain("tenantctl entra users enable jane@contoso.com")
	end)

	it("counts findings by severity", function()
		local root = view("troubleshoot-user.json", USER)
		local badges = {}
		for _, b in find(root, "badge") do
			table.insert(badges, `{(b.p :: any).text}:{(b.p :: any).tone}`)
		end
		expect(badges).toEqual({ "1 high:error", "1 medium:warning", "1 low:info", "1 info:info" })
	end)

	it("makes next commands copyable", function()
		local root = view("troubleshoot-user.json", USER)
		local next = textNode(root, "tenantctl entra users enable jane@contoso.com") :: fake.Node
		expect((next.p :: any).actions).toEqual({ click = "copy" })
	end)

	it("says which sections could not be checked", function()
		local root = view("troubleshoot-user.json", USER)
		expect(texts(root)).toContain("Not checked: risk  Risk detections need Entra ID P2.  FORBIDDEN")
	end)

	it("puts nested objects in sections and lists in tables with status badges", function()
		local root = view("troubleshoot-user.json", USER)
		expect(sectionNamed(root, "Account")).notToBeNil()
		local devices = sectionNamed(root, "Devices") :: fake.Node
		local tbl = find(devices, "table")[1]
		local p = tbl.p :: any
		expect(p.cols[1].head).toBe("Device name")
		expect(p.cols[1].grow).toBe(1)
		expect(p.rows[1].cells[3]).toEqual({ badge = { text = "Noncompliant", tone = "error" } })
		expect(p.rows[1].cells[4]).toEqual({ text = "3d ago", title = "2026-11-17 10:00 UTC" })
	end)

	it("colors a disabled account", function()
		local root = view("troubleshoot-user.json", USER)
		local account = sectionNamed(root, "Account") :: fake.Node
		local kv = find(account, "kv")[1]
		local enabled = (kv.p :: any).items[1]
		expect(enabled.k).toBe("Enabled")
		expect(enabled.v).toEqual({ t = "no", s = "warning strong" })
	end)

	it("shows small objects inline and dates with their age", function()
		local root = view("users-get.json", { "entra", "users", "get", "jane" })
		local items = (find(root, "kv")[1].p :: any).items
		local byKey = {}
		for _, item in items do
			byKey[spanText(item.k)] = spanText(item.v)
		end
		expect(byKey["Manager"]).toBe("Bob Smith · bob@contoso.com")
		expect(byKey["Created"]).toBe("2024-02-01 09:12 UTC  2y ago")
		expect(byKey["Mobile phone"]).toBe("—")
		expect(byKey["Licenses"]).toBe("SPE_E3, POWER_BI_PRO")
		expect(byKey["Sign ins"]).toBe(
			"2026-11-19 16:02 UTC · 2026-11-20 07:01 UTC · 2026-11-20 07:01 UTC · signInActivity"
		)
	end)
end)

describe("render list", function()
	local LIST = { "intune", "devices", "list" }

	it("warns that more results exist", function()
		local root = view("devices-list.json", LIST)
		expect(texts(root)[1]).toBe("3 of 57 shown: raise --top or pass --all.")
	end)

	it("moves id columns last, in mono", function()
		local root = view("devices-list.json", LIST)
		local cols = (find(root, "table")[1].p :: any).cols
		expect(cols[1].id).toBe("deviceName")
		expect(cols[#cols].id).toBe("id")
		expect(cols[#cols].mono).toBe(true)
		expect(cols[#cols].truncate).toBe("middle")
	end)

	it("opens the selected row's details", function()
		local root = view("devices-list.json", LIST, { data = 3 })
		local p = find(root, "table")[1].p :: any
		expect(p.selected).toBe("data#3")
		expect(p.rows[3].id).toBe("data#3")
		local card = find(root, "card")[1]
		expect(spanText((card.p :: any).head)).toBe("MAC-0007")
		local items = (find(card, "kv")[1].p :: any).items
		expect(spanText(items[#items].v)).toBe("no")
	end)

	it("moves id-named columns last even when they aren't GUIDs", function()
		local doc = output.read({
			"id      type      detail",
			"------  --------  -------",
			"abc123  Password",
			"def456  Passkey   synced",
		}, { "entra", "users", "mfa", "jane" })
		assert(doc)
		local root = (render.render :: any)(ui, doc, { now = NOW, selected = {} })
		local cols = (find(root, "table")[1].p :: any).cols
		expect(cols[1].id).toBe("type")
		expect(cols[#cols].id).toBe("id")
	end)

	it("says when there are no results", function()
		local root = view("empty-list.json", { "entra", "users", "list" })
		expect(texts(root)[1]).toBe("No results")
	end)
end)

describe("render error and confirmation", function()
	it("shows an error card with its code, hint and request id", function()
		local root = view("error-forbidden.json", { "intune", "devices", "list" })
		local card = find(root, "card")[1]
		local p = card.p :: any
		expect(p.tone).toBe("error")
		expect(p.meta).toBe("FORBIDDEN")
		expect(spanText(p.head)).toBe("Insufficient privileges to complete the operation.")
		local kv = (find(card, "kv")[1].p :: any).items
		expect(spanText(kv[2].v)).toBe("7a1b2c3d-4e5f-4061-8273-9a0b1c2d3e4f")
	end)

	it("shows the confirmation preview and a copyable command", function()
		local root = view("confirm-wipe.json", { "intune", "devices", "wipe", "LAPTOP-0042" })
		local card = find(root, "card")[1]
		expect((card.p :: any).meta).toBe("valid until 2026-11-20 15:30 UTC")
		expect(texts(card)).toContain("The device cannot be recovered after a wipe.")
		local rerun = textNode(card, "tenantctl intune devices wipe LAPTOP-0042 --confirm c0nf1rm-t0k3n")
		expect(((rerun :: fake.Node).p :: any).actions).toEqual({ click = "copy" })
	end)
end)

describe("render table format", function()
	it("renders the same report and says values may be cut", function()
		local root = view("troubleshoot-user.txt", USER)
		expect(texts(root)[1]).toContain("2 problems for jane@contoso.com")
		local all = texts(root)
		expect(all[#all]).toContain("Long values are cut")
	end)
end)

describe("format", function()
	it("labels keys", function()
		expect(format.label("lastSyncDateTime")).toBe("Last sync")
		expect(format.label("userPrincipalName")).toBe("User principal name")
		expect(format.label("osVersion")).toBe("OS version")
		expect(format.label("device.isCompliant")).toBe("Device is compliant")
	end)

	it("reads dates with zones", function()
		expect(format.parseDate("2026-11-20T14:00:00+02:00")).toBe(NOW)
		expect(format.parseDate("2026-11-20T12:00:00.123Z")).toBe(NOW)
		expect(format.parseDate("not a date")).toBeNil()
		expect(format.age(NOW + 3 * 86400, NOW)).toBe("in 3d")
	end)

	it("colors status words only under status keys", function()
		expect(format.statusTone("complianceState", "nonCompliant")).toBe("error")
		expect(format.statusTone("status", "serviceDegradation")).toBe("warning")
		expect(format.statusTone("department", "high")).toBeNil()
	end)
end)
