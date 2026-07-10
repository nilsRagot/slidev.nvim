local M = {
	slidev_id = nil, -- State variable to track the Slidev job ID
	slide_path = nil, -- Absolute path of the slides file currently being presented
	slide_symlink = nil, -- Path Slidev is launched on (slides symlink inside slidev_cwd)
	symlinks = {}, -- Absolute paths of every symlink created inside slidev_cwd (for cleanup)
}

---@class SlidevOptions
---@field slidev_cwd string|nil
---@field slidev_port integer
---@field slidev_command string[]
---@field before_open_hook fun(slides_file_path: string)|fun()|nil
---@field after_open_hook fun(slides_file_path: string)|fun()|nil
---@field before_close_hook fun()|nil
---@field after_close_hook fun()|nil

local uv = vim.uv or vim.loop

-- Autocommands that auto-close Slidev live in this group so we can attach on
-- open and wipe them on close without leaking handlers between runs.
local autocloseGroup = vim.api.nvim_create_augroup("SlidevAutoClose", { clear = true })

---Create a symlink to `path` inside slidev_cwd (named after the file's basename)
---so Slidev can serve it from within the addon project, and record it in
---M.symlinks so close() can clean it up. No-ops when the file already lives in
---slidev_cwd; stale symlinks left over from a previous run are replaced.
---@param path string Absolute or relative path of the file to expose to Slidev
function M.createSymlinkToSlidevCwd(path)
	local target = vim.fn.fnamemodify(path, ":p")
	local name = vim.fn.fnamemodify(target, ":t")
	local link = vim.fs.joinpath(M.options.slidev_cwd, name)

	-- If the file already lives in slidev_cwd, Slidev can serve it directly.
	if vim.fn.fnamemodify(link, ":p") == target then
		return
	end

	local stat = uv.fs_lstat(link)
	if stat then
		if stat.type == "link" then
			uv.fs_unlink(link) -- stale symlink left over from a previous run
		else
			error("Cannot create Slidev symlink: a file already exists at " .. link)
		end
	end

	local ok, err = uv.fs_symlink(target, link)
	if not ok then
		error("Failed to create Slidev symlink: " .. tostring(err))
	end

	if not vim.tbl_contains(M.symlinks, link) then
		table.insert(M.symlinks, link)
	end
end

---Remove every symlink recorded in M.symlinks and reset the tracking table.
local function removeSymlinks()
	for _, link in ipairs(M.symlinks) do
		local stat = uv.fs_lstat(link)
		if stat and stat.type == "link" then
			uv.fs_unlink(link)
		end
	end
	M.symlinks = {}
end

---Collect the destination of every markdown image (`![alt](dest)`) in a slides
---file using Treesitter, walking the injected markdown_inline trees.
---@param slide_path string
---@return string[] destinations Raw destination strings as written in the file
local function queryImageDestinations(slide_path)
	local destinations = {}

	local content = table.concat(vim.fn.readfile(slide_path), "\n")

	local ok, parser = pcall(vim.treesitter.get_string_parser, content, "markdown")
	if not ok or not parser then
		vim.notify("Slidev: markdown Treesitter parser is not available", vim.log.levels.WARN)
		return destinations
	end

	local query = vim.treesitter.query.parse("markdown_inline", "(image (link_destination) @dest)")

	parser:parse(true)

	-- Images live in the injected markdown_inline trees, so recurse into children.
	local function collect(ltree)
		if ltree:lang() == "markdown_inline" then
			for _, tree in pairs(ltree:trees()) do
				for _, node in query:iter_captures(tree:root(), content) do
					table.insert(destinations, vim.treesitter.get_node_text(node, content))
				end
			end
		end
		for _, child in pairs(ltree:children()) do
			collect(child)
		end
	end
	collect(parser)

	return destinations
end

---Symlink every local image referenced by a slides file into slidev_cwd. Remote
---assets (http://, data:, ...) and missing files are skipped; relative paths
---resolve against the slides file's directory.
---@param slide_path string
function M.createImagesSymlinks(slide_path)
	local slide_dir = vim.fn.fnamemodify(slide_path, ":h")
	for _, dest in ipairs(queryImageDestinations(slide_path)) do
		if not dest:match("^%a[%w+.-]*://") and not vim.startswith(dest, "data:") then
			local abs = vim.startswith(dest, "/") and dest or vim.fs.joinpath(slide_dir, dest)
			abs = vim.fn.fnamemodify(abs, ":p")
			if uv.fs_stat(abs) then
				M.createSymlinkToSlidevCwd(abs)
			end
		end
	end
end

---Symlink the currently-tracked slides file into slidev_cwd and record the path
---Slidev should be launched on.
function M.createSlideSymlink()
	if not M.slide_path then
		return
	end
	M.createSymlinkToSlidevCwd(M.slide_path)
	local name = vim.fn.fnamemodify(M.slide_path, ":t")
	M.slide_symlink = vim.fs.joinpath(M.options.slidev_cwd, name)
end

---Sync everything the slides file depends on into slidev_cwd: the slides file
---itself and every local image it references.
function M.sync()
	if not M.slide_path then
		print("Slidev: no slides file is open. Run :SlidevOpen first.")
		return
	end
	M.createImagesSymlinks(M.slide_path)
	M.createSlideSymlink()
end

---Attach autocommands that close Slidev when the slides buffer is deleted or
---when Neovim quits. Clears any previously attached handlers first.
---@param bufnr integer
local function attachAutoClose(bufnr)
	vim.api.nvim_clear_autocmds({ group = autocloseGroup })
	vim.api.nvim_create_autocmd("BufDelete", {
		group = autocloseGroup,
		buffer = bufnr,
		callback = function()
			M.close()
		end,
	})
	vim.api.nvim_create_autocmd("VimLeavePre", {
		group = autocloseGroup,
		callback = function()
			M.close()
		end,
	})
end

local function clearAutoClose()
	vim.api.nvim_clear_autocmds({ group = autocloseGroup })
end

---@return "Windows"|"Darwin"|"Linux"|"unknown"
local function detectOs()
	local os_name = "unknown"
	local separator = package.config:sub(1, 1)
	if separator == "\\" then
		-- If the path separator is '\', we are on Windows
		os_name = "Windows"
	else
		-- For Unix-like systems (macOS, Linux), we query the system
		local f = io.popen("uname -s")
		if f then
			-- Read the response and remove the newline character
			os_name = f:read("*a"):gsub("\n", "")
			f:close()
		end
	end

	return os_name
end

function M.isSlidevRunning()
	if M.slidev_id then
		local status = vim.fn.jobwait({ M.slidev_id }, 0)[1]
		return status == -1 -- -1 means the job is still running
	end
	return false
end

---@param slides_file_path string
function M.openSlidevServer(slides_file_path)
	if M.isSlidevRunning() then
		print("Slidev is already running, Job id : " .. M.slidev_id)
		return
	end
	-- Copy the configured command so we never mutate the shared options table.
	local command = vim.deepcopy(M.options.slidev_command)
	table.insert(command, slides_file_path)
	for _, arg in ipairs({ "--port", tostring(M.options.slidev_port) }) do
		table.insert(command, arg)
	end
	M.slidev_id = vim.fn.jobstart(command, {
		cwd = M.options.slidev_cwd,
	})
	print("Slidev started with Job id: " .. M.slidev_id)
end

function M.closeSlidevServer()
	if M.isSlidevRunning() then
		vim.fn.jobstop(M.slidev_id)
		print("Slidev stopped, Job id: " .. M.slidev_id)
		M.slidev_id = nil
	else
		print("Slidev is not running.")
	end
end

function M.browseSlidev()
	if not require("telescope.builtin") then
		print("Telescope is not available.")
		return
	end
	require("telescope.builtin").find_files({
		prompt_title = "Browse Slidev",
		cwd = M.options.slidev_cwd,
	})
end

function M.openSlidevPreviewInNewBrowserWindow()
	local os_name = detectOs()

	local command = ""
	local url = string.format("http://localhost:%d", M.options.slidev_port)
	if os_name == "Windows" then
		-- The empty quotes after 'start' prevent bugs with certain URLs on Windows
		command = string.format('start "" "%s"', url)
	elseif os_name == "Darwin" then
		command = string.format('open "%s"', url)
	elseif os_name == "Linux" then
		command = string.format('xdg-open "%s"', url)
	else
		print("Unsupported or unknown operating system.")
		return false
	end
	-- 3. Execute the command
	return os.execute(command)
end

---Full open flow: track the slides file, sync it and its images into slidev_cwd,
---launch Slidev on the synced slides file, and arm the auto-close autocommands.
---@param slides_file_path string
function M.open(slides_file_path)
	if M.options.before_open_hook then
		M.options.before_open_hook(slides_file_path)
	end
	M.slide_path = vim.fn.fnamemodify(slides_file_path, ":p")
	M.sync()
	M.openSlidevServer(M.slide_symlink or M.slide_path)
	attachAutoClose(vim.api.nvim_get_current_buf())
	if M.options.after_open_hook then
		M.options.after_open_hook(slides_file_path)
	end
end

---Full close flow: stop the server, remove the symlink, and disarm the
---auto-close autocommands. No-op when nothing is open.
function M.close()
	if not M.isSlidevRunning() and #M.symlinks == 0 and not M.slide_path then
		return
	end
	if M.options.before_close_hook then
		M.options.before_close_hook()
	end
	M.closeSlidevServer()
	removeSymlinks()
	M.slide_path = nil
	M.slide_symlink = nil
	clearAutoClose()
	if M.options.after_close_hook then
		M.options.after_close_hook()
	end
end

---@type SlidevOptions
local defaultOptions = {
	slidev_cwd = nil,
	slidev_port = 3030,
	slidev_command = { "npx", "slidev" },
	before_open_hook = nil,
	after_open_hook = M.openSlidevPreviewInNewBrowserWindow,
	before_close_hook = nil,
	after_close_hook = nil,
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
		M.open(slides_file_path)
	end, { nargs = "?", complete = "file" })

	vim.api.nvim_create_user_command("SlidevClose", function()
		M.close()
	end, {})

	vim.api.nvim_create_user_command("SlidevSync", function()
		M.sync()
	end, {})

	vim.api.nvim_create_user_command("SlidevBrowse", function()
		M.browseSlidev()
	end, {})
end

return M
