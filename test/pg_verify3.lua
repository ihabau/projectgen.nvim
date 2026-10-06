-- Headless verification for the four FRONTEND tabs of lua/projectgen.lua. Run with:
--   nvim --headless -u <config>/init.lua -l pg_verify3.lua -c "qa!"
--
-- pg_verify2.lua covers Java/Spring/Android; this file is only about npm output.
-- Same conventions as that suite: the wizard is non-blocking, so every key is a
-- buffer-local mapping whose callback can be invoked directly - no vim.wait,
-- no feedkeys, no deferred watchdog. If a callback throws, the run fails loudly
-- instead of hanging.

local tmp = vim.env.PG_VERIFY_DIR
if not tmp or tmp == "" then
  tmp = (vim.env.TEMP or vim.fn.tempname()) .. "\\pgverify3"
  vim.fn.delete(tmp, "rf")
end
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

-- Missing files read as "" rather than throwing, so one absent file becomes one
-- clear FAIL instead of an E484 that aborts the run. CRLF is normalised: write()
-- forces "b" (LF), and asserting on line endings would only test the filesystem.
local function read(path)
  if vim.fn.filereadable(path) == 0 then return "" end
  -- Parens are load-bearing: `string.gsub` returns (string, count), and without
  -- them that count rides along as an extra argument to whatever consumes the
  -- result - which turned every vim.json.decode call into decode(str, <int>).
  return (table.concat(vim.fn.readfile(path), "\n"):gsub("\r\n", "\n"))
end
local function exists(path) return vim.fn.filereadable(path) == 1 end

---A generator wrote a file that npm would reject. Parsing it is the only check
---that catches a stray comma or a doubled key - every substring assertion below
---would still pass against syntactically broken JSON.
local function json_of(path)
  local ok, tbl = pcall(vim.json.decode, read(path))
  if not ok then return nil end
  return tbl
end

local function float_win()
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.bo[vim.api.nvim_win_get_buf(w)].filetype == "projectgen-wizard" then return w end
  end
  return nil
end

---Press a buffer-local normal-mode key in the float by running its callback.
local function press(win, key)
  local buf = vim.api.nvim_win_get_buf(win)
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
    if m.lhs == key then
      vim.api.nvim_win_call(win, function() m.callback() end)
      return
    end
  end
  error("no keymap for " .. key)
end

local function lines(win) return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false) end
local function buffer_text(win) return table.concat(lines(win), "\n") end

---Rewrite a field row the way typing into it would, then let the wizard read it
---back on <CR>.
local function set_field(win, label, value)
  for i, l in ipairs(lines(win)) do
    if l:find(" " .. label .. ": ", 1, true) == 1 then
      vim.api.nvim_buf_set_lines(vim.api.nvim_win_get_buf(win), i - 1, i, false, { " " .. label .. ": " .. value })
      return
    end
  end
  error("no field row for " .. label)
end

---Toggle the checklist row whose text contains `needle` (first match wins).
---Idempotent: a preselected row is already `[x]`, and pressing `x` again would
---UNtick it - which is how `router` disappeared from the react project.
local function tick(win, needle)
  for i, l in ipairs(lines(win)) do
    if l:find(needle, 1, true) then
      if l:find("[x]", 1, true) then return true end
      vim.api.nvim_win_call(win, function() vim.api.nvim_win_set_cursor(win, { i, 0 }) end)
      press(win, "x")
      return true
    end
  end
  return false
end

local function row_ticked(win, needle)
  for _, l in ipairs(lines(win)) do
    if l:find(needle, 1, true) then return l:find("[x]", 1, true) ~= nil end
  end
  return false
end

---Open the wizard on `run`, set both fields, optionally tick, then create.
---
---chdir back to `tmp` first: every generator ends with `vim.fn.chdir(dir)`, so
---without this the next project would resolve its path relative to the previous
---one and land nested inside it.
---@return boolean created
local function generate(run, project, extra_ticks)
  vim.fn.chdir(tmp)
  local pg = require "projectgen"
  local wiz = pg.wizard(run)
  set_field(wiz.win, "Project name", project)
  set_field(wiz.win, "npm name    ", project)
  for _, needle in ipairs(extra_ticks or {}) do
    if not tick(wiz.win, needle) then error("no row to tick for " .. needle) end
  end
  press(wiz.win, "<CR>")
  return float_win() == nil
