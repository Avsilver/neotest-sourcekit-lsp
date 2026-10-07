package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

local original_vim = _G.vim
local util

local function startswith(value, prefix)
  return value:sub(1, #prefix) == prefix
end

local function endswith(value, suffix)
  return value:sub(-#suffix) == suffix
end

local function split(value, separator)
  local parts = {}
  local start = 1
  while true do
    local first, last = value:find(separator, start, true)
    if not first then
      table.insert(parts, value:sub(start))
      return parts
    end
    table.insert(parts, value:sub(start, first - 1))
    start = last + 1
  end
end

local function install_vim_stub()
  _G.vim = {
    endswith = endswith,
    startswith = startswith,
    split = split,
    loop = {
      os_uname = function()
        return { sysname = "Darwin" }
      end,
    },
  }
end

before_each(function()
  install_vim_stub()
  util = require("neotest-sourcekit-lsp.util")
end)

after_each(function()
  _G.vim = original_vim
end)

describe("neotest-sourcekit-lsp.util", function()
  it("gets the prefix before a delimiter", function()
    assert.equals("testExample", util.get_prefix("testExample(value)", "("))
  end)

  it("collects test positions from nested lists", function()
    local top_level = { type = "test", id = "top-level" }
    local nested = { type = "test", id = "nested" }
    local positions = util.collect_tests({
      top_level,
      {
        { type = "namespace", name = "Suite" },
        { nested },
      },
    })

    assert.same({ top_level, nested }, positions)
  end)

  it("matches module and suite without confusing similarly prefixed targets", function()
    local sibling = {
      type = "test",
      id = "/repo/Tests/FooTests2/File.swift::Suite::testExample",
    }
    local expected = {
      type = "test",
      id = "/repo/Tests/FooTests/File.swift::Suite::testExample",
    }

    local found = util.find_position({ sibling, expected }, "FooTests.Suite", "testExample()")

    assert.equals(expected, found)
  end)

  it("matches Swift module names normalized from hyphenated targets", function()
    local expected = {
      type = "test",
      id = "/repo/Tests/bw_alfredTests/File.swift::testExample",
    }

    local found = util.find_position({ expected }, "bw-alfredTests", "testExample()")

    assert.equals(expected, found)
  end)

  it("matches a unique test in a build-server workspace layout", function()
    local expected = {
      type = "test",
      id = "/repo/Components/Infrastructure/GRDBFocusRepositoryTests.swift::GRDBFocusRepositoryTests::update",
      path = "/repo/Components/Infrastructure/GRDBFocusRepositoryTests.swift",
    }

    local found = util.find_position({ expected }, "LTPInfrastructureTests.GRDBFocusRepositoryTests", "update()")

    assert.equals(expected, found)
  end)

  it("uses SourceKit-LSP module metadata to disambiguate identical test names", function()
    local other_target = {
      type = "test",
      module = "OtherTests",
      path = "/repo/Other/Tests.swift",
      id = "/repo/Other/Tests.swift::GRDBFocusRepositoryTests::update",
    }
    local expected = {
      type = "test",
      module = "LTPInfrastructureTests",
      path = "/repo/Components/Infrastructure/Tests.swift",
      id = "/repo/Components/Infrastructure/Tests.swift::GRDBFocusRepositoryTests::update",
    }

    local found = util.find_position(
      { other_target, expected },
      "LTPInfrastructureTests.GRDBFocusRepositoryTests",
      "update()"
    )

    assert.equals(expected, found)
  end)

  it("matches a unique position when the SourceKit module differs from JUnit's target name", function()
    local expected = {
      type = "test",
      module = "LTPDomain",
      path = "/repo/Packages/LTPDomain/Tests/LTPDomainTests/LTPDomainTests.swift",
      id = "/repo/Packages/LTPDomain/Tests/LTPDomainTests/LTPDomainTests.swift::example",
    }

    local found = util.find_position({ expected }, "LTPDomainTests", "example()")

    assert.equals(expected, found)
  end)

  it("falls back to the test identifier when JUnit and SourceKit suite names differ", function()
    local expected = {
      type = "test",
      module = "LTPDomain",
      path = "/repo/Packages/LTPDomain/Tests/LTPDomain2Tests/LTPDomain2Tests.swift",
      id = "/repo/Packages/LTPDomain/Tests/LTPDomain2Tests/LTPDomain2Tests.swift::a1",
    }

    local found = util.find_position({ expected }, "LTPDomain2Tests.LTPDomain2Tests", "a1()")

    assert.equals(expected, found)
  end)

  it("does not guess when a test name is ambiguous", function()
    local first = { type = "test", id = "/repo/One.swift::Suite::testSame" }
    local second = { type = "test", id = "/repo/Two.swift::Suite::testSame" }

    local found = util.find_position({ first, second }, "UnknownModule.Suite", "testSame()")

    assert.is_nil(found)
  end)

  it("returns the current platform name", function()
    assert.equals("macOS", util.get_os())
  end)
end)
