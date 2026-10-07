local lib = require("neotest.lib")
local async = require("neotest.async")
local xml = require("neotest.lib.xml")
local util = require("neotest-sourcekit-lsp.util")
local Path = require("plenary.path")
local logger = require("neotest-sourcekit-lsp.logging")
local filetype = require("plenary.filetype")
local files = require("neotest.lib.file")
local nio = require("nio")
local excluded_dirs = { Sources = true, build = true, [".git"] = true, [".build"] = true, [".swiftpm"] = true }

---Return all LSP clients that can answer Swift requests.
---@return vim.lsp.Client[]
local function swift_lsp_clients()
	local clients = {}
	for _, client in ipairs(vim.lsp.get_clients()) do
		local filetypes = (client.config and client.config.filetypes) or {}
		local name = (client.name or ""):lower()
		if name:find("sourcekit") or vim.tbl_contains(filetypes, "swift") then
			table.insert(clients, client)
		end
	end
	return clients
end

---Find the (deepest) Swift LSP client whose root contains `file_path`.
---@param file_path string
---@return vim.lsp.Client|nil
local function client_for_file(file_path)
	local best, best_len = nil, -1
	for _, client in ipairs(swift_lsp_clients()) do
		local root = client.config and client.config.root_dir
		if root and vim.startswith(file_path, root) and #root > best_len then
			best, best_len = client, #root
		end
	end
	return best
end

---Call the sourcekit-lsp custom `workspace/tests` request and await its result.
---@async
---@param client vim.lsp.Client
---@return any[]|nil, any?
local function request_workspace_tests(client)
	local future = nio.control.future()
	local ok, call_err = pcall(client.request, client, "workspace/tests", {}, function(err, result)
		future.set({ err = err, result = result })
	end)
	if not ok then
		return nil, call_err
	end
	local res = future.wait()
	if not res then
		return nil, "no response from workspace/tests"
	end
	return res.result, res.err
end

