--!strict
-- Loads tests/fixtures/<name>.<ext> as the lines a lens receives: split on newlines, the final
-- empty line dropped (a terminal never feeds one).

local fs = require("@lune/fs")

local function lines(name: string): { string }
	local text = fs.readFile(`tests/fixtures/{name}`)
	local out: { string } = {}
	for line in string.gmatch(text, "([^\n]*)\n") do
		table.insert(out, line)
	end
	return out
end

return { lines = lines }
