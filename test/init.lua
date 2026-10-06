-- Minimal headless init for test/pg_verify*.lua. Run from the repo root so
-- `require "projectgen"` resolves to THIS checkout, not any installed copy:
--   nvim --headless -u test/init.lua -l test/pg_verify3.lua -c "qa!"
vim.opt.runtimepath:prepend(vim.fn.getcwd())