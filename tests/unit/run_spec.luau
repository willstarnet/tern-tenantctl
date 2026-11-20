--!strict
local t = require("../lib/test")
local run = require("../../lens/run")

local describe, it, expect = t.describe, t.it, t.expect

describe("run", function()
	it("starts only tenantctl, with the words a shell would pass", function()
		local spec =
			run.spec([[TENANTCTL_PROFILE=x ./bin/tenantctl intune devices rename LAPTOP --name 'Jane'"'"'s PC']])
		assert(spec)
		expect(spec.argv).toEqual({ "./bin/tenantctl", "intune", "devices", "rename", "LAPTOP", "--name", "Jane's PC" })
		expect(spec.env).toEqual({ TENANTCTL_PROFILE = "x" })
		expect(spec.args[1]).toBe("intune")
		expect((run.spec("bun run tenantctl health overview") :: run.Spec).argv[3]).toBe("tenantctl")
	end)

	it("refuses anything else", function()
		expect(run.spec("rm -rf /")).toBeNil()
		expect(run.spec("tenantctl health overview; rm -rf ~")).toBeNil()
		expect(run.spec("tenantctl $(whoami)")).toBeNil()
		expect(run.spec("tenantctl 'unclosed")).toBeNil()
		expect(run.spec("FOO=1 tenantctl health overview")).toBeNil()
		expect(run.spec("tenantctl")).toBeNil()
	end)

	it("fills in what a command asks for", function()
		local line = "tenantctl intune devices rename LAPTOP"
		expect(run.complete(line, "--name", "Jane's PC")).toBe(
			[[tenantctl intune devices rename LAPTOP --name 'Jane'"'"'s PC']]
		)
		expect(run.complete("tenantctl entra groups add-member Sales", "members", "bob@contoso.com")).toBe(
			"tenantctl entra groups add-member Sales bob@contoso.com"
		)
		expect(run.complete("tenantctl entra users update jane", "*", "--department Sales")).toBe(
			"tenantctl entra users update jane --department Sales"
		)
		expect(run.complete("tenantctl entra users update jane", "*", "--department $(id)")).toBeNil()
		expect(run.complete("tenantctl entra signin-error <code>", "<", "50126")).toBe(
			"tenantctl entra signin-error 50126"
		)
		expect(run.complete(line, "--name", "  ")).toBeNil()
		expect(run.hint("--name", line)).toBe("Name")
	end)

	it("reads a click back", function()
		expect({ run.parseAct("ask", "--name|tenantctl x") }).toEqual({ "tenantctl x", "--name" })
		expect({ run.parseAct("run=tenantctl x") }).toEqual({ "tenantctl x" })
	end)
end)
