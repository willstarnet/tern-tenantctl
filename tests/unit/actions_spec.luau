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

-- The view of fixture `name` as run by `typed`, with `selected` rows open.
local function view(name: string, typed: string, selected: { [string]: number? }?): fake.Node
	local args = {}
	for word in string.gmatch(typed, "%S+") do
		table.insert(args, word)
	end
	local program = table.remove(args, 1) :: string
	local doc = output.read(fixtures.lines(name), args)
	assert(doc, `{name} not read`)
	local inv = actions.invocation(program, args, typed, typed, doc.command)
	return (render.render :: any)(ui, doc, { now = NOW, selected = selected or {}, inv = inv })
end

-- Every action a view offers, by its label, the first of a label in view order (the record's own
-- before its relations').
local function offered(root: fake.Node): { [string]: { act: string, variant: string? } }
	local out = {}
	for _, b in find(root, "button") do
		local p = b.p :: any
		if p.actions and p.actions.click and out[p.text] == nil then
			out[p.text] = { act = p.actions.click, variant = p.variant }
		end
	end
	return out
end

-- The actions bars in a view, in order.
local function bars(root: fake.Node): { fake.Node }
	local out = {}
	for _, r in find(root, "col") do
		if r.p and (r.p :: any).role == "tenantctl.actions" then
			table.insert(out, r)
		end
	end
	return out
end

-- The folded group of actions headed `name`.
local function group(root: fake.Node, name: string): fake.Node?
	for _, s in find(root, "section") do
		if string.sub(spanText((s.p :: any).head), 1, #name) == name then
			return s
		end
	end
	return nil
end

local LAPTOP = "0b8d1c3e-8f4e-4b39-9a51-6c2f0e7d1a11"

describe("actions on a selected row", function()
	it("offers a device's remote actions, run on its Intune id", function()
		local root = view("devices-list.json", "tenantctl intune devices list", { data = 1 })
		local card = find(root, "card")[1]
		local all = offered(card)
		expect(all["Sync"].act).toBe(`run=tenantctl intune devices sync {LAPTOP}`)
		expect(all["Rotate LAPS"].act).toBe(`run=tenantctl intune devices rotate-laps {LAPTOP}`)
		expect(all["Restart"].variant).toBe("danger")
		expect(all["Details"].act).toBe(`run=tenantctl intune devices get {LAPTOP}`)
	end)

	it("reaches the device's user", function()
		local root = view("devices-list.json", "tenantctl intune devices list", { data = 1 })
		local user = group(find(root, "card")[1], "User") :: fake.Node
		expect(spanText((user.p :: any).head)).toBe("User  jane@contoso.com")
		expect((user.p :: any).collapsed).toBe(true)
		local all = offered(user)
		expect(all["Revoke sessions"].act).toBe("run=tenantctl entra users revoke-sessions jane@contoso.com")
		expect(all["Reset password"].variant).toBe("danger")
	end)

	it("offers nothing until a row is selected", function()
		local root = view("devices-list.json", "tenantctl intune devices list")
		expect(#bars(root)).toBe(0)
	end)

	it("acts on a device listed under a user", function()
		local root =
			view("troubleshoot-user.json", "tenantctl troubleshoot user jane@contoso.com", { ["data.devices"] = 1 })
		local card = find(root, "card")[1]
		expect(offered(card)["Sync"].act).toBe(`run=tenantctl intune devices sync {LAPTOP}`)
		-- its Entra object and Defender machine, by the Entra device id Intune keeps
		local entra = group(card, "Entra device") :: fake.Node
		expect(offered(entra)["Disable"].act).toBe(
			"run=tenantctl entra devices disable 6d1f0a2b-3c4d-4e5f-8a9b-0c1d2e3f4a5b"
		)
		expect(group(card, "Defender machine")).notToBeNil()
	end)

	it("types a command that needs more input instead of running it", function()
		local root = view("devices-list.json", "tenantctl intune devices list", { data = 1 })
		local rename = offered(find(root, "card")[1])["Rename…"]
		expect(rename.act).toBe(`fill=tenantctl intune devices rename {LAPTOP} --name `)
	end)

	it("quotes values for the shell", function()
		expect(actions.quote("Jane's iPhone")).toBe([['Jane'"'"'s iPhone']])
		expect(actions.quote("jane@contoso.com")).toBe("jane@contoso.com")
		-- a newline would run the line early: no action at all
		expect(actions.quote("a\nb")).toBeNil()
	end)

	it("offers only what the device's platform supports", function()
		local windows =
			offered(find(view("devices-list.json", "tenantctl intune devices list", { data = 1 }), "card")[1])
		expect(windows["Rotate LAPS"]).notToBeNil()
		expect(windows["Lock"]).toBeNil()
		local iphone =
			offered(find(view("devices-list.json", "tenantctl intune devices list", { data = 2 }), "card")[1])
		expect(iphone["Lock"]).notToBeNil()
		expect(iphone["Rotate LAPS"]).toBeNil()
	end)

	it("removes a member from the group it was listed under, not adds it again", function()
		local root = view("group-members.json", "tenantctl entra groups members Sales", { data = 1 })
		local all = offered(find(root, "card")[1])
		expect(all["Remove member"].act).toBe("run=tenantctl entra groups remove-member Sales user:bob@contoso.com")
		expect(all["Add member"]).toBeNil()
	end)

	it("knows a device member is an Entra device", function()
		local root = view("group-members.json", "tenantctl entra groups members Sales", { data = 2 })
		local all = offered(find(root, "card")[1])
		expect(all["Remove member"].act).toBe(
			"run=tenantctl entra groups remove-member Sales device:2f3e4d5c-6b7a-4c8d-9e0f-1a2b3c4d5e6f"
		)
		expect(all["Disable"].act).toBe("run=tenantctl entra devices disable 2f3e4d5c-6b7a-4c8d-9e0f-1a2b3c4d5e6f")
	end)
end)

describe("actions on the record a run is about", function()
	it("puts the user's actions under the verdict", function()
		local root = view("troubleshoot-user.json", "tenantctl troubleshoot user jane@contoso.com")
		local bar = bars(root)[1]
		local all = offered(bar)
		expect(all["Revoke sessions"].act).toBe("run=tenantctl entra users revoke-sessions jane@contoso.com")
		expect(all["Troubleshoot sign-ins"]).notToBeNil()
		-- the run itself is not offered again
		expect(all["Troubleshoot"]).toBeNil()
	end)

	it("leaves out a change that would do nothing", function()
		local all = offered(bars(view("users-get.json", "tenantctl entra users get jane"))[1])
		expect(all["Enable"]).toBeNil()
		expect(all["Disable"]).notToBeNil()
	end)

	it("acts on the user's manager", function()
		local root = view("users-get.json", "tenantctl entra users get jane")
		local manager = bars(root)[2]
		expect(offered(manager)["Revoke sessions"].act).toBe(
			"run=tenantctl entra users revoke-sessions bob@contoso.com"
		)
	end)

	it("keeps the profile and the program as typed", function()
		local root = view("users-get.json", "./bin/tenantctl --profile contoso entra users get jane")
		expect(offered(bars(root)[1])["Disable"].act).toBe(
			"run=./bin/tenantctl --profile contoso entra users disable jane@contoso.com"
		)
	end)

	it("reads the command from the arguments in table format", function()
		local root = view("users-get.txt", "tenantctl entra users get jane")
		expect(offered(bars(root)[1])["Disable"].act).toBe("run=tenantctl entra users disable jane@contoso.com")
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
		local all = offered(find(root, "card")[2])
		expect(all["Sync"].act).toBe(`run=tenantctl intune devices sync {PICKED}`)
	end)
end)

describe("findings and confirmations", function()
	it("runs a finding's next step", function()
		local root = view("troubleshoot-user.json", "tenantctl --profile contoso troubleshoot user jane@contoso.com")
		local run = offered(root)["Run"]
		expect(run.act).toBe("run=tenantctl --profile contoso entra users enable jane@contoso.com")
	end)

	it("approves a confirmation by running its re-run command", function()
		local root = view("confirm-wipe.json", "tenantctl intune devices wipe LAPTOP-0042")
		local approve = offered(root)["Approve"]
		expect(approve.act).toBe("run=tenantctl intune devices wipe LAPTOP-0042 --confirm c0nf1rm-t0k3n")
		expect(spanText((find(root, "card")[1].p :: any).head)).toBe("Confirm intune devices wipe")
	end)
end)