end

local pg = require "projectgen"

print "== commands =="
pg.setup()
for _, c in ipairs {
  "NewProject",
  "NewJavaProject",
  "NewSpringBootProject",
  "NewAndroidProject",
  "NewVanillaJSProject",
  "NewViteProject",
  "NewReactProject",
  "NewNextJSProject",
} do
  check(c .. " registered", vim.fn.exists(":" .. c) == 2)
end
-- The bug this suite exists to catch: "Next.js" has no space, so stripping
-- spaces only produced `NewNext.jsProject`, which Vim refuses to register.
check("no illegal NewNext.jsProject", vim.fn.exists(":NewNext.jsProject") == 0)

print "== shell =="
vim.fn.chdir(tmp)
do
  local wiz = pg.wizard "vanilla"
  local text = buffer_text(wiz.win)
  check("all seven tabs rendered", text:find("Next.js", 1, true) ~= nil and text:find("Vanilla JS", 1, true) ~= nil)
  check("npm field label", text:find("npm name    : ", 1, true) ~= nil)
  check("npm field is not labelled Package", text:find(" Package: ", 1, true) == nil)

  -- Arrows must NOT switch tabs; they are plain cursor motion. A regression
  -- here is invisible unless something explicitly asserts the binding is gone.
  local bound = {}
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(wiz.buf, "n")) do
    bound[m.lhs] = true
  end
  for _, k in ipairs { "<Left>", "<Right>", "<Up>", "<Down>" } do
    check(k .. " not bound to a tab action", bound[k] == nil)
  end
  check("<Tab> bound", bound["<Tab>"] ~= nil)
  check("<S-Tab> bound", bound["<S-Tab>"] ~= nil)
  for d = 1, 7 do
    check(d .. " bound to tab " .. d, bound[tostring(d)] ~= nil)
  end

  -- Arrows are not merely "unmapped to tabs": they must still MOVE the cursor.
  -- Asserting only the absence of a keymap would pass even if <Right> had been
  -- disabled outright, which is the other half of the original bug.
  local before = text
  vim.api.nvim_win_set_cursor(wiz.win, { 3, 0 })
  local c0 = vim.api.nvim_win_get_cursor(wiz.win)
  vim.api.nvim_win_call(wiz.win, function() vim.cmd "normal! 6l" end)
  local c1 = vim.api.nvim_win_get_cursor(wiz.win)
  check("<Right> motion actually moves the cursor", c1[2] > c0[2], c0[2] .. " -> " .. c1[2])
  check("cursor move did not switch tabs", buffer_text(wiz.win):find("[4 Vanilla JS]", 1, true) ~= nil)

  press(wiz.win, "7")
  check("digit 7 selects Next.js", buffer_text(wiz.win):find("[7 Next.js]", 1, true) ~= nil)
  press(wiz.win, "1")
  check("digit 1 returns to Java", buffer_text(wiz.win):find("[1 Java]", 1, true) ~= nil)
  check("Java tab shows Package label", buffer_text(wiz.win):find(" Package     : ", 1, true) ~= nil)
  press(wiz.win, "<Tab>")
  check("<Tab> advances to Spring Boot", buffer_text(wiz.win):find("[2 Spring Boot]", 1, true) ~= nil)
  press(wiz.win, "<S-Tab>")
  check("<S-Tab> returns to Java", buffer_text(wiz.win):find("[1 Java]", 1, true) ~= nil)
  press(wiz.win, "q")
  check("q closes the wizard", float_win() == nil)
  check("wizard opened with content", before ~= "")
end

