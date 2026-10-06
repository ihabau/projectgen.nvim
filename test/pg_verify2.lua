-- Headless verification for lua/projectgen.lua. Run with:
--   nvim --headless -u <config>/init.lua -l pg_verify2.lua -c "qa!"
--
-- The wizard is NON-BLOCKING, which makes this suite much simpler than the
-- blocking picker it replaces: M.wizard() returns {win, buf} synchronously and
-- every key is a buffer-local mapping whose callback can be invoked directly.
-- No vim.wait, no vim.defer_fn, no feedkeys, no watchdog - if a callback throws,
-- the run fails loudly instead of hanging.
--
-- Locate the float by its filetype, NOT by "is relative": command-line and
-- preview windows are relative too (see AGENTS.md).

local tmp = vim.env.PG_VERIFY_DIR
if not tmp or tmp == "" then
  tmp = (vim.env.TEMP or vim.fn.tempname()) .. "\\pgverify2"
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

-- Missing files read as "" rather than throwing, so one absent pom turns into
-- one clear FAIL instead of an E484 that aborts the whole run. CRLF is
-- normalised so these assertions are about content, not line endings.
local function read(path)
  if vim.fn.filereadable(path) == 0 then return "" end
  return table.concat(vim.fn.readfile(path), "\n"):gsub("\r\n", "\n")
end
local function exists(path) return vim.fn.filereadable(path) == 1 end

-- Indentation is 4 SPACES per level, matching IntelliJ and the poms already in
-- school/lexicon. The older suite assumed literal tabs and matched nothing.
local S8, S12, S16 = "        ", "            ", "                "

-- Maven refuses to parse a pom containing two <dependencies> blocks, and that
-- is exactly the defect this suite missed on its first green-ish pass: every
-- presence check still passed while the build died on a parse error. Count the
-- structural tags instead of merely checking they are present.
local function count(haystack, needle)
  local n, pos = 0, haystack:find(needle, 1, true)
  while pos do
    n = n + 1
    pos = haystack:find(needle, pos + 1, true)
  end
  return n
end

local function count_pattern(haystack, pattern)
  local n = 0
  for _ in haystack:gmatch(pattern) do n = n + 1 end
  return n
end

---Assert the structural tags each pom must carry exactly once, and that none
---are closed without being opened. Open tags are matched with `[ >]` so a root
---element carrying attributes (`<project xmlns=...`) still counts, without
---`<projectVersion>` matching `<project`.
local function wellformed(label, pom)
  for _, tag in ipairs { "project", "dependencies", "build", "plugins" } do
    local open = count_pattern(pom, "<" .. tag .. "[ >]")
    local close = count(pom, "</" .. tag .. ">")
    check(label .. ": exactly one <" .. tag .. ">", open == 1, "open=" .. open)
    check(label .. ": exactly one </" .. tag .. ">", close == 1, "close=" .. close)
  end
  check(label .. ": every dependency element is closed", count(pom, "<dependency>") == count(pom, "</dependency>"))
end

---Slice out one <dependency> element by artifactId, so a check can talk about
---"this dependency" without depending on where its tags happen to land. Entries
---carry a trailing <!-- note -->, so the next tag is not always adjacent.
local function block_of(pom, artifact)
  return pom:match("<artifactId>" .. artifact .. "</artifactId>(.-)\n" .. S8 .. "</dependency>")
end
---The wizard's floating window, identified by the filetype the module sets.
local function float_win()
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(w)
    if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].filetype == "projectgen-wizard" then return w end
  end
end

---Press a buffer-local normal-mode key in the float by running its callback.
---@param win integer
---@param key string
local function press(win, key)
  local buf = vim.api.nvim_win_get_buf(win)
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
    if m.lhs == key then
      vim.api.nvim_win_call(win, function()
        m.callback()
      end)
      return
    end
  end
  error("no keymap for " .. key)
end

---@param win integer
---@return string[]
local function lines(win) return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false) end

---Rewrite a field row the way typing into it would, then let the wizard's own
---sync_field read it back on <CR>.
---@param win integer
---@param label string
---@param value string
local function set_field(win, label, value)
  for i, l in ipairs(lines(win)) do
    if l:find(label, 1, true) == 1 or l:find(" " .. label, 1, true) == 1 then
      local pad = label == "Package" and "Package     " or label
      vim.api.nvim_buf_set_lines(vim.api.nvim_win_get_buf(win), i - 1, i, false, { " " .. pad .. ": " .. value })
      return
    end
  end
  error("no field row for " .. label)
