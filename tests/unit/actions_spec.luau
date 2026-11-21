--!strict
local t = require("../lib/test")
local fixtures = require("../lib/fixtures")
local fake = require("../lib/ui")
local output = require("../../lens/output")
local render = require("../../lens/render")
local actions = require("../../lens/actions")
local format = require("../../lens/format")

local describe, it, expect = t.describe, t.it, t.expect
local ui, find, spanText = fake.ui, fake.find, fake.spanText

local NOW = format.parseDate("2026-11-20T12:00:00Z") :: number

-- The view of fixture `name` as run by `typed`, with `selected` rows and `opened` panels open.
local function view(
	name: string,
	typed: string,
	selected: { [string]: number? }?,
	opened: { [string]: string? }?
): fake.Node
	local args = {}
	for word in string.gmatch(typed, "%S+") do
		table.insert(args, word)
	end
	local program = table.remove(args, 1) :: string
	local doc = output.read(fixtures.lines(name), args)
	assert(doc, `{name} not read`)
	local inv = actions.invocation(program, args, typed, typed, doc.command)
	return (render.render :: any)(ui, doc, { now = NOW, selected = selected or {}, opened = opened or {}, inv = inv })
end

type Offer = { label: string, act: string, variant: string?, panel: string? }

-- The panel `button` opens, as `path` and panel id, when it opens one.
local function opens(button: fake.Node): (string?, string?)
	local p = button.p :: any
	local click = if p.actions then p.actions.click else nil
	return string.match(click or "", "^open=(.*)|([^|]+)$")
end

-- The action buttons in `node` (panel toggles left out), in view order; `panel` names the button
-- that opened them.
local function buttonsIn(node: fake.Node, panel: string?, into: { Offer }?): { Offer }
	local out = into or {}
	for _, b in find(node, "button") do
		local p = b.p :: any
		if p.actions and p.actions.click and opens(b) == nil then
			table.insert(out, { label = p.text, act = p.actions.click, variant = p.variant, panel = panel })
		end
	end
	return out
end

-- The actions bars in a view, in order.
local function bars(root: fake.Node): { fake.Node }
	local out = {}
	for _, n in find(root, "col") do
		if n.p and (n.p :: any).role == "tenantctl.actions" then
			table.insert(out, n)
		end
	end
	return out
end

-- Every action a person can reach in a view: its buttons, then those in each panel its bars open;
-- with `bar`, only that bar's (the n-th of the view).
local function reachable(name: string, typed: string, selected: { [string]: number? }?, bar: number?): { Offer }
	local function scope(root: fake.Node): fake.Node?
		return if bar then bars(root)[bar] else root
	end
	local root = scope(view(name, typed, selected))
	if root == nil then
		return {}
	end
	local out = buttonsIn(root)
	for _, b in find(root, "button") do
		local path, panel = opens(b)
		local opened = if path then scope(view(name, typed, selected, { [path :: string] = panel })) else nil
		for _, n in if opened then find(opened, "row") else {} do
			if n.p and (n.p :: any).role == "tenantctl.panel" then
				buttonsIn(n, (b.p :: any).text, out)
			end
		end
	end
	return out
end

-- The first offer labeled `label`, in the panel opened by `panel` when given.
local function offer(list: { Offer }, label: string, panel: string?): Offer?
	for _, o in list do
		if o.label == label and (panel == nil or o.panel == panel) then
			return o
		end
	end
	return nil
end

-- The labels of a node's action buttons, in order.
local function labels(node: fake.Node): { string }
	local out = {}
	for _, o in buttonsIn(node) do
		table.insert(out, o.label)
	end
	return out
end

local LAPTOP = "0b8d1c3e-8f4e-4b39-9a51-6c2f0e7d1a11"
local DEVICES = "tenantctl intune devices list"

