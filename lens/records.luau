--!strict
-- What kind of record each part of a view is: the rows of `intune devices list` are Intune devices,
-- `troubleshoot user`'s `devices` are too, its `mfa.methods` are authentication methods. Known
-- commands say so per path; anything else is recognised by its fields.

local json = require("./json")
type Value = json.Value

-- Per command: `subject`, where in `data` the record the run is about sits ("" is `data` itself),
-- and the kind of the rows (or object) at each path below `data` ("" for a list's rows). Paths skip
-- row numbers: `members` is the members list inside any selected row. "member" and "intune.item"
-- pick the kind from each row's `type` or `kind`; "none" means no actions.
local CONTEXT: { [string]: { [string]: string } } = {
	["troubleshoot user"] = {
		subject = "user",
		devices = "intune.device",
		["mfa.methods"] = "auth.method",
		["mailbox.inboxRules"] = "exchange.rule",
		["signins.failureGroups"] = "signin.error",
		["signins.latest"] = "signin",
	},
	["troubleshoot signin"] = {
		subject = "user",
		failureGroups = "signin.error",
		latest = "signin",
		["mfa.methods"] = "auth.method",
	},
	["troubleshoot device"] = {
		subject = "device",
		compliance = "intune.compliance",
		configuration = "intune.config",
		entra = "entra.device",
		["signins.failureGroups"] = "signin.error",
		["configuration.users"] = "user",
	},
	["troubleshoot mail"] = { messages = "trace.message" },
	["troubleshoot tenant"] = {
		licenses = "license",
		appCredentials = "entra.appcredential",
		["incidents.incidents"] = "defender.incident",
	},
	["entra users list"] = { [""] = "user" },
	["entra users get"] = { subject = "", manager = "user" },
	["entra users groups"] = {
		subject = "user",
		groups = "group",
		directoryRoles = "none",
		administrativeUnits = "none",
	},
	["entra users licenses"] = { subject = "user", assignments = "license" },
	["entra users auth-methods"] = { subject = "user", methods = "auth.method" },
	["entra users devices"] = { [""] = "entra.device" },
	["entra users signins"] = { [""] = "signin" },
	["entra users deleted"] = { [""] = "entra.deleteduser" },
	["entra groups list"] = { [""] = "group" },
	["entra groups get"] = { subject = "", owners = "user", licenses = "none" },
	["entra groups members"] = { [""] = "member" },
	["entra licenses"] = { [""] = "license" },
	["entra signins"] = { [""] = "signin" },
	["entra signin-error"] = { subject = "", [""] = "signin.error" },
	["entra audit"] = { [""] = "none" },
	["entra roles list"] = { [""] = "none", members = "member" },
	["entra roles user"] = { subject = "user", active = "none", eligible = "none" },
	["entra apps list"] = { [""] = "entra.app" },
	["entra apps get"] = { subject = "" },
	["entra apps expiring"] = { [""] = "entra.appcredential" },
	["entra apps consents"] = { subject = "app", delegated = "none", application = "none" },
	["entra ca list"] = { [""] = "entra.ca" },
	["entra ca get"] = { subject = "" },
	["entra ca locations"] = { [""] = "none", usedBy = "entra.ca" },
	["entra risky-users"] = { [""] = "user" },
	["entra risk-detections"] = { [""] = "signin" },
	["entra devices list"] = { [""] = "entra.device" },
	["entra devices get"] = { subject = "", owners = "user", users = "user" },
	["entra access-reviews list"] = { [""] = "access.review" },
	["entra access-reviews decisions"] = { subject = "review", decisions = "none" },
	["entra partners"] = { [""] = "none" },
	["entra subscriptions"] = { [""] = "none" },
	["intune devices list"] = { [""] = "intune.device" },
	["intune devices get"] = { subject = "", primaryUsers = "user" },
	["intune devices compliance"] = { subject = "device", policies = "intune.compliance" },
	["intune devices config-states"] = { subject = "device", problems = "intune.config", profiles = "intune.config" },
	["intune devices apps"] = { [""] = "none" },
	["intune devices bitlocker-key"] = { subject = "device", keys = "none" },
	["intune devices laps"] = { subject = "device", credentials = "none" },
	["intune devices actions"] = { subject = "device", actions = "none" },
	["intune devices sync-status"] = { subject = "device", stages = "none" },
	["intune compliance list"] = { [""] = "intune.compliance" },
	["intune compliance status"] = { [""] = "intune.device" },
	["intune compliance settings"] = { subject = "policy", settings = "none" },
	["intune config list"] = { [""] = "intune.config" },
	["intune config status"] = { [""] = "intune.device" },
	["intune config get"] = { subject = "", assignments = "none" },
	["intune apps list"] = { [""] = "intune.app" },
	["intune apps status"] = { subject = "app", ["devices.items"] = "intune.device" },
	["intune apps assignments"] = { subject = "app", assignments = "none" },
	["intune assignments"] = {
		subject = "group",
		included = "intune.item",
		excluded = "intune.item",
		allUsers = "intune.item",
		allDevices = "intune.item",
	},
	["intune filters list"] = { [""] = "intune.filter" },
	["intune filters get"] = { subject = "filter", usedBy = "intune.item" },
	["intune report noncompliant"] = { devices = "intune.device", byReason = "none" },
	["intune autopilot list"] = { [""] = "autopilot.device" },
	["intune autopilot get"] = {
		subject = "device",
		deploymentProfile = "autopilot.profile",
		intendedDeploymentProfile = "autopilot.profile",
		intuneDevice = "intune.device",
		otherIntuneRecords = "intune.device",
	},
	["intune autopilot imports"] = { [""] = "none" },
	["intune autopilot events"] = { [""] = "autopilot.event" },
	["intune autopilot profiles list"] = { [""] = "autopilot.profile" },
	["intune autopilot profiles get"] = { subject = "" },
	["intune enrollment list"] = { [""] = "intune.enrollment" },
	["intune enrollment get"] = { subject = "" },
	["intune scripts list"] = { [""] = "intune.script" },
	["intune scripts status"] = { subject = "script", devices = "intune.device" },
	["intune updates list"] = { [""] = "intune.update" },
	["intune updates get"] = { subject = "policy" },
	["intune cleanup-rules list"] = { [""] = "none" },
	["defender machines list"] = { [""] = "defender.machine" },
	["defender machines get"] = { subject = "", recentActions = "defender.action" },
	["defender machines actions"] = { [""] = "defender.action" },
	["defender incidents list"] = { [""] = "defender.incident" },
	["defender incidents get"] = { subject = "", alerts = "defender.alert", comments = "none" },
	["defender alerts list"] = { [""] = "defender.alert" },
	["defender alerts get"] = { subject = "", comments = "none" },
	["defender alerts for-user"] = { subject = "user", alerts = "defender.alert" },
	["defender alerts for-device"] = { alerts = "defender.alert" },
	["defender hunt templates"] = { [""] = "none" },
	["exchange mailbox"] = { subject = "" },
	["exchange auto-reply get"] = { subject = "" },
	["exchange messages search"] = { [""] = "mail.message" },
	["exchange calendar permissions"] = { [""] = "none" },
	["exchange calendar events"] = { [""] = "none" },
	["exchange rules list"] = { [""] = "exchange.rule" },
	["exchange rules audit"] = { mailboxes = "user", ["mailboxes.rules"] = "exchange.rule", errors = "none" },
	["exchange forwarding"] = { subject = "", inboxRules = "exchange.rule" },
	["exchange permissions list"] = { [""] = "user" },
	["exchange mailbox details"] = { subject = "" },
	["exchange dl list"] = { [""] = "exchange.dl" },
	["exchange dl members"] = { [""] = "user" },
	["exchange quarantine list"] = { [""] = "quarantine.message" },
	["exchange transport-rules"] = { [""] = "none" },
	["exchange rooms list"] = { [""] = "user" },
	["exchange rooms free"] = { free = "user" },
	["exchange trace"] = { [""] = "trace.message" },
	["exchange trace details"] = { subject = "", events = "none" },
	["exchange usage"] = { [""] = "user" },
	["sharepoint sites list"] = { [""] = "sharepoint.site" },
	["sharepoint sites get"] = { subject = "", group = "group", ["group.owners"] = "user" },
	["sharepoint sites drives"] = { [""] = "sharepoint.drive" },
	["sharepoint sites permissions"] = { subject = "", group = "group", appPermissions = "none" },
	["sharepoint files search"] = { [""] = "sharepoint.file" },
	["sharepoint files get"] = { subject = "" },
	["sharepoint files permissions"] = { subject = "item", permissions = "permission", anonymousLinks = "permission" },
	["sharepoint files versions"] = { [""] = "version" },
	["sharepoint onedrive get"] = { subject = "" },
	["sharepoint onedrive usage"] = { [""] = "user" },
	["sharepoint sites usage"] = { [""] = "sharepoint.site" },
	["purview ediscovery list"] = { [""] = "ediscovery.case" },
	["purview ediscovery custodians"] = { [""] = "user" },
	["purview audit queries"] = { [""] = "audit.query" },
	["teams list"] = { [""] = "team" },
	["teams get"] = { subject = "" },
	["teams members"] = { [""] = "user" },
	["teams channels"] = { [""] = "channel" },
	["teams channels members"] = { [""] = "user" },
	["teams user"] = { subject = "", teams = "team" },
	["teams presence"] = { [""] = "user" },
	["teams calls list"] = { [""] = "teams.call" },
	["teams calls get"] = { subject = "", failures = "none", quality = "none" },
	["teams calls pstn"] = { [""] = "none" },
	["teams activity"] = { [""] = "user" },
	["health issues"] = { [""] = "health.issue" },
	["health issue"] = { subject = "", posts = "none" },
	["health messages"] = { [""] = "health.message" },
	["health message"] = { subject = "" },
	["health overview"] = { degraded = "none", recentlyRestored = "none", services = "none" },
}

local function text(v: Value, key: string): string?
	return json.text(json.get(v, key))
end

local function has(v: Value, key: string): boolean
	local f = json.get(v, key)
	return f ~= nil and f.kind ~= "null"
end

local MEMBER: { [string]: string } = {
	user = "user",
	group = "group",
	device = "entra.device",
	servicePrincipal = "entra.app",
}

local ITEM: { [string]: string } = {
	app = "intune.app",
	compliance = "intune.compliance",
	config = "intune.config",
	profile = "intune.config",
	settingsCatalog = "intune.config",
	endpointSecurity = "intune.config",
}

-- A record recognised by its fields, for commands and paths the table doesn't name.
local function byFields(v: Value): string?
	if has(v, "deletedDateTime") and has(v, "userPrincipalName") then
		return "entra.deleteduser"
	elseif has(v, "computerDnsName") then
		return "defender.machine"
	elseif
		has(v, "deviceName") and (has(v, "complianceState") or has(v, "managementState") or has(v, "azureADDeviceId"))
	then
		return "intune.device"
	elseif has(v, "serialNumber") and (has(v, "enrollmentState") or has(v, "profileStatus")) then
		return "autopilot.device"
	elseif has(v, "deviceId") and (has(v, "join") or has(v, "joinType")) then
		return "entra.device"
	elseif has(v, "userPrincipalName") then
		return "user"
	elseif has(v, "alertId") then
		return "defender.alert"
	end
	return nil
end

-- `data`, `data.devices`, `data#3.members` → ``, `devices`, `members`.
local function relative(path: string): string
	local rel = string.gsub(string.gsub(path, "^data", ""), "#%d+", "")
	return (string.gsub(rel, "^%.", ""))
end

-- The kind of the object or row `v` at `path` in the output of `command`, nil when it isn't a
-- record anything acts on. `strict` takes only what the table says, never a guess from fields.
local function kindAt(command: string?, path: string, v: Value, strict: boolean?): string?
	if v.kind ~= "object" then
		return nil
	end
	local known = if command then CONTEXT[command] else nil
	local kind = if known then known[relative(path)] else nil
	if kind == "member" then
		return MEMBER[text(v, "type") or ""]
	elseif kind == "intune.item" then
		return ITEM[text(v, "kind") or ""]
	elseif kind == "none" then
		return nil
	elseif kind then
		return kind
	end
	return if strict then nil else byFields(v)
end

-- Where the record the run is about sits in `data`: "" for `data`, a key, or nil.
local function subjectPath(command: string?): string?
	local known = if command then CONTEXT[command] else nil
	return if known then known.subject else nil
end

-- The kind of a directory object row by its `type` (`user`, `group`, `device`, …), if any.
local function memberKind(v: Value): string?
	return MEMBER[text(v, "type") or ""]
end

return {
	kindAt = kindAt,
	subjectPath = subjectPath,
	relative = relative,
	memberKind = memberKind,
}
