local constants = require("perfnvim.constants")

local M = {}

local function _PlaceSigns(signgroupidentifier, signname, lines, file_path)
	for _, line_num in ipairs(lines) do
		vim.fn.sign_place(0, signgroupidentifier, signname, vim.fn.bufnr(file_path), { lnum = line_num })
	end
end

local function _ClearSignsAndPlace(signgroupidentifier, signname, lines, file_path)
	-- Clear existing signs from the buffer
	vim.fn.sign_unplace(signgroupidentifier, { buffer = vim.fn.bufnr(file_path) })
	-- Place new signs
	_PlaceSigns(signgroupidentifier, signname, lines, file_path)
end

function M._AnnotateAddedLines(lines, file_path)
	local added_lines = {}
	for _, line in ipairs(lines) do
		if line:match("^(%d+)a") then
			local start_num, end_num = line:match("%d+a(%d+),(%d+)")
			if start_num and end_num then
				start_num = tonumber(start_num)
				end_num = tonumber(end_num)
				for i = start_num, end_num do
					table.insert(added_lines, i)
				end
			else
				local num = line:match("%d+a(%d+)")
				if num then
					num = tonumber(num)
					table.insert(added_lines, num)
				end
			end
		end
	end
	_ClearSignsAndPlace(constants.p4addSignGroupIdentifier, constants.p4addSignName, added_lines, file_path)
end

function M._AnnotateDeletedLines(lines, file_path)
	local deleted_lines = {}
	for _, line in ipairs(lines) do
		if line:match("^%d+[,?%d+]*d%d+[,?%d+]") then
			local start_num = line:match("d(%d+)")
			if start_num then
				start_num = tonumber(start_num)
				table.insert(deleted_lines, start_num)
			end
		end
	end
	_ClearSignsAndPlace(constants.p4deletesSignGroupIdentifier, constants.p4deleteSignName, deleted_lines, file_path)
end

function M._AnnotateChangedLines(lines, file_path)
	local changed_lines = {}
	for _, line in ipairs(lines) do
		if line:match("^%d+[,?%d+]*c%d+[,?%d+]") then
			local start_num, end_num = line:match("c(%d+),?(%d*)")
			if start_num then
				start_num = tonumber(start_num)
				if end_num == "" or end_num == nil then
					end_num = start_num
				else
					end_num = tonumber(end_num)
				end
				for i = start_num, end_num do
					table.insert(changed_lines, i)
				end
			end
		end
	end
	_ClearSignsAndPlace(constants.p4changesSignGroupIdentifier, constants.p4changeSignName, changed_lines, file_path)
end

-- A file opened for add has no depot revision to diff against, so "p4 diff" says nothing and
-- prints "file(s) not opened for edit." on stderr. In that case every line is new content, so
-- confirm the open action with "p4 opened" and mark the whole file with the add sign.
local function _AnnotateOpenedForAdd(file_dir, file_name, file_path)
	local opened_output = {}

	local function on_stdout(job_id, data, event)
		if event == "stdout" and data then
			for _, line in ipairs(data) do
				table.insert(opened_output, line)
			end
		end
	end

	local function on_exit(job_id, exit_code, event)
		if event ~= "exit" then
			return
		end
		local bufnr = vim.fn.bufnr(file_path)
		if bufnr == -1 then
			return
		end
		-- "p4 opened -s" prints e.g. "//depot/.../file#1 - add default change (text)".
		local is_add = false
		for _, line in ipairs(opened_output) do
			if line:find(" %- add ") or line:find(" %- move/add ") then
				is_add = true
				break
			end
		end
		local added_lines = {}
		if is_add then
			for i = 1, vim.api.nvim_buf_line_count(bufnr) do
				table.insert(added_lines, i)
			end
		end
		-- When not an add, added_lines stays empty and this clears any stale add signs.
		_ClearSignsAndPlace(constants.p4addSignGroupIdentifier, constants.p4addSignName, added_lines, file_path)
	end

	vim.fn.jobstart({ "p4", "opened", "-s", file_name }, {
		cwd = file_dir,
		env = { PWD = file_dir },
		on_stdout = on_stdout,
		on_exit = on_exit,
		stdout_buffered = true,
	})
end

