local M = {
	slidev_id = nil, -- State variable to track the Slidev job ID
	slidev_symlink = nil, -- Absolute path of the symlink created inside slidev_cwd
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

---Symlink the slides file into `slidev_cwd` so Slidev serves it from inside the
---addon project, then return the path Slidev should be launched on.
---@param slides_file_path string
---@return string link Absolute path of the symlink (or the file itself if already inside slidev_cwd)
local function createSlidevSymlink(slides_file_path)
	local target = vim.fn.fnamemodify(slides_file_path, ":p")
	local name = vim.fn.fnamemodify(target, ":t")
	local link = vim.fs.joinpath(M.options.slidev_cwd, name)

	-- If the slides file already lives in slidev_cwd, serve it directly.
	if vim.fn.fnamemodify(link, ":p") == target then
		return target
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
	return link
end

---Remove the symlink created by createSlidevSymlink, if it still points at one.
local function removeSlidevSymlink()
	if not M.slidev_symlink then
		return
	end
	local stat = uv.fs_lstat(M.slidev_symlink)
	if stat and stat.type == "link" then
		uv.fs_unlink(M.slidev_symlink)
	end
	M.slidev_symlink = nil
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

---Full open flow: symlink the slides file into slidev_cwd, launch Slidev on it,
---and arm the auto-close autocommands.
---@param slides_file_path string
function M.open(slides_file_path)
	if M.options.before_open_hook then
		M.options.before_open_hook(slides_file_path)
	end
	M.slidev_symlink = createSlidevSymlink(slides_file_path)
	M.openSlidevServer(M.slidev_symlink)
	attachAutoClose(vim.api.nvim_get_current_buf())
	if M.options.after_open_hook then
		M.options.after_open_hook(slides_file_path)
	end
end

---Full close flow: stop the server, remove the symlink, and disarm the
---auto-close autocommands. No-op when nothing is open.
function M.close()
	if not M.isSlidevRunning() and not M.slidev_symlink then
		return
	end
	if M.options.before_close_hook then
		M.options.before_close_hook()
	end
	M.closeSlidevServer()
	removeSlidevSymlink()
	clearAutoClose()
	if M.options.after_close_hook then
		M.options.after_close_hook()
	end
end

---@type SlidevOptions
local defaultOptions = {
	slidev_cwd = nil,
	slidev_port = 3030,
	slidev_command = { "npm", "run", "dev", "--", "--port", tostring(3030) },
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

	vim.api.nvim_create_user_command("SlidevBrowse", function()
		M.browseSlidev()
	end, {})
end

return M