print "== npm name validation =="
do
  local wiz = pg.wizard "vite"
  set_field(wiz.win, "Project name", "vite-case")
  set_field(wiz.win, "npm name    ", "UPPERCASE-BAD")
  press(wiz.win, "<CR>")
  check("uppercase npm name refused", float_win() ~= nil, "wizard closed instead of rejecting")
  if float_win() then
    set_field(float_win(), "npm name    ", "vite-case")
    press(float_win(), "<CR>")
  end
  check("wizard closes on a valid npm name", float_win() == nil)
end

-- ---------------------------------------------------------------------------
print "== vanilla =="
do
  local d = tmp .. "/verify-vanilla"
  local created = generate("vanilla", "verify-vanilla", { "vitest", "jsdom" })
  check("vanilla: create closed the wizard", created)
  for _, f in ipairs { "package.json", ".gitignore", "index.html", "main.js", "styles.css" } do
    check("vanilla: " .. f .. " written", exists(d .. "/" .. f))
  end

  local pkg = json_of(d .. "/package.json")
  check("vanilla: package.json parses", pkg ~= nil)
  if pkg then
    check("vanilla: name field", pkg.name == "verify-vanilla", tostring(pkg.name))
    check("vanilla: private", pkg.private == true)
    check("vanilla: dev script runs serve", pkg.scripts and pkg.scripts.dev == "serve .", tostring(pkg.scripts and pkg.scripts.dev))
    check("vanilla: test script present", pkg.scripts and pkg.scripts.test == "vitest run")
    check("vanilla: jquery is a runtime dep", pkg.dependencies and pkg.dependencies.jquery ~= nil)
    check("vanilla: axios is a runtime dep", pkg.dependencies and pkg.dependencies.axios ~= nil)
    check("vanilla: serve is a devDep", pkg.devDependencies and pkg.devDependencies.serve ~= nil)
    check("vanilla: vitest is a devDep", pkg.devDependencies and pkg.devDependencies.vitest ~= nil)
    check("vanilla: no bundler leaked in", pkg.devDependencies and pkg.devDependencies.vite == nil)
    check("vanilla: no type:module", pkg.type == nil)
    -- zustand is ESM-only: a page with no bundler cannot load it.
    check("vanilla: no zustand (ESM-only, unusable here)", pkg.dependencies and pkg.dependencies.zustand == nil)
  end

  local html = read(d .. "/index.html")
  check("vanilla: jquery script tag", html:find("./node_modules/jquery/dist/jquery.js", 1, true) ~= nil)
  check("vanilla: axios script tag", html:find("./node_modules/axios/dist/axios.min.js", 1, true) ~= nil)
  check("vanilla: main.js loaded last", html:find('<script src="./main.js"></script>', 1, true) ~= nil)
  check("vanilla: has an element for main.js to fill", html:find('id="libs"', 1, true) ~= nil)

  local js = read(d .. "/main.js")
  check("vanilla: probes jQuery's global", js:find('window["jQuery"]', 1, true) ~= nil)
  check("vanilla: probes axios's global", js:find('window["axios"]', 1, true) ~= nil)

  check("vanilla: vitest config written", exists(d .. "/vitest.config.mjs"))
  check("vanilla: test file written", exists(d .. "/main.test.js"))
  check("vanilla: test uses jsdom", read(d .. "/vitest.config.mjs"):find("jsdom", 1, true) ~= nil)
  check("vanilla: .gitignore keeps node_modules out", read(d .. "/.gitignore"):find("node_modules/", 1, true) ~= nil)
end

