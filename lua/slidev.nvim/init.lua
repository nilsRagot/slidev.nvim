local M = {
	slidev_jobid = nil,
}

M.options = {}

---@class SlidevOptions
---@field slidev_cwd string|nil
---@field slidev_command string[]
---@field before_open_hook fun(slides_file_path: string)|fun()|nil
---@field after_open_hook fun(slides_file_path: string)|fun()|nil
---@field browser_app_name string|nil

---Ensure the slides file's YAML frontmatter registers `slidev_cwd` as an addon.
---Uses obsidian.nvim's YAML parser for a proper parse/serialize roundtrip.
---@param slides_file_path string
local function ensureAddonInFrontmatter(slides_file_path)
	local yaml = require("obsidian.yaml")
	local addon = M.options.slidev_cwd
	local lines = vim.fn.readfile(slides_file_path)

	-- Split the leading `---` ... `---` frontmatter block from the body.
	local fm_lines, body_start = {}, 1
	if lines[1] == "---" then
		for i = 2, #lines do
			if lines[i] == "---" then
				body_start = i + 1
				break
			end
			table.insert(fm_lines, lines[i])
		end
	end

	local data, key_order = {}, {}
	if #fm_lines > 0 then
		local parsed, order = yaml.loads(table.concat(fm_lines, "\n"))
		if type(parsed) == "table" then
			data = parsed
			key_order = order or {}
		end
	end

	data.addons = data.addons or {}
	for _, v in ipairs(data.addons) do
		if v == addon then
			return -- already registered, leave the file untouched
		end
	end
	table.insert(data.addons, addon)
	if not vim.tbl_contains(key_order, "addons") then
		table.insert(key_order, "addons")
	end

	-- Build a comparator from the recorded order so existing keys keep their
	-- position; any keys not seen during parsing sort to the end.
	local rank = {}
	for i, k in ipairs(key_order) do
		rank[k] = i
	end
	local order_fn = function(a, b)
		return (rank[a] or math.huge) < (rank[b] or math.huge)
	end

	local new_lines = { "---" }
	for _, l in ipairs(yaml.dumps_lines(data, order_fn)) do
		table.insert(new_lines, l)
	end
	table.insert(new_lines, "---")
	for i = body_start, #lines do
		table.insert(new_lines, lines[i])
	end
	vim.fn.writefile(new_lines, slides_file_path)
end

---@type SlidevOptions
local defaultOptions = {
	slidev_cwd = nil,
	slidev_command = { "npm", "run", "dev" },
	browser_app_name = "Arc",
	before_open_hook = nil,
	after_open_hook = function(url)
		if not M.options.browser_app_name then
			return
		end
		local command = string.format("open -a %s %s", M.options.browser_app_name, url)
		os.execute(command)
	end,
	after_close_hook = nil,
}

local function isSlidevRunning()
	if M.slidev_id then
		local status = vim.fn.jobwait({ M.slidev_id }, 0)[1]
		return status == -1 -- -1 means the job is still running
	end
	return false
end

---@param slides_file_path string
local function openSlidev(slides_file_path)
	if isSlidevRunning() then
		print("Slidev is already running, Job id : " .. M.slidev_id)
		return
	end
	local command = M.options.slidev_command
	table.insert(command, "--")
	table.insert(command, slides_file_path)
	M.slidev_id = vim.fn.jobstart(command, {
		cwd = M.options.slidev_cwd,
	})
	print("Slidev started with Job id: " .. M.slidev_id)
end

local function closeSlidev()
	if isSlidevRunning() then
		vim.fn.jobstop(M.slidev_id)
		print("Slidev stopped, Job id: " .. M.slidev_id)
		M.slidev_id = nil
	else
		print("Slidev is not running.")
	end
end

local function browseSlidev()
	require("telescope.builtin").find_files({
		prompt_title = "Browse Slidev",
		cwd = M.options.slidev_cwd,
	})
end

M = {
	openSlidev = openSlidev,
	closeSlidev = closeSlidev,
	isSlidevRunning = isSlidevRunning,
	browseSlidev = browseSlidev,
	ensureAddonInFrontmatter = ensureAddonInFrontmatter,
}

---@param optionOverrides SlidevOptions?
M.setup = function(optionOverrides)
	optionOverrides = optionOverrides or {}
	M.options = vim.tbl_deep_extend("force", defaultOptions, optionOverrides)
	if not M.options.slidev_cwd then
		error("slidev_cwd must be set in the options")
	end
	vim.api.nvim_create_user_command("SlidevOpen", function(options)
		local slides_file_path = options.args == "" and vim.api.nvim_buf_get_name(0) or options.args
		if M.options.before_open_hook then
			M.options.before_open_hook(slides_file_path)
		end
		ensureAddonInFrontmatter(slides_file_path)
		openSlidev(slides_file_path)
		if M.options.after_open_hook then
			M.options.after_open_hook(slides_file_path)
		end
	end, {})
	vim.api.nvim_create_user_command("SlidevClose", function()
		closeSlidev()
		if M.options.after_close_hook then
			M.options.after_close_hook()
		end
	end, {})
	vim.api.nvim_create_user_command("SlidevBrowse", function()
		browseSlidev()
	end, {})
end

return M
