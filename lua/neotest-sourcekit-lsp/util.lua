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
---@param cwd string
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

  -- Normalize hyphens and underscores because Swift replaces hyphens in folder names
  -- with underscores in compiled module names (e.g. bw-alfredTests -> bw_alfredTests).
  local normalized_module = string.gsub(module, "%-", "_")
  local prefix = string.gsub(cwd .. "/Tests/" .. normalized_module, "%-", "_")
  local prefix_fallback = string.gsub(cwd .. "/" .. normalized_module, "%-", "_")

  for _, item in ipairs(list) do
    if item.type == "test" and vim.endswith(item.id, suffix) then
      local normalized_item_id = string.gsub(item.id, "%-", "_")
      if
        vim.startswith(normalized_item_id, prefix)
        or vim.startswith(normalized_item_id, prefix_fallback)
        or string.find(normalized_item_id, "/" .. normalized_module .. "/")
      then
        return item
      end
    end
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