end

---Toggle the checklist row whose text contains `needle`.
---@param win integer
---@param needle string
local function tick(win, needle)
  for i, l in ipairs(lines(win)) do
    if l:find(needle, 1, true) then
      vim.api.nvim_win_call(win, function()
        vim.api.nvim_win_set_cursor(win, { i, 0 })
      end)
      press(win, "x")
      return
    end
  end
  error("no row matching " .. needle)
end

---@param win integer
---@param needle string
---@return boolean
local function row_ticked(win, needle)
  for _, l in ipairs(lines(win)) do
    if l:find(needle, 1, true) then return l:find("[x]", 1, true) ~= nil end
  end
  return false
end

---@param win integer
---@return string
local function buffer_text(win) return table.concat(lines(win), "\n") end

local pg = require "projectgen"

print "== commands =="
for _, c in ipairs { "NewProject", "NewJavaProject", "NewSpringBootProject", "NewAndroidProject" } do
  check(c .. " registered", vim.fn.exists(":" .. c) == 2)
end

-- ---------------------------------------------------------------------------
print "== wizard shell =="
vim.fn.chdir(tmp)
do
  local wiz = pg.wizard "java"
  check("wizard returns a window", wiz.win ~= nil and vim.api.nvim_win_is_valid(wiz.win))
  check("wizard buffer filetype", vim.bo[wiz.buf].filetype == "projectgen-wizard")
  check("wizard is a real float", vim.api.nvim_win_get_config(wiz.win).relative == "editor")
  check("java tab active by default", buffer_text(wiz.win):find "%[1 Java%]" ~= nil)
  check("all three tabs rendered", buffer_text(wiz.win):find "Spring Boot" ~= nil and buffer_text(wiz.win):find "Android" ~= nil)
  check("junit ticked by default", row_ticked(wiz.win, "junit-jupiter"))
  check("help footer rendered", buffer_text(wiz.win):find "<CR> create" ~= nil)
  press(wiz.win, "2")
  check("tab 2 switches to spring", buffer_text(wiz.win):find "%[2 Spring Boot%]" ~= nil)
  check("spring defaults to webmvc", row_ticked(wiz.win, "spring-boot-starter-webmvc"))
  check("spring name field follows the tab", buffer_text(wiz.win):find "hello%-spring" ~= nil)
  press(wiz.win, "3")
  check("tab 3 switches to android", buffer_text(wiz.win):find "%[3 Android%]" ~= nil)
  check("android has its own checklist", buffer_text(wiz.win):find "core%-ktx" ~= nil)
  press(wiz.win, "1")
  check("tab 1 returns to java", buffer_text(wiz.win):find "%[1 Java%]" ~= nil)
  press(wiz.win, "q")
  check("q closes the wizard", float_win() == nil)
end

