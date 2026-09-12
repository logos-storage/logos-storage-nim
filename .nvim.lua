local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
local nimble_bin = vim.fn.expand("~/.nimble/bin")
local nimbus_nimsuggest =
  root .. "/vendor/nimbus-build-system/vendor/Nim/bin/nimsuggest"

vim.lsp.config("nim_langserver", {
  cmd = { nimble_bin .. "/nimlangserver" },
  cmd_env = {
    NIMBUS_BUILD_SYSTEM = "yes",
  },
  capabilities = {
    workspace = {
      configuration = false,
    },
  },
  settings = {
    nim = {
      nimsuggestPath = nimbus_nimsuggest,
      inlayHints = {
        exceptionHints = {
          enable = false,
        },
      },
      projectMapping = {
        {
          projectFile = "library/libstorage.nim",
          fileRegex = "^(library/libstorage[.]nim|library/.*[.]nim)$",
        },
        {
          projectFile = "tests/testStorage.nim",
          fileRegex = "^(tests/testStorage[.]nim|tests/storage/.*[.]nim)$",
        },
        {
          projectFile = "tests/testIntegration.nim",
          fileRegex = "^(tests/testIntegration[.]nim|tests/integration/.*[.]nim)$",
        },
        {
          projectFile = "tests/testLibstorage.nim",
          fileRegex = "^(tests/testLibstorage[.]nim|tests/libstorage/.*[.]nim)$",
        },
        {
          projectFile = "storage.nim",
          fileRegex = "^(storage[.]nim|storage/.*[.]nim)$",
        },
      },
    },
  },
})
