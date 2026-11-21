--!strict
local t = require("../lib/test")
local block = require("../../lens/block")
local fake = require("../lib/ui")
local fixtures = require("../lib/fixtures")

local describe, it, expect = t.describe, t.it, t.expect

describe("actions block", function()
	local function result(name: string, status: number): block.Result
		local text = table.concat(fixtures.lines(name), "\n")
		return { status = status, stdout = text, stderr = "", timed_out = false }
	end

	it("draws a finished run's result with its own actions", function()
		local state = block.new()
		local r = block.add(state, "tenantctl intune devices list", "/tmp")
		block.settle(r, result("devices-list.json", 0), 1.2)
		expect(r.status).toBe("done")
		state.selected["r1:data"] = 1
		local root = block.view(fake.ui, state, 0)
		local labels = {}
		for _, b in fake.find(root, "button") do
			labels[(b.p :: any).text] = (b.p :: any).actions.click
		end
		expect(labels["Sync"]).toBe("run=tenantctl intune devices sync 0b8d1c3e-8f4e-4b39-9a51-6c2f0e7d1a11")
	end)

	it("reports failures and approvals", function()
		local state = block.new()
		local failed = block.add(state, "tenantctl intune devices list", nil)
		block.settle(failed, result("error-forbidden.json", 4), 0.4)
		expect(failed.status).toBe("failed")
		expect({ block.summary(failed) }).toEqual({
			"error",
			"Failed",
			"Insufficient privileges to complete the operation.",
		})
		local wipe = block.add(state, "tenantctl intune devices wipe LAPTOP-0042", nil)
		block.settle(wipe, result("confirm-wipe.json", 3), 0.4)
		expect(wipe.status).toBe("approval")
		expect(block.add(state, "sh -c 'echo hi'", nil).status).toBe("failed")
	end)

	it("draws a failed run's error inside its card, not as a second card", function()
		local state = block.new()
		local r = block.add(state, "tenantctl intune devices list", nil)
		block.settle(r, result("error-forbidden.json", 4), 0.4)
		local root = block.view(fake.ui, state, 0)
		expect(#fake.find(root, "card")).toBe(1)
		expect(fake.texts(root)).toContain("Insufficient privileges to complete the operation.  FORBIDDEN")
		local copy = fake.find(root, "button")[1]
		expect((copy.p :: any).actions.click).toBe("copy=tenantctl intune devices list")
	end)

	it("never starts a run again after a restart", function()
		local state = block.new()
		block.add(state, "tenantctl intune devices sync LAPTOP-0042", nil)
		local restored = block.restore(block.save(state))
		expect(restored.runs[1].status).toBe("interrupted")
		expect(restored.next).toBe(2)
	end)
end)
