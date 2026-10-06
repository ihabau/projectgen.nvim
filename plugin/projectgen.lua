-- projectgen.nvim loader.
--
-- plugin/ files are sourced automatically once the plugin lands on
-- 'runtimepath', so a bare `{ "ihabau/projectgen.nvim" }` spec (lazy.nvim or
-- any manager) is enough to get all eight commands. The only registration that
-- happens here is inert user-command registration - nothing generates or runs
-- until :NewProject is actually invoked. M.setup() is idempotent, so a config
-- that would rather call it explicitly can do so.
require("projectgen").setup()
