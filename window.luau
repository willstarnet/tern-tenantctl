--!strict
-- tern-tenantctl's window half: routes the action links the views open. It checks the link carries
-- the host's secret, asks for any input the command still needs (once for every row of a bulk
-- action), and runs it in the tenantctl block of the clicked pane's tab, opening one below the pane
-- when the tab has none.

local run = require("./lens/run")

local KIND = "tern-tenantctl.action"

type Item = { line: string, row: string?, name: string? }
type Payload = {
	nonce: string,
	line: string,
	ask: string?,
	cwd: string?,
	-- the block's workspace it was clicked in, and a bulk action's rows
	from: string?,
	batch: { label: string, items: { Item } }?,
}

local function decode(url: string): Payload?
	local b64 = string.match(url, "^tern%-tenantctl://action/([%w%-_=]+)$")
	if b64 == nil then
		return nil
	end
	local ok, payload = pcall(function()
		return tern.json.decode(tern.base64.decode(b64 :: string))
	end)
	if not ok or type(payload) ~= "table" or type(payload.line) ~= "string" then
		return nil
	end
	return payload :: Payload
end

-- Runs `payload` in the tab's tenantctl block, or a new one below `origin`.
local function deliver(cx: WindowCx, origin: number?, payload: Payload)
	local body = tern.json.encode({
		nonce = payload.nonce,
		line = payload.line,
		cwd = payload.cwd,
		from = payload.from,
		batch = payload.batch,
	})
	local tab = if origin then cx.session:tab_of(origin) else nil
	for _, p in cx.session:panes() do
		if p.block == KIND and not p.parked and (tab == nil or p.tab == tab) then
			cx.session:event(p.pane, { ev = "action", id = "main", act = "enqueue", value = body })
			return
		end
	end
	local ok = pcall(function()
		if origin then
			cx:new_block(KIND, { body }, "beside", { focus = false, target = origin, dir = "down" })
		else
			cx:new_block(KIND, { body }, "below", { focus = false })
		end
	end)
	if not ok then
		cx:toast("error", "Action not started", "The tenantctl block could not open")
	end
end

tern.route.link(function(link: LinkRequest, cx: WindowCx): RouteDecision?
	if string.sub(link.url, 1, 17) ~= "tern-tenantctl://" then
		return nil
	end
	local payload = decode(link.url)
	if payload == nil or payload.nonce ~= tern.kv.get("nonce") then
		cx:toast("error", "Action expired", "Run the command again")
		return { handled = true }
	end
	local p = payload :: Payload
	local ask = p.ask
	if ask == nil then
		deliver(cx, link.pane, p)
		return { handled = true }
	end
	cx:prompt({ placeholder = run.hint(ask, p.line), icon = "terminal", action = "run" })
		:next(function(answer: string?, _err: string?, later: WindowCx?)
			local wcx = later or cx
			if answer == nil then
				return
			end
			local line = run.complete(p.line, ask, answer)
			if line == nil then
				wcx:toast("error", "Value not usable", "Plain words only")
				return
			end
			local batch = p.batch
			if batch then
				local items: { Item } = {}
				for _, it in batch.items do
					local done = run.complete(it.line, ask, answer)
					if done then
						table.insert(items, { line = done, row = it.row, name = it.name })
					end
				end
				batch = { label = batch.label, items = items }
			end
			deliver(wcx, link.pane, { nonce = p.nonce, line = line, cwd = p.cwd, from = p.from, batch = batch })
		end)
	return { handled = true }
end)
