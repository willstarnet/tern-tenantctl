--!strict
-- Field labels, status tones, dates and scalar text: the decisions that make a value readable,
-- kept apart from the node building so they are tested on their own.

local json = require("./json")
type Value = json.Value

local ACRONYMS: { [string]: string } = {
	ad = "AD",
	aad = "AAD",
	api = "API",
	bitlocker = "BitLocker",
	ca = "CA",
	cpu = "CPU",
	dns = "DNS",
	id = "ID",
	ids = "IDs",
	imei = "IMEI",
	ip = "IP",
	laps = "LAPS",
	mdm = "MDM",
	mfa = "MFA",
	onedrive = "OneDrive",
	os = "OS",
	sharepoint = "SharePoint",
	signin = "sign-in",
	signins = "sign-ins",
	sku = "SKU",
	smtp = "SMTP",
	sso = "SSO",
	tpm = "TPM",
	upn = "UPN",
	url = "URL",
	vpn = "VPN",
}

-- `lastSyncDateTime` → `Last sync`, `userPrincipalName` → `User principal name`, `osVersion` →
-- `OS version`, `device.os` → `Device OS`. Same rules as tenantctl's approval prompts.
local function label(key: string): string
	local base = string.gsub(key, "DateTime$", "")
	if base == "" then
		base = key
	end
	base = string.gsub(base, "([%l%d])(%u)", "%1 %2")
	base = string.gsub(base, "(%u+)(%u%l)", "%1 %2")
	local words: { string } = {}
	for word in string.gmatch(base, "[^%s_%.%-]+") do
		local lower = string.lower(word)
		table.insert(words, ACRONYMS[lower] or lower)
	end
	if #words == 0 then
		return key
	end
	local first = words[1]
	words[1] = string.upper(string.sub(first, 1, 1)) .. string.sub(first, 2)
	return table.concat(words, " ")
end

-- Keys whose values are a status word worth a color.
local STATUS_KEY_PARTS = {
	"status",
	"state",
	"severity",
	"result",
	"risk",
	"level",
	"compliance",
	"health",
	"outcome",
	"classification",
	"determination",
}

local TONES: { [string]: string } = {}
local function tone(t: string, words: { string })
	for _, w in words do
		TONES[w] = t
	end
end
tone("error", {
	"high",
	"critical",
	"severe",
	"failure",
	"failed",
	"error",
	"noncompliant",
	"denied",
	"blocked",
	"serviceinterruption",
	"interrupted",
	"compromised",
	"confirmedcompromised",
	"atrisk",
	"expired",
	"unhealthy",
	"down",
	"truepositive",
})
tone("warning", {
	"medium",
	"moderate",
	"warning",
	"degraded",
	"servicedegradation",
	"ingraceperiod",
	"conflict",
	"investigating",
	"restoringservice",
	"extendedrecovery",
	"verifyingservice",
	"partial",
	"partiallysucceeded",
	"expiring",
	"stale",
})
tone("success", {
	"success",
	"succeeded",
	"compliant",
	"healthy",
	"serviceoperational",
	"operational",
	"resolved",
	"ok",
	"passed",
	"completed",
	"complete",
	"servicerestored",
	"remediated",
	"dismissed",
	"falsepositive",
	"benignpositive",
})
tone("info", {
	"low",
	"info",
	"informational",
	"inprogress",
	"running",
	"enabledforreportingbutnotenforced",
})
tone("pending", { "pending", "notstarted", "queued", "waiting", "new" })
tone(
	"muted",
	{ "unknown", "notapplicable", "none", "n/a", "skipped", "unknownfuturevalue", "notevaluated", "inactive" }
)

local function isStatusKey(key: string): boolean
	local lower = string.lower(key)
	for _, part in STATUS_KEY_PARTS do
		if string.find(lower, part, 1, true) then
			return true
		end
	end
	return false
end

-- The tone of a status word under `key` (`severity: "high"` → `error`), or nil when the key isn't
-- a status or the word is not one Tern should color.
local function statusTone(key: string, text: string): string?
	if not isStatusKey(key) then
		return nil
	end
	local word = string.lower((string.gsub(text, "[%s_]", "")))
	return TONES[word]
end

local GUID = "^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$"

local function isGuid(s: string): boolean
	return string.match(s, GUID) ~= nil
end