function M._AnnotateSigns()
	-- Only annotate real, on-disk files. Special buffers (oil://, terminal, help, quickfix, ...)
	-- have a non-empty 'buftype' and a name that isn't a filesystem path; oil in particular fires
	-- BufWritePost on its own "oil://" buffer when you save a delete. Passing the resulting bogus
	-- directory to jobstart's cwd throws E475 ("expected valid directory").
	if vim.bo.buftype ~= "" then
		return
	end
	local file_path = vim.fn.expand("%:p")
	-- Run "p4 diff" from the file's own directory and pass just the file name, rather than an
	-- absolute path. The client root may be reached through a symlink (e.g. an AltRoot), in which
	-- case %:p resolves to the symlink *target* and p4 rejects it with "not under client's root".
	-- Running from the directory lets p4 resolve the path against the client mapping itself.
	--
	-- We must also set $PWD in the job env: jobstart's `cwd` changes the child's physical working
	-- directory, but the child otherwise inherits $PWD from Neovim (wherever nvim was launched). p4
	-- trusts $PWD over the real cwd both to resolve the relative file name and to locate the
	-- P4CONFIG (.perforce) by walking up. A stale $PWD makes p4 pick the wrong client and report
	-- "not under client's root" / "file(s) not opened on this client".
	local file_dir = vim.fn.fnamemodify(file_path, ":h")
	local file_name = vim.fn.fnamemodify(file_path, ":t")
	local diff_output = {}
	local err_output = {}

	local function on_stdout(job_id, data, event)
		if event == "stdout" and data then
			for _, line in ipairs(data) do
				table.insert(diff_output, line)
			end
		end
	end

	local function on_stderr(job_id, data, event)
		if event == "stderr" and data then
			for _, line in ipairs(data) do
				if line ~= "" then
					table.insert(err_output, line)
				end
			end
		end
	end

	-- Not every stderr line is a real failure. p4 diff writes these to stderr for perfectly normal
	-- files that simply have nothing to annotate; they must be silenced, not reported:
	--   "<file> - file(s) not opened on this client."  -- tracked but not open for edit
	--   "<file> - file(s) not opened for edit."        -- open on client but not for edit
	--   "Path '...' is not under client's root ..."     -- file outside the client (non-p4 files)
	--   "<file> - no such file(s)."                     -- not in the depot
	local function _IsBenignStderr(line)
		return line:find("file%(s%) not opened on this client")
			or line:find("file%(s%) not opened for edit")
			or line:find("is not under client's root")
			or line:find("no such file%(s%)")
			or line:find("file%(s%) not on client")
	end

	local function on_exit(job_id, exit_code, event)
		if event == "exit" then
			local real_errors = {}
			for _, line in ipairs(err_output) do
				if not _IsBenignStderr(line) then
					table.insert(real_errors, line)
				end
			end
			if #real_errors > 0 then
				vim.schedule(function()
					vim.notify(
						"perfnvim: p4 diff failed for " .. file_path .. "\n" .. table.concat(real_errors, "\n"),
						vim.log.levels.WARN
					)
				end)
				return
			end
			-- "file(s) not opened for edit." means the file may be opened for add, which p4 diff
			-- cannot annotate. Clear any stale change/delete signs and let the add handler decide.
			for _, line in ipairs(err_output) do
				if line:find("file%(s%) not opened for edit") then
					_ClearSignsAndPlace(constants.p4changesSignGroupIdentifier, constants.p4changeSignName, {}, file_path)
					_ClearSignsAndPlace(constants.p4deletesSignGroupIdentifier, constants.p4deleteSignName, {}, file_path)
					_AnnotateOpenedForAdd(file_dir, file_name, file_path)
					return
				end
			end
			-- Benign stderr (or none) means there is nothing to annotate; an empty diff still runs
			-- through the annotate helpers, which clears any stale signs from the buffer.
			local lines = vim.split(table.concat(diff_output, "\n"), "\n")
			M._AnnotateAddedLines(lines, file_path)
			M._AnnotateChangedLines(lines, file_path)
			M._AnnotateDeletedLines(lines, file_path)
		end
	end

	vim.fn.jobstart({ "p4", "diff", file_name }, {
		cwd = file_dir,
		env = { PWD = file_dir },
		on_stdout = on_stdout,
		on_stderr = on_stderr,
		on_exit = on_exit,
		stdout_buffered = true,
		stderr_buffered = true,
	})
end

return M