local M = {
	name = "neotest-sourcekit-lsp",
	root = function(path)
		local package_root = files.match_root_pattern("Package.swift")(path)
		if package_root then
			return package_root
		end
		-- Fall back to the LSP workspace root so Xcode projects don't crash discovery.
		local client = client_for_file(path)
		return client and client.config and client.config.root_dir or nil
	end,
	filter_dir = function(name)
		return not excluded_dirs[name]
	end,
	is_test_file = function(file_path)
		if not vim.endswith(file_path, ".swift") then
			return false
		end
		local elems = vim.split(file_path, Path.path.sep)
		local file_name = elems[#elems]
		return vim.endswith(file_name, "Test.swift") or vim.endswith(file_name, "Tests.swift")
	end,
}

-- Add filetype for swift until it gets added to plenary's built-in filetypes
-- See https://github.com/nvim-lua/plenary.nvim?tab=readme-ov-file#plenaryfiletype for more information
if filetype.detect_from_extension("swift") == "" then
	filetype.add_table({
		extension = { ["swift"] = "swift" },
	})
end

local treesitter_query = [[
;; @Suite struct TestSuite
;; Captures the optional display name, e.g. @Suite("My Suite")
((class_declaration
    (modifiers
        (attribute
            (user_type
                (type_identifier) @annotation (#eq? @annotation "Suite"))
            (line_string_literal
                (line_str_text) @namespace.display_name)?))?
         name: (type_identifier) @namespace.name)
         ) @namespace.definition

((class_declaration
    name: (user_type
      (type_identifier) @namespace.name))) @namespace.definition

;; @Test test func
;; Captures the optional display name, e.g. @Test("My test")
((function_declaration
    (modifiers
        (attribute
            (user_type
                (type_identifier) @annotation (#eq? @annotation "Test"))
            (line_string_literal
                (line_str_text) @test.display_name)?))
         name: (simple_identifier) @test.name)) @test.definition

]]

---@async
---@param cmd string[]
---@return string|nil
local function shell(cmd)
	local code, result = lib.process.run(cmd, { stdout = true, stderr = true })
	if result == nil or code ~= 0 or result.stderr ~= nil or result.stdout == nil then
		logger.error("Failed to run command: " .. vim.inspect(cmd) .. " " .. vim.inspect(result))
		return nil
	end
	return result.stdout
end

---@async
---@return string|nil
local function get_dyld_path()
	local os = util.get_os()
	if os == "Linux" then
		return shell({ "swiftly", "use", "-p" })
	elseif os == "macOS" then
		return shell({ "xcrun", "--show-sdk-platform-path" }) or ""
	else
		return nil
	end
end

---Builds a neotest position from the captured treesitter nodes, preferring the
---Swift Testing display name (e.g. `@Test("My test")`) over the identifier.
---The identifier is kept so position ids and run filters stay stable.
---@param file_path string
---@param source string
---@param captured_nodes table<string, userdata>
---@return neotest.Position|nil
function M._build_position(file_path, source, captured_nodes)
	local match_type
	if captured_nodes["test.name"] then
		match_type = "test"
	elseif captured_nodes["namespace.name"] then
		match_type = "namespace"
	end
	if not match_type then
		return nil
	end

	local identifier = vim.treesitter.get_node_text(captured_nodes[match_type .. ".name"], source)
	local display_name_node = captured_nodes[match_type .. ".display_name"]
	local display_name = display_name_node and vim.treesitter.get_node_text(display_name_node, source) or nil
	local definition = captured_nodes[match_type .. ".definition"]

	---@type neotest.Position
	return {
		type = match_type,
		path = file_path,
		name = display_name or identifier,
		identifier = identifier,
		range = { definition:range() },
	}
end

---Builds a position id from the identifiers (not display names) so that result
---parsing and run filters keep matching the Swift function/suite names.
---@param position neotest.Position
---@param parents neotest.Position[]
---@return string
function M._position_id(position, parents)
	local parts = { position.path }
	for _, parent in ipairs(parents) do
		table.insert(parts, parent.identifier or parent.name)
	end
	table.insert(parts, position.identifier or position.name)
	return table.concat(parts, "::")
end

---@param id string
---@return string
local function module_of(id)
	return id:match("^([^.]+)%.") or ""
end

---Convert a `workspace/tests` result tree into a flat neotest position list
---(file + namespaces + tests) for the given file.
---@param items any[]
---@param file_path string
---@return neotest.Position[]
function M._items_to_positions(items, file_path)
	local line_count = #vim.fn.readfile(file_path)
	---@type neotest.Position[]
	local positions = {
		{
			type = "file",
			path = file_path,
			name = vim.fn.fnamemodify(file_path, ":t"),
			range = { 0, 0, math.max(line_count - 1, 0), 0 },
		},
	}

	local function visit(item, parent_id)
		local loc = item.location
		local path = loc and loc.uri and vim.uri_to_fname(loc.uri) or nil
		local is_suite = item.children ~= nil and #item.children > 0
		local id = item.id or ""

		if path == file_path and loc and loc.range then
			local local_name
			if parent_id and vim.startswith(id, parent_id .. "/") then
				local_name = id:sub(#parent_id + 2)
			else
				local module = module_of(id)
				local_name = module ~= "" and id:sub(#module + 2) or id
			end
			-- Drop disambiguating location suffixes and parameter lists.
			local_name = local_name:gsub("/.*$", "")
			local identifier = is_suite and local_name or local_name:gsub("%(.*$", "")

			if identifier ~= "" then
				local range = loc.range
				table.insert(positions, {
					type = is_suite and "namespace" or "test",
					path = file_path,
					name = item.label or identifier,
					identifier = identifier,
					range = { range.start.line, range.start.character, range["end"].line, range["end"].character },
				})
			end
		end

		for _, child in ipairs(item.children or {}) do
			visit(child, id)
		end
	end

	for _, item in ipairs(items or {}) do
		visit(item, nil)
	end
	return positions
end

---@async
---@param file_path string
---@return neotest.Tree
function M._treesitter_discover(file_path)
	return lib.treesitter.parse_positions(file_path, treesitter_query, {
		nested_tests = true,
		require_namespaces = false,
		build_position = "require('neotest-sourcekit-lsp')._build_position",
		position_id = "require('neotest-sourcekit-lsp')._position_id",
	})
end

---@async
---@param file_path string
---@return neotest.Tree
M.discover_positions = function(file_path)
	-- Prefer test discovery through sourcekit-lsp's `workspace/tests` request
	-- (works for XCTest + Swift Testing, includes display names/tags/disabled
	-- state and exact ranges). Fall back to the treesitter query when no
	-- sourcekit-lsp client is attached to the file.
	local client = client_for_file(file_path)
	if client then
		local items, err = request_workspace_tests(client)
		if items then
			local positions = M._items_to_positions(items, file_path)
			return lib.positions.parse_tree(positions, {
				nested_tests = true,
				require_namespaces = false,
				position_id = M._position_id,
			})
		end
		logger.error("sourcekit-lsp workspace/tests failed: " .. vim.inspect(err))
	end
	return M._treesitter_discover(file_path)
end

---Removes new line characters
---@param str string
---@return string
local function remove_nl(str)
	local trimmed, _ = string.gsub(str, "\n", "")
	return trimmed
end

---Returns Xcode devoloper path
---@async
---@return string|nil
local function get_dap_cmd()
	--  TODO: use swiftly
	--  local result = shell({"swiftly", "use", "-p"})
	local result = shell({ "xcode-select", "-p" })
	if not result then
		return nil
	end
	result = shell({ "fd", "swiftpm-testing-helper", remove_nl(result) })
	if not result then
		return nil
	end
	return remove_nl(result)
end

---@async
---@return string[]|nil
local function get_test_executable()
	local bin_path = shell({ "swift", "build", "--show-bin-path" })
	if not bin_path then
		return nil
	end
	local json_path = remove_nl(bin_path) .. "/description.json"
	if not files.exists(json_path) then
		return nil
	end
	local decoded = vim.json.decode(files.read(json_path))
	return decoded.builtTestProducts[1].binaryPath
end

---@async
---@param test_name string
---@return table|nil
local function get_dap_config(test_name)
	local executable = get_test_executable()
	if not executable then
		logger.error("Failed to get the test executable path")
		return nil
	end
	local os = util.get_os()
	local args = {
		"--testing-library",
		"swift-testing",
		"--enable-swift-test",
		"--filter",
		test_name,
	}
	local program
	if os == "Linux" then
		program = executable
	elseif os == "macOS" then
		program = get_dap_cmd()
		if not program then
			logger.error("Failed to get the spm test helper path")
			return nil
		end
		args["--test-bundle-path"] = executable
	else
		logger.debug("Unsupported OS")
		return nil
	end

	local config = {
		name = "Swift Test debugger",
		type = "lldb",
		request = "launch",
		program = program,
		cwd = "${workspaceFolder}",
		stopOnEntry = false,
		args = args,
	}
	if os == "Linux" then
		config.waitFor = false
	end
	return config
end

---@async
---@return integer
local function ensure_test_bundle_is_build()
	local code, result = lib.process.run({
		"swift",
		"build",
		"--build-tests",
		"--enable-swift-testing",
		"--disable-xctest",
		"-c",
		"debug",
	})
	if code ~= 0 then
		logger.debug("Failed to build test bundle: " .. result.stderr)
	end
	return code
end

---Finds the test target for a given file in the package directory
---@async
---@param package_directory string
---@param file_name string
---@return string|nil The test target name or nil if not found
local function find_test_target(package_directory, file_name)
	local result = shell({ "swift", "package", "--package-path", package_directory, "describe", "--type", "json" })
	if result == nil then
		logger.error("Failed to run swift package describe.")
		return nil
	end

	local decoded = vim.json.decode(result)
	if not decoded then
		logger.error("Failed to decode swift package describe output.")
		return nil
	end

	for _, target in ipairs(decoded.targets or {}) do
		if target.type == "test" and target.sources and vim.list_contains(target.sources, file_name) then
			return target.name
		end
	end
	return nil
end

---@async
---@param args neotest.RunArgs
---@return neotest.RunSpec|neotest.RunSpec[]|nil
function M.build_spec(args)
	if not args.tree then
		logger.error("Unexpectedly did not receive a neotest.Tree.")
		return nil
	end
	local position = args.tree:data()
	local junit_folder = async.fn.tempname()
	local cwd = assert(M.root(position.path), "could not locate root directory of " .. position.path)

	if args.strategy == "dap" then
		-- id pattern /Users/name/project/Tests/ProjectTests/fileName.swift::Suite::testName
		-- or for suite-less tests /Users/name/project/Tests/ProjectTests/fileName.swift::testName
		local file_name, chain = position.id:match(".*/(.-%.swift)::(.*)")

		if file_name == nil or chain == nil or chain == "" then
			logger.error("Could not extract file and test name from position.id: " .. position.id)
			return
		end

		local parts = vim.split(chain, "::", { plain = true })
		local test_name = table.remove(parts)
		local class_name = #parts > 0 and table.concat(parts, ".") or nil

		local target = find_test_target(cwd, file_name)
		if not target then
			logger.error("Swift test target not found.")
			return
		end

		local full_test_name = target .. "." .. (class_name and (class_name .. "/") or "") .. test_name .. "()"
		if ensure_test_bundle_is_build() ~= 0 then
			logger.error("Failed to build test bundle.")
			return nil
		end
		local path = get_dyld_path() or ""
		return {
			cwd = cwd,
			context = { is_dap_active = true, position_id = position.id },
			strategy = get_dap_config(full_test_name),
			env = { ["DYLD_FRAMEWORK_PATH"] = remove_nl(path) .. "/Developer/Library/Frameworks" },
		}
	end

	local command = {
		"swift",
		"test",
		"--enable-swift-testing",
		"--disable-xctest",
		"-c",
		"debug",
		"--xunit-output",
		junit_folder .. "junit.xml",
		"-q",
	}
	local filters = {}
	if position.type == "file" then
		table.insert(filters, "/" .. position.name)
	elseif position.type == "namespace" then
		table.insert(filters, "." .. (position.identifier or position.name))
	elseif position.type == "test" then
		-- Build a filter from the full hierarchy in the position id so that
		-- top-level (suite-less) tests are filtered too, and prefix it with the
		-- test target/module so identically named tests in sibling targets (e.g.
		-- FooTests and FooTests2) are not run as well.
		local file, chain = string.match(position.id, "^(.-%.swift)::(.*)$")
		if chain ~= nil and chain ~= "" then
			local parts = vim.split(chain, "::", { plain = true })
			local module = file and file:match("/Tests/([^/]+)/")
			if module then
				table.insert(parts, 1, module)
			end
			table.insert(filters, table.concat(parts, "."))
		end
	elseif position.type == "dir" and position.path ~= cwd then
		table.insert(filters, position.name)
	end

	if #filters > 0 then
		table.insert(command, "--filter")
		for _, filter in ipairs(filters) do
			table.insert(command, filter)
		end
	end

	return {
		command = command,
		context = {
			results_path = junit_folder .. "junit.xml",
		},
		cwd = cwd,
	}
end

---Parse the output of swift test to get the line number and error message
---@async
---@param output string[] The output of the swift test command
---@param position neotest.Position The position of the test
---@param test_name string The name of the test
---@return integer?, string? The line number and error message. nil if not found
local function parse_errors(output, position, test_name)
	local pattern = "Test (%w+)%(%) recorded an issue at ([%w-_]+%.swift):(%d+):%d+: (.+)"
	local pattern_with_arguments =
		"Test (%w+)%b() recorded an issue with 1 argument value → (.+) at ([%w-_]+%.swift):(%d+):%d+: (.+)"
	for _, line in ipairs(output) do
		local method, file, line_number, message = line:match(pattern)
		if method and file and line_number and message then
			if test_name == method and vim.endswith(position.path, file) then
				return tonumber(line_number) - 1 or nil, message
			end
		end
		method, _, file, line_number, message = line:match(pattern_with_arguments)
		if method and file and line_number and message then
			if test_name == method and vim.endswith(position.path, file) then
				return tonumber(line_number) - 1 or nil, message
			end
		end
	end
	return nil, nil
end

local function xml_as_list(value)
	if value == nil then
		return {}
	elseif #value == 0 then
		return { value }
	end
	return value
end

---@async
---@param spec neotest.RunSpec
---@param result neotest.StrategyResult
---@param tree neotest.Tree
---@return table<string, neotest.Result>
function M.results(spec, result, tree)
	local test_results = {}
	local nodes = {}
	local context = spec.context or {}

	if context.errors ~= nil and #context.errors > 0 then
		-- mark as failed if a non-test error occurred.
		test_results[context.position_id] = {
			status = "failed",
			errors = context.errors,
		}
		return test_results
	elseif context.is_dap_active and context.position_id then
		-- return early if test result processing is not desired.
		test_results[context.position_id] = {
			status = "skipped",
		}
		return test_results
	end

	local position = tree:data()
	local list = tree:to_list()
	local tests = util.collect_tests(list)
	if position.type == "test" then
		table.insert(nodes, position)
	end

	for _, node in ipairs(tests) do
		table.insert(nodes, node)
	end
	local raw_output = files.read_lines(result.output)

	if context.results_path and files.exists(context.results_path) then
		local root = xml.parse(files.read(context.results_path))

		for _, testsuite in ipairs(xml_as_list(root.testsuites.testsuite)) do
			for _, testcase in ipairs(xml_as_list(testsuite.testcase)) do
				local test_position = util.find_position(nodes, testcase._attr.classname, testcase._attr.name, spec.cwd)
				if test_position ~= nil then
					if testcase.failure then
						local line_number, error_message =
							parse_errors(raw_output, test_position, util.get_prefix(testcase._attr.name, "("))
						test_results[test_position.id] = {
							status = "failed",
						}
						if line_number and error_message then
							test_results[test_position.id].errors = {
								{ line = line_number, message = error_message },
							}
						end
					else
						test_results[test_position.id] = {
							status = "passed",
						}
					end
				else
					logger.debug("Position not found: " .. testcase._attr.classname .. "/" .. testcase._attr.name)
				end
			end
		end
	elseif context.position_id ~= nil then
		test_results[context.position_id] = {
			status = "failed",
			output = result.output,
			short = table.concat(raw_output, "\n"),
		}
	end
	return test_results
end

setmetatable(M, {
	__call = function(_, opts)
		opts = opts or {}
		if opts.log_level then
			logger:set_level(opts.log_level)
		end
		return M
	end,
})

return M