-- ---------------------------------------------------------------------------
print "== java (maven) =="
do
  vim.fn.chdir(tmp)
  local wiz = pg.wizard "java"
  press(wiz.win, "n") -- clear the defaults, tick exactly what we assert on
  set_field(wiz.win, "Project name", "verify-java")
  set_field(wiz.win, "Package", "com.example.verifyjava")
  tick(wiz.win, "org.junit.jupiter:junit-jupiter")
  tick(wiz.win, "org.projectlombok:lombok")
  tick(wiz.win, "org.assertj:assertj-core")
  press(wiz.win, "<CR>")

  check("wizard closed after create", float_win() == nil)
  local jdir = tmp .. "/verify-java"
  check("pom.xml written", exists(jdir .. "/pom.xml"))
  check("Main.java written", exists(jdir .. "/src/main/java/com/example/verifyjava/Main.java"))
  check("MainTest.java written", exists(jdir .. "/src/test/java/com/example/verifyjava/MainTest.java"))
  check(".gitignore written", exists(jdir .. "/.gitignore"))
  check("gitignore ignores target", read(jdir .. "/.gitignore"):find "target/" ~= nil)
  check("no gradle files", not exists(jdir .. "/build.gradle"))

  local jpom = read(jdir .. "/pom.xml")
  wellformed("java pom", jpom)
  check("groupId is the package", jpom:find "<groupId>com.example.verifyjava</groupId>" ~= nil)
  check("artifactId is the name", jpom:find "<artifactId>verify%-java</artifactId>" ~= nil)
  check("no spring parent", not jpom:find "spring%-boot%-starter%-parent")
  -- Indentation is 4 SPACES per level; see S8/S12 above.
  check(
    "junit-jupiter 5.11.4 scope test, adjacent",
    jpom:find("<artifactId>junit%-jupiter</artifactId>\n" .. S12 .. "<version>5%.11%.4</version>\n" .. S12 .. "<scope>test</scope>") ~= nil,
    jpom:match "<artifactId>junit%-jupiter</artifactId>.-\n" .. S8 .. "</dependency>"
  )
  -- Standalone Java has no BOM, so lombok must carry an explicit version and
  -- `provided` scope. The version is the one Boot 4.1.1 manages, so the whole
  -- coursework ends up on one lombok.
  check(
    "lombok 1.18.46 scope provided, adjacent",
    jpom:find("<artifactId>lombok</artifactId>\n" .. S12 .. "<version>1%.18%.46</version>\n" .. S12 .. "<scope>provided</scope>") ~= nil,
    block_of(jpom, "lombok") and (block_of(jpom, "lombok"):gsub("%s+", " ")) or "no element found"
  )
  check("assertj present", jpom:find "assertj%-core" ~= nil)
  -- No parent here, so the compiler plugin must state <release> itself.
  check("compiler release 21", jpom:find "<release>21</release>" ~= nil)
  check("compiler plugin pinned (no parent)", jpom:match "maven%-compiler%-plugin</artifactId>\n" .. S12 .. "<version>" ~= nil)
  check("annotationProcessorPaths present", jpom:find "annotationProcessorPaths" ~= nil)
  check("surefire present for junit", jpom:find "maven%-surefire%-plugin" ~= nil)
  check("surefire pinned (no parent)", jpom:match "maven%-surefire%-plugin</artifactId>\n" .. S12 .. "<version>" ~= nil)
  check("no spring boot plugin", jpom:find "spring%-boot%-maven%-plugin" == nil)
  check("mvnw written", exists(jdir .. "/mvnw"))
  check("mvnw.cmd written", exists(jdir .. "/mvnw.cmd"))
  check("wrapper properties written", exists(jdir .. "/.mvn/wrapper/maven-wrapper.properties"))
  check("no security dep", jpom:find "starter%-security" == nil)
  check("no swagger dep", jpom:find "springdoc" == nil)
end

-- A no-test-dependency project must not get a test source it cannot compile.
do
  vim.fn.chdir(tmp)
  local wiz = pg.wizard "java"
  press(wiz.win, "n")
  set_field(wiz.win, "Project name", "verify-bare")
  set_field(wiz.win, "Package", "com.example.verifybare")
  press(wiz.win, "<CR>")
  local bdir = tmp .. "/verify-bare"
  check("bare pom written", exists(bdir .. "/pom.xml"))
  check("no test source without a test dep", not exists(bdir .. "/src/test/java/com/example/verifybare/MainTest.java"))
  check("no dependencies block when empty", read(bdir .. "/pom.xml"):find "<dependencies>" == nil)
  check("no surefire when no test dep", read(bdir .. "/pom.xml"):find "surefire" == nil)
end

