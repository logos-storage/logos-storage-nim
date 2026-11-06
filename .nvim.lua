local nimble_bin = vim.fn.expand("~/.nimble/bin")

vim.lsp.config("nim_langserver", {
  cmd = { nimble_bin .. "/nimlangserver" },
  capabilities = {
    workspace = {
      configuration = false,
    },
  },
  settings = {
    nim = {
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