-- ---------------------------------------------------------------------------
print "== vite =="
do
  local d = tmp .. "/verify-vite"
  local created = generate("vite", "verify-vite", { "tailwind" })
  check("vite: create closed the wizard", created)
  for _, f in ipairs { "package.json", ".gitignore", "index.html", "src/main.js", "src/style.css" } do
    check("vite: " .. f .. " written", exists(d .. "/" .. f))
  end

  local pkg = json_of(d .. "/package.json")
  check("vite: package.json parses", pkg ~= nil)
  if pkg then
    check("vite: name field", pkg.name == "verify-vite", tostring(pkg.name))
    check("vite: dev script", pkg.scripts and pkg.scripts.dev == "vite", tostring(pkg.scripts and pkg.scripts.dev))
    check("vite: build script", pkg.scripts and pkg.scripts.build == "vite build")
    check("vite: preview script", pkg.scripts and pkg.scripts.preview == "vite preview")
    check("vite: vite is a devDep", pkg.devDependencies and pkg.devDependencies.vite ~= nil)
    check("vite: axios ships as a dep", pkg.dependencies and pkg.dependencies.axios ~= nil)
    check("vite: dayjs ships as a dep", pkg.dependencies and pkg.dependencies.dayjs ~= nil)
    check("vite: tailwind is a devDep", pkg.devDependencies and pkg.devDependencies.tailwindcss ~= nil)
    check("vite: tailwind vite plugin is a devDep", pkg.devDependencies and pkg.devDependencies["@tailwindcss/vite"] ~= nil)
    check("vite: type:module set", pkg.type == "module", tostring(pkg.type))
    -- React must never appear on a plain Vite project.
    check("vite: no react", pkg.dependencies == nil or pkg.dependencies.react == nil)
  end

  local main = read(d .. "/src/main.js")
  check("vite: imports its stylesheet", main:find('import "./style.css";', 1, true) ~= nil)
  check("vite: imports axios", main:find('import axios from "axios";', 1, true) ~= nil)
  check("vite: imports dayjs", main:find('import dayjs from "dayjs";', 1, true) ~= nil)
  -- Referenced, not merely imported: an unread import is tree-shaken away.
  check("vite: bindings referenced", main:find("export const libraries = [", 1, true) ~= nil)

  local cfg = read(d .. "/vite.config.js")
  check("vite: config exists because a plugin was ticked", cfg ~= "")
  check("vite: tailwind plugin wired", cfg:find("tailwindcss()", 1, true) ~= nil)
  check("vite: index.html uses a module script", read(d .. "/index.html"):find('src="/src/main.js"', 1, true) ~= nil)
  check("vite: stylesheet is tailwind v4", read(d .. "/src/style.css"):find('@import "tailwindcss";', 1, true) ~= nil)
end

-- ---------------------------------------------------------------------------
print "== react =="
do
  local d = tmp .. "/verify-react"
  local created = generate("react", "verify-react", { "router" })
  check("react: create closed the wizard", created)
  for _, f in ipairs { "package.json", "vite.config.js", "index.html", "src/main.jsx", "src/App.jsx", "src/style.css" } do
    check("react: " .. f .. " written", exists(d .. "/" .. f))
  end

  local pkg = json_of(d .. "/package.json")
  check("react: package.json parses", pkg ~= nil)
  if pkg then
    -- React ships to the browser, so it is a dependency, not a devDependency.
    check("react: react is a runtime dep", pkg.dependencies and pkg.dependencies.react ~= nil)
    check("react: react-dom is a runtime dep", pkg.dependencies and pkg.dependencies["react-dom"] ~= nil)
    check("react: react is NOT a devDep", pkg.devDependencies == nil or pkg.devDependencies.react == nil)
    check("react: vite is a devDep", pkg.devDependencies and pkg.devDependencies.vite ~= nil)
    check("react: plugin-react is a devDep", pkg.devDependencies and pkg.devDependencies["@vitejs/plugin-react"] ~= nil)
    check("react: router is a runtime dep", pkg.dependencies and pkg.dependencies["react-router-dom"] ~= nil)
    check("react: type:module set", pkg.type == "module", tostring(pkg.type))
  end

  local cfg = read(d .. "/vite.config.js")
  check("react: plugin-react wired", cfg:find('import react from "@vitejs/plugin-react";', 1, true) ~= nil)
  check("react: react() in plugins", cfg:find("react()", 1, true) ~= nil)

  local entry = read(d .. "/src/main.jsx")
  check("react: renders App", entry:find("<App />", 1, true) ~= nil)
  check("react: mounts #root", entry:find('getElementById("root")', 1, true) ~= nil)
  check("react: index.html has #root", read(d .. "/index.html"):find('id="root"', 1, true) ~= nil)

  local app = read(d .. "/src/App.jsx")
  check("react: exports a component", app:find("export default function App()", 1, true) ~= nil)
  check("react: imports the router", app:find("react-router-dom", 1, true) ~= nil)