describe("actions on a selected row", function()
	it("offers a device's remote actions, run on its Intune id", function()
		local all = reachable("devices-list.json", DEVICES, { data = 1 })
		expect((offer(all, "Sync") :: Offer).act).toBe(`run=tenantctl intune devices sync {LAPTOP}`)
		expect((offer(all, "Rotate LAPS") :: Offer).act).toBe(`run=tenantctl intune devices rotate-laps {LAPTOP}`)
		expect((offer(all, "Restart") :: Offer).variant).toBe("danger")
		expect((offer(all, "Details", "Look up") :: Offer).act).toBe(`run=tenantctl intune devices get {LAPTOP}`)
	end)

	it("leads with the most used actions and keeps the rest a click away", function()
		local root = view("devices-list.json", DEVICES, { data = 1 })
		expect(labels(bars(root)[1])).toEqual({ "Sync", "Troubleshoot", "Restart", "Rotate LAPS" })
		local all = reachable("devices-list.json", DEVICES, { data = 1 })
		expect(offer(all, "Sync", "Look up")).toBeNil()
		expect((offer(all, "Wipe", "Manage") :: Offer).variant).toBe("danger")
		expect((offer(all, "Locate", "Manage") :: Offer).variant).toBe("quiet")
		expect(offer(all, "Restart", "Manage")).toBeNil()
	end)

	it("lists a panel's actions in a column per area", function()
		local root = view("users-get.json", "tenantctl entra users get jane", nil, { data = "lookup" })
		local panel = find(root, "row")
		local columns
		for _, n in panel do
			if n.p and (n.p :: any).role == "tenantctl.panel" then
				columns = n.c
			end
		end
		assert(columns, "no panel")
		local heads = {}
		for _, col in columns do
			table.insert(heads, fake.texts(col)[1])
		end
		expect(heads).toEqual({ "Troubleshoot", "Entra", "Defender", "Exchange", "SharePoint", "Teams", "Purview" })
	end)

	it("reaches the device's user", function()
		local all = reachable("devices-list.json", DEVICES, { data = 1 })
		local revoke = offer(all, "Revoke sessions", "User") :: Offer
		expect(revoke.act).toBe("run=tenantctl entra users revoke-sessions jane@contoso.com")
		expect(revoke.variant).toBe("danger")
	end)

	it("offers nothing until a row is selected", function()
		expect(#bars(view("devices-list.json", DEVICES))).toBe(0)
	end)

	it("acts on a device listed under a user", function()
		local all = reachable(
			"troubleshoot-user.json",
			"tenantctl troubleshoot user jane@contoso.com",
			{ ["data.devices"] = 1 }
		)
		expect((offer(all, "Sync") :: Offer).act).toBe(`run=tenantctl intune devices sync {LAPTOP}`)
		-- its Entra object and Defender machine, by the Entra device id Intune keeps
		expect((offer(all, "Disable", "Entra device") :: Offer).act).toBe(
			"run=tenantctl entra devices disable 6d1f0a2b-3c4d-4e5f-8a9b-0c1d2e3f4a5b"
		)
		expect(offer(all, "Alerts", "Defender machine")).notToBeNil()
	end)

	it("asks for the input a command still needs", function()
		local rename = offer(reachable("devices-list.json", DEVICES, { data = 1 }), "Rename…") :: Offer
		expect(rename.act).toBe(`ask=--name|tenantctl intune devices rename {LAPTOP}`)
	end)

	it("quotes values for the shell", function()
		expect(actions.quote("Jane's iPhone")).toBe([['Jane'"'"'s iPhone']])
		expect(actions.quote("jane@contoso.com")).toBe("jane@contoso.com")
		-- a newline would run the line early: no action at all
		expect(actions.quote("a\nb")).toBeNil()
	end)

	it("reveals a Windows device's LAPS password", function()
		local windows = reachable("devices-list.json", DEVICES, { data = 1 })
		local reveal = offer(windows, "Reveal LAPS password", "Look up") :: Offer
		expect(reveal.act).toBe(`run=tenantctl intune devices laps {LAPTOP} --reveal`)
		expect((offer(windows, "LAPS", "Look up") :: Offer).act).toBe(`run=tenantctl intune devices laps {LAPTOP}`)
		local iphone = reachable("devices-list.json", DEVICES, { data = 2 })
		expect(offer(iphone, "Reveal LAPS password")).toBeNil()
	end)

	it("offers the rarer forms of a device's routine tasks", function()
		local windows = reachable("devices-list.json", DEVICES, { data = 1 })
		expect((offer(windows, "Reveal BitLocker key", "Look up") :: Offer).act).toBe(
			`run=tenantctl intune devices bitlocker-key {LAPTOP} --reveal`
		)
		expect((offer(windows, "Defender full scan", "Manage") :: Offer).act).toBe(
			`run=tenantctl intune devices defender-scan {LAPTOP} --full-scan`
		)
		expect((offer(windows, "Wipe, keep user files", "Manage") :: Offer).variant).toBe("danger")
		-- the wipe flags are Windows only
		local mac = reachable("devices-list.json", DEVICES, { data = 3 })
		expect(offer(mac, "Wipe")).notToBeNil()
		expect(offer(mac, "Wipe, keep user files")).toBeNil()
	end)

	it("offers only what the device's platform supports", function()
		local windows = reachable("devices-list.json", DEVICES, { data = 1 })
		expect(offer(windows, "Rotate LAPS")).notToBeNil()
		expect(offer(windows, "Lock")).toBeNil()
		local iphone = reachable("devices-list.json", DEVICES, { data = 2 })
		expect(offer(iphone, "Lock")).notToBeNil()
		expect(offer(iphone, "Rotate LAPS")).toBeNil()
	end)

	it("removes a member from the group it was listed under, not adds it again", function()
		local root = view("group-members.json", "tenantctl entra groups members Sales", { data = 1 })
		local bar = buttonsIn(bars(find(root, "card")[1])[1])
		-- what the list is for leads
		expect(bar[1].label).toBe("Remove member")
		expect(bar[1].act).toBe("run=tenantctl entra groups remove-member Sales user:bob@contoso.com")
		local all = reachable("group-members.json", "tenantctl entra groups members Sales", { data = 1 })
		expect(offer(all, "Add member")).toBeNil()
	end)

	it("knows a device member is an Entra device", function()
		local all = reachable("group-members.json", "tenantctl entra groups members Sales", { data = 2 })
		expect((offer(all, "Remove member") :: Offer).act).toBe(
			"run=tenantctl entra groups remove-member Sales device:2f3e4d5c-6b7a-4c8d-9e0f-1a2b3c4d5e6f"
		)
		expect((offer(all, "Disable") :: Offer).act).toBe(
			"run=tenantctl entra devices disable 2f3e4d5c-6b7a-4c8d-9e0f-1a2b3c4d5e6f"
		)
	end)
end)

describe("actions on the record a run is about", function()
	it("puts the user's actions under the verdict", function()
		local all = reachable("troubleshoot-user.json", "tenantctl troubleshoot user jane@contoso.com")
		local revoke = offer(all, "Revoke sessions") :: Offer
		expect(revoke.act).toBe("run=tenantctl entra users revoke-sessions jane@contoso.com")
		expect(revoke.panel).toBeNil()
		expect(offer(all, "Troubleshoot sign-ins", "Look up")).notToBeNil()
		-- the run itself is not offered again
		expect(offer(all, "Troubleshoot")).toBeNil()
	end)

	it("leaves out a change that would do nothing", function()
		local all = reachable("users-get.json", "tenantctl entra users get jane", nil, 1)
		expect(offer(all, "Enable")).toBeNil()
		expect(offer(all, "Disable", "Manage")).notToBeNil()
	end)

	it("acts on the user's manager", function()
		local manager = buttonsIn(bars(view("users-get.json", "tenantctl entra users get jane"))[2])
		expect((offer(manager, "Revoke sessions") :: Offer).act).toBe(
			"run=tenantctl entra users revoke-sessions bob@contoso.com"
		)
	end)

	it("keeps the profile and the program as typed", function()
		local all = reachable("users-get.json", "./bin/tenantctl --profile contoso entra users get jane")
		expect((offer(all, "Disable") :: Offer).act).toBe(
			"run=./bin/tenantctl --profile contoso entra users disable jane@contoso.com"
		)
	end)

	it("reads the command from the arguments in table format", function()
		local all = reachable("users-get.txt", "tenantctl entra users get jane")
		expect((offer(all, "Disable") :: Offer).act).toBe("run=tenantctl entra users disable jane@contoso.com")
	end)
end)

describe("ambiguous matches", function()
	local PICKED = "1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d"

	for _, name in { "error-ambiguous.json", "error-ambiguous.txt" } do
		it(`lists the candidates and re-runs the command on the one picked ({name})`, function()
			local root = view(name, "tenantctl --profile contoso intune devices get WS-PF3")
			local tbl = find(root, "table")[1]
			local p = tbl.p :: any
			expect(#p.rows).toBe(2)
			expect(p.rows[1].cells[1]).toEqual({
				button = {
					text = "Use",
					act = `run=tenantctl --profile contoso intune devices get {PICKED}`,
					variant = "primary",
				},
			})
		end)
	end

	it("acts on a selected candidate as the device it is", function()
		local root = view("error-ambiguous.json", "tenantctl intune devices get WS-PF3", { error = 1 })
		local sync = offer(buttonsIn(find(root, "card")[2]), "Sync") :: Offer
		expect(sync.act).toBe(`run=tenantctl intune devices sync {PICKED}`)
	end)
end)

describe("findings and confirmations", function()
	it("runs a finding's next step", function()
		local root = view("troubleshoot-user.json", "tenantctl --profile contoso troubleshoot user jane@contoso.com")
		local run = offer(buttonsIn(root), "Run") :: Offer
		expect(run.act).toBe("run=tenantctl --profile contoso entra users enable jane@contoso.com")
	end)

	it("approves a confirmation by running its re-run command", function()
		local root = view("confirm-wipe.json", "tenantctl intune devices wipe LAPTOP-0042")
		local approve = offer(buttonsIn(root), "Approve") :: Offer
		expect(approve.act).toBe("run=tenantctl intune devices wipe LAPTOP-0042 --confirm c0nf1rm-t0k3n")
		expect(spanText((find(root, "card")[1].p :: any).head)).toBe("Confirm intune devices wipe")
	end)
end)
