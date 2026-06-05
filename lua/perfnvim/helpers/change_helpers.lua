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

function M._AnnotateSigns()
	local file_path = vim.fn.expand("%:p")
	local diff_output = {}

	local function on_stdout(job_id, data, event)
		if event == "stdout" and data then
			for _, line in ipairs(data) do
				table.insert(diff_output, line)
			end
		end
	end

	local function on_exit(job_id, exit_code, event)
		if event == "exit" then
			local lines = vim.split(table.concat(diff_output, "\n"), "\n")
			M._AnnotateAddedLines(lines, file_path)
			M._AnnotateChangedLines(lines, file_path)
			M._AnnotateDeletedLines(lines, file_path)
		end
	end

	vim.fn.jobstart("p4 diff " .. file_path, {
		on_stdout = on_stdout,
		on_exit = on_exit,
		stdout_buffered = true,
	})
end

return M
