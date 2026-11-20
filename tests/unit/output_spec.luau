--!strict
local t = require("../lib/test")
local fixtures = require("../lib/fixtures")
local json = require("../../lens/json")
local output = require("../../lens/output")

local describe, it, expect = t.describe, t.it, t.expect

type Value = json.Value

local function keys(v: Value?): { string }
	return if v and v.keys then v.keys else {}
end

local function items(v: Value?): { Value }
	return if v and v.items then v.items else {}
end

local function str(v: Value?, key: string): string?
	return json.text(json.get(v, key))
end

describe("json.decode", function()
	it("keeps member order and nulls", function()
		local v = json.decode('{"z": 1, "a": null, "m": [true, "x\\u00e9"]}')
		expect(keys(v)).toEqual({ "z", "a", "m" })
		expect((json.get(v, "a") :: Value).kind).toBe("null")
		expect(json.text(items(json.get(v, "m"))[2])).toBe("xé")
	end)

	it("reports where it failed", function()
		local v, err = json.decode('{"a": }')
		expect(v).toBeNil()
		expect(err).toContain("byte 7")
	end)
end)

describe("output.read json", function()
	it("reads a report with its findings in order", function()
		local doc = output.read(fixtures.lines("troubleshoot-user.json"), { "troubleshoot", "user", "jane" })
		assert(doc)
		expect(doc.kind).toBe("success")
		expect(doc.format).toBe("json")
		expect(keys(doc.data)[2]).toBe("verdict")
		local findings = items(json.get(doc.data, "findings"))
		expect(#findings).toBe(4)
		expect(str(findings[2], "detail")).toBe("The mailbox is soft-deleted 30 days after the last plan is removed.")
	end)

	it("reads list meta", function()
		local doc = output.read(fixtures.lines("devices-list.json"), { "intune", "devices", "list" })
		assert(doc and doc.meta)
		expect(doc.meta.count).toBe(3)
		expect(doc.meta.total).toBe(57)
		expect(doc.meta.truncated).toBe(true)
	end)

	it("keeps stderr lines around the document as notes", function()
		local lines = fixtures.lines("devices-list.json")
		table.insert(lines, 1, "Graph rejected the device filter; applying os client-side.")
		local doc = output.read(lines, { "intune", "devices", "list" })
		assert(doc)
		expect(doc.notes).toEqual({ "Graph rejected the device filter; applying os client-side." })
	end)

	it("reads errors", function()
		local doc = output.read(fixtures.lines("error-forbidden.json"), { "intune", "devices", "list" })
		assert(doc)
		expect(doc.kind).toBe("error")
		expect(doc.code).toBe("FORBIDDEN")
		expect(doc.requestId).toBe("7a1b2c3d-4e5f-4061-8273-9a0b1c2d3e4f")
		expect(str(doc.details, "role")).toBe("Intune Administrator")
	end)

	it("reads confirmation requests", function()
		local doc = output.read(fixtures.lines("confirm-wipe.json"), { "intune", "devices", "wipe", "LAPTOP-0042" })
		assert(doc)
		expect(doc.kind).toBe("confirm")
		expect(doc.rerun).toBe("tenantctl intune devices wipe LAPTOP-0042 --confirm c0nf1rm-t0k3n")
		expect(str(json.get(doc.preview, "device"), "deviceName")).toBe("LAPTOP-0042")
	end)
end)

describe("output.read table format", function()
	it("reads scalars, nested objects and the tables inside them", function()
		local doc = output.read(fixtures.lines("troubleshoot-user.txt"), { "troubleshoot", "user", "jane" })
		assert(doc)
		expect(doc.format).toBe("table")
		expect(keys(doc.data)).toEqual({
			"user",
			"verdict",
			"mfa",
			"mailbox",
			"findings",
			"unavailable",
			"account",
			"signins",
			"devices",
		})
		expect(str(json.get(doc.data, "user"), "displayName")).toBe("Jane Doe")
		local findings = items(json.get(doc.data, "findings"))
		expect(str(findings[1], "next")).toBe("tenantctl entra users enable jane@contoso.com")
		expect((json.get(findings[3], "detail") :: Value).kind).toBe("null")
		local signins = json.get(doc.data, "signins")
		expect(json.get(signins, "total")).toEqual(json.num(48, "48"))
		expect(str(items(json.get(signins, "failureGroups"))[1], "name")).toBe("InvalidUserNameOrPassword")
		expect(json.get(json.get(doc.data, "account"), "enabled")).toEqual(json.bool(false))
	end)

	it("reads a list and its footer", function()
		local doc = output.read(fixtures.lines("devices-list.txt"), { "intune", "devices", "list" })
		assert(doc and doc.meta)
		expect(#items(doc.data)).toBe(3)
		expect(str(items(doc.data)[3], "osVersion")).toBe("15.1 (24B83)")
		expect(doc.meta.total).toBe(57)
		expect(doc.meta.truncated).toBe(true)
	end)

	it("cuts cells by characters, not bytes", function()
		local doc = output.read({
			"name               os",
			"-----------------  -----",
			"Kai’s MacBook Pro  macOS",
			"Ünïcode…           iOS",
		}, { "intune", "devices", "list" })
		assert(doc)
		expect(str(items(doc.data)[1], "name")).toBe("Kai’s MacBook Pro")
		expect(str(items(doc.data)[1], "os")).toBe("macOS")
		expect(str(items(doc.data)[2], "os")).toBe("iOS")
	end)

	it("reads empty values and JSON cells", function()
		local doc = output.read(fixtures.lines("users-get.txt"), { "entra", "users", "get", "jane" })
		assert(doc)
		expect((json.get(doc.data, "mobilePhone") :: Value).kind).toBe("null")
		expect(str(json.get(doc.data, "manager"), "displayName")).toBe("Bob Smith")
		expect(#items(json.get(doc.data, "licenses"))).toBe(2)
	end)

	it("reads an empty list", function()
		local doc = output.read(fixtures.lines("empty-list.txt"), { "entra", "users", "list" })
		assert(doc and doc.meta)
		expect(#items(doc.data)).toBe(0)
		expect(doc.meta.count).toBe(0)
	end)

	it("reads errors with details and the request id", function()
		local doc = output.read(fixtures.lines("error-forbidden.txt"), { "intune", "devices", "list" })
		assert(doc)
		expect(doc.code).toBe("FORBIDDEN")
		expect(doc.hint).toContain("auth login")
		expect(str(doc.details, "needs")).toBe("DeviceManagementManagedDevices.Read.All")
		expect(doc.requestId).toBe("7a1b2c3d-4e5f-4061-8273-9a0b1c2d3e4f")
	end)

	it("reads confirmation requests", function()
		local doc = output.read(fixtures.lines("confirm-wipe.txt"), { "intune", "devices", "wipe", "LAPTOP-0042" })
		assert(doc)
		expect(doc.kind).toBe("confirm")
		expect(doc.expiresAt).toBe("2026-11-20T15:30:00.000Z")
		expect(doc.rerun).toBe("tenantctl intune devices wipe LAPTOP-0042 --confirm c0nf1rm-t0k3n")
		expect(str(json.get(doc.preview, "device"), "user")).toBe("jane@contoso.com")
	end)
end)

describe("output.read leaves prose raw", function()
	it("for help and version", function()
		expect(output.read({ "tenantctl 0.2.3" }, { "--version" })).toBeNil()
		expect(output.read({ "Usage: tenantctl <area> <command>" }, {})).toBeNil()
		expect(output.read({ "x  y" }, { "entra", "--help" })).toBeNil()
	end)

	it("for domain help", function()
		local doc = output.read({
			"tenantctl entra - Users, groups and policies",
			"",
			"Commands:",
			"  users list  List users",
			"  users get   Show one user",
			"",
			"Run `tenantctl entra <command> --help` for details.",
		}, { "entra" })
		expect(doc).toBeNil()
	end)
end)

describe("output.read csv", function()
	it("reads quoted fields", function()
		local doc = output.read({ "name,note", 'a,"x, ""y"""', "b," }, { "entra", "users", "list", "--csv" })
		assert(doc)
		expect(doc.format).toBe("csv")
		expect(str(items(doc.data)[1], "note")).toBe('x, "y"')
		expect((json.get(items(doc.data)[2], "note") :: Value).kind).toBe("null")
	end)
end)