-- Days from 1970-01-01 to the civil date (Howard Hinnant's algorithm).
local function daysFromCivil(y: number, m: number, d: number): number
	y = if m <= 2 then y - 1 else y
	local era = (if y >= 0 then y else y - 399) // 400
	local yoe = y - era * 400
	local mp = (m + 9) % 12
	local doy = (153 * mp + 2) // 5 + d - 1
	local doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
	return era * 146097 + doe - 719468
end

local function civilFromDays(z: number): (number, number, number)
	z += 719468
	local era = (if z >= 0 then z else z - 146096) // 146097
	local doe = z - era * 146097
	local yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
	local y = yoe + era * 400
	local doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
	local mp = (5 * doy + 2) // 153
	local d = doy - (153 * mp + 2) // 5 + 1
	local m = if mp < 10 then mp + 3 else mp - 9
	return (if m <= 2 then y + 1 else y), m, d
end

-- Seconds since the epoch of an ISO 8601 date-time with a zone (`2026-11-20T14:35:13.5Z`,
-- `…+02:00`), or nil for anything else. A bare date reads as midnight UTC.
local function parseDate(s: string): number?
	local y, mo, d, rest = string.match(s, "^(%d%d%d%d)%-(%d%d)%-(%d%d)(.*)$")
	if y == nil or rest == nil then
		return nil
	end
	local base = daysFromCivil(tonumber(y) :: number, tonumber(mo) :: number, tonumber(d) :: number) * 86400
	if rest == "" then
		return base
	end
	local h, mi, tail = string.match(rest, "^T(%d%d):(%d%d)(.*)$")
	if h == nil or tail == nil then
		return nil
	end
	local sec = 0
	local secText, after = string.match(tail, "^:(%d%d)(.*)$")
	if secText and after then
		sec = tonumber(secText) :: number
		tail = string.gsub(after, "^%.%d+", "")
	end
	local offset = 0
	if tail == "Z" then
		offset = 0
	else
		local sign, oh, om = string.match(tail, "^([%+%-])(%d%d):?(%d%d)$")
		if sign == nil then
			return nil
		end
		offset = ((tonumber(oh) :: number) * 60 + (tonumber(om) :: number)) * 60
		if sign == "-" then
			offset = -offset
		end
	end
	return base + (tonumber(h) :: number) * 3600 + (tonumber(mi) :: number) * 60 + sec - offset
end

-- `2026-11-20 14:35 UTC`.
local function showDate(t: number): string
	local days = t // 86400
	local secs = t - days * 86400
	local y, m, d = civilFromDays(days)
	return string.format("%04d-%02d-%02d %02d:%02d UTC", y, m, d, secs // 3600, (secs % 3600) // 60)
end

-- `just now`, `5m ago`, `3h ago`, `12d ago`, `4mo ago`, `2y ago`, or `in 3d` for the future.
local function age(t: number, now: number): string
	local diff = now - t
	local future = diff < 0
	local s = math.abs(diff)
	local text
	if s < 60 then
		return if future then "in under a minute" else "just now"
	elseif s < 3600 then
		text = `{s // 60}m`
	elseif s < 86400 then
		text = `{s // 3600}h`
	elseif s < 86400 * 90 then
		text = `{s // 86400}d`
	elseif s < 86400 * 730 then
		text = `{s // (86400 * 30)}mo`
	else
		text = `{s // (86400 * 365)}y`
	end
	return if future then `in {text}` else `{text} ago`
end

-- One line of text for a scalar (nil for objects and arrays); dates read `2026-11-20 14:35 UTC`.
local function scalar(v: Value): string?
	if v.kind == "string" then
		local t = parseDate(v.s :: string)
		if t then
			return showDate(t)
		end
		return (string.gsub(v.s :: string, "%s+", " "))
	elseif v.kind == "number" then
		return v.s
	elseif v.kind == "boolean" then
		return if v.b then "yes" else "no"
	elseif v.kind == "null" then
		return ""
	end
	return nil
end

local function isEmpty(v: Value): boolean
	if v.kind == "null" then
		return true
	elseif v.kind == "string" then
		return v.s == ""
	elseif v.kind == "array" then
		return #(v.items :: { Value }) == 0
	elseif v.kind == "object" then
		return #(v.keys :: { string }) == 0
	end
	return false
end

-- Keys a person never needs: Graph's OData annotations.
local function hidden(key: string): boolean
	return string.sub(key, 1, 1) == "@"
end

-- A short, single-line summary of any value, for table cells and inline lists:
-- `Bob Smith · bob@contoso.com · managed no`, `a, b, c`, `3 items`. Strings and numbers speak for
-- themselves; a yes/no needs its label.
local function summary(v: Value, limit: number?): string
	local max = limit or 80
	local out: string
	if v.kind == "object" then
		local parts: { string } = {}
		local ids: { string } = {}
		for _, k in v.keys :: { string } do
			local item = (v.map :: { [string]: Value })[k]
			local text = scalar(item)
			if text and text ~= "" and not hidden(k) then
				if item.kind == "boolean" then
					text = `{string.lower(label(k))} {text}`
				end
				table.insert(if string.match(text, GUID) then ids else parts, text)
			elseif text == nil and not isEmpty(item) then
				table.insert(parts, `{string.lower(label(k))} …`)
			end
		end
		out = table.concat(if #parts > 0 then parts else ids, " · ")
	elseif v.kind == "array" then
		local items = v.items :: { Value }
		local parts: { string } = {}
		for _, item in items do
			local text = scalar(item)
			if text == nil then
				local n = #items
				return `{n} item{if n == 1 then "" else "s"}`
			end
			table.insert(parts, text)
		end
		out = table.concat(parts, ", ")
	else
		out = scalar(v) or ""
	end
	if utf8.len(out) and (utf8.len(out) :: number) > max then
		local cut = utf8.offset(out, max) or (max + 1)
		out = string.sub(out, 1, cut - 1) .. "…"
	end
	return out
end

-- The tone of a finding or alert severity word, defaulting to muted.
local function severityTone(word: string): string
	return statusTone("severity", word) or "muted"
end

return {
	label = label,
	statusTone = statusTone,
	severityTone = severityTone,
	isStatusKey = isStatusKey,
	isGuid = isGuid,
	parseDate = parseDate,
	showDate = showDate,
	age = age,
	scalar = scalar,
	isEmpty = isEmpty,
	hidden = hidden,
	summary = summary,
}