end

-- ---------------------------------------------------------------------------
print "== next =="
do
  local d = tmp .. "/verify-next"
  local created = generate("next", "verify-next", { "eslint" })
  check("next: create closed the wizard", created)
  for _, f in ipairs {
    "package.json",
    ".gitignore",
    "next.config.mjs",
    "jsconfig.json",
    "postcss.config.mjs",
    "app/layout.jsx",
    "app/page.jsx",
    "app/globals.css",
    "eslint.config.mjs",
  } do
    check("next: " .. f .. " written", exists(d .. "/" .. f))
  end

  local pkg = json_of(d .. "/package.json")
  check("next: package.json parses", pkg ~= nil)
  if pkg then
    check("next: next is a runtime dep", pkg.dependencies and pkg.dependencies.next ~= nil)
    check("next: react is a runtime dep", pkg.dependencies and pkg.dependencies.react ~= nil)
    check("next: dev script", pkg.scripts and pkg.scripts.dev == "next dev", tostring(pkg.scripts and pkg.scripts.dev))
    check("next: build script", pkg.scripts and pkg.scripts.build == "next build")
    check("next: start script", pkg.scripts and pkg.scripts.start == "next start")
    -- `next lint` was removed, so lint is plain eslint.
    check("next: lint script is eslint", pkg.scripts and pkg.scripts.lint == "eslint .", tostring(pkg.scripts and pkg.scripts.lint))
    check("next: eslint is a devDep", pkg.devDependencies and pkg.devDependencies.eslint ~= nil)
    -- eslint-config-next peers typescript, but that peer is optional and the
    -- project is JS: declaring it would ship an unused package.
    check("next: no typescript", pkg.devDependencies == nil or pkg.devDependencies.typescript == nil)
    -- eslint@10 breaks eslint-config-next at runtime despite a >=9 peer range.
    local eslint_v = pkg.devDependencies and pkg.devDependencies.eslint
    local major = eslint_v and eslint_v:match "^[%^~<>= ]*(%d+)"
    check(
      "next: eslint pinned below 10",
      major ~= nil and tonumber(major) ~= nil and tonumber(major) < 10,
      tostring(eslint_v)
    )
    check("next: tailwind is a devDep", pkg.devDependencies and pkg.devDependencies.tailwindcss ~= nil)
    check("next: postcss plugin is a devDep", pkg.devDependencies and pkg.devDependencies["@tailwindcss/postcss"] ~= nil)
    check("next: no type:module", pkg.type == nil)
  end

  local layout = read(d .. "/app/layout.jsx")
  check("next: layout imports globals", layout:find('import "./globals.css";', 1, true) ~= nil)
  check("next: layout exports RootLayout", layout:find("export default function RootLayout", 1, true) ~= nil)

  local page = read(d .. "/app/page.jsx")
  check("next: page exports a component", page:find("export default function Page()", 1, true) ~= nil)

  local jsconfig = json_of(d .. "/jsconfig.json")
  check("next: jsconfig parses", jsconfig ~= nil)
  if jsconfig then
    check("next: @/ alias mapped", jsconfig.compilerOptions and jsconfig.compilerOptions.paths ~= nil)
  end

  check("next: postcss wired to tailwind", read(d .. "/postcss.config.mjs"):find("@tailwindcss/postcss", 1, true) ~= nil)
  check("next: globals.css is tailwind v4", read(d .. "/app/globals.css"):find('@import "tailwindcss";', 1, true) ~= nil)

  local eslint_cfg = read(d .. "/eslint.config.mjs")
  check("next: flat config spreads core-web-vitals", eslint_cfg:find("...coreWebVitals", 1, true) ~= nil)
  check(
    "next: silences the phantom pages/ warning",
    eslint_cfg:find('"@next/next/no-html-link-for-pages": "off"', 1, true) ~= nil
  )
