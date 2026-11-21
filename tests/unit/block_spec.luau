--!strict
local t = require("../lib/test")
local block = require("../../lens/block")
local fake = require("../lib/ui")
local fixtures = require("../lib/fixtures")

local describe, it, expect = t.describe, t.it, t.expect

local LAPTOP = "0b8d1c3e-8f4e-4b39-9a51-6c2f0e7d1a11"
local IPHONE = "5e2a7b90-1d44-4f6a-8c3b-2b9d0a6e7f22"

local function result(name: string, status: number): block.Result
	local text = table.concat(fixtures.lines(name), "\n")
	return { status = status, stdout = text, stderr = "", timed_out = false }
end

-- tenantctl's envelope, pretty-printed as it prints it (`{` and `}` on lines of their own).
local function ok(members: string): block.Result
	return { status = 0, stdout = "{\n" .. members .. "\n}", stderr = "", timed_out = false }
end

-- What `intune devices get` prints for the laptop.
local LAPTOP_JSON = [["ok": true, "command": "intune devices get", "data": {"id": "]]
	.. LAPTOP
	.. [[", "deviceName": "LAPTOP-0042", "os": "Windows", "complianceState": "noncompliant"}]]
local SYNCED = [["ok": true, "command": "intune devices sync", "data": {}]]

local function lines(runs: { block.Run }): { string }
	local out = {}
	for _, r in runs do
		table.insert(out, r.line)
	end
	return out
end

-- Every button label in a view, with its click.
local function buttons(root: fake.Node): { [string]: string }
	local out = {}
	for _, b in fake.find(root, "button") do
		local p = b.p :: any
		if p.actions and p.actions.click and out[p.text] == nil then
			out[p.text] = p.actions.click
		end
	end
	return out
end

describe("workspace", function()
	it("opens the record an action is on, reading it whole first", function()
		local state = block.new()
		local started = block.submit(state, `tenantctl intune devices sync {LAPTOP}`, "/tmp", nil)
		expect(lines(started)).toEqual({
			`tenantctl intune devices get {LAPTOP}`,
			`tenantctl intune devices sync {LAPTOP}`,
		})
		local w = block.space(state, state.current) :: block.Workspace
		expect(w.kind).toBe("intune.device")
		expect(#w.activity).toBe(1)
		expect(w.activity[1].label).toBe("Sync")
		expect(w.tabs[1].label).toBe("Details")
	end)

	it("names the record and leads with its actions once read", function()
		local state = block.new()
		local started = block.submit(state, `tenantctl intune devices get {LAPTOP}`, nil, nil)
		expect(#started).toBe(1)
		block.settle(state, started[1], ok(LAPTOP_JSON), 0.3)
		local w = block.space(state, state.current) :: block.Workspace
		expect(w.name).toBe("LAPTOP-0042")
		local all = buttons(block.view(fake.ui, state, 0))
		expect(all["Sync"]).toBe(`run=tenantctl intune devices sync {LAPTOP}`)
		expect(all["Refresh"]).toBe(`refresh={w.key}`)
	end)

	it("shows a lookup in its own tab and refreshes it in place", function()
		local state = block.new()
		local first = block.submit(state, `tenantctl intune devices get {LAPTOP}`, nil, nil)
		block.settle(state, first[1], ok(LAPTOP_JSON), 0.3)
		block.submit(state, `tenantctl intune devices laps {LAPTOP} --reveal`, nil, state.current)
		block.submit(state, `tenantctl intune devices laps {LAPTOP} --reveal`, nil, state.current)
		local w = block.space(state, state.current) :: block.Workspace
		local labels = {}
		for _, tab in w.tabs do
			table.insert(labels, tab.label)
		end
		expect(labels).toEqual({ "Details", "Reveal LAPS password" })
		expect(w.tab).toBe("Reveal LAPS password")
		expect(#state.spaces).toBe(1)
	end)

	it("reads the record again once a change is done", function()
		local state = block.new()
		local started = block.submit(state, `tenantctl intune devices sync {LAPTOP}`, nil, nil)
		block.settle(state, started[1], ok(LAPTOP_JSON), 0.3)
		local follow = block.settle(state, started[2], ok(SYNCED), 1)
		expect(lines(follow)).toEqual({ `tenantctl intune devices get {LAPTOP}` })
		expect({ block.summary(state, started[2]) }).toEqual({ "success", "Sync done" })
	end)

	it("keeps a record opened by name and by id in one workspace", function()
		local state = block.new()
		-- by name, then by id, before either has been read
		local byName = block.submit(state, "tenantctl intune devices sync LAPTOP-0042", nil, nil)
		local byId = block.submit(state, `tenantctl intune devices laps {LAPTOP} --reveal`, nil, nil)
		expect(#state.spaces).toBe(2)
		-- reading it by id tells its name too: the two are one
		block.settle(state, byId[1], ok(LAPTOP_JSON), 0.3)
		expect(#state.spaces).toBe(1)
		local w = block.space(state, state.current) :: block.Workspace
		expect(w.name).toBe("LAPTOP-0042")
		expect(w.activity[1].label).toBe("Sync")
		local labels = {}
		for _, tab in w.tabs do
			table.insert(labels, tab.label)
		end
		expect(labels).toEqual({ "Details", "Reveal LAPS password" })
		-- the name workspace's own read ends without opening it again
		block.settle(state, byName[1], ok(LAPTOP_JSON), 0.3)
		expect(#state.spaces).toBe(1)
		-- any spelling of either name lands there
		block.submit(state, "tenantctl intune devices restart laptop-0042", nil, nil)
		block.submit(state, `tenantctl intune devices rotate-laps {LAPTOP}`, nil, nil)
		expect(#state.spaces).toBe(1)
		expect(#w.activity).toBe(3)
	end)

	it("keeps a change to a related record in the workspace it was made from", function()
		local state = block.new()
		local first = block.submit(state, `tenantctl intune devices get {LAPTOP}`, nil, nil)
		block.settle(state, first[1], ok(LAPTOP_JSON), 0.3)
		local device = state.current
		block.submit(state, "tenantctl entra users revoke-sessions jane@contoso.com", nil, device)
		expect(state.current).toBe(device)
		local w = block.space(state, device) :: block.Workspace
		expect(w.activity[1].label).toBe("Revoke sessions")
		expect(#state.spaces).toBe(1)
		-- a lookup of it opens its own workspace
		block.submit(state, "tenantctl entra users signins jane@contoso.com", nil, device)
		expect(state.current).toBe("user|jane@contoso.com")
	end)

	it("draws a failed change's error in the workspace", function()
		local state = block.new()
		local started = block.submit(state, `tenantctl intune devices sync {LAPTOP}`, nil, nil)
		block.settle(state, started[2], result("error-forbidden.json", 4), 0.4)
		expect(started[2].status).toBe("failed")
		expect(fake.texts(block.view(fake.ui, state, 0))).toContain(
			"Insufficient privileges to complete the operation.  FORBIDDEN"
		)
		expect({ block.summary(state, started[2]) }).toEqual({
			"error",
			"Sync failed",
			"Insufficient privileges to complete the operation.",
		})
	end)

	it("settles a confirmation once it is approved", function()
		local state = block.new()
		local started = block.submit(state, "tenantctl intune devices wipe LAPTOP-0042", nil, nil)
		local wipe = started[#started]
		block.settle(state, wipe, result("confirm-wipe.json", 3), 0.4)
		expect(wipe.status).toBe("approval")
		expect(buttons(block.view(fake.ui, state, 0))["Approve"]).toBe(
			"run=tenantctl intune devices wipe LAPTOP-0042 --confirm c0nf1rm-t0k3n"
		)
		block.submit(state, "tenantctl intune devices wipe LAPTOP-0042 --confirm c0nf1rm-t0k3n", nil, state.current)
		expect(wipe.status).toBe("approved")
		local w = block.space(state, state.current) :: block.Workspace
		expect(#w.activity).toBe(2)
	end)
end)

describe("several rows", function()
	local function listed(): (block.State, block.Run)
		local state = block.new()
		local started = block.submit(state, "tenantctl intune devices list", nil, nil)
		block.settle(state, started[1], result("devices-list.json", 0), 0.5)
		return state, started[1]
	end

	it("opens a list as a workspace of its own", function()
		local state, list = listed()
		local w = block.space(state, state.current) :: block.Workspace
		expect(w.kind).toBeNil()
		expect(w.details).toBe(list.id)
		expect(buttons(block.view(fake.ui, state, 0))["Pick several"]).toBe(`pick=r{list.id}:data`)
	end)

	it("runs an action on each picked row, a few at a time", function()
		local state, list = listed()
		local path = `r{list.id}:data`
		block.togglePicking(state, path)
		block.setPicked(state, { `{path}#1`, `{path}#2` })
		local items = block.bulkPlan(state, path, "Sync")
		expect(#items).toBe(2)
		expect(items[2].line).toBe(`tenantctl intune devices sync {IPHONE}`)
		expect(items[2].name).toBe("Jane's iPhone")
		-- a Windows-only action skips the iPhone
		expect(#block.bulkPlan(state, path, "Rotate LAPS")).toBe(1)
		local runs = block.addBatch(state, "Sync", items, nil)
		expect(runs[1].status).toBe("queued")
		expect(#block.due(state)).toBe(2)
		block.settle(state, runs[1], ok(SYNCED), 1)
		expect({ block.summary(state, runs[1]) }).toEqual({ nil, nil, nil })
		block.settle(state, runs[2], result("error-forbidden.json", 4), 1)
		expect({ block.summary(state, runs[2]) }).toEqual({ "error", "Sync finished", "1 done, 1 failed" })
		-- each row says how it went
		local tbl = fake.find(block.view(fake.ui, state, 0), "table")[1]
		local p = tbl.p :: any
		expect(p.multi).toBe(true)
		expect(p.rows[1].cells[2]).toEqual({ badge = { text = "Sync", tone = "success" } })
		expect(p.rows[2].cells[2].badge.text).toBe("Sync failed")
	end)
end)

describe("restart", function()
	it("never starts a run again after a restart", function()
		local state = block.new()
		block.submit(state, `tenantctl intune devices sync {LAPTOP}`, nil, nil)
		local restored = block.restore(block.save(state))
		expect(restored.runs[1].status).toBe("interrupted")
		expect(restored.next).toBe(3)
		expect(#restored.spaces).toBe(1)
		expect(restored.current).toBe(state.current)
	end)

	it("only runs tenantctl", function()
		local state = block.new()
		expect(#block.submit(state, "sh -c 'echo hi'", nil, nil)).toBe(0)
	end)
end)
