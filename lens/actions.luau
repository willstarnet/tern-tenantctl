--!strict
-- Actions on the records a view shows. A record (a table row, or the object a report is about) has
-- a kind (`user`, `intune.device`, …). Every tenantctl command whose argument takes that kind is an
-- action on it, run by typing its command line into the pane. A record also reaches the records it
-- relates to: an Intune device its Entra object, Defender machine and user; a row of a member list
-- the group it belongs to.

local json = require("./json")
local format = require("./format")
local catalog = require("./catalog")

type Value = json.Value
type Command = catalog.Command

export type Entity = {
	kind: string,
	-- the record's fields, when the view has them
	value: Value?,
	-- what the user typed for it (the run's argument), used when its fields don't name it
	ref: string?,
}

export type Action = {
	label: string,
	-- the command line, quoted for the shell
	line: string,
	-- "read" | "write" | "destructive"
	risk: string,
	-- input the command still needs, asked for before it runs (see `run.complete`): `--name` (a
	-- flag's value), `members` (a positional's), `*` (options the person types); nil when complete
	ask: string?,
	summary: string,
	domain: string,
}

-- Actions on one record, reached through `ref`.
export type Target = {
	kind: string,
	ref: string,
	-- the record itself, not one it relates to
	own: boolean,
	-- every action, troubleshooting first, then the record's own area, then the rest by area
	actions: { Action },
	-- the few it leads with (shown as buttons), in order; each is also in `actions`
	featured: { Action },
}

-- How the run that printed the view started tenantctl, so actions start it the same way.
export type Invocation = {
	-- `tenantctl`, `./bin/tenantctl`, `bun run tenantctl`, after any `TENANTCTL_*=…` assignments
	prefix: string,
	-- `--profile`, carried into every action
	profile: string?,
	-- the run's command (`entra users get`), when known
	id: string?,
	-- its positional values by argument name
	values: { [string]: string },
	-- its arguments after the program, as typed
	args: { string },
}

local ZERO_GUID = "00000000-0000-0000-0000-000000000000"

-- Kinds a record can be: the name shown for it and the command prefixes that are its own (its
-- area, listed right after troubleshooting).
local KINDS: { [string]: { name: string, home: { string } } } = {
	user = { name = "User", home = { "entra users", "entra risky-users" } },
	["intune.device"] = { name = "Intune device", home = { "intune devices" } },
	["entra.device"] = { name = "Entra device", home = { "entra devices" } },
	["defender.machine"] = { name = "Defender machine", home = { "defender machines" } },
	["autopilot.device"] = { name = "Autopilot device", home = { "intune autopilot" } },
	group = { name = "Group", home = { "entra groups" } },
	["exchange.dl"] = { name = "Distribution list", home = { "exchange dl" } },
	["entra.app"] = { name = "Enterprise app", home = { "entra apps" } },
	["entra.deleteduser"] = { name = "Deleted user", home = { "entra users" } },
	["entra.ca"] = { name = "Conditional Access policy", home = { "entra ca" } },
	["intune.app"] = { name = "Intune app", home = { "intune apps" } },
	["intune.compliance"] = { name = "Compliance policy", home = { "intune compliance" } },
	["intune.config"] = { name = "Configuration profile", home = { "intune config" } },
	["intune.update"] = { name = "Update policy", home = { "intune updates" } },
	["intune.filter"] = { name = "Assignment filter", home = { "intune filters" } },
	["intune.script"] = { name = "Script", home = { "intune scripts" } },
	["intune.enrollment"] = { name = "Enrollment configuration", home = { "intune enrollment" } },
	["autopilot.profile"] = { name = "Autopilot profile", home = { "intune autopilot profiles" } },
	["defender.incident"] = { name = "Incident", home = { "defender incidents" } },
	["defender.alert"] = { name = "Alert", home = { "defender alerts" } },
	["defender.action"] = { name = "Machine action", home = { "defender machines" } },
	team = { name = "Team", home = { "teams" } },
	channel = { name = "Channel", home = { "teams channels" } },
	["sharepoint.site"] = { name = "Site", home = { "sharepoint sites" } },
	["sharepoint.file"] = { name = "File", home = { "sharepoint files" } },
	permission = { name = "Sharing permission", home = { "sharepoint files" } },
	version = { name = "Version", home = { "sharepoint files" } },
	["exchange.rule"] = { name = "Inbox rule", home = { "exchange rules" } },
	["mail.message"] = { name = "Message", home = { "exchange messages" } },
	["quarantine.message"] = { name = "Quarantined message", home = { "exchange quarantine" } },
	["trace.message"] = { name = "Traced message", home = { "exchange trace" } },
	["auth.method"] = { name = "Authentication method", home = { "entra users" } },
	["signin.error"] = { name = "Sign-in error", home = { "entra signin-error" } },
	["access.review"] = { name = "Access review", home = { "entra access-reviews" } },
	["ediscovery.case"] = { name = "eDiscovery case", home = { "purview ediscovery" } },
	["audit.query"] = { name = "Audit query", home = { "purview audit" } },
	["health.issue"] = { name = "Service issue", home = { "health issue" } },
	["health.message"] = { name = "Message center post", home = { "health message" } },
	["teams.call"] = { name = "Call", home = { "teams calls" } },
	license = { name = "License", home = { "entra users license" } },
	-- target-only kinds: an argument with its own identity rules
	["entra.member"] = { name = "Member", home = {} },
	["defender.host"] = { name = "Defender machine", home = { "defender alerts" } },
	["exchange.access"] = { name = "Mailbox access", home = {} },
}

-- What each argument takes, by command prefix and argument name; the first rule that matches wins.
-- An argument no rule names (a file, a query, an email to invite) is never filled from a record.
local ARGS: { { prefix: string, arg: string, kinds: { string } } } = {
	{ prefix = "troubleshoot mail", arg = "recipient", kinds = { "user" } },
	{ prefix = "intune autopilot profiles", arg = "deployment-profile", kinds = { "autopilot.profile" } },
	{ prefix = "intune autopilot", arg = "device", kinds = { "autopilot.device" } },
	{ prefix = "troubleshoot device", arg = "device", kinds = { "intune.device" } },
	{ prefix = "intune devices", arg = "device", kinds = { "intune.device" } },
	{ prefix = "intune apps", arg = "app", kinds = { "intune.app" } },
	{ prefix = "intune apps", arg = "item", kinds = { "intune.app" } },
	{ prefix = "intune compliance", arg = "policy", kinds = { "intune.compliance" } },
	{ prefix = "intune compliance", arg = "item", kinds = { "intune.compliance" } },
	{ prefix = "intune config", arg = "policy", kinds = { "intune.config" } },
	{ prefix = "intune config", arg = "item", kinds = { "intune.config" } },
	{ prefix = "intune updates", arg = "policy", kinds = { "intune.update" } },
	{ prefix = "intune filters", arg = "filter", kinds = { "intune.filter" } },
	{ prefix = "intune scripts", arg = "script", kinds = { "intune.script" } },
	{ prefix = "intune enrollment", arg = "config", kinds = { "intune.enrollment" } },
	{ prefix = "entra devices", arg = "device", kinds = { "entra.device" } },
	{ prefix = "entra users restore", arg = "user", kinds = { "entra.deleteduser" } },
	{ prefix = "entra users auth-method", arg = "method-id", kinds = { "auth.method" } },
	{ prefix = "entra users license", arg = "sku", kinds = { "license" } },
	{ prefix = "entra groups", arg = "member", kinds = { "entra.member" } },
	{ prefix = "entra groups", arg = "members", kinds = { "entra.member" } },
	{ prefix = "entra apps", arg = "app", kinds = { "entra.app" } },
	{ prefix = "entra ca", arg = "policy", kinds = { "entra.ca" } },
	{ prefix = "entra signin-error", arg = "code", kinds = { "signin.error" } },
	{ prefix = "entra access-reviews", arg = "review-id", kinds = { "access.review" } },
	{ prefix = "defender machines package-url", arg = "action-id", kinds = { "defender.action" } },
	{ prefix = "defender machines", arg = "machine", kinds = { "defender.machine" } },
	{ prefix = "defender alerts for-device", arg = "device", kinds = { "defender.host" } },
	{ prefix = "defender incidents", arg = "id", kinds = { "defender.incident" } },
	{ prefix = "defender alerts", arg = "id", kinds = { "defender.alert" } },
	{ prefix = "defender threat-submit", arg = "message-id", kinds = { "mail.message" } },
	{ prefix = "exchange messages", arg = "message", kinds = { "mail.message" } },
	{ prefix = "exchange rules", arg = "rule", kinds = { "exchange.rule" } },
	{ prefix = "exchange quarantine", arg = "identity", kinds = { "quarantine.message" } },
	{ prefix = "exchange trace details", arg = "trace-id", kinds = { "trace.message" } },
	{ prefix = "exchange dl", arg = "group", kinds = { "exchange.dl" } },
	{ prefix = "exchange dl", arg = "member", kinds = { "user", "exchange.dl" } },
	{ prefix = "exchange dl", arg = "members", kinds = { "user", "exchange.dl" } },
	{ prefix = "exchange permissions", arg = "access", kinds = { "exchange.access" } },
	{ prefix = "sharepoint sites", arg = "site", kinds = { "sharepoint.site" } },
	{ prefix = "sharepoint files", arg = "ref", kinds = { "sharepoint.file" } },
	{ prefix = "sharepoint files", arg = "permission-id", kinds = { "permission" } },
	{ prefix = "sharepoint files", arg = "version-id", kinds = { "version" } },
	{ prefix = "sharepoint onedrive", arg = "owner", kinds = { "user" } },
	{ prefix = "sharepoint onedrive", arg = "grantee", kinds = { "user" } },
	{ prefix = "purview ediscovery", arg = "case", kinds = { "ediscovery.case" } },
	{ prefix = "purview audit results", arg = "query-id", kinds = { "audit.query" } },
	{ prefix = "teams channels members", arg = "channel", kinds = { "channel" } },
	{ prefix = "teams calls get", arg = "id", kinds = { "teams.call" } },
	{ prefix = "teams", arg = "team", kinds = { "team" } },
	{ prefix = "teams presence", arg = "users", kinds = { "user" } },
	{ prefix = "health issue", arg = "id", kinds = { "health.issue" } },
	{ prefix = "health message", arg = "id", kinds = { "health.message" } },
	{ prefix = "", arg = "user", kinds = { "user" } },
	{ prefix = "", arg = "mailbox", kinds = { "user" } },
	{ prefix = "", arg = "group", kinds = { "group" } },
}

local function text(v: Value?, key: string): string?
	local s = json.text(json.get(v, key))
	if s == nil or s == "" or s == ZERO_GUID or string.find(s, "…", 1, true) then
		return nil
	end
	return s
end

local function truthy(v: Value?, key: string): boolean
	local f = json.get(v, key)
	return f ~= nil and f.kind == "boolean" and f.b == true
end

-- `jane@contoso.com`, not a display name that could match someone else.
local function address(v: Value?, key: string): string?
	local s = text(v, key)
	return if s and string.find(s, "^[^%s@]+@[^%s@]+$") then s else nil
end

-- How a record of kind `source` gives an argument of kind `target`: the first non-empty field, or a
-- function; `when` limits it to the records it applies to.
type Ref = {
	fields: { string }?,
	get: ((v: Value) -> string?)?,
	when: ((v: Value) -> boolean)?,
	prefix: string?,
}

local USER_FIELDS = { "userPrincipalName", "upn", "user", "email", "mail", "primarySmtpAddress", "userId", "id" }

local function fieldIs(key: string, values: { string }): (v: Value) -> boolean
	return function(v: Value): boolean
		return table.find(values, text(v, key) or "") ~= nil
	end
end

local ACCESS: { [string]: string } = { FullAccess = "full", SendAs = "sendas", SendOnBehalf = "sendonbehalf" }

local REFS: { [string]: { [string]: Ref } } = {
	user = {
		user = { fields = USER_FIELDS },
		["intune.device"] = {
			get = function(v)
				return address(v, "user")
			end,
		},
		["autopilot.device"] = {
			get = function(v)
				return address(v, "assignedUser")
			end,
		},
		["defender.alert"] = {
			get = function(v)
				return address(v, "user")
			end,
		},
		["defender.incident"] = {
			get = function(v)
				return address(v, "assignedTo")
			end,
		},
		signin = {
			get = function(v)
				return address(v, "user")
			end,
		},
		["trace.message"] = {
			get = function(v)
				return address(v, "recipient")
			end,
		},
	},
	["intune.device"] = {
		["intune.device"] = { fields = { "id", "managedDeviceId", "deviceId", "deviceName", "device", "serialNumber" } },
		["entra.device"] = { fields = { "deviceId" } },
		["defender.machine"] = { fields = { "aadDeviceId" } },
		["autopilot.device"] = { fields = { "managedDeviceId" } },
	},
	["entra.device"] = {
		["entra.device"] = { fields = { "id", "deviceId", "displayName" } },
		["intune.device"] = { fields = { "azureADDeviceId" } },
		["defender.machine"] = { fields = { "aadDeviceId" } },
		["autopilot.device"] = { fields = { "azureAdDeviceId" } },
	},
	["defender.machine"] = {
		["defender.machine"] = { fields = { "id" } },
		["intune.device"] = { fields = { "azureADDeviceId" } },
		["entra.device"] = { fields = { "deviceId" } },
		["autopilot.device"] = { fields = { "azureAdDeviceId" } },
	},
	-- `defender alerts for-device` takes a machine id or a computer name, not an Entra device id
	["defender.host"] = {
		["defender.machine"] = { fields = { "id" } },
		["intune.device"] = { fields = { "deviceName" } },
	},
	["autopilot.device"] = {
		["autopilot.device"] = { fields = { "serialNumber", "id" } },
		["intune.device"] = {
			fields = { "serialNumber" },
			when = function(v)
				return truthy(v, "autopilotEnrolled")
			end,
		},
	},
	group = {
		group = { fields = { "id", "mail", "email", "displayName" } },
	},
	-- Exchange names a distribution list by its address, never by an Entra id
	["exchange.dl"] = {
		["exchange.dl"] = { fields = { "email", "mail", "name" } },
		group = {
			fields = { "mail" },
			when = fieldIs("type", { "distribution", "mail-security", "Distribution", "Mail-enabled security" }),
		},
	},
	-- `entra groups add-member`/`remove-member` take `user:`, `group:` or `device:` before the id
	["entra.member"] = {
		user = { fields = { "userPrincipalName", "id", "userId" }, prefix = "user:" },
		group = { fields = { "id" }, prefix = "group:" },
		["entra.device"] = { fields = { "id" }, prefix = "device:" },
	},
	["entra.app"] = {
		["entra.app"] = { fields = { "id", "appId" } },
		["entra.appcredential"] = { fields = { "appId" } },
	},
	["entra.deleteduser"] = { ["entra.deleteduser"] = { fields = { "id" } } },
	["entra.ca"] = { ["entra.ca"] = { fields = { "id", "policyId", "name" } } },
	["intune.app"] = { ["intune.app"] = { fields = { "id" } } },
	["intune.compliance"] = { ["intune.compliance"] = { fields = { "id", "policyId" } } },
	["intune.config"] = {
		["intune.config"] = {
			fields = { "id", "policyId" },
			when = function(v)
				return text(v, "kind") ~= "admx"
			end,
		},
		["intune.update"] = { fields = { "id" }, when = fieldIs("kind", { "ring" }) },
	},
	["intune.update"] = { ["intune.update"] = { fields = { "id" } } },
	["intune.filter"] = { ["intune.filter"] = { fields = { "id", "filterId" } } },
	["intune.script"] = { ["intune.script"] = { fields = { "id" } } },
	["intune.enrollment"] = { ["intune.enrollment"] = { fields = { "id" } } },
	["autopilot.profile"] = { ["autopilot.profile"] = { fields = { "id" } } },
	["defender.incident"] = {
		["defender.incident"] = { fields = { "id", "incidentId" } },
		["defender.alert"] = { fields = { "incidentId" } },
	},
	["defender.alert"] = { ["defender.alert"] = { fields = { "alertId", "id" } } },
	["defender.action"] = {
		["defender.action"] = { fields = { "id" }, when = fieldIs("type", { "CollectInvestigationPackage" }) },
	},
	team = {
		team = { fields = { "id" } },
		group = {
			fields = { "id" },
			when = function(v)
				return truthy(v, "isTeam")
			end,
		},
	},
	channel = { channel = { fields = { "id" } } },
	["sharepoint.site"] = {
		["sharepoint.site"] = { fields = { "webUrl", "url" } },
		["sharepoint.drive"] = { fields = { "webUrl" } },
	},
	["sharepoint.file"] = {
		["sharepoint.file"] = {
			get = function(v)
				local drive, item = text(v, "driveId"), text(v, "id")
				if drive and item then
					return `{drive}:{item}`
				end
				return text(v, "ref") or text(v, "webUrl")
			end,
		},
	},
	-- an inherited permission is removed on the item it comes from, not this one
	permission = {
		permission = {
			fields = { "id" },
			when = function(v)
				return text(v, "kind") ~= "inherited" and not truthy(v, "inherited")
			end,
		},
	},
	version = { version = { fields = { "id" } } },
	["exchange.rule"] = { ["exchange.rule"] = { fields = { "id" } } },
	["mail.message"] = {
		["mail.message"] = { fields = { "id", "internetMessageId" } },
		["trace.message"] = { fields = { "messageId" } },
	},
	["quarantine.message"] = { ["quarantine.message"] = { fields = { "identity" } } },
	["trace.message"] = { ["trace.message"] = { fields = { "id", "traceId" } } },
	["auth.method"] = {
		["auth.method"] = {
			fields = { "id" },
			when = function(v)
				return text(v, "type") ~= "Password"
			end,
		},
	},
	["signin.error"] = {
		["signin.error"] = { fields = { "errorCode", "code" } },
		signin = { fields = { "errorCode" } },
	},
	["access.review"] = { ["access.review"] = { fields = { "id" } } },
	["ediscovery.case"] = { ["ediscovery.case"] = { fields = { "id" } } },
	["audit.query"] = { ["audit.query"] = { fields = { "queryId" } } },
	["health.issue"] = { ["health.issue"] = { fields = { "id" } } },
	["health.message"] = { ["health.message"] = { fields = { "id" } } },
	["teams.call"] = { ["teams.call"] = { fields = { "id" } } },
	-- only a directly assigned license can be removed from the user
	license = {
		license = {
			fields = { "sku", "skuPartNumber", "skuId" },
			when = function(v)
				return text(v, "assignedVia") ~= "group"
			end,
		},
	},
	["exchange.access"] = {
		user = {
			get = function(v)
				return ACCESS[text(v, "access") or ""]
			end,
		},
	},
}

-- The value an argument of kind `target` takes from `e`, or nil when `e` doesn't give one.
local function refFor(target: string, e: Entity): string?
	local ref = (REFS[target] or {})[e.kind]
	local v = e.value
	if ref and v and v.kind == "object" and (ref.when == nil or (ref.when :: (Value) -> boolean)(v)) then
		local found: string? = nil
		if ref.get then
			found = ref.get(v)
		else
			for _, key in ref.fields or {} do
				found = text(v, key)
				if found then
					break
				end
			end
		end
		if found then
			return (ref.prefix or "") .. found
		end
	end
	if target == e.kind and e.ref then
		return e.ref
	end
	return nil
end

-- The kinds an argument takes, or nil when no record gives it.
local function argKinds(id: string, arg: string): { string }?
	for _, rule in ARGS do
		if
			rule.arg == arg
			and (rule.prefix == "" or id == rule.prefix or string.sub(id, 1, #rule.prefix + 1) == rule.prefix .. " ")
		then
			return rule.kinds
		end
	end
	return nil
end

-- A word for the shell. Safe characters stay bare; anything else is single-quoted, with `'` and `\`
-- written in double quotes so the result reads the same in sh, bash, zsh and fish. Control
-- characters (a newline would run the line early) make it unusable: nil.
local function quote(s: string): string?
	if s == "" then
		return "''"
	end
	if string.find(s, "%c") then
		return nil
	end
	-- `=` is safe after the first character (zsh expands a leading `=cmd`); a dash quoted is still a flag
	if string.match(s, "^[%w@%._/:+,%-][%w@%._/:+,%-=]*$") then
		return s
	end
	local parts: { string } = {}
	for run, special in string.gmatch(s, "([^'\\]*)(['\\]?)") do
		if run ~= "" then
			table.insert(parts, `'{run}'`)
		end
		if special == "'" then
			table.insert(parts, `"'"`)
		elseif special == "\\" then
			table.insert(parts, `"\\\\"`)
		end
	end
	return table.concat(parts)
end

-- `--profile x` and the program as typed, so an action runs where the original did.
local function start(inv: Invocation): string
	local p = quote(inv.profile or "")
	return if inv.profile and p then `{inv.prefix} --profile {p}` else inv.prefix
end

-- Rewrites a `tenantctl …` line tenantctl printed (a finding's next step, a confirmation's re-run)
-- to start tenantctl the way this run did. Other text stays as it is.
local function relocate(line: string, inv: Invocation): string
	if string.sub(line, 1, 10) ~= "tenantctl " then
		return line
	end
	local rest = string.sub(line, 11)
	if inv.profile and not string.find(rest, "--profile", 1, true) then
		return `{start(inv)} {rest}`
	end
	return `{inv.prefix} {rest}`
end

local VALUE_FLAGS: { [string]: boolean } =
	{ ["--output"] = true, ["-o"] = true, ["--fields"] = true, ["--profile"] = true, ["--confirm"] = true }

local byId: { [string]: Command } = {}
for _, c in catalog.commands do
	byId[c.id] = c
end

-- The run's command id (from the output, else the longest catalog id its leading words make), and
-- the values it gave its positional arguments.
local function invocation(program: string, args: { string }, typed: string?, line: string?, id: string?): Invocation
	local rest = args
	local prefix = "tenantctl"
	if program == "bun" and args[1] == "run" and args[2] == "tenantctl" then
		prefix = "bun run tenantctl"
		rest = table.move(args, 3, #args, 1, {})
	else
		-- the program as typed (a path), and any TENANTCTL_* assignments before it
		for _, src in { typed or "", line or "" } do
			local env: { string } = {}
			local found: string? = nil
			for word in string.gmatch(src, "%S+") do
				if string.match(word, "^TENANTCTL_[%u_]+=[%w@%._/:+,%-]*$") then
					table.insert(env, word)
				elseif string.match(word, "^[%w%._/~%-]*tenantctl$") then
					found = word
					break
				end
			end
			if found then
				table.insert(env, found)
				prefix = table.concat(env, " ")
				break
			end
		end
	end
	local profile: string? = nil
	local words: { string } = {}
	local i = 1
	while i <= #rest do
		local a = rest[i]
		if a == "--profile" then
			profile = rest[i + 1]
			i += 1
		elseif string.sub(a, 1, 10) == "--profile=" then
			profile = string.sub(a, 11)
		elseif VALUE_FLAGS[a] then
			i += 1
		elseif string.sub(a, 1, 1) ~= "-" then
			table.insert(words, a)
		else
			break
		end
		i += 1
	end
	local command: Command? = if id then byId[id] else nil
	if id == nil then
		for n = math.min(#words, 5), 1, -1 do
			local candidate = table.concat(words, " ", 1, n)
			if byId[candidate] then
				id = candidate
				command = byId[candidate]
				break
			end
		end
	end
	local values: { [string]: string } = {}
	if command then
		-- positional values: the words after the command id, and `--name value` for positional names
		local idWords = select(2, string.gsub(command.id, "%S+", "")) :: number
		local positionalNames: { [string]: boolean } = {}
		for _, p in command.positional do
			positionalNames[p.name] = true
		end
		local bools: { [string]: boolean } =
			{ ["--json"] = true, ["--csv"] = true, ["--full"] = true, ["--dry-run"] = true, ["--debug"] = true }
		for _, b in command.bools do
			bools["--" .. b] = true
		end
		local bare: { string } = {}
		local seen = 0
		local j = 1
		while j <= #rest do
			local a = rest[j]
			local name, inline = string.match(a, "^%-%-([^=]+)=(.*)$")
			if a == "--" then
				for k = j + 1, #rest do
					table.insert(bare, rest[k])
				end
				break
			elseif name then
				if positionalNames[name] then
					values[name] = inline :: string
				end
			elseif string.sub(a, 1, 2) == "--" or string.match(a, "^%-%a$") then
				local flag = string.match(a, "^%-%-(.+)$")
				if flag and positionalNames[flag] and rest[j + 1] then
					values[flag] = rest[j + 1]
					j += 1
				elseif not bools[a] then
					j += 1
				end
			else
				seen += 1
				if seen > idWords then
					table.insert(bare, a)
				end
			end
			j += 1
		end
		local k = 1
		for _, p in command.positional do
			if values[p.name] == nil and bare[k] then
				values[p.name] = bare[k]
				k += 1
			end
		end
	end
	return { prefix = prefix, profile = profile, id = id, values = values, args = rest }
end

local DOMAINS: { [string]: string } = {
	troubleshoot = "Troubleshoot",
	entra = "Entra",
	intune = "Intune",
	defender = "Defender",
	exchange = "Exchange",
	sharepoint = "SharePoint",
	purview = "Purview",
	teams = "Teams",
	health = "Health",
}

-- Labels the rule in `labelOf` gets wrong.
local LABELS: { [string]: string } = {
	["troubleshoot signin"] = "Troubleshoot sign-ins",
	["troubleshoot mail"] = "Troubleshoot mail",
	["defender alerts for-device"] = "Alerts",
	["exchange mailbox details"] = "Mailbox details",
	["entra users tap"] = "Temporary Access Pass",
	["entra risky-users dismiss"] = "Dismiss risk",
	["entra risky-users confirm-compromised"] = "Confirm compromised",
	["entra signin-error"] = "Explain",
	["entra users restore"] = "Restore",
	["exchange hold"] = "Litigation hold",
	["sharepoint onedrive get"] = "OneDrive",
	["sharepoint onedrive grant"] = "Grant OneDrive access",
	["sharepoint onedrive revoke"] = "Revoke OneDrive access",
	["purview ediscovery hold"] = "Place on hold",
	["purview ediscovery release"] = "Release from hold",
	["purview audit mailbox-access"] = "Mailbox access audit",
	["teams user"] = "Teams",
	["defender threat-submit email"] = "Submit as threat",
}

local VERBS: { [string]: boolean } = {
	add = true,
	remove = true,
	set = true,
	clear = true,
	enable = true,
	disable = true,
	delete = true,
	assign = true,
	unassign = true,
	update = true,
	release = true,
	grant = true,
	revoke = true,
	restore = true,
	convert = true,
	search = true,
}

local function startsWith(id: string, prefix: string): boolean
	return id == prefix or string.sub(id, 1, #prefix + 1) == prefix .. " "
end

-- The home prefix of `kind` that `id` starts with, if any.
local function homeOf(id: string, kind: string): string?
	local known = KINDS[kind]
	if known == nil then
		return nil
	end
	for _, prefix in known.home do
		if startsWith(id, prefix) then
			return prefix
		end
	end
	return nil
end

type Slot = { name: string, positional: boolean, required: boolean, kinds: { string }? }

-- A button's label: the command's words after its area, without the record's own noun (`intune
-- devices` on a device), the argument names and `get`/`list`, verb first. On a device `intune
-- devices rotate-laps` reads "Rotate LAPS"; on a user `entra users license add` reads "Add
-- license", `defender alerts for-user` "Alerts", `entra users get` "Details".
local function labelOf(c: Command, kind: string, slots: { Slot }): string
	if LABELS[c.id] then
		return LABELS[c.id]
	end
	local home = homeOf(c.id, kind)
	local words: { string } = {}
	for w in string.gmatch(if home then string.sub(c.id, #home + 2) else c.id, "%S+") do
		table.insert(words, w)
	end
	if home == nil then
		local domain = table.remove(words, 1) :: string
		if domain == "troubleshoot" then
			return "Troubleshoot"
		end
	end
	local names: { [string]: boolean } = {}
	for _, s in slots do
		names[s.name] = true
		names[s.name .. "s"] = true
		names[`for-{s.name}`] = true
	end
	local kept: { string } = {}
	for _, w in words do
		if not names[w] and w ~= "get" and w ~= "list" then
			table.insert(kept, w)
		end
	end
	if #kept == 0 then
		if words[#words] == "get" then
			return "Details"
		end
		local domain = string.match(c.id, "^%S+") :: string
		return DOMAINS[domain] or format.label(domain)
	end
	if #kept > 1 and VERBS[kept[#kept]] then
		table.insert(kept, 1, table.remove(kept) :: string)
	end
	return format.label(table.concat(kept, "-"))
end

-- Kinds a person can name by typing (an address, a group name): an argument of one of these may be
-- left for them to type. Ids they would have to look up never are.
local TYPEABLE: { [string]: boolean } = { user = true, group = true, ["entra.member"] = true, ["exchange.dl"] = true }

local function typeable(s: Slot): boolean
	for _, kind in s.kinds or ({} :: { string }) do
		if TYPEABLE[kind] then
			return true
		end
	end
	return false
end

local function slotsOf(c: Command): { Slot }
	local out: { Slot } = {}
	for _, p in c.positional do
		table.insert(out, { name = p.name, positional = true, required = p.required, kinds = argKinds(c.id, p.name) })
	end
	for _, f in c.flags do
		table.insert(out, { name = f, positional = false, required = true, kinds = argKinds(c.id, f) })
	end
	return out
end

-- The value `e` gives an argument taking `kinds`, and the kind it gave it as.
local function anyRef(kinds: { string }?, e: Entity?): (string?, string?)
	if kinds == nil or e == nil then
		return nil, nil
	end
	for _, k in kinds do
		local r = refFor(k, e)
		if r then
			return r, k
		end
	end
	return nil, nil
end

local function overlaps(a: { string }?, b: { string }?): boolean
	for _, k in a or ({} :: { string }) do
		if table.find(b or ({} :: { string }), k) then
			return true
		end
	end
	return false
end

-- The first two words: `exchange permissions`, `entra groups`.
local function noun(id: string): string
	return string.match(id, "^%S+ %S+") or id
end

-- The command line for `c` with the `bound` argument values: positionals bare while every earlier
-- one is bound, the rest as flags; and, when a required argument is missing, what to ask for it:
-- the positional's name when a bare word at the end fills it, else its flag (`--name`).
local function lineFor(inv: Invocation, c: Command, slots: { Slot }, bound: { [string]: string }): (string?, string?)
	local parts: { string } = { start(inv), c.id }
	local missing: string? = nil
	local bare = true
	for _, s in slots do
		local v = bound[s.name]
		if v then
			local q = quote(v)
			if q == nil then
				return nil, nil
			end
			if s.positional and bare and string.sub(v, 1, 1) ~= "-" then
				table.insert(parts, q)
			else
				-- `--device=-x`: a value starting with a dash would read as a flag
				table.insert(parts, if string.sub(v, 1, 1) == "-" then `--{s.name}={q}` else `--{s.name} {q}`)
				bare = bare and not s.positional
			end
		else
			if s.required and missing == nil then
				missing = if s.positional and bare then s.name else `--{s.name}`
			end
			bare = bare and not s.positional
		end
	end
	return table.concat(parts, " "), missing
end

-- Commands whose required input tenantctl only checks when they run (one of several flags): what
-- to ask for, `*` being options the person types (`--department Sales`).
local FINISH: { [string]: string } = {
	["entra users update"] = "*",
	["entra apps revoke-consent"] = "*",
	["exchange hold"] = "*",
	["exchange auto-reply set"] = "*",
	["defender incidents update"] = "*",
	["defender alerts update"] = "*",
	["intune autopilot update"] = "*",
	["intune apps unassign"] = "--group",
	["intune compliance assign"] = "--group",
	["intune compliance unassign"] = "--group",
	["intune config assign"] = "--group",
	["intune config unassign"] = "--group",
	["intune autopilot profiles assign"] = "--group",
	["intune autopilot profiles unassign"] = "--group",
	["sharepoint files unshare"] = "*",
}

-- Commands that would change nothing given the record's state: left out when `field` is `when`.
local HIDDEN: { [string]: { field: string, when: boolean } } = {
	["entra users enable"] = { field = "accountEnabled", when = true },
	["entra users disable"] = { field = "accountEnabled", when = false },
	["entra devices enable"] = { field = "accountEnabled", when = true },
	["entra devices disable"] = { field = "accountEnabled", when = false },
	["entra apps enable"] = { field = "accountEnabled", when = true },
	["entra apps disable"] = { field = "accountEnabled", when = false },
	["teams archive"] = { field = "isArchived", when = true },
	["teams unarchive"] = { field = "isArchived", when = false },
}

-- Platforms a device action works on (tenantctl refuses the others before sending anything).
local PLATFORMS: { [string]: { string } } = {
	["intune devices restart"] = { "windows", "macos", "ios", "android" },
	["intune devices lock"] = { "ios", "android", "macos" },
	["intune devices locate"] = { "windows", "ios", "android" },
	["intune devices defender-scan"] = { "windows" },
	["intune devices defender-update"] = { "windows" },
	["intune devices rotate-bitlocker"] = { "windows" },
	["intune devices rotate-laps"] = { "windows" },
	["intune devices laps"] = { "windows" },
	["intune devices collect-logs"] = { "windows" },
	["intune devices fresh-start"] = { "windows" },
	["intune devices rename"] = { "windows", "ios", "macos" },
	["intune devices wipe"] = { "windows", "ios", "android", "macos" },
	["intune devices reset-passcode"] = { "ios", "android" },
	["defender machines isolate"] = { "windows", "linux" },
	["defender machines scan"] = { "windows", "linux", "macos" },
	["defender machines restrict"] = { "windows" },
	["defender machines unrestrict"] = { "windows" },
	["defender machines stop-quarantine-file"] = { "windows" },
}

-- `windows`, `ios`, `android`, `macos`, `linux` from a device's OS field, nil when it has none.
local function platformOf(v: Value?): string?
	local os = string.lower(text(v, "os") or text(v, "operatingSystem") or text(v, "osPlatform") or "")
	for _, p in { "windows", "android", "linux" } do
		if string.find(os, p, 1, true) then
			return p
		end
	end
	if string.find(os, "mac", 1, true) then
		return "macos"
	elseif string.find(os, "ios", 1, true) or string.find(os, "ipados", 1, true) then
		return "ios"
	end
	return nil
end

-- How `c` takes `subject`: as its first argument (the others from `parent`, from the subject, or
-- left to type), or, under a parent, as a later one with the parent first: a mailbox's inbox rule,
-- a group's member. Returns the bound values, the slot the subject fills and whether the parent
-- filled one.
local function bind(
	c: Command,
	slots: { Slot },
	subject: Entity,
	parent: Entity?,
	current: string?
): ({ [string]: string }?, Slot?, boolean)
	local first = slots[1]
	if parent and anyRef(first.kinds, parent) then
		local bound: { [string]: string } = { [first.name] = anyRef(first.kinds, parent) :: string }
		local via: Slot? = nil
		for i = 2, #slots do
			local s = slots[i]
			local r = anyRef(s.kinds, subject)
			-- two records of one kind (a mailbox and a trustee) pair only under the run's own noun
			if
				r
				and via == nil
				and (not overlaps(s.kinds, first.kinds) or (current and noun(current) == noun(c.id)))
			then
				bound[s.name] = r
				via = s
			elseif s.kinds and r and not overlaps(s.kinds, first.kinds) then
				bound[s.name] = r
			end
		end
		local complete = via ~= nil
		for _, s in slots do
			complete = complete and (bound[s.name] ~= nil or not s.required)
		end
		if complete then
			return bound, via, true
		end
	end
	local r = anyRef(first.kinds, subject)
	if r == nil then
		return nil, nil, false
	end
	local bound: { [string]: string } = { [first.name] = r }
	local usedParent = false
	for i = 2, #slots do
		local s = slots[i]
		if s.kinds and not overlaps(s.kinds, first.kinds) then
			local fromParent = anyRef(s.kinds, parent)
			local v = fromParent or anyRef(s.kinds, subject)
			if v then
				bound[s.name] = v
				usedParent = usedParent or fromParent ~= nil
			end
		end
		-- an argument left to type must be one a person can name
		if bound[s.name] == nil and s.required and s.positional and not typeable(s) then
			return nil, nil, false
		end
	end
	return bound, first, usedParent
end

-- Commands whose flag makes them a second action on the record, offered right after the plain one:
-- the rarer but routine forms of a device task. `platforms` narrows a variant further than its
-- command (tenantctl only honours the wipe flags on Windows).
type Variant = { flag: string, label: string, summary: string, platforms: { string }? }
local VARIANTS: { [string]: { Variant } } = {
	["intune devices laps"] = {
		{
			flag = "--reveal",
			label = "Reveal LAPS password",
			summary = "Show the LAPS local admin password; every reveal is recorded in the Entra audit log",
		},
	},
	["intune devices bitlocker-key"] = {
		{
			flag = "--reveal",
			label = "Reveal BitLocker key",
			summary = "Show the BitLocker recovery keys; every reveal is recorded in the Entra audit log",
		},
	},
	["intune devices defender-scan"] = {
		{
			flag = "--full-scan",
			label = "Defender full scan",
			summary = "Start a Defender full scan instead of a quick one",
		},
	},
	["intune devices wipe"] = {
		{
			flag = "--keep-enrollment-data",
			label = "Wipe, keep enrollment",
			summary = "Wipe the device but keep its enrollment and provisioning data",
			platforms = { "windows" },
		},
		{
			flag = "--keep-user-data",
			label = "Wipe, keep user files",
			summary = "Wipe the device but keep the user's files",
			platforms = { "windows" },
		},
	},
	["intune devices fresh-start"] = {
		{
			flag = "--keep-user-data",
			label = "Fresh start, keep user files",
			summary = "Fresh start that keeps user files",
		},
	},
	["defender machines scan"] = {
		{ flag = "--full-scan", label = "Full scan", summary = "Run a full antivirus scan instead of a quick one" },
	},
	["defender machines isolate"] = {
		{
			flag = "--selective",
			label = "Isolate, keep Outlook and Teams",
			summary = "Selective isolation: the machine is cut off except for Outlook and Teams",
		},
	},
}

local RISK_ORDER: { [string]: number } = { read = 0, write = 1, destructive = 2 }
local DOMAIN_ORDER: { [string]: number } = {
	troubleshoot = 0,
	entra = 1,
	intune = 2,
	defender = 3,
	exchange = 4,
	sharepoint = 5,
	teams = 6,
	purview = 7,
	health = 8,
}
-- Target-only kinds shown with the record they name.
local SHOWN_AS: { [string]: string } = { ["defender.host"] = "defender.machine" }

-- The commands a record leads with, most used first; the rest wait in its menus. A kind without
-- a list leads with its first few troubleshooting and own-area actions that aren't destructive.
local FEATURED: { [string]: { string } } = {
	user = {
		"troubleshoot user",
		"entra users signins",
		"entra users revoke-sessions",
		"entra users reset-password",
		"entra users devices",
	},
	["intune.device"] = {
		"intune devices sync",
		"troubleshoot device",
		"intune devices restart",
		"intune devices rotate-laps",
		"intune devices compliance",
	},
	["entra.device"] = { "entra devices get", "entra devices disable", "entra devices enable" },
	["defender.machine"] = {
		"defender alerts for-device",
		"defender machines scan",
		"defender machines isolate",
		"defender machines release",
	},
	["autopilot.device"] = { "intune autopilot get", "intune autopilot update" },
	group = { "entra groups members", "entra groups add-member" },
	["exchange.dl"] = { "exchange dl members", "exchange dl add-member" },
	["entra.app"] = { "entra apps consents", "entra apps disable", "entra apps enable" },
	["defender.incident"] = { "defender incidents get", "defender incidents update" },
	["defender.alert"] = { "defender alerts get", "defender alerts update" },
	team = { "teams members", "teams channels", "teams members add" },
	["exchange.rule"] = { "exchange rules disable", "exchange rules delete" },
	["quarantine.message"] = { "exchange quarantine release" },
}
local MAX_FEATURED = 4

-- The actions `g` leads with: a change through the record it was listed under (remove this
-- member: what the list is for) first, then its kind's featured commands, else its first few
-- troubleshooting and own-area actions that aren't destructive.
local function featuredOf(g: Target, ids: { [Action]: string }, paired: { [Action]: boolean }): { Action }
	local out: { Action } = {}
	local taken: { [Action]: boolean } = {}
	local function take(a: Action)
		if #out < MAX_FEATURED and not taken[a] then
			taken[a] = true
			table.insert(out, a)
		end
	end
	for _, a in g.actions do
		if paired[a] then
			take(a)
		end
	end
	local list = FEATURED[g.kind]
	if list then
		for _, id in list do
			for _, a in g.actions do
				if ids[a] == id then
					take(a)
				end
			end
		end
		return out
	end
	for _, a in g.actions do
		if #out >= MAX_FEATURED - 1 then
			break
		end
		local own = a.domain == DOMAINS.troubleshoot or homeOf(ids[a], g.kind) ~= nil
		if own and a.risk ~= "destructive" then
			take(a)
		end
	end
	return out
end

-- Every action on `subject`, grouped by the record each acts on: the subject first, then the
-- records it relates to (its user, its Defender machine, …). `parent` is the record the subject
-- was listed under (a member list's group, an inbox rule list's mailbox). `current` is the run's
-- own command, left out when the subject is what the run was about (`subject.ref` set).
local function targets(inv: Invocation, subject: Entity, parent: Entity?, current: string?): { Target }
	local groups: { [string]: Target } = {}
	local order: { string } = {}
	local rank: { [Action]: number } = {}
	local ids: { [Action]: string } = {}
	local paired: { [Action]: boolean } = {}
	for index, c in catalog.commands do
		local slots = slotsOf(c)
		local bound, slot, usedParent = bind(c, slots, subject, parent, current)
		if bound == nil or slot == nil then
			continue
		end
		-- the list shows the two are already related: adding one to the other again does nothing
		if usedParent and string.find(c.id, " add%-?%a*$") then
			continue
		end
		local _, reached = anyRef(slot.kinds, subject)
		-- an action through the parent belongs to the subject, under its own name
		local kind: string = if slot ~= slots[1] then subject.kind else reached :: string
		local ref = refFor(kind, subject) or bound[slot.name]
		if c.id == current and slot == slots[1] and kind == subject.kind and subject.ref then
			continue
		end
		-- no Enable on an enabled account, no Unarchive on a live team
		local hide = HIDDEN[c.id]
		if hide and slot == slots[1] and kind == subject.kind and subject.value then
			local flag = json.get(subject.value, hide.field)
			if flag and flag.kind == "boolean" and flag.b == hide.when then
				continue
			end
		end
		local platforms = PLATFORMS[c.id]
		local platform = if platforms then platformOf(subject.value) else nil
		if platforms and platform and not table.find(platforms, platform) then
			continue
		end
		local line, ask = lineFor(inv, c, slots, bound)
		if line == nil then
			continue
		end
		-- an unshare with the permission picked is complete
		if ask == nil and not bound["permission-id"] then
			ask = FINISH[c.id]
		end
		local domain = string.match(c.id, "^%S+") :: string
		-- troubleshooting first, then the record's own area, then the rest by area; reads first
		local homeDomain = string.match((KINDS[kind] or { home = {} }).home[1] or "", "^%S+")
		local area = if domain == "troubleshoot" then 0 elseif domain == homeDomain then 1 else 2
		local base = area * 1e7 + (DOMAIN_ORDER[domain] or 9) * 1e5 + (RISK_ORDER[c.risk] or 0) * 1e4 + index
		local shown = SHOWN_AS[kind] or kind
		if groups[shown] == nil then
			groups[shown] = { kind = shown, ref = ref, own = shown == subject.kind, actions = {}, featured = {} }
			table.insert(order, shown)
		end
		local function add(action: Action, r: number)
			ids[action] = c.id
			paired[action] = slot ~= slots[1]
			rank[action] = r
			table.insert(groups[shown].actions, action)
		end
		add({
			label = labelOf(c, kind, slots) .. (if ask then "…" else ""),
			line = line :: string,
			risk = c.risk,
			ask = ask,
			summary = c.summary,
			domain = DOMAINS[domain] or domain,
		}, base)
		-- the same command with a flag that makes it another action, listed right after it
		for i, v in VARIANTS[c.id] or ({} :: { Variant }) do
			if v.platforms and platform == nil then
				platform = platformOf(subject.value)
			end
			if v.platforms and platform and not table.find(v.platforms, platform) then
				continue
			end
			add({
				label = v.label .. (if ask then "…" else ""),
				line = `{line} {v.flag}`,
				risk = c.risk,
				ask = ask,
				summary = v.summary,
				domain = DOMAINS[domain] or domain,
			}, base + i / 10)
		end
	end
	local own: { Target } = {}
	local related: { Target } = {}
	for _, key in order do
		local g = groups[key]
		table.sort(g.actions, function(a, b)
			return rank[a] < rank[b]
		end)
		if g.own then
			g.featured = featuredOf(g, ids, paired)
		end
		table.insert(if g.own then own else related, g)
	end
	table.move(related, 1, #related, #own + 1, own)
	return own
end

-- The kind of record `id`'s first argument takes, and that argument's name.
local function targetOf(id: string?): (string?, string?)
	local c = if id then byId[id] else nil
	local first = if c then c.positional[1] else nil
	if c == nil or first == nil then
		return nil, nil
	end
	local kinds = argKinds(c.id, first.name)
	return if kinds then kinds[1] else nil, first.name
end

-- On an AMBIGUOUS error: the argument whose value the message names (`"WS-PF3" matches 4
-- devices`), that value and the kind of record it takes.
local function ambiguousArg(inv: Invocation, message: string): (string?, string?, string?)
	local c = if inv.id then byId[inv.id] else nil
	if c == nil then
		return nil, nil, nil
	end
	for _, p in c.positional do
		local v = inv.values[p.name]
		if v and v ~= "" and string.find(message, v, 1, true) then
			local kinds = argKinds(c.id, p.name)
			return p.name, v, if kinds then kinds[1] else nil
		end
	end
	return nil, nil, nil
end

-- The run's command line again with one argument's value `old` replaced by `new`: the same command
-- on the record the person picked. Nil when `old` isn't one of its arguments.
local function rerunWith(inv: Invocation, old: string, new: string): string?
	local c = if inv.id then byId[inv.id] else nil
	local idWords = if c then select(2, string.gsub(c.id, "%S+", "")) :: number else 0
	local parts: { string } = { inv.prefix }
	local words = 0
	local done = false
	for _, a in inv.args do
		local flag = string.match(a, "^(%-%-[^=]+)=")
		local value = if done
			then nil
			elseif flag and string.sub(a, #flag + 2) == old then `{flag}=`
			elseif a == old and words >= idWords then ""
			else nil
		if string.sub(a, 1, 1) ~= "-" then
			words += 1
		end
		local q = quote(if value then new else a)
		if q == nil then
			return nil
		end
		table.insert(parts, if value then value .. q else q)
		done = done or value ~= nil
	end
	return if done then table.concat(parts, " ") else nil
end

-- The risk (`read`, `write`, `destructive`) of the command tenantctl `args` run, if known.
local function riskOf(args: { string }): string?
	local inv = invocation("tenantctl", args)
	local c = if inv.id then byId[inv.id] else nil
	return if c then c.risk else nil
end

-- What a tenantctl command line does, read from its arguments (after the program): its command,
-- the record it acts on (the kind and value of its first argument), the label its action has on
-- that record (a variant's when its flag is there), its risk, and whether it approves a change
-- (`--confirm <token>`).
export type Described = {
	id: string?,
	kind: string?,
	ref: string?,
	label: string,
	risk: string,
	approval: boolean,
}

local function describe(args: { string }): Described
	local inv = invocation("tenantctl", args)
	local c = if inv.id then byId[inv.id] else nil
	local approval = false
	for _, a in args do
		approval = approval or a == "--confirm" or string.sub(a, 1, 10) == "--confirm="
	end
	if c == nil then
		-- the catalog lists every command that takes a record; the rest list or report
		return { label = table.concat(args, " "), risk = "read", approval = approval }
	end
	local kind, arg = targetOf(c.id)
	local ref = if arg then inv.values[arg] else nil
	if kind == nil or ref == nil or ref == "" then
		local label = format.label(table.concat(string.split(c.id, " "), "-"))
		return { id = c.id, label = label, risk = c.risk, approval = approval }
	end
	local label = labelOf(c, kind, slotsOf(c))
	for _, v in VARIANTS[c.id] or ({} :: { Variant }) do
		if table.find(args, v.flag) then
			label = v.label
		end
	end
	return { id = c.id, kind = kind, ref = ref, label = label, risk = c.risk, approval = approval }
end

-- The command line that reads the record `ref` of `kind` whole (`intune devices get <ref>`), started
-- the way `inv` was; nil when its kind has no such command.
local function detailsLine(inv: Invocation, kind: string, ref: string): string?
	local q = quote(ref)
	if q == nil then
		return nil
	end
	for _, c in catalog.commands do
		local first = c.positional[1]
		if c.risk == "read" and string.match(c.id, " get$") and first and homeOf(c.id, kind) then
			local kinds = argKinds(c.id, first.name)
			local others = #c.flags == 0
			for i = 2, #c.positional do
				others = others and not c.positional[i].required
			end
			if kinds and table.find(kinds, kind) and others then
				return `{start(inv)} {c.id} {q}`
			end
		end
	end
	return nil
end

-- The command line `inv` ran, as typed.
local function lineOf(inv: Invocation): string?
	local parts: { string } = { inv.prefix }
	for _, a in inv.args do
		local q = quote(a)
		if q == nil then
			return nil
		end
		table.insert(parts, q)
	end
	return table.concat(parts, " ")
end

return {
	KINDS = KINDS,
	quote = quote,
	relocate = relocate,
	invocation = invocation,
	refFor = refFor,
	targetOf = targetOf,
	targets = targets,
	ambiguousArg = ambiguousArg,
	rerunWith = rerunWith,
	riskOf = riskOf,
	describe = describe,
	detailsLine = detailsLine,
	lineOf = lineOf,
}