-- ---------------------------------------------------------------------------
print "== spring (maven, boot 4) =="
do
  vim.fn.chdir(tmp)
  local wiz = pg.wizard "spring"
  set_field(wiz.win, "Project name", "verify-spring")
  set_field(wiz.win, "Package", "com.example.verifyspring")
  tick(wiz.win, "spring-boot-starter-data-jpa:")
  tick(wiz.win, "spring-boot-starter-data-jpa-test")
  tick(wiz.win, "springdoc-openapi-starter-webmvc-ui")
  tick(wiz.win, "com.h2database:h2")
  press(wiz.win, "<CR>")

  check("wizard closed after create", float_win() == nil)
  local sdir = tmp .. "/verify-spring"
  check("pom.xml written", exists(sdir .. "/pom.xml"))
  check("no gradle files", not exists(sdir .. "/build.gradle"))
  local sjava = vim.fn.glob(sdir .. "/src/main/java/com/example/verifyspring/*.java", false, true)
  check("exactly one application source", #sjava == 1, table.concat(sjava, ","))
  check(
    "application class name matches file",
    sjava[1] ~= nil and vim.fn.fnamemodify(sjava[1], ":t") == "VerifyspringApplication.java",
    sjava[1] and vim.fn.fnamemodify(sjava[1], ":t") or "none"
  )
  check("application.properties written", exists(sdir .. "/src/main/resources/application.properties"))

  local spom = read(sdir .. "/pom.xml")
  wellformed("spring pom", spom)
  check(
    "parent 4.1.1",
    spom:find("spring%-boot%-starter%-parent</artifactId>\n" .. S8 .. "<version>4%.1%.1</version>") ~= nil
  )
  -- A managed starter must carry neither <version> nor <scope>; use block_of
  -- (file scope) rather than expecting adjacent tags.
  local webmvc_block = block_of(spom, "spring%-boot%-starter%-webmvc")
  check(
    "managed starter has no version/scope",
    webmvc_block ~= nil and not webmvc_block:find("<version>") and not webmvc_block:find("<scope>"),
    webmvc_block and ("block=" .. (webmvc_block:gsub("%s+", " "))) or "no element found"
  )
  check("webmvc selected at all", webmvc_block ~= nil)
  local jpa_block = block_of(spom, "spring%-boot%-starter%-data%-jpa")
  check("second managed starter also clean", jpa_block ~= nil and not jpa_block:find("<version>"))
  -- NOT managed by the Boot BOM, so it needs an explicit version...
  local doc_block = block_of(spom, "springdoc%-openapi%-starter%-webmvc%-ui")
  check(
    "springdoc pins its own version 3.0.0",
    doc_block ~= nil and doc_block:find("<version>3%.0%.0</version>") ~= nil,
    doc_block and (doc_block:gsub("%s+", " ")) or "no element found"
  )
  -- ...while h2 IS in the BOM: scope yes, version no. And because JPA was
  -- ticked, h2 must be promoted from test to RUNTIME scope or the app cannot
  -- boot (this exact scaffold failed with "no suitable driver class").
  local h2_block = block_of(spom, "h2")
  check(
    "h2 gets a scope but no version",
    h2_block ~= nil and h2_block:find("<scope>runtime</scope>") ~= nil and h2_block:find("<version>") == nil,
    h2_block and (h2_block:gsub("%s+", " ")) or "no element found"
  )
  check(
    "h2 promoted to runtime when JPA ticked",
    h2_block ~= nil and not h2_block:find("<scope>test</scope>", 1, true),
    h2_block and (h2_block:gsub("%s+", " ")) or "no element found"
  )
  check("boot plugin present", spom:find "spring%-boot%-maven%-plugin" ~= nil)
  check("boot plugin has no pinned version", not spom:match("spring%-boot%-maven%-plugin</artifactId>\n" .. S12 .. "<version>"))
  -- The Boot parent supplies every plugin version AND drives
  -- maven.compiler.release from <java.version>, exactly like IntelliJ and the
  -- school/lexicon poms. Pinning either here would drift when Boot moves.
  check("java.version is 17 (parent drives release)", spom:find "<java%.version>17</java%.version>" ~= nil)
  check("no redundant sourceEncoding property", spom:find "project%.build%.sourceEncoding" == nil)
  check("no explicit <release> under a Boot parent", spom:find "<release>" == nil)
  check("surefire not pinned under a Boot parent", not spom:match("maven%-surefire%-plugin</artifactId>\n" .. S12 .. "<version>"))
  check("compiler plugin omitted when no annotation processors", spom:find "maven%-compiler%-plugin" == nil)
-- IntelliJ's placeholder blocks, so a generated pom is comparable with theirs.
  -- url/license/developer are self-closing; licenses/developers/scm are containers.
  for _, tag in ipairs { "url", "license", "developer" } do
    check("intellij placeholder <" .. tag .. " />", spom:find("<" .. tag .. " />", 1, true) ~= nil)
  end
  for _, tag in ipairs { "licenses", "developers", "scm" } do
    check("intellij placeholder <" .. tag .. ">", spom:find("<" .. tag .. ">", 1, true) ~= nil)
    check("intellij placeholder </" .. tag .. ">", spom:find("</" .. tag .. ">", 1, true) ~= nil)
  end
  check("scm carries IntelliJ's four empty children", spom:find("<connection />", 1, true) ~= nil and spom:find("<tag />", 1, true) ~= nil)
  -- Ticking a test starter must actually produce a runnable test.
  local tsrc = read(sdir .. "/src/test/java/com/example/verifyspring/VerifyspringApplicationTests.java")
  check("context-load test generated", tsrc:find "@SpringBootTest" ~= nil)
  check("context-load test names the app class", tsrc:find "class VerifyspringApplicationTests" ~= nil)
  check("context-load test has a @Test method", tsrc:find "void contextLoads%(" ~= nil)
  -- Maven wrapper, so the project builds the same way on every machine.
  check("mvnw written", exists(sdir .. "/mvnw"))
  check("mvnw.cmd written", exists(sdir .. "/mvnw.cmd"))
  check("wrapper properties written", exists(sdir .. "/.mvn/wrapper/maven-wrapper.properties"))
  check("wrapper pins a concrete maven version", read(sdir .. "/.mvn/wrapper/maven-wrapper.properties"):find "apache%-maven%-%d+%.%d+%.%d+%-bin%.zip" ~= nil)
  check("no bare security (never ticked)", spom:find "starter%-security" == nil)
end

-- ---------------------------------------------------------------------------
-- Regression: ticking JPA without ticking H2 produced a pom whose only driver
-- was test-scoped, so the generated app died at boot with
-- "Failed to determine a suitable driver class". H2 must be pulled in at
-- runtime scope on the user's behalf.
print "== spring: JPA implies a runtime driver =="
do
  vim.fn.chdir(tmp)
  local wiz = pg.wizard "spring"
  set_field(wiz.win, "Project name", "verify-jpaonly")
  set_field(wiz.win, "Package", "com.example.verifyjpaonly")
  press(wiz.win, "n") -- clear defaults, including the H2 tick
  tick(wiz.win, "spring-boot-starter-data-jpa:")
  press(wiz.win, "<CR>")
  check("created with jpa and no explicit h2", vim.fn.isdirectory(tmp .. "/verify-jpaonly") == 1)

  local jpom = read(tmp .. "/verify-jpaonly/pom.xml")
  wellformed("jpa-only pom", jpom)
  local blk = block_of(jpom, "h2")
  check(
    "h2 auto-added at runtime scope",
    blk ~= nil and blk:find("<scope>runtime</scope>", 1, true) ~= nil,
    blk and (blk:gsub("%s+", " ")) or "no element found"
  )
  check("h2 stays version-free (BOM-managed)", blk ~= nil and blk:find "<version>" == nil)
end

-- Without JPA the promotion must not happen: H2 is still a test dependency.
print "== spring: h2 stays test-scoped without jpa =="
do
  vim.fn.chdir(tmp)
  local wiz = pg.wizard "spring"
  set_field(wiz.win, "Project name", "verify-h2only")
  set_field(wiz.win, "Package", "com.example.verifyh2only")
  press(wiz.win, "n")
  tick(wiz.win, "com.h2database:h2")
  press(wiz.win, "<CR>")
  local hblock = block_of(read(tmp .. "/verify-h2only/pom.xml"), "h2")
  check(
    "h2 keeps test scope when no datasource starter is ticked",
    hblock ~= nil and hblock:find("<scope>test</scope>", 1, true) ~= nil,
    hblock and (hblock:gsub("%s+", " ")) or "no element found"
  )
end

-- ---------------------------------------------------------------------------
-- Under a Boot parent, lombok must be written the way IntelliJ writes it:
-- <optional>true</optional>, no version, no scope, with the version coming from
-- annotationProcessorPaths-less configuration. school/lexicon poms agree.
print "== spring: lombok is BOM-managed =="
do
  vim.fn.chdir(tmp)
  local wiz = pg.wizard "spring"
  set_field(wiz.win, "Project name", "verify-lombok")
  set_field(wiz.win, "Package", "com.example.verifylombok")
  press(wiz.win, "n")
  tick(wiz.win, "org.projectlombok:lombok")
  press(wiz.win, "<CR>")

  local dir = tmp .. "/verify-lombok"
  local pom = read(dir .. "/pom.xml")
  wellformed("lombok pom", pom)
  local blk = block_of(pom, "lombok")
  check("lombok present", blk ~= nil, blk and (blk:gsub("%s+", " ")) or "no element found")
  check("lombok has no version under Boot", blk ~= nil and blk:find("<version>") == nil)
  check("lombok has no scope under Boot", blk ~= nil and blk:find("<scope>") == nil)
  check(
    "lombok marked optional",
    blk ~= nil and blk:find("<optional>true</optional>", 1, true) ~= nil,
    blk and (blk:gsub("%s+", " ")) or "no element found"
  )
  -- The compiler plugin now exists solely to carry the processor path.
  check("compiler plugin added for the processor", pom:find "maven%-compiler%-plugin" ~= nil)
  check("compiler plugin still unpinned", not pom:match("maven%-compiler%-plugin</artifactId>\n" .. S12 .. "<version>"))
  check("annotationProcessorPaths present", pom:find "annotationProcessorPaths" ~= nil)
  check(
    "processor path version-free under Boot",
    not pom:match("annotationProcessorPaths>.-<artifactId>lombok</artifactId>\n" .. S16 .. "<version>"),
    "found a pinned version on the lombok processor path"
  )
end

-- ---------------------------------------------------------------------------
print "== spring validation =="
do
  vim.fn.chdir(tmp)
  local wiz = pg.wizard "spring"
  set_field(wiz.win, "Project name", "verify-badpkg")
  set_field(wiz.win, "Package", "com..bad")
  press(wiz.win, "<CR>")
  check("wizard stays open on a bad package", float_win() ~= nil)
  check("error is shown in the float", buffer_text(float_win()):find "empty segment" ~= nil)
  check("bad package writes nothing", vim.fn.isdirectory(tmp .. "/verify-badpkg") == 0)
  press(float_win(), "q")
  check("wizard closed after cancel", float_win() == nil)

  -- A non-empty target must be refused, and the float must survive to say so.
  local wiz2 = pg.wizard "spring"
  set_field(wiz2.win, "Project name", "verify-spring")
  set_field(wiz2.win, "Package", "com.example.verifyspring")
  press(wiz2.win, "<CR>")
  check("existing dir refused, float stays open", float_win() ~= nil)
  check("refusal explains why", buffer_text(float_win()):find "not empty" ~= nil)
  press(float_win(), "q")
end

-- ---------------------------------------------------------------------------
print "== android (gradle, deps now tickable) =="
do
  vim.fn.chdir(tmp)
  local wiz = pg.wizard "android"
  set_field(wiz.win, "Project name", "verify-android")
  set_field(wiz.win, "Package", "com.example.verifyandroid")
  tick(wiz.win, "com.google.android.material:material")
  tick(wiz.win, "androidx.room:room-runtime")
  tick(wiz.win, "androidx.test.espresso:espresso-core")
  press(wiz.win, "<CR>")

  check("wizard closed after create", float_win() == nil)
  local adir = tmp .. "/verify-android"
  check("settings.gradle.kts", exists(adir .. "/settings.gradle.kts"))
  check("build.gradle.kts", exists(adir .. "/build.gradle.kts"))
  check("app/build.gradle.kts", exists(adir .. "/app/build.gradle.kts"))
  check("AndroidManifest.xml", exists(adir .. "/app/src/main/AndroidManifest.xml"))
  check("MainActivity.kt", exists(adir .. "/app/src/main/java/com/example/verifyandroid/MainActivity.kt"))
  check("strings.xml", exists(adir .. "/app/src/main/res/values/strings.xml"))
  check("themes.xml", exists(adir .. "/app/src/main/res/values/themes.xml"))
  check("no pom.xml in android project", not exists(adir .. "/pom.xml"))
  local abuild = read(adir .. "/app/build.gradle.kts")
  -- Minor API levels (android-36.1) cannot be expressed by the flat
  -- `compileSdk = N` form at all, so the block form is required here.
  check("compileSdk uses the block form", abuild:match "compileSdk %{" ~= nil)
  check("compileSdk release() is an integer", abuild:match "release%(%d+%) %{" ~= nil)
  check("compileSdk sets minorApiLevel", abuild:match "minorApiLevel = %d+" ~= nil)
  -- release(36) { } RETURNS a value; only assigning it to `version` actually
  -- sets compileSdk. Without `version =` AGP fails configuration outright.
  check("compileSdk assigns release() to version", abuild:match "version = release%(%d+%) %{" ~= nil)
  check("targetSdk stays an integer", abuild:match "targetSdk = %d+" ~= nil)
  -- minSdk is what decides the oldest DEVICE, and must stay independent of
  -- compileSdk - a high compileSdk does not mean "old phones excluded".
  check("minSdk independent of compileSdk", abuild:match "minSdk = 24" ~= nil)
  check("default core-ktx kept", abuild:find "androidx.core:core%-ktx" ~= nil)
  check("ticked material emitted", abuild:find "com.google.android.material:material:1.12.0" ~= nil)
  check("ticked room emitted", abuild:find "androidx.room:room%-runtime:2.6.1" ~= nil)
  check("espresso goes to androidTest", abuild:find 'androidTestImplementation%("androidx.test.espresso:espresso%-core' ~= nil)
  check("theme follows the material tick", read(adir .. "/app/src/main/res/values/themes.xml"):find "Material3" ~= nil)
  check("local.properties from ANDROID_HOME", vim.fn.filereadable(adir .. "/local.properties") == 1)

  -- Android Studio's own project shape, so opening it does not look half-built.
  check("viewBinding enabled", abuild:find "viewBinding = true" ~= nil)
  check(
    "instrumentation runner declared",
    abuild:find 'testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"' ~= nil
  )
  check("proguardFiles wired up", abuild:find "proguard%-rules%.pro" ~= nil)
  check("proguard-rules.pro written", exists(adir .. "/app/proguard-rules.pro"))
  check("colors.xml written", exists(adir .. "/app/src/main/res/values/colors.xml"))
  check("night themes written", exists(adir .. "/app/src/main/res/values-night/themes.xml"))
  check("backup_rules.xml written", exists(adir .. "/app/src/main/res/xml/backup_rules.xml"))
  check("data_extraction_rules.xml written", exists(adir .. "/app/src/main/res/xml/data_extraction_rules.xml"))

  -- A manifest attribute pointing at a missing resource fails at link time, so the
  -- two rules files and the attributes referencing them must both be present.
  local man = read(adir .. "/app/src/main/AndroidManifest.xml")
  check("manifest references backup_rules", man:find "android:fullBackupContent=\"@xml/backup_rules\"" ~= nil)
  check("manifest references data_extraction_rules", man:find "android:dataExtractionRules=\"@xml/data_extraction_rules\"" ~= nil)

  -- material was ticked, so the layout + viewbinding activity is the right choice.
  check("activity_main.xml written", exists(adir .. "/app/src/main/res/layout/activity_main.xml"))
  local act = read(adir .. "/app/src/main/java/com/example/verifyandroid/MainActivity.kt")
  check("activity extends AppCompatActivity", act:find "AppCompatActivity" ~= nil)
  check("activity uses view binding", act:find "ActivityMainBinding" ~= nil)
  check("no dead framework import left behind", act:find "import android.app.Activity" == nil)
  -- espresso was ticked but androidx.test.ext:junit was not, so the instrumented
  -- test must NOT be written: it imports @RunWith(AndroidJUnit4), which needs it.
  check(
    "no instrumented test without androidx.test.ext:junit",
    not exists(adir .. "/app/src/androidTest/java/com/example/verifyandroid/ExampleInstrumentedTest.kt")
  )

  -- Gradle's version is pinned even though gradlew cannot be generated.
  local gwp = read(adir .. "/gradle/wrapper/gradle-wrapper.properties")
  check("gradle wrapper properties written", gwp:find "distributionUrl=" ~= nil)
  -- AGP 8.13 requires Gradle 8.13; the two must not drift apart.
  check("gradle distribution pinned to a version", gwp:find "gradle%-%d+%.%d+%-bin%.zip" ~= nil)
  check("gradle matches the AGP minimum", gwp:find "gradle%-8%.13%-bin" ~= nil)
  local agp = read(adir .. "/build.gradle.kts")
  check("AGP 8.13 (reaches API 36.1)", agp:find 'id%("com%.android%.application"%) version "8%.13%.0"' ~= nil)
  check("no AGP 8.7 left behind", agp:find "8%.7%.3" == nil)
  check("no gradle-wrapper.jar claimed", not exists(adir .. "/gradle/wrapper/gradle-wrapper.jar"))
end

-- The dependency-free template must still work when nothing is ticked: it uses
-- framework APIs only, so it cannot reference a library that is absent.
print "== android: bare project uses framework APIs only =="
do
  vim.fn.chdir(tmp)
  local wiz = pg.wizard "android"
  set_field(wiz.win, "Project name", "verify-android-bare")
  set_field(wiz.win, "Package", "com.example.verifyandroidbare")
  press(wiz.win, "n")
  press(wiz.win, "<CR>")

  local adir = tmp .. "/verify-android-bare"
  local act = read(adir .. "/app/src/main/java/com/example/verifyandroidbare/MainActivity.kt")
  check("bare activity extends framework Activity", act:find "class MainActivity : Activity%(" ~= nil)
  check("bare activity needs no appcompat", act:find "AppCompatActivity" == nil)
  check("bare project has no layout", not exists(adir .. "/app/src/main/res/layout/activity_main.xml"))
  check("bare project still writes the rules files", exists(adir .. "/app/proguard-rules.pro"))
  check("bare project pins gradle too", exists(adir .. "/gradle/wrapper/gradle-wrapper.properties"))
end

-- appcompat ticked WITHOUT constraintlayout: the layout must not reference
-- ConstraintLayout, or the build fails at resource linking.
print "== android: layout avoids unticked constraintlayout =="
do
  vim.fn.chdir(tmp)
  local wiz = pg.wizard "android"
  set_field(wiz.win, "Project name", "verify-android-nocl")
  set_field(wiz.win, "Package", "com.example.verifyandroidnocl")
  press(wiz.win, "n")
  tick(wiz.win, "androidx.appcompat:appcompat")
  press(wiz.win, "<CR>")

  local adir = tmp .. "/verify-android-nocl"
  local layout = read(adir .. "/app/src/main/res/layout/activity_main.xml")
  check("layout written for appcompat", #layout > 0)
  check("layout avoids ConstraintLayout", layout:find "ConstraintLayout" == nil, layout:gsub("\n", " "))
  check("layout uses the framework root instead", layout:find "<LinearLayout" ~= nil)
end

-- Ticking the AndroidX test runner must produce a test that can actually compile.
print "== android: androidx test runner produces the instrumented test =="
do
  vim.fn.chdir(tmp)
  local wiz = pg.wizard "android"
  set_field(wiz.win, "Project name", "verify-android-at")
  set_field(wiz.win, "Package", "com.example.verifyandroidat")
  press(wiz.win, "n")
  tick(wiz.win, "androidx.test.ext:junit")
  tick(wiz.win, "junit:junit")
  press(wiz.win, "<CR>")

  local adir = tmp .. "/verify-android-at"
  local abuild = read(adir .. "/app/build.gradle.kts")
  check("androidx-junit goes to androidTest", abuild:find 'androidTestImplementation%("androidx.test.ext:junit' ~= nil)
  check("junit goes to testImplementation", abuild:find 'testImplementation%("junit:junit' ~= nil)
  local it = read(adir .. "/app/src/androidTest/java/com/example/verifyandroidat/ExampleInstrumentedTest.kt")
  -- parentheses are magic in Lua patterns, so they have to be escaped here.
  check("instrumented test written", it:find "@RunWith%(AndroidJUnit4::class%)" ~= nil)
  check("instrumented test asserts the package", it:find "com.example.verifyandroidat" ~= nil)
  local ut = read(adir .. "/app/src/test/java/com/example/verifyandroidat/ExampleUnitTest.kt")
  check("unit test written", ut:find "addition_isCorrect" ~= nil)
end

print "== summary =="
print("tmpdir=" .. tmp)
-- os.exit, NOT vim.cmd "quitall!": deferred callbacks can still be queued when
-- the script body ends, and quitall lets them print after the summary.
if #failures > 0 then
  print(string.format("FAILED %d:", #failures))
  for _, f in ipairs(failures) do
    print("  - " .. f)
  end
  io.stdout:flush()
  os.exit(1)
else
  print "all assertions passed"
  io.stdout:flush()
  os.exit(0)
end
