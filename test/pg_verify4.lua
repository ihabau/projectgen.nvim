-- Framework matrix: tick EVERY row on every frontend tab and generate.
-- The npm install/build runs happen outside this script; this just produces
-- the fixtures and reports what the wizard put in each package.json.
--
-- Run: nvim --headless -u "$env:LOCALAPPDATA\nvim\init.lua" -l <this file> -c "qa!"

local tmp = (vim.env.TEMP or "/tmp") .. "\\pgverify4"
vim.fn.delete(tmp, "rf")
vim.fn.mkdir(tmp, "p")

local failures = {}
local function check(name, ok, detail)
  if ok then
    print("  ok   " .. name)
  else
    failures[#failures + 1] = name .. (detail and (" - " .. detail) or "")
    print("  FAIL " .. name .. (detail and (" - " .. detail) or ""))
  end
end

local function float_win()
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.bo[vim.api.nvim_win_get_buf(w)].filetype == "projectgen-wizard" then return w end
  end
end

local function press(win, key)
  local buf = vim.api.nvim_win_get_buf(win)
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
    if m.lhs == key then
      vim.api.nvim_win_call(win, function() m.callback() end)
      return true
    end
  end
  return false
end

local function lines(win)
  return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)
end

local function set_field(win, label, value)
  for i, l in ipairs(lines(win)) do
    if l:find(" " .. label .. ": ", 1, true) == 1 then
      vim.api.nvim_buf_set_lines(vim.api.nvim_win_get_buf(win), i - 1, i, false, { " " .. label .. ": " .. value })
      return true
    end
  end
  return false
end

---Generate `run` with every checklist row ticked.
---@return boolean created
local function generate_all(run, project)
  vim.fn.chdir(tmp)
  local pg = require "projectgen"
  local wiz = pg.wizard(run)
  set_field(wiz.win, "Project name", project)
  set_field(wiz.win, "npm name    ", project)
  press(wiz.win, "a") -- tick all (keeps core rows)
  press(wiz.win, "<CR>")
  return float_win() == nil
end

local runs = { "vanilla", "vite", "react", "next" }
for _, run in ipairs(runs) do
  print("== " .. run .. " (everything ticked) ==")
  local created = generate_all(run, "all-" .. run)
  check(run .. ": created", created)
end

print("")
if #failures == 0 then
  print("GENERATED: " .. table.concat(runs, ", "))
  print("TMP=" .. tmp)
else
  print(#failures .. " FAILURE(S)")
  print("TMP=" .. tmp)
end
