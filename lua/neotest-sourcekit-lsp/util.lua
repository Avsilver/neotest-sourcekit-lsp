local M = {}
local separator = "::"

---Get the prefix of a string.
---@param str string
---@param char string
---@return string
M.get_prefix = function(str, char)
  return string.match(str, "^[^" .. char .. "]*")
end

M.collect_tests = function(nested_table)
  local flattened_table = {}

  local function recurse(subtable)
    for _, item in ipairs(subtable) do
      if type(item) == "table" then
        if item.type == "test" then
          table.insert(flattened_table, item)
        else
          recurse(item)
        end
      end
    end
  end

  recurse(nested_table)
  return flattened_table
end

---@param list neotest.Position[]
---@param class_name string
---@param test_name string
---@param cwd? string
---@return neotest.Position?
M.find_position = function(list, class_name, test_name, cwd)
  local parts = vim.split(class_name, ".", { plain = true })
  local module = parts[1]
  if not module then
    return nil
  end

  local suites = {}
  for i = 2, #parts do
    table.insert(suites, parts[i])
  end

  local test_name_clean = M.get_prefix(test_name, "(")
  local suffix
  if #suites > 0 then
    suffix = separator .. table.concat(suites, separator) .. separator .. test_name_clean
  else
    suffix = separator .. test_name_clean
  end

  -- SourceKit-LSP IDs carry the test target/module. Use that where available;
  -- filesystem layout is only a disambiguation hint for older/tree-sitter
  -- positions, since build-server workspaces do not require Tests/<module>.
  local normalized_module = string.gsub(module, "%-", "_")
  local function find_candidates(match_suffix)
    local matches = {}
    for _, item in ipairs(list) do
      local item_path = item.path or (item.id and item.id:match("^(.-)::")) or ""
      local package_root = cwd and cwd:gsub("[/\\]+$", "")
      local in_package = not package_root or item_path == package_root or vim.startswith(item_path, package_root .. "/")
      if item.type == "test" and in_package and vim.endswith(item.id, match_suffix) then
        table.insert(matches, item)
      end
    end
    return matches
  end

  local candidates = find_candidates(suffix)
  -- JUnit class names and SourceKit's suite hierarchy are not always identical
  -- (notably for top-level Swift Testing tests). Fall back to the test
  -- identifier only, then disambiguate below.
  if #candidates == 0 then
    candidates = find_candidates(separator .. test_name_clean)
  end

  if #candidates == 0 then
    return nil
  end

  local function normalize(value)
    return string.gsub(value or "", "%-", "_")
  end

  local module_matches = {}
  for _, item in ipairs(candidates) do
    if item.module and item.module ~= "" then
      if normalize(item.module) == normalized_module then
        table.insert(module_matches, item)
      end
    end
  end
  if #module_matches == 1 then
    return module_matches[1]
  elseif #module_matches > 1 then
    candidates = module_matches
  end

  local path_matches = {}
  for _, item in ipairs(candidates) do
    local item_path = item.path or (item.id and item.id:match("^(.-)::")) or ""
    for segment in string.gmatch(item_path, "[^/]+") do
      if normalize(segment) == normalized_module then
        table.insert(path_matches, item)
        break
      end
    end
  end
  if #path_matches == 1 then
    return path_matches[1]
  elseif #path_matches > 1 then
    return nil
  end

  -- A unique class/suite/test match is sufficient when the target name is not
  -- represented in the discovered position's metadata or path.
  if #candidates == 1 then
    return candidates[1]
  end
  return nil
end

---@alias Platform
---| 'Linux'
---| 'macOS'
---| 'Windows'

---@return Platform|nil
M.get_os = function()
  local os_type = vim.loop.os_uname().sysname
  if os_type == "Linux" then
    return "Linux"
  elseif os_type == "Darwin" then
    return "macOS"
  elseif os_type == "Windows_NT" then
    return "Windows"
  else
    return nil
  end
end

return M