end

-- ---------------------------------------------------------------------------
print "== next without eslint =="
do
  local d = tmp .. "/verify-next-nolint"
  local created = generate("next", "verify-next-nolint", { "tailwind" })
  check("next-nolint: create closed the wizard", created)
  local pkg = json_of(d .. "/package.json")
  if pkg then
    check("next-nolint: no lint script", pkg.scripts and pkg.scripts.lint == nil)
    check("next-nolint: no eslint dep", pkg.devDependencies == nil or pkg.devDependencies.eslint == nil)
  end
  check("next-nolint: no eslint.config.mjs", not exists(d .. "/eslint.config.mjs"))
  check("next-nolint: tailwind still wired", exists(d .. "/postcss.config.mjs"))
end

-- ---------------------------------------------------------------------------
print "== no leaked Lua comments =="
do
  -- The one check that is NOT a presence assertion, and therefore the only one
  -- capable of catching the bug that cost the most time. Every other section
  -- asks "is string X present"; none of them can notice a string that should
  -- not be there. Lua's `--` had leaked into four generated JS templates and
  -- into application.properties, and the whole suite sailed past it until a
  -- real `vite build` reported PARSE_ERROR.
  --
  -- JS and .properties never use `--` as a comment, so a line starting with it
  -- in one of these files is always the wrong language.
  local function walk(dir, out)
    out = out or {}
    if vim.fn.isdirectory(dir) ~= 1 then return out end
    for _, e in ipairs(vim.fn.readdir(dir)) do
      local p = dir .. "/" .. e
      if vim.fn.isdirectory(p) == 1 then
        if e ~= "node_modules" and e ~= "dist" and e ~= ".next" then walk(p, out) end
      else
        out[#out + 1] = p
      end
    end
    return out
  end

  local bad = {}
  for _, run in ipairs { "vanilla", "vite", "react", "next", "next-nolint" } do
    for _, f in ipairs(walk(tmp .. "/verify-" .. run)) do
      local ext = f:match "%.(%w+)$"
      if ext == "js" or ext == "jsx" or ext == "mjs" or ext == "properties" then
        local n = 0
        for _, line in ipairs(vim.split(read(f), "\n", { plain = true })) do
          if line:match "^%s*%-%- " or line:match "^%s*%-%-%s*$" then
            n = n + 1
          end
        end
        if n > 0 then
          bad[#bad + 1] = f:gsub("\\", "/"):gsub(".*/pgverify3/", "") .. " (" .. n .. " lines)"
        end
      end
    end
  end
  check("no -- comment leaked into a generated JS/properties file", #bad == 0, table.concat(bad, "; "))
end

-- ---------------------------------------------------------------------------
print "== framework compatibility =="
do
  -- Which rows a tab OFFERS is a compatibility decision, not a style choice:
  --   - zustand's `create` is a React hook, so it must not appear on Vanilla or
  --     plain Vite even though its `react` peer is optional and installs fine.
  --   - @testing-library/react peers `react`/`react-dom` NON-optionally, so on
  --     the Vite tab npm silently installed a whole React tree into an app that
  --     has no React and cannot render one.
  --   - jQuery's factory throws at import time with no `window`, and Next
  --     evaluates client modules on the server while prerendering - so it is
  --     unusable there regardless of "use client".
  local function rows_on(run)
    local wiz = pg.wizard(run)
    local names = {}
    for _, l in ipairs(lines(wiz.win)) do
      local _, _, npm_name = l:match "^( %[[ x]%])%s+(%S+)%s+(%S+)"
      if npm_name then names[npm_name] = true end
    end
    press(wiz.win, "q")
    return names
  end

  local v, vi, r, n = rows_on "vanilla", rows_on "vite", rows_on "react", rows_on "next"
  check("vanilla: no zustand", not v.zustand)
  check("vite: no zustand", not vi.zustand)
  check("vite: no @testing-library/react", not vi["@testing-library/react"])
  check("react: offers @testing-library/react", r["@testing-library/react"] == true)
  check("next: no jquery", not n.jquery)
  check("next: offers zustand", n.zustand == true)

  -- "use client" must be the first line, or Next resolves client libraries
  -- through the react-server condition and the build dies on the import.
  local page = read(tmp .. "/verify-next/app/page.jsx")
  check(
    "next: page.jsx starts with \"use client\"",
    page:sub(1, 13) == '"use client";',
    vim.inspect(page:sub(1, 40))
  )

  -- The Vite entry is imported by its own test file under jsdom, where #app
  -- does not exist; an unguarded write threw before any test ran.
  check("vite: created", generate("vite", "verify-fw-vite"))
  local main = read(tmp .. "/verify-fw-vite/src/main.js")
  check("vite: #app write is guarded", main:find("if (root) {", 1, true) ~= nil)
  check("vite: no Lua comment leaked into main.js", (main:find("\n-- ", 1, true)) == nil)

  -- A test that never imports the library it was installed for proves nothing.
  local created =
    generate("react", "verify-react-rtl", { "vitest", "@testing-library/react", "@testing-library/jest-dom" })
  check("react-rtl: created", created)
  local t = read(tmp .. "/verify-react-rtl/src/App.test.jsx")
  check("react-rtl: test renders with RTL", t:find("render(<App />)", 1, true) ~= nil)
  check("react-rtl: test imports jest-dom matchers", t:find("jest-dom/vitest", 1, true) ~= nil)
  check("react-rtl: test asserts through toHaveTextContent", t:find("toHaveTextContent", 1, true) ~= nil)

  -- With vitest but WITHOUT RTL the plain smoke test must still be emitted,
  -- and must not pretend to render anything.
  check("react-plain: created", generate("react", "verify-react-plain", { "vitest" }))
  local plain = read(tmp .. "/verify-react-plain/src/App.test.jsx")
  check("react: plain test emitted without RTL", plain:find("libraryNames", 1, true) ~= nil)
  check("react: plain test does not use RTL", (plain:find("testing-library/react", 1, true)) == nil)
end

-- ---------------------------------------------------------------------------
print "== catalogue hygiene =="
do
  -- Two rows carrying the same npm package inside ONE tab is a real defect, not
  -- cosmetics: they share a tick through state.enabled[id], so the package
  -- would be listed twice in package.json and one line would appear to control
  -- the other. The Next tab regressed exactly this way (axios and dayjs were
  -- offered under both Libraries and React).
  --
  -- Reached through the rendered buffer rather than the private catalogues: if
  -- the wizard draws it, the wizard offers it.
  for _, run in ipairs { "vanilla", "vite", "react", "next" } do
    local wiz = pg.wizard(run)
    local seen, n = {}, 0
    local dupes = {}
    for _, l in ipairs(lines(wiz.win)) do
      -- " [x] <label padded to 26> <npm> <version>  <note>"
      local _, label, npm_name = l:match "^( %[[ x]%])%s+(%S+)%s+(%S+)"
      if npm_name then
        n = n + 1
        if seen[npm_name] then
          dupes[#dupes + 1] = npm_name .. " (also as " .. seen[npm_name] .. ")"
        end
        seen[npm_name] = label
      end
    end
    check(run .. ": offers checklist rows", n > 0, "n=" .. n)
    check(run .. ": no duplicate package rows", #dupes == 0, table.concat(dupes, ", "))
    press(wiz.win, "q")
  end
  check("all wizard instances closed", float_win() == nil)
end

-- ---------------------------------------------------------------------------
print ""
if #failures == 0 then
  print("ALL PASSED")
else
  print(#failures .. " FAILURE(S):")
  for _, f in ipairs(failures) do
    print("  - " .. f)
  end
end

-- os.exit, NOT vim.cmd "quitall!": deferred callbacks can still be queued when
-- the last window closes, and a bare :qa then reports a spurious error.
os.exit(#failures == 0 and 0 or 1)
