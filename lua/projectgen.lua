-- projectgen: IntelliJ-style "New Project" for Java / Spring Boot / Android /
-- Vanilla JS / Vite / React / Next.js.
--
-- Distributed as the standalone plugin `ihabau/projectgen.nvim`.
--
-- ================================ WHAT IT IS ================================
-- A single floating window that stands in for IntelliJ's "New Project" dialog.
-- Seven tabs (Java, Spring Boot, Android, Vanilla JS, Vite, React, Next.js)
-- live in that one window: you edit the project name and package as ordinary
-- text, tick the dependencies you want from a checklist, and press Create. Each
-- tick becomes a real coordinate in the build file - a Maven <dependency> for
-- Java and Spring, a Gradle dependency for Android, an npm dependency for the
-- frontend tabs - so the generated project opens with its dependencies already
-- resolved instead of a skeleton you have to fill in by hand.
--
--   :NewProject             open the wizard (Java tab)
--   :NewJavaProject         open it on the Java tab       <Leader>pv
--   :NewSpringBootProject   open it on the Spring tab      <Leader>ps
--   :NewAndroidProject      open it on the Android tab     <Leader>pa
--   :NewVanillaJSProject    open it on the JS tab          <Leader>pb
--   :NewViteProject         open it on the Vite tab        <Leader>pt
--   :NewReactProject        open it on the React tab       <Leader>pr
--   :NewNextJSProject       open it on the Next.js tab     <Leader>px
--                                            :NewProject  <Leader>pn
--
-- The wizard is the one flow: each per-type command just opens it on another
-- tab. There is deliberately no second, tab-less code path - two would drift.
-- WHAT YOU GET:
--   Java    pom.xml (Maven, release 21) + Main.java + a JUnit 5 test + mvnw
--   Spring  pom.xml (Boot 4.1.1 parent, release 17) + the @SpringBootApplication
--           class + application.properties + an @SpringBootTest context-load
--           test + mvnw. Plugin versions are left to the Boot parent, and
--           Lombok is written the way IntelliJ writes it, so the pom matches
--           the ones IntelliJ produces and the ones under school/lexicon.
--   Android settings/build gradle.kts, app module, manifest, a themed
--           MainActivity, layouts, colours, backup rules, ProGuard rules and
--           test stubs.
--
-- THE POMS ARE OFFLINE-GENERATED. Spring does not download a start.spring.io
-- zip; the catalogue below is the source of truth, which is faster and immune to
-- the service being down.
--
-- ============================ WHY IT LOOKS THIS WAY ==========================
-- WHY THIS IS A STANDALONE PLUGIN AND HOW ITS COMMANDS GET REGISTERED:
-- it was a plain module inside one user's nvim-config, consumed as
--   require("projectgen").setup()
-- from the config's lazy setup. It is now the standalone repo
-- `ihabau/projectgen.nvim`. `plugin/projectgen.lua` calls M.setup() when the
-- plugin loads, so a bare `{ "ihabau/projectgen.nvim" }` spec gets all eight
-- commands with no further wiring; M.setup() is idempotent so a config that
-- wants command registration under its own control can call it too.
-- Nothing here loads configuration or writes files at load time - the only
-- thing plugin/projectgen.lua does is register inert user commands.
--
--
-- DESIGN CONSTRAINTS, all deliberate:
-- * NOTHING RUNS AT LOAD TIME. Every entry point is an explicit user command.
--   These write files to disk; a config that did that on startup would be
--   unacceptable.
-- * AN EXISTING NON-EMPTY DIRECTORY IS ALWAYS REFUSED. No `--force`, no
--   overwriting. A generator that clobbers your work is worse than no generator.
-- * FULLY OFFLINE. Nothing here touches the network.
-- * MAVEN FOR JAVA AND SPRING, GRADLE FOR ANDROID. The Android Gradle Plugin is
--   not distributed for Maven, so that one project has no choice.
--
--
-- THE WIZARD NEVER BLOCKS. An earlier revision drove the checklist from inside
-- `vim.wait(math.huge, function() return done end)`. `vim.wait` parks the main
-- loop in `os_inchar`/event polling, and a mapping registered inside a float is
-- not reachable while that happens - the float appeared and then swallowed every
-- keystroke, which reads to the user as "the popup is frozen". Nothing here
-- waits. Every interaction mutates state and redraws; Create is the only key
-- that ends the flow.
--
-- FIELDS ARE EDITED IN THE BUFFER, not with `vim.fn.input`. `input()` is modal
-- and blocks for the same reason. The name and package rows are real text: press
-- `i` / `A` / `x` on them like any other line.
--
-- THE MAVEN WRAPPER IS GENERATED, THE GRADLE ONE IS NOT. Maven's wrapper works
-- script-only (`distributionType=script`), so mvnw, mvnw.cmd and
-- maven-wrapper.properties are all plain text and are written from
-- lua/projectgen/wrapper/. Gradle's wrapper hard-requires the binary
-- gradle-wrapper.jar - delete it and gradlew.bat dies with "Unable to access
-- jarfile" - so only its gradle-wrapper.properties is written and the generator
-- prints the one command that fills in the rest.

local M = {}

---Namespace for the wizard's own highlights. Not needed outside this module.
local ns = vim.api.nvim_create_namespace("projectgen_wizard")

---@param msg string
---@param level integer|nil
local function notify(msg, level)
	vim.notify("projectgen: " .. msg, level or vim.log.levels.INFO)
end

---@param s string
---@return string
local function slugify(s)
	return (s:gsub("[^%w%._-]", "-"):gsub("%-+", "-"))
end

---Turn a project name into a usable Java class name: strip everything that is
---not alphanumeric, then capitalise. "verify-spring" -> "Verifyspring".
---@param name string
---@return string|nil
local function class_name(name)
	local id = name:gsub("[^%w]", "")
	if id == "" then
		return nil
	end
	return (id:gsub("^%l", string.upper))
end

---Validate a package name and turn it into a source path.
---@param pkg string
---@return string|nil path, string|nil err
local function pkg_path(pkg)
	if pkg == "" then
		return nil, "package must not be empty"
	end
	-- Reject empty segments first: "com..demo" and ".com" would otherwise slip
	-- through the gmatch loop below (gmatch skips empty runs) and turn into a
	-- source path with an empty directory in it.
	if pkg:match("%.%.") or pkg:match("^%.") or pkg:match("%.$") then
		return nil, "package has an empty segment (leading, trailing or doubled '.')"
	end
	-- Deliberately NO whole-string `^%a[%w_]*$` check here. That pattern is
	-- anchored at BOTH ends, so it rejects every real package name, because
	-- "com.acme.demo" contains dots. It is per-segment validation that matters.
	for part in pkg:gmatch("[^%.]+") do
		-- `%w[_]*` would be too loose: a Java identifier cannot start with a digit.
		if not part:match("^%a[%w_]*$") then
			return nil, "package segment '" .. part .. "' is not a valid Java identifier"
		end
	end
	return (pkg:gsub("%.", "/")), nil
end

---Validate an npm package name.
---
---This is deliberately NOT `pkg_path()`. npm's rules differ from Java's in both
---directions: `com.example.demo` is a perfectly legal npm name, while an npm
---name may not contain uppercase or spaces at all. Reusing the Java check would
---reject valid names, and the reverse re-use would accept names the registry
---refuses (`npm publish` fails with EINVALIDPACKAGENAME), which is a much worse
---place to find out.
---@param name string
---@return string|nil _, string|nil err
local function npm_name(name)
	if name == "" then
		return nil, "npm name must not be empty"
	end
	if #name > 214 then
		return nil, "npm name must be 214 characters or fewer"
	end
	if name:match("^[%._]") then
		return nil, "npm name may not start with '.' or '_'"
	end
	if name ~= name:lower() then
		return nil, "npm name must be lowercase"
	end
	if name:find("%s") then
		return nil, "npm name may not contain spaces"
	end
	-- Everything else is the registry's own character set.
	if not name:match("^[a-z0-9][a-z0-9._%-]*$") then
		return nil, "npm name may only contain a-z, 0-9, '.', '_' and '-'"
	end
	return name, nil
end

---Refuse to touch a directory that already has content.
---@param path string
---@return boolean ok, string|nil err
local function dir_is_free(path)
	local stat = vim.uv.fs_stat(path)
	if not stat then
		return true
	end
	if stat.type ~= "directory" then
		return false, path .. " exists and is not a directory"
	end
	if #vim.fn.readdir(path) > 0 then
		return false, path .. " already exists and is not empty"
	end
	return true
end

---Write a file, creating parent directories first.
---
---The "b" flag forces LF line endings. Without it writefile translates to CRLF on
---Windows, and a generated pom.xml then differs from every other pom in the repo
---for no reason.
---@param path string
---@param lines string[]
local function write(path, lines)
	vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
	vim.fn.writefile(lines, path, "b")
end

---Resolve where the project directory should live.
---@param name string
---@return string|nil dir, string|nil err
local function resolve_dir(name)
	if not name or name == "" then
		return nil, "cancelled"
	end
	local base = vim.fn.getcwd()
	local dir = base .. "/" .. name
	local ok, err = dir_is_free(dir)
	if not ok then
		return nil, err
	end
	return dir, nil
end

---Where this module's own non-Lua assets live, resolved once at load time from
---`debug.getinfo` so it does not depend on the cwd (the generators chdir).
---`lua/projectgen/wrapper/` holds the Maven Wrapper scripts verbatim.
local ASSET_DIR = (function()
	local src = debug.getinfo(1, "S").source
	if not src or src:sub(1, 1) ~= "@" then
		return nil
	end
	return vim.fn.fnamemodify(vim.fn.fnamemodify(src:sub(2), ":p"), ":h") .. "/projectgen"
end)()

---Maven version the generated wrapper pins. The wrapper downloads this on first
---use, which is the whole point of shipping it: everyone builds with the same
---Maven, without installing it.
local WRAPPER_MAVEN_VERSION = "3.9.9"
local WRAPPER_VERSION = "3.3.4"

---Write `mvnw`, `mvnw.cmd` and `.mvn/wrapper/maven-wrapper.properties`.
---
---The wrapper is script-only (`distributionType=script`), so nothing binary is
---involved - the scripts bootstrap themselves from `distributionUrl` on first
---run. That is what makes it writable from Lua, and it is why the earlier
---"no wrapper is generated" note no longer holds: the blocker was always the
---`maven-wrapper.jar`, not the scripts.
---@param dir string
local function write_maven_wrapper(dir)
	if not ASSET_DIR or vim.fn.filereadable(ASSET_DIR .. "/wrapper/mvnw") == 0 then
		notify("maven wrapper assets missing at " .. tostring(ASSET_DIR) .. " - skipped", vim.log.levels.WARN)
		return false
	end

	local function asset(name)
		return vim.fn.readfile(ASSET_DIR .. "/wrapper/" .. name)
	end

	-- mvnw is a POSIX shell script and keeps LF; write() forces that with "b".
	write(dir .. "/mvnw", asset("mvnw"))
	-- mvnw.cmd is a Windows batch file and wants CRLF, which is writefile's default
	-- on Windows, so it deliberately does NOT get the "b" flag.
	vim.fn.mkdir(dir .. "/.mvn/wrapper", "p")
	vim.fn.writefile(asset("mvnw.cmd"), dir .. "/mvnw.cmd")
	-- The properties file is written rather than copied so the pinned Maven
	-- version stays a single constant above instead of drifting inside an asset.
	write(dir .. "/.mvn/wrapper/maven-wrapper.properties", {
		"wrapperVersion=" .. WRAPPER_VERSION,
		"distributionType=script",
		"distributionUrl=https://repo.maven.apache.org/maven2/org/apache/maven/apache-maven/"
			.. WRAPPER_MAVEN_VERSION
			.. "/apache-maven-"
			.. WRAPPER_MAVEN_VERSION
			.. "-bin.zip",
		"wrapperUrl=https://repo.maven.apache.org/maven2/org/apache/maven/wrapper/maven-wrapper/"
			.. WRAPPER_VERSION
			.. "/maven-wrapper-"
			.. WRAPPER_VERSION
			.. ".jar",
	})

	-- The shim is useless without the executable bit, and writefile does not set
	-- it. Harmless to skip on Windows, where it is meaningless.
	if vim.fn.has("unix") == 1 then
		pcall(vim.fn.setfperm, dir .. "/mvnw", "rwxr-xr-x")
	end
	return true
end

local MAVEN_GITIGNORE = {
	"target/",
	"*.class",
	".idea/",
	"*.iml",
	".DS_Store",
}

local ANDROID_GITIGNORE = {
	"*.iml",
	".gradle/",
	"/local.properties",
	"/.idea/",
	".DS_Store",
	"/build",
	"/captures",
	".externalNativeBuild",
	".cxx",
	"app/build/",
}

-- ---------------------------------------------------------------------------
-- Dependency catalogue.
--
-- One table per checklist section. Each entry is a row the wizard renders and
-- the generators turn into a <dependency> (or a Gradle `implementation` line).
--
--   id       stable key used by the wizard's `state.enabled` set
--   label    what the checklist prints
--   g, a     Maven groupId / artifactId
--   v        explicit version, or nil when `managed`
--   managed  version comes from spring-boot-starter-parent's dependency
--            management - emit NO <version>, because a pinned one silently
--            overrides the BOM and is how a Boot 4 project ends up running a
--            Boot 3 library
--   scope    emitted only when set; Boot-managed starters take none
--   optional emits <optional>true</optional> (devtools)
--   note     shown on the row and mirrored into the pom as an XML comment
--
-- Versions come from the poms already in school/lexicon where those projects
-- pin something, so a generated project matches what the coursework expects.
-- ---------------------------------------------------------------------------

local JAVA_ENTRIES = {
	{
		id = "jackson",
		label = "Jackson (JSON)",
		g = "com.fasterxml.jackson.core",
		a = "jackson-databind",
		v = "2.18.2",
		note = "JSON read/write without a framework",
	},
	{
		id = "lombok",
		label = "Lombok",
		g = "org.projectlombok",
		a = "lombok",
		-- The standalone-Java truth (Boot parents get it normalised to
		-- optional/no-version by normalise_lombok). 1.18.46 is what Boot 4.1.1
		-- manages, so the whole coursework ends up on one Lombok.
		v = "1.18.46",
		scope = "provided",
		note = "wired into annotationProcessorPaths",
	},
	{
		id = "mapstruct",
		label = "MapStruct",
		g = "org.mapstruct",
		a = "mapstruct",
		v = "1.6.3",
		note = "compile-time mapper interfaces",
	},
	{
		id = "slf4j",
		label = "SLF4J API",
		g = "org.slf4j",
		a = "slf4j-api",
		v = "2.0.16",
		note = "logging facade, no binding",
	},
	{
		id = "logback",
		label = "Logback",
		g = "ch.qos.logback",
		a = "logback-classic",
		v = "1.5.16",
		note = "the SLF4J binding to pair with slf4j",
	},
}

local JAVA_TEST_ENTRIES = {
	{
		id = "junit",
		label = "JUnit 5 (Jupiter)",
		g = "org.junit.jupiter",
		a = "junit-jupiter",
		v = "5.11.4",
		scope = "test",
	},
	{ id = "assertj", label = "AssertJ", g = "org.assertj", a = "assertj-core", v = "3.27.3", scope = "test" },
}

local SPRING_ENTRIES = {
	{
		id = "webmvc",
		label = "Spring Web MVC",
		g = "org.springframework.boot",
		a = "spring-boot-starter-webmvc",
		managed = true,
		note = "the 4.x name; starter-web still exists and also works",
	},
	{
		-- Not an alias: starter-web in Boot 4 is a thin wrapper over spring-boot-webmvc
		-- plus tomcat and http-converter. Offered because existing coursework poms
		-- (school/lexicon) use it and it still builds, verified against Boot 4.1.1.
		id = "web",
		label = "Spring Web (legacy name)",
		g = "org.springframework.boot",
		a = "spring-boot-starter-web",
		managed = true,
		note = "still in the 4.1.1 BOM, wraps webmvc + tomcat",
	},
	{
		id = "datajpa",
		label = "Spring Data JPA",
		g = "org.springframework.boot",
		a = "spring-boot-starter-data-jpa",
		managed = true,
		datasource = true,
		note = "needs a JDBC driver at runtime or the app will not boot",
	},
	{
		id = "validation",
		label = "Bean Validation",
		g = "org.springframework.boot",
		a = "spring-boot-starter-validation",
		managed = true,
	},
	{
		id = "security",
		label = "Spring Security",
		g = "org.springframework.boot",
		a = "spring-boot-starter-security",
		managed = true,
		note = "every route answers 401 until you configure it",
	},
	{
		id = "actuator",
		label = "Actuator",
		g = "org.springframework.boot",
		a = "spring-boot-starter-actuator",
		managed = true,
		note = "actuator/health 404s unless it is exposed",
	},
	{
		id = "aspectj",
		label = "Spring AOP (AspectJ)",
		g = "org.springframework.boot",
		a = "spring-boot-starter-aspectj",
		managed = true,
		note = "4.x name; starter-aop is its predecessor",
	},
	{
		id = "dataredis",
		label = "Spring Data Redis",
		g = "org.springframework.boot",
		a = "spring-boot-starter-data-redis",
		managed = true,
	},
	{
		id = "devtools",
		label = "DevTools",
		g = "org.springframework.boot",
		a = "spring-boot-starter-devtools",
		managed = true,
		scope = "runtime",
		optional = true,
	},
	{ id = "h2", label = "H2 (in-memory DB)", g = "com.h2database", a = "h2", managed = true, scope = "test" },
	{
		id = "mysql",
		label = "MySQL driver",
		g = "com.mysql",
		a = "mysql-connector-j",
		managed = true,
		scope = "runtime",
	},
	{
		id = "springdoc",
		label = "springdoc OpenAPI / Swagger UI",
		g = "org.springdoc",
		a = "springdoc-openapi-starter-webmvc-ui",
		v = "3.0.0",
		note = "not in the Boot BOM - 2.x will not start on Boot 4",
	},
	{
		id = "lombok",
		label = "Lombok",
		g = "org.projectlombok",
		a = "lombok",
		-- The standalone-Java truth (Boot parents get it normalised to
		-- optional/no-version by normalise_lombok). 1.18.46 is what Boot 4.1.1
		-- manages, so the whole coursework ends up on one Lombok.
		v = "1.18.46",
		scope = "provided",
		note = "wired into annotationProcessorPaths",
	},
	{ id = "mapstruct", label = "MapStruct", g = "org.mapstruct", a = "mapstruct", v = "1.6.3" },
	{
		id = "jjwt",
		label = "JJWT (JWT tokens)",
		g = "io.jsonwebtoken",
		a = "jjwt-api",
		v = "0.12.6",
		note = "pair with jjwt-impl + jjwt-jackson at runtime",
	},
}

local SPRING_TEST_ENTRIES = {
	{
		id = "t-webmvc",
		label = "Web MVC test",
		g = "org.springframework.boot",
		a = "spring-boot-starter-webmvc-test",
		managed = true,
	},
	{
		id = "t-datajpa",
		label = "Data JPA test",
		g = "org.springframework.boot",
		a = "spring-boot-starter-data-jpa-test",
		managed = true,
	},
	{
		id = "t-security",
		label = "Security test",
		g = "org.springframework.boot",
		a = "spring-boot-starter-security-test",
		managed = true,
	},
	{
		id = "boot-test",
		label = "spring-boot-starter-test",
		g = "org.springframework.boot",
		a = "spring-boot-starter-test",
		managed = true,
		scope = "test",
	},
}

local ANDROID_ENTRIES = {
	{ id = "core-ktx", label = "core-ktx", g = "androidx.core", a = "core-ktx", v = "1.15.0" },
	{
		id = "appcompat",
		label = "appcompat",
		g = "androidx.appcompat",
		a = "appcompat",
		v = "1.7.0",
		note = "switches the theme off the framework one",
	},
	{
		id = "material",
		label = "Material Components",
		g = "com.google.android.material",
		a = "material",
		v = "1.12.0",
		note = "theme becomes Material3",
	},
	{
		id = "constraintlayout",
		label = "constraintlayout",
		g = "androidx.constraintlayout",
		a = "constraintlayout",
		v = "2.2.0",
	},
	{ id = "activity-ktx", label = "activity-ktx", g = "androidx.activity", a = "activity-ktx", v = "1.9.3" },
	{
		id = "lifecycle",
		label = "lifecycle-viewmodel-ktx",
		g = "androidx.lifecycle",
		a = "lifecycle-viewmodel-ktx",
		v = "2.8.7",
	},
	{
		id = "navigation",
		label = "navigation-fragment-ktx",
		g = "androidx.navigation",
		a = "navigation-fragment-ktx",
		v = "2.8.5",
	},
	{ id = "room", label = "Room runtime", g = "androidx.room", a = "room-runtime", v = "2.6.1" },
	{ id = "retrofit", label = "Retrofit", g = "com.squareup.retrofit2", a = "retrofit", v = "2.11.0" },
}

local ANDROID_TEST_ENTRIES = {
	{ id = "junit", label = "JUnit 4 (unit tests)", g = "junit", a = "junit", v = "4.13.2", scope = "test" },
	{
		-- Required for @RunWith(AndroidJUnit4::class). Espresso does NOT bring it, so
		-- without this entry an instrumented test cannot compile.
		id = "androidx-junit",
		label = "AndroidX test runner",
		g = "androidx.test.ext",
		a = "junit",
		v = "1.2.1",
		androidtest = true,
		note = "provides @RunWith(AndroidJUnit4)",
	},
	{
		id = "espresso",
		label = "Espresso (UI tests)",
		g = "androidx.test.espresso",
		a = "espresso-core",
		v = "3.6.1",
		androidtest = true,
	},
}

-- ---------------------------------------------------------------------------
-- npm catalogues: the four frontend tabs.
--
-- Every version was checked against the registry with `npm view <pkg> version`
-- (2026-10-06) and is `^`-ranged, so npm may take patches but not silently
-- jump a major. `dev = true` routes the entry to devDependencies: shipping a
-- bundler or test runner as a runtime dependency is exactly what
-- `npm install --omit=dev` exists to exclude.
--
-- `umd` is the browser-global build inside the installed package, used only by
-- the Vanilla tab, which has no bundler and must point a plain <script> at a
-- real file. Those paths come from an actual `npm install` of each package,
-- because a guessed path produces a page that fails silently instead of a
-- build error.
--
-- `imp` is the import statement the bundler tabs drop into their entry module.
--
-- `core` marks a package the project cannot exist without: the row is ticked,
-- cannot be unticked, and the generator writes it even if the set were stale.
--
-- `implies` lists rows that must travel with this one. It exists for MUI,
-- whose peerDependencies demand @emotion/react and @emotion/styled - a
-- project npm then refuses to install is worse than one extra tick.
-- ---------------------------------------------------------------------------

---Browser-usable libraries. Vanilla loads them from `umd`, bundlers from `imp`.
local NPM_BROWSER = {
	{
		id = "jquery",
		label = "jQuery",
		npm = "jquery",
		v = "^4.0.0",
		umd = "dist/jquery.js",
		-- `jQuery`, not `$`: window.$ is the one a noConflict call clears.
		global = "jQuery",
		imp = 'import $ from "jquery";',
	},
	{
		id = "lodash",
		label = "Lodash",
		npm = "lodash",
		v = "^4.18.1",
		umd = "lodash.js",
		global = "_",
		imp = 'import _ from "lodash";',
	},
	{
		id = "axios",
		label = "Axios",
		npm = "axios",
		v = "^1.20.0",
		umd = "dist/axios.min.js",
		global = "axios",
		imp = 'import axios from "axios";',
	},
	{
		id = "dayjs",
		label = "Day.js",
		npm = "dayjs",
		v = "^1.11.23",
		umd = "dayjs.min.js",
		global = "dayjs",
		imp = 'import dayjs from "dayjs";',
	},
	{
		id = "gsap",
		label = "GSAP",
		npm = "gsap",
		v = "^3.15.0",
		umd = "dist/gsap.min.js",
		-- The gsap UMD writes its exports onto `window` itself, so `window.gsap`.
		global = "gsap",
		imp = 'import { gsap } from "gsap";',
	},
	{
		id = "chartjs",
		label = "Chart.js",
		npm = "chart.js",
		v = "^4.5.1",
		umd = "dist/chart.umd.min.js",
		global = "Chart",
		imp = 'import { Chart } from "chart.js";',
	},
	{
		id = "lenis",
		label = "Lenis",
		npm = "lenis",
		v = "^1.3.26",
		umd = "dist/lenis.min.js",
		global = "Lenis",
		imp = 'import Lenis from "lenis";',
	},
}

---No UMD build, so bundler tabs only - Vanilla cannot use it.
local NPM_ZUSTAND =
	{ id = "zustand", label = "zustand", npm = "zustand", v = "^5.0.15", imp = 'import { create } from "zustand";' }

---Browser-global libraries only. Vanilla uses it because it has no bundler, and
---Vite uses it as well even though it has one: zustand's own `imp` is
---`import { create } from "zustand"`, which is a React hook. Its `react` peer
---is optional so npm would install it happily on a React-less tab - but the
---import could never be used, which is worse than an install error.
local NPM_BROWSER_LIBS = vim.deepcopy(NPM_BROWSER)
---React, and Next (which is React): these can carry ESM-only zustand too.
local NPM_BUNDLED_LIBS = vim.list_extend(vim.deepcopy(NPM_BROWSER), { NPM_ZUSTAND })

---jQuery is the one browser library that cannot be server-rendered: its
---factory throws at import time when `window` is undefined, and Next evaluates
---client modules on the server anyway to prerender their HTML - so `"use
---client"` does not save it. Measured in isolation with `import("<pkg>")`
---under plain Node from a generated project's own node_modules: jquery THROWS;
---lodash, axios, dayjs, gsap, chart.js, lenis and zustand all resolve. This is
---the same exclusion mechanism as zustand being kept off Vanilla/Vite.
local NPM_BROWSER_NEXT = vim.tbl_filter(function(e)
	return e.id ~= "jquery"
end, vim.deepcopy(NPM_BROWSER))
local NPM_NEXT_BROWSER = vim.list_extend(NPM_BROWSER_NEXT, { NPM_ZUSTAND })

local NPM_VITE_CORE = {
	{ id = "vite", label = "vite", npm = "vite", v = "^8.3.2", dev = true, core = true },
	{
		id = "legacy",
		label = "@vitejs/plugin-legacy",
		npm = "@vitejs/plugin-legacy",
		v = "^8.2.3",
		dev = true,
		note = "old-browser bundles",
	},
}

local NPM_REACT_CORE = {
	{ id = "react", label = "react", npm = "react", v = "^19.3.0", core = true },
	{ id = "react-dom", label = "react-dom", npm = "react-dom", v = "^19.3.0", core = true },
	{ id = "vite", label = "vite", npm = "vite", v = "^8.3.2", dev = true, core = true },
	{
		id = "vite-react",
		label = "@vitejs/plugin-react",
		npm = "@vitejs/plugin-react",
		v = "^6.1.2",
		dev = true,
		core = true,
	},
}

local NPM_REACT_LIBS = {
	{
		id = "router",
		label = "react-router-dom",
		npm = "react-router-dom",
		v = "^7.18.4",
		imp = 'import { BrowserRouter, Link, Route, Routes } from "react-router-dom";',
	},
	{
		id = "query",
		label = "@tanstack/react-query",
		npm = "@tanstack/react-query",
		v = "^5.104.1",
		imp = 'import { QueryClient, QueryClientProvider } from "@tanstack/react-query";',
	},
	{
		id = "framer",
		label = "framer-motion",
		npm = "framer-motion",
		v = "^14.0.0",
		imp = 'import { motion } from "framer-motion";',
	},
	{
		id = "lucide",
		label = "lucide-react",
		npm = "lucide-react",
		v = "^1.52.0",
		imp = 'import { Sparkles } from "lucide-react";',
	},
	{ id = "datefn", label = "date-fns", npm = "date-fns", v = "^4.4.0", imp = 'import { format } from "date-fns";' },
	{ id = "clsx", label = "clsx", npm = "clsx", v = "^2.1.1", imp = 'import { clsx } from "clsx";' },
	{
		id = "hookform",
		label = "react-hook-form",
		npm = "react-hook-form",
		v = "^7.89.0",
		imp = 'import { useForm } from "react-hook-form";',
	},
	{
		id = "mui",
		label = "@mui/material",
		npm = "@mui/material",
		v = "^9.4.0",
		note = "drags in emotion",
		imp = 'import Button from "@mui/material/Button";',
		implies = { "emotion-react", "emotion-styled" },
	},
	{ id = "emotion-react", label = "@emotion/react", npm = "@emotion/react", v = "^11.14.0", dev = false },
	{ id = "emotion-styled", label = "@emotion/styled", npm = "@emotion/styled", v = "^11.14.1", dev = false },
}

local NPM_NEXT_CORE = {
	{ id = "next", label = "next", npm = "next", v = "^16.3.8", core = true },
	{ id = "react", label = "react", npm = "react", v = "^19.3.0", core = true },
	{ id = "react-dom", label = "react-dom", npm = "react-dom", v = "^19.3.0", core = true },
}

local NPM_NEXT_LIBS = {
	{ id = "clsx", label = "clsx", npm = "clsx", v = "^2.1.1", imp = 'import { clsx } from "clsx";' },
	{
		id = "lucide",
		label = "lucide-react",
		npm = "lucide-react",
		v = "^1.52.0",
		imp = 'import { Sparkles } from "lucide-react";',
	},
	-- axios/dayjs deliberately absent: NPM_BUNDLED_LIBS already lists them for
	-- this tab, and a second row with the same id would share one tick across
	-- two lines and emit the package twice.
	{
		id = "query",
		label = "@tanstack/react-query",
		npm = "@tanstack/react-query",
		v = "^5.104.1",
		imp = 'import { QueryClient, QueryClientProvider } from "@tanstack/react-query";',
	},
	{ id = "datefn", label = "date-fns", npm = "date-fns", v = "^4.4.0", imp = 'import { format } from "date-fns";' },
	{
		id = "hookform",
		label = "react-hook-form",
		npm = "react-hook-form",
		v = "^7.89.0",
		imp = 'import { useForm } from "react-hook-form";',
	},
	{
		id = "mui",
		label = "@mui/material",
		npm = "@mui/material",
		v = "^9.4.0",
		note = "drags in emotion",
		imp = 'import Button from "@mui/material/Button";',
		implies = { "emotion-react", "emotion-styled" },
	},
	{ id = "emotion-react", label = "@emotion/react", npm = "@emotion/react", v = "^11.14.0" },
	{ id = "emotion-styled", label = "@emotion/styled", npm = "@emotion/styled", v = "^11.14.1" },
}

---Tailwind is v4 on every tab; the plugin differs because Vite has its own
---integration and Next reaches PostCSS. Mixing v3 instructions in yields a
---project that builds fine and silently renders unstyled.
local NPM_STYLE_VITE = {
	{ id = "tailwind", label = "tailwindcss", npm = "tailwindcss", v = "^4.3.3", dev = true, implies = { "tw-vite" } },
	{
		id = "tw-vite",
		label = "@tailwindcss/vite",
		npm = "@tailwindcss/vite",
		v = "^4.3.3",
		dev = true,
		note = "Vite plugin",
	},
	{ id = "sass", label = "sass", npm = "sass", v = "^1.105.1", dev = true, note = "compile .scss" },
}

local NPM_STYLE_NEXT = {
	{
		id = "tailwind",
		label = "tailwindcss",
		npm = "tailwindcss",
		v = "^4.3.3",
		dev = true,
		implies = { "tw-postcss" },
	},
	{
		id = "tw-postcss",
		label = "@tailwindcss/postcss",
		npm = "@tailwindcss/postcss",
		v = "^4.3.3",
		dev = true,
		note = "PostCSS plugin",
	},
	{ id = "sass", label = "sass", npm = "sass", v = "^1.105.1", dev = true, note = "compile .scss" },
}

---Vite has no React, so only the framework-agnostic runner goes here.
---
---`@testing-library/react` is deliberately absent from this tab. It peers
---`react` and `react-dom` NON-optionally (unlike zustand and lenis, whose
---react peers are marked optional), so npm auto-installs a full React tree to
---satisfy it - a plain Vite project ended up with react@19 in node_modules and
---nothing to render it with.
local NPM_TEST_VITE = {
	{ id = "vitest", label = "vitest", npm = "vitest", v = "^5.0.3", dev = true, note = "test runner" },
	{ id = "jsdom", label = "jsdom", npm = "jsdom", v = "^30.1.2", dev = true, note = "browser environment" },
}

---React: the testing library too. `@testing-library/react` also peers
---`@testing-library/dom` non-optionally, but that one is NOT a row - npm
---auto-installs it (verified at 10.4.2 from both RTL packages), and a row
---would need `implies` from two parents, which `toggle()` cannot express: it
---clears an implied row the moment ANY parent goes off, silently breaking the
---other one.
local NPM_TEST_REACT = {
	{ id = "vitest", label = "vitest", npm = "vitest", v = "^5.0.3", dev = true, note = "test runner" },
	-- Sole parent of jsdom: rendering without a DOM is a test failure, so the
	-- environment is not a separate decision.
	{ id = "jsdom", label = "jsdom", npm = "jsdom", v = "^30.1.2", dev = true, note = "browser environment" },
	{
		id = "tl-react",
		label = "@testing-library/react",
		npm = "@testing-library/react",
		v = "^16.3.3",
		dev = true,
		note = "pulls in jsdom",
		implies = { "jsdom" },
	},
	{
		id = "tl-jest",
		label = "@testing-library/jest-dom",
		npm = "@testing-library/jest-dom",
		v = "^7.0.1",
		dev = true,
		note = "vitest matchers",
	},
}

---Optional: `next lint` was removed, so ESLint only runs if the user wants it.
---
---Pinned to 9 on purpose. eslint-config-next declares `eslint >=9.0.0`, but
---eslint 10 dies at runtime with `scopeManager.addGlobals is not a function`
---even though `npm install` exits 0 - the peer range overstates what it
---supports, so the version is pinned rather than inherited.
---
---`typescript` is absent on purpose too: eslint-config-next does peer it, but
---that peer is optional (peerDependenciesMeta), and install + a real lint run
---both pass without it. This tab generates JS, not TS.
local NPM_LINT_NEXT = {
	{ id = "eslint", label = "eslint", npm = "eslint", v = "^9.39.5", dev = true, implies = { "eslint-next" } },
	{ id = "eslint-next", label = "eslint-config-next", npm = "eslint-config-next", v = "^16.3.8", dev = true },
}

local NPM_VANILLA_TOOL = {
	{
		id = "serve",
		label = "serve",
		npm = "serve",
		v = "^14.2.6",
		dev = true,
		core = true,
		note = "static dev server",
	},
}

---Vanilla can be tested too, but say what it costs: vitest peers vite, so npm
---will pull a bundler into a project that otherwise has none. Stating it on
---the row beats a surprise during `npm install`.
local NPM_VANILLA_TEST = {
	{ id = "vitest", label = "vitest", npm = "vitest", v = "^5.0.3", dev = true, note = "peers vite" },
	{ id = "jsdom", label = "jsdom", npm = "jsdom", v = "^30.1.2", dev = true, note = "browser environment" },
}

---Frontend runs share one helper set; used for validation and for the field
---label, since "com.example.demo" and "my-app" are different problems.
local JS_RUNS = { vanilla = true, vite = true, react = true, next = true }

---@param run string
---@return boolean
local function is_js(run)
	return JS_RUNS[run] == true
end

---Project types, in tab order. `run` names the generator on M, `cmd` an
---explicit suffix for the :New*Project command when the tab label cannot be
---derived from it - see M.setup, where "Next.js" otherwise becomes an illegal
---`NewNext.jsProject`.
local TABS = {
	{ tab = "Java", run = "java" },
	{ tab = "Spring Boot", run = "spring" },
	{ tab = "Android", run = "android" },
	{ tab = "Vanilla JS", run = "vanilla" },
	{ tab = "Vite", run = "vite" },
	{ tab = "React", run = "react" },
	{ tab = "Next.js", run = "next", cmd = "NextJS" },
}

---Where each tab's checklist rows come from.
---@param run string
---@return {heading:string, items:table}[]
local function sections_for(run)
	if run == "java" then
		return {
			{ heading = "Libraries", items = JAVA_ENTRIES },
			{ heading = "Testing", items = JAVA_TEST_ENTRIES },
		}
	end
	if run == "spring" then
		return {
			{ heading = "Starters", items = SPRING_ENTRIES },
			{ heading = "Test support", items = SPRING_TEST_ENTRIES },
		}
	end
	if run == "android" then
		return {
			{ heading = "AndroidX", items = ANDROID_ENTRIES },
			{ heading = "Testing", items = ANDROID_TEST_ENTRIES },
		}
	end
	if run == "vanilla" then
		return {
			{ heading = "Libraries", items = NPM_BROWSER_LIBS },
			{ heading = "Tooling", items = NPM_VANILLA_TOOL },
			{ heading = "Testing", items = NPM_VANILLA_TEST },
		}
	end
	if run == "vite" then
		return {
			{ heading = "Core", items = NPM_VITE_CORE },
			{ heading = "Libraries", items = NPM_BROWSER_LIBS },
			{ heading = "Styling", items = NPM_STYLE_VITE },
			{ heading = "Testing", items = NPM_TEST_VITE },
		}
	end
	if run == "react" then
		return {
			{ heading = "Core", items = NPM_REACT_CORE },
			{ heading = "Libraries", items = NPM_BUNDLED_LIBS },
			{ heading = "React", items = NPM_REACT_LIBS },
			{ heading = "Styling", items = NPM_STYLE_VITE },
			{ heading = "Testing", items = NPM_TEST_REACT },
		}
	end
	return {
		{ heading = "Core", items = NPM_NEXT_CORE },
		{ heading = "Libraries", items = NPM_NEXT_BROWSER },
		{ heading = "React", items = NPM_NEXT_LIBS },
		{ heading = "Styling", items = NPM_STYLE_NEXT },
		{ heading = "Linting", items = NPM_LINT_NEXT },
	}
end

---What a fresh tab starts with. Chosen so the common case needs no keystrokes.
---@param run string
---@return string[]
local function preselect_for(run)
	if run == "java" then
		return { "junit" }
	end
	if run == "spring" then
		return { "webmvc", "t-webmvc" }
	end
	if run == "android" then
		return { "core-ktx", "constraintlayout" }
	end
	if run == "vanilla" then
		return { "jquery", "axios" }
	end
	if run == "vite" then
		return { "axios", "dayjs" }
	end
	if run == "react" then
		return { "router", "clsx" }
	end
	return { "clsx", "tailwind" }
end

---@param run string
---@return string
local function default_name(run)
	if run == "java" then
		return "hello-java"
	end
	if run == "spring" then
		return "hello-spring"
	end
	if run == "android" then
		return "hello-android"
	end
	if run == "vanilla" then
		return "hello-vanilla"
	end
	if run == "vite" then
		return "hello-vite"
	end
	if run == "react" then
		return "hello-react"
	end
	return "hello-next"
end

---Highest platform this generator's AGP can actually compile against.
---AGP 8.13 is documented as supporting API 36.1 max; 37.0 needs AGP 9.1.1+.
local AGP_MAX_SDK = 36
local AGP_MAX_MINOR = 1

---Pick a compileSdk that is actually installed.
---
---Since AGP 8.13 the SDK layout is not just `platforms/android-<int>`: Google
---shipped *minor* API levels (android-36.1, android-37.0), and the old
---`^android%-(%d+)$` scan silently matched NONE of them. That produced a
---generator that fell back to 35 and emitted a project which then died at
---configuration time with "Failed to find target with hash string" on a machine
---that had a perfectly good modern SDK installed.
---
---So both forms are parsed, minor versions included, and the best platform that
---is both installed AND supported by this AGP wins. Anything installed above
---AGP_MAX is reported rather than picked: compiling against it fails, and a
---silent fallback would hide the real cause.
---@return integer sdk, integer|nil minor, string|nil warning
local function pick_android_sdk()
	local root = ((vim.env.ANDROID_HOME or vim.env.ANDROID_SDK_ROOT or ""):gsub("\\", "/"))
	local best, best_minor, saw_newer

	if root ~= "" then
		local ok, dirs = pcall(vim.fs.dir, root .. "/platforms")
		if ok then
			for name in dirs do
				-- `android-36` and `android-36.1`; `android-37.0` normalises to minor 0,
				-- which is exactly what the flat `compileSdk = 37` form means.
				local major_s, minor_s = name:match("^android%-(%d+)%.?(%d*)$")
				local major = tonumber(major_s)
				if major then
					local minor = tonumber(minor_s) or 0
					if major > AGP_MAX_SDK or (major == AGP_MAX_SDK and minor > AGP_MAX_MINOR) then
						saw_newer = true
					elseif not best or major > best or (major == best and minor > best_minor) then
						best, best_minor = major, minor
					end
				end
			end
		end
	end

	if best then
		local warning
		if saw_newer then
			warning = (
				"a newer platform than API %d.%d is installed, but AGP 8.13 cannot compile "
				.. "against it - using the highest it can. API 37.0 needs AGP 9.1.1+"
			):format(AGP_MAX_SDK, AGP_MAX_MINOR)
		end
		return best, best_minor, warning
	end

	local where = root ~= "" and (root .. "/platforms") or "$ANDROID_HOME is unset"
	return AGP_MAX_SDK,
		nil,
		"no usable platform under "
			.. where
			.. (' - installing one is required (sdkmanager "platforms;android-%d")'):format(AGP_MAX_SDK)
end

-- ---------------------------------------------------------------------------
-- pom.xml assembly
-- ---------------------------------------------------------------------------

---Turn picked catalogue entries into an id -> entry lookup.
---@param picked table[]
---@return table<string, table>
local function picked_set(picked)
	local set = {}
	for _, e in ipairs(picked or {}) do
		set[e.id] = e
	end
	return set
end

---One <dependency> element.
---
---Element order is fixed (groupId, artifactId, version, scope, optional, note)
---so two runs over the same selection produce byte-identical poms. `note` goes
---LAST on purpose: a reader scanning the element sees coordinates first, and it
---keeps the version/scope pair adjacent, which is what the verification asserts.
---@param e table
---@return string[]
local function dep_xml(e)
	local L = {
		"        <dependency>",
		"            <groupId>" .. e.g .. "</groupId>",
		"            <artifactId>" .. e.a .. "</artifactId>",
	}
	-- A managed entry gets NO <version>: spring-boot-starter-parent already
	-- imports the Boot BOM, and a hardcoded version silently overrides it.
	if not e.managed and e.v then
		L[#L + 1] = "            <version>" .. e.v .. "</version>"
	end
	if e.scope then
		L[#L + 1] = "            <scope>" .. e.scope .. "</scope>"
	end
	if e.optional then
		L[#L + 1] = "            <optional>true</optional>"
	end
	if e.note then
		L[#L + 1] = "            <!-- " .. e.note .. " -->"
	end
	L[#L + 1] = "        </dependency>"
	return L
end

---Lombok's version, for poms with no BOM to inherit it from. The Boot 4.1.1 BOM
---manages 1.18.46; matching it keeps one Lombok across the whole coursework.
local LOMBOK_VERSION = "1.18.46"

---Lombok needs different treatment per parent, so normalise it per generator.
---Under Boot the BOM supplies the version and IntelliJ (and every pom under
---school/lexicon) writes `<optional>true</optional>` with no version and no scope.
---Standalone there is no BOM, so it must carry a version, and `provided` is the
---scope that keeps it off the runtime classpath.
---@param has table<string, table>
---@param managed boolean true when a Boot parent will manage the version
local function normalise_lombok(has, managed)
	if not has.lombok then
		return
	end
	local l = vim.deepcopy(has.lombok)
	if managed then
		l.v, l.scope, l.optional = nil, nil, true
	else
		l.v, l.scope, l.optional = LOMBOK_VERSION, "provided", nil
	end
	has.lombok = l
end

---Entries whose Spring auto-configuration refuses to start without a JDBC
---driver on the RUNTIME classpath. H2 is catalogueued as a test dependency, so
---ticking JPA on its own used to emit a scaffold that died at boot with
---"Failed to determine a suitable driver class". Callers use this to promote H2.
---@param enabled table<string, any>
---@return boolean
local function needs_datasource(enabled)
	for _, group in ipairs({ SPRING_ENTRIES }) do
		for _, e in ipairs(group) do
			if e.datasource and enabled[e.id] then
				return true
			end
		end
	end
	return false
end

---Every ticked entry across the given catalogue groups, in catalogue order.
---@param groups table[][]
---@param has table<string, table>
---@return table[]
local function picked_entries(groups, has)
	local out = {}
	for _, items in ipairs(groups) do
		for _, e in ipairs(items) do
			-- Resolve through `has`: it normally holds the identical table, but
			-- callers may override one entry (JPA promoting h2 to runtime scope), and
			-- emitting the catalogue copy would silently discard that override.
			if has[e.id] then
				out[#out + 1] = has[e.id]
			end
		end
	end
	return out
end

---@param groups table[][]
---@param has table<string, table>
---@return string[]
local function dep_block(groups, has)
	local entries = picked_entries(groups, has)
	-- An empty <dependencies/> is legal but pointless; drop it so a no-dependency
	-- project reads as the minimal thing it is.
	if #entries == 0 then
		return {}
	end
	local L = { "    <dependencies>" }
	for _, e in ipairs(entries) do
		vim.list_extend(L, dep_xml(e))
	end
	L[#L + 1] = "    </dependencies>"
	return L
end

---Annotation processors needed by the ticked entries.
---@param has table<string, table>
---@param managed boolean
---@return table[]
local function annotation_processors(has, managed)
	local ap = {}
	-- Under Boot the BOM supplies lombok's version and `has.lombok.v` is nil, so
	-- fall back to the constant only when there is nothing managing it.
	if has.lombok then
		ap[#ap + 1] = { g = "org.projectlombok", a = "lombok", v = managed and nil or LOMBOK_VERSION }
	end
	-- MapStruct is NOT in the Boot BOM, so its version is always explicit.
	if has.mapstruct then
		ap[#ap + 1] = { g = "org.mapstruct", a = "mapstruct", v = "1.6.3" }
	end
	return ap
end

---maven-compiler-plugin, plus annotationProcessorPaths for whatever ticked entry
---needs one (Lombok, MapStruct).
---
---`managed` means a Boot parent is present, which changes two things: the plugin
---version and `<release>` both come from the parent (via `java.version`), so
---emitting them is noise IntelliJ does not emit either; and with no annotation
---processors there is nothing left to configure, so the plugin is omitted
---outright rather than added as an empty shell.
---@param release integer
---@param has table<string, table>
---@param indent string
---@param managed boolean|nil
---@return string[]
local function compiler_plugin(release, has, indent, managed)
	local ap = annotation_processors(has, managed)
	if managed and #ap == 0 then
		return {}
	end

	local L = {
		indent .. "<plugin>",
		indent .. "    <groupId>org.apache.maven.plugins</groupId>",
		indent .. "    <artifactId>maven-compiler-plugin</artifactId>",
	}
	if not managed then
		-- No parent to inherit a version from. 3.13.0 is the first that understands
		-- `<release>` properly on JDK 21.
		L[#L + 1] = indent .. "    <version>3.13.0</version>"
	end
	L[#L + 1] = indent .. "    <configuration>"
	if not managed then
		L[#L + 1] = indent .. "        <release>" .. release .. "</release>"
	end
	if #ap > 0 then
		L[#L + 1] = indent .. "        <annotationProcessorPaths>"
		for _, p in ipairs(ap) do
			L[#L + 1] = indent .. "            <path>"
			L[#L + 1] = indent .. "                <groupId>" .. p.g .. "</groupId>"
			L[#L + 1] = indent .. "                <artifactId>" .. p.a .. "</artifactId>"
			if p.v then
				L[#L + 1] = indent .. "                <version>" .. p.v .. "</version>"
			end
			L[#L + 1] = indent .. "            </path>"
		end
		L[#L + 1] = indent .. "        </annotationProcessorPaths>"
		-- MapStruct needs the parameter names, and so does anything binding
		-- constructor arguments by name.
		if has.mapstruct then
			L[#L + 1] = indent .. "        <compilerArgs><arg>-parameters</arg></compilerArgs>"
		end
	end
	L[#L + 1] = indent .. "    </configuration>"
	L[#L + 1] = indent .. "</plugin>"
	return L
end

---Surefire only earns its place when a JUnit-flavoured test dep was ticked;
--- otherwise the default binding is old enough to miss Jupiter.
---@param has table<string, table>
---@param indent string
---@param managed boolean|nil
---@return string[]
local function surefire_plugin(has, indent, managed)
	if not (has.junit or has["t-webmvc"] or has["t-datajpa"] or has["t-security"] or has["boot-test"]) then
		return {}
	end
	local L = {
		indent .. "<plugin>",
		indent .. "    <groupId>org.apache.maven.plugins</groupId>",
		indent .. "    <artifactId>maven-surefire-plugin</artifactId>",
	}
	if not managed then
		L[#L + 1] = indent .. "    <version>3.5.2</version>"
	end
	L[#L + 1] = indent .. "</plugin>"
	return L
end

---@param has table<string, table>
---@param release integer
---@param indent string
---@param managed boolean|nil
---@return string[]
local function plugins_block(has, release, indent, managed)
	local L = { indent .. "<plugins>" }
	vim.list_extend(L, compiler_plugin(release, has, indent .. "    ", managed))
	vim.list_extend(L, surefire_plugin(has, indent .. "    ", managed))
	L[#L + 1] = indent .. "</plugins>"
	return L
end

---@param name string
---@param pkg string
---@return string[]
local function pom_header_standalone(name, pkg)
	return {
		'<?xml version="1.0" encoding="UTF-8"?>',
		'<project xmlns="http://maven.apache.org/POM/4.0.0"',
		'    xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"',
		'    xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 https://maven.apache.org/xsd/maven-4.0.0.xsd">',
		"    <modelVersion>4.0.0</modelVersion>",
		"",
		"    <groupId>" .. pkg .. "</groupId>",
		"    <artifactId>" .. name .. "</artifactId>",
		"    <version>0.0.1-SNAPSHOT</version>",
		"    <name>" .. name .. "</name>",
	}
end

---The empty metadata blocks IntelliJ writes into every Maven pom it creates:
---`<url />`, an empty `<licenses>`, `<developers>` and `<scm>`.
---
---They carry no information whatsoever - they are placeholders for you to fill -
---but they are what makes a generated pom line-for-line comparable with one that
---came out of IntelliJ, which is the point of matching them. Every pom under
---school/lexicon has them.
---@return string[]
local function intellij_placeholders()
	return {
		"    <url />",
		"    <licenses>",
		"        <license />",
		"    </licenses>",
		"    <developers>",
		"        <developer />",
		"    </developers>",
		"    <scm>",
		"        <connection />",
		"        <developerConnection />",
		"        <tag />",
		"        <url />",
		"    </scm>",
	}
end

---Shared tail for both Maven poms.
---@param deps string[]
---@param build string[]
---@return string[]
local function pom_footer(deps, build)
	local L = {}
	vim.list_extend(L, deps)
	if #deps > 0 then
		L[#L + 1] = ""
	end
	L[#L + 1] = "    <build>"
	vim.list_extend(L, build)
	L[#L + 1] = "    </build>"
	L[#L + 1] = ""
	L[#L + 1] = "</project>"
	return L
end

-- ---------------------------------------------------------------------------
-- :NewJavaProject - plain Java 21, Maven, from the ticked checklist.
-- ---------------------------------------------------------------------------

---@param name string project name
---@param pkg string package name
---@param picked table[] catalogue entries, in catalogue order
---@param dir string|nil target directory; resolved from cwd when nil
function M.java(name, pkg, picked, dir)
	local ppath, perr = pkg_path(pkg or "")
	if not ppath then
		return notify(perr, vim.log.levels.ERROR)
	end
	if not dir then
		local d, err = resolve_dir(name)
		if not d then
			return notify(err, vim.log.levels.ERROR)
		end
		dir = d
	end

	local has = picked_set(picked)
	normalise_lombok(has, false)
	local src = dir .. "/src/main/java/" .. ppath
	local test = dir .. "/src/test/java/" .. ppath
	local pom = pom_header_standalone(name, pkg)
	vim.list_extend(pom, {
		"",
		"    <description>" .. name .. "</description>",
	})
	vim.list_extend(pom, intellij_placeholders())
	vim.list_extend(pom, {
		"",
		"    <properties>",
		"        <project.build.sourceEncoding>UTF-8</project.build.sourceEncoding>",
		"        <maven.compiler.release>21</maven.compiler.release>",
		"    </properties>",
	})
	local deps = dep_block({ JAVA_ENTRIES, JAVA_TEST_ENTRIES }, has)
	-- pom_footer emits the dependency block; appending `deps` here as well would
	-- put a second <dependencies> in the pom and Maven refuses to parse it.
	-- managed = false: there is no parent, so the compiler plugin must carry its
	-- own version and `<release>`.
	vim.list_extend(pom, pom_footer(deps, plugins_block(has, 21, "        ", false)))

	write(dir .. "/.gitignore", MAVEN_GITIGNORE)
	write(dir .. "/pom.xml", pom)
	local wrapped = write_maven_wrapper(dir)
	write(src .. "/Main.java", {
		"package " .. pkg .. ";",
		"",
		"public class Main {",
		"    public static void main(String[] args) {",
		'        System.out.println("Hello from ' .. name .. '");',
		"    }",
		"}",
	})
	-- A test source with no test framework on the classpath is a compile error,
	-- so it is only written when something test-scoped was actually ticked.
	if has.junit or has.assertj then
		write(test .. "/MainTest.java", {
			"package " .. pkg .. ";",
			"",
			"import static org.junit.jupiter.api.Assertions.assertTrue;",
			"",
			"import org.junit.jupiter.api.Test;",
			"",
			"class MainTest {",
			"    @Test",
			"    void greets() {",
			"        assertTrue(true);",
			"    }",
			"}",
		})
	end

	notify(name .. " created at " .. dir)
	if not wrapped then
		notify("no wrapper written - run `mvn wrapper:wrapper` once in that directory", vim.log.levels.WARN)
	end
	vim.fn.chdir(dir)
	notify("cwd is now " .. dir .. " (`:cd -` to go back)")
	return dir
end

-- ---------------------------------------------------------------------------
-- :NewSpringBootProject - Spring Boot 4.1, Maven, fully offline.
-- ---------------------------------------------------------------------------

---@param name string
---@param pkg string
---@param picked table[]
---@param dir string|nil
function M.spring(name, pkg, picked, dir)
	local ppath, perr = pkg_path(pkg or "")
	if not ppath then
		return notify(perr, vim.log.levels.ERROR)
	end
	if not dir then
		local d, err = resolve_dir(name)
		if not d then
			return notify(err, vim.log.levels.ERROR)
		end
		dir = d
	end

	local has = picked_set(picked)
	-- The Boot BOM manages Lombok's version, so write it the way IntelliJ does:
	-- optional, no version, no scope.
	normalise_lombok(has, true)
	-- JPA cannot boot without a runtime driver. Copy rather than mutate: has.h2 is
	-- the shared catalogue table, and rewriting its scope there would silently
	-- change every later project generated in this session.
	if needs_datasource(has) then
		local h2 = has.h2 and vim.deepcopy(has.h2) or { id = "h2", label = "H2 (in-memory DB)" }
		h2.g, h2.a, h2.managed, h2.scope = "com.h2database", "h2", true, "runtime"
		h2.note = "runtime scope so JPA has a driver to boot on"
		has.h2 = h2
	end
	local app = class_name(name)
	if not app then
		return notify("project name has no alphanumeric characters", vim.log.levels.ERROR)
	end

	local pom = {
		'<?xml version="1.0" encoding="UTF-8"?>',
		'<project xmlns="http://maven.apache.org/POM/4.0.0"',
		'    xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"',
		'    xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 https://maven.apache.org/xsd/maven-4.0.0.xsd">',
		"    <modelVersion>4.0.0</modelVersion>",
		"",
		"    <parent>",
		"        <groupId>org.springframework.boot</groupId>",
		"        <artifactId>spring-boot-starter-parent</artifactId>",
		"        <version>4.1.1</version>",
		"        <relativePath /> <!-- lookup parent from repository -->",
		"    </parent>",
		"",
		"    <groupId>" .. pkg .. "</groupId>",
		"    <artifactId>" .. name .. "</artifactId>",
		"    <version>0.0.1-SNAPSHOT</version>",
		"    <name>" .. name .. "</name>",
		"    <description>" .. name .. "</description>",
	}
	vim.list_extend(pom, intellij_placeholders())
	vim.list_extend(pom, {
		"",
		-- Only java.version, exactly like IntelliJ and the school/lexicon poms: the
		-- Boot parent already sets project.build.sourceEncoding and drives
		-- maven.compiler.release from this property, so repeating either is noise.
		"    <properties>",
		"        <java.version>17</java.version>",
		"    </properties>",
	})

	local deps = dep_block({ SPRING_ENTRIES, SPRING_TEST_ENTRIES }, has)

	local build = { "        <plugins>" }
	-- spring-boot-maven-plugin carries NO version: the parent manages it.
	vim.list_extend(build, {
		"            <plugin>",
		"                <groupId>org.springframework.boot</groupId>",
		"                <artifactId>spring-boot-maven-plugin</artifactId>",
		"            </plugin>",
	})
	-- managed = true throughout: the parent supplies every plugin version and
	-- <release>, so pinning them here would drift the moment the Boot version moves.
	vim.list_extend(build, compiler_plugin(17, has, "            ", true))
	vim.list_extend(build, surefire_plugin(has, "            ", true))
	build[#build + 1] = "        </plugins>"

	vim.list_extend(pom, pom_footer(deps, build))

	write(dir .. "/.gitignore", MAVEN_GITIGNORE)
	write(dir .. "/pom.xml", pom)
	local wrapped = write_maven_wrapper(dir)
	write(dir .. "/src/main/java/" .. ppath .. "/" .. app .. "Application.java", {
		"package " .. pkg .. ";",
		"",
		"import org.springframework.boot.SpringApplication;",
		"import org.springframework.boot.autoconfigure.SpringBootApplication;",
		"",
		"@SpringBootApplication",
		"public class " .. app .. "Application {",
		"",
		"    public static void main(String[] args) {",
		"        SpringApplication.run(" .. app .. "Application.class, args);",
		"    }",
		"}",
	})
	write(dir .. "/src/main/resources/application.properties", {
		"# Server",
		"server.port=8080",
		"",
		-- A .properties file comments with '#' or '!'. '--' is Lua/SQL/Haskell, and
		-- Java happily reads it as a bare key instead of failing, so this one cost
		-- nothing and was wrong.
		"# Logging",
		"logging.level.root=INFO",
	})

	-- Ticking a test starter but writing no test leaves surefire reporting
	-- "No tests to run", which looks like a broken build rather than an empty one.
	-- IntelliJ and start.spring.io both emit this context-load test, so match them.
	if has["t-webmvc"] or has["t-datajpa"] or has["t-security"] or has["boot-test"] then
		write(dir .. "/src/test/java/" .. ppath .. "/" .. app .. "ApplicationTests.java", {
			"package " .. pkg .. ";",
			"",
			"import org.junit.jupiter.api.Test;",
			"import org.springframework.boot.test.context.SpringBootTest;",
			"",
			"@SpringBootTest",
			"class " .. app .. "ApplicationTests {",
			"",
			"    @Test",
			"    void contextLoads() {",
			"    }",
			"}",
		})
	end

	notify(name .. " created at " .. dir)
	if not wrapped then
		notify("no wrapper written - run `mvn wrapper:wrapper` once, then `mvn spring-boot:run`", vim.log.levels.WARN)
	end
	notify("run it with `mvn spring-boot:run` (or `./mvnw spring-boot:run` on unix)", vim.log.levels.INFO)
	if has.security then
		notify("Spring Security ticked: every endpoint answers 401 until you configure it", vim.log.levels.WARN)
	end
	if has.springdoc then
		notify("Swagger UI at /swagger-ui.html once the app is running", vim.log.levels.INFO)
	end
	vim.fn.chdir(dir)
	notify("cwd is now " .. dir .. " (`:cd -` to go back)")
	return dir
end

-- ---------------------------------------------------------------------------
-- :NewAndroidProject - local Gradle/Kotlin/manifest boilerplate. Offline.
-- ---------------------------------------------------------------------------

---@param name string
---@param pkg string
---@param picked table[]
---@param dir string|nil
function M.android(name, pkg, picked, dir)
	local ppath, perr = pkg_path(pkg or "")
	if not ppath then
		return notify(perr, vim.log.levels.ERROR)
	end
	if not dir then
		local d, err = resolve_dir(name)
		if not d then
			return notify(err, vim.log.levels.ERROR)
		end
		dir = d
	end

	local has = picked_set(picked)
	local theme = "Theme." .. (class_name(name) or "App")
	local main = dir .. "/app/src/main/java/" .. ppath .. "/MainActivity.kt"
	local sdk, sdk_minor, sdk_warning = pick_android_sdk()

	-- A Material3 or AppCompat theme only resolves when that library is on the
	-- classpath, so the theme follows the checklist instead of being hardcoded.
	local theme_parent = "android:Theme.Material.Light.NoActionBar"
	if has.material then
		theme_parent = "Theme.Material3.DayNight.NoActionBar"
	elseif has.appcompat then
		theme_parent = "Theme.AppCompat.Light.NoActionBar"
	end

	local dep_lines = {}
	for _, e in ipairs(picked_entries({ ANDROID_ENTRIES, ANDROID_TEST_ENTRIES }, has)) do
		local configuration = "implementation"
		if e.androidtest then
			configuration = "androidTestImplementation"
		elseif e.scope == "test" then
			configuration = "testImplementation"
		end
		dep_lines[#dep_lines + 1] = string.format('    %s("%s:%s:%s")', configuration, e.g, e.a, e.v)
	end

	write(dir .. "/.gitignore", ANDROID_GITIGNORE)
	write(dir .. "/settings.gradle.kts", {
		"pluginManagement {",
		"    repositories {",
		"        google()",
		"        mavenCentral()",
		"        gradlePluginPortal()",
		"    }",
		"}",
		"dependencyResolutionManagement {",
		"    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)",
		"    repositories {",
		"        google()",
		"        mavenCentral()",
		"    }",
		"}",
		"",
		'rootProject.name = "' .. name .. '"',
		'include(":app")',
	})
	-- AGP 8.13 / Gradle 8.13 is the pairing that reaches API 36.1. The previous
	-- 8.7.3 was capped at API 35, and it was paired with Gradle 9.5.1, which is
	-- simply not supported (AGP 8.7 requires Gradle 8.9).
	write(dir .. "/build.gradle.kts", {
		"plugins {",
		'    id("com.android.application") version "8.13.0" apply false',
		'    id("org.jetbrains.kotlin.android") version "2.0.21" apply false',
		"}",
	})
	write(dir .. "/gradle.properties", {
		"org.gradle.jvmargs=-Xmx2048m -Dfile.encoding=UTF-8",
		"android.useAndroidX=true",
		"kotlin.code.style=official",
		"android.nonTransitiveRClass=true",
		-- Gradle's default 30s read timeout is not enough for the 13 MB AGP jar on a
		-- slow or throttled link: the first configuration died with "Read timed out"
		-- even though the very same URL answered HEAD 200 immediately. Raising the
		-- socket timeout plus retries is the difference between a first build that
		-- works and one you have to run twice.
		"systemProp.org.gradle.internal.http.socketTimeout=180000",
		"systemProp.org.gradle.internal.http.connectionTimeout=180000",
		"systemProp.org.gradle.internal.repository.max.retries=5",
	})
	local app_build = {
		"plugins {",
		'    id("com.android.application")',
		'    id("org.jetbrains.kotlin.android")',
		"}",
		"",
		"android {",
		'    namespace = "' .. pkg .. '"',
		-- Minor API levels (android-36.1) need the block form; the flat
		-- `compileSdk = N` cannot express one, which is what made every generated
		-- project fail on a minor-version SDK.
		--
		-- `version =` is REQUIRED. `release(36) { }` is a function returning a
		-- CompileSdkVersion; without assigning it, `version` stays null and AGP
		-- fails configuration with "does not specify compileSdk" (verified).
		"    compileSdk {",
		"        version = release(" .. sdk .. ") {",
		"            minorApiLevel = " .. sdk_minor,
		"        }",
		"    }",
		"",
		"    defaultConfig {",
		'        applicationId = "' .. pkg .. '"',
		-- Decides which DEVICES the app installs on, independent of compileSdk.
		"        minSdk = 24",
		-- Always an integer: targetSdk has no minor concept, and Play requires the
		-- major level here.
		"        targetSdk = " .. sdk,
		"        versionCode = 1",
		'        versionName = "1.0"',
		-- Android Studio always sets this, and an androidTest source set without it
		-- cannot run at all.
		'        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"',
		"    }",
		"",
		"    buildTypes {",
		"        release {",
		"            isMinifyEnabled = false",
		-- ProGuard rules are written below regardless of the minify flag, so turning
		-- shrinking on later needs no other edit.
		'            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")',
		"        }",
		"    }",
		"    compileOptions {",
		"        sourceCompatibility = JavaVersion.VERSION_17",
		"        targetCompatibility = JavaVersion.VERSION_17",
		"    }",
		"    kotlinOptions {",
		'        jvmTarget = "17"',
		"    }",
		"    buildFeatures {",
		-- Android Studio's template turns this on, and it is what lets MainActivity
		-- reference ActivityMainBinding instead of findViewById.
		"        viewBinding = true",
		"    }",
		"}",
		"",
		"dependencies {",
	}
	-- `table.unpack` is not dependable on Neovim's LuaJIT (see AGENTS.md), so the
	-- dependency lines are concatenated explicitly rather than spliced in.
	vim.list_extend(app_build, dep_lines)
	app_build[#app_build + 1] = "}"
	write(dir .. "/app/build.gradle.kts", app_build)
	write(dir .. "/app/src/main/AndroidManifest.xml", {
		'<?xml version="1.0" encoding="utf-8"?>',
		'<manifest xmlns:android="http://schemas.android.com/apk/res/android">',
		"    <application",
		'        android:allowBackup="true"',
		'        android:dataExtractionRules="@xml/data_extraction_rules"',
		'        android:fullBackupContent="@xml/backup_rules"',
		'        android:label="@string/app_name"',
		'        android:supportsRtl="true"',
		'        android:theme="@style/' .. theme .. '">',
		"        <activity",
		'            android:name=".MainActivity"',
		'            android:exported="true">',
		"            <intent-filter>",
		'                <action android:name="android.intent.action.MAIN" />',
		'                <category android:name="android.intent.category.LAUNCHER" />',
		"            </intent-filter>",
		"        </activity>",
		"    </application>",
		"</manifest>",
	})
	write(dir .. "/app/src/main/res/values/strings.xml", {
		'<?xml version="1.0" encoding="utf-8"?>',
		"<resources>",
		'    <string name="app_name">' .. name .. "</string>",
		"</resources>",
	})
	write(dir .. "/app/src/main/res/values/themes.xml", {
		'<?xml version="1.0" encoding="utf-8"?>',
		"<resources>",
		'    <style name="' .. theme .. '" parent="' .. theme_parent .. '" />',
		"</resources>",
	})
	write(dir .. "/app/src/main/res/values-night/themes.xml", {
		'<?xml version="1.0" encoding="utf-8"?>',
		"<resources>",
		-- Without a night variant the app stays light after dark mode, which reads as
		-- a bug rather than a choice.
		'    <style name="' .. theme .. '" parent="' .. theme_parent:gsub("%.Light", "") .. '" />',
		"</resources>",
	})
	write(dir .. "/app/src/main/res/values/colors.xml", {
		'<?xml version="1.0" encoding="utf-8"?>',
		"<resources>",
		'    <color name="black">#FF000000</color>',
		'    <color name="white">#FFFFFFFF</color>',
		"</resources>",
	})
	-- Referenced from the manifest above, so both must exist or the build fails at
	-- resource-linking time rather than at runtime.
	write(dir .. "/app/src/main/res/xml/backup_rules.xml", {
		'<?xml version="1.0" encoding="utf-8"?>',
		"<full-backup-content>",
		"</full-backup-content>",
	})
	write(dir .. "/app/src/main/res/xml/data_extraction_rules.xml", {
		'<?xml version="1.0" encoding="utf-8"?>',
		"<data-extraction-rules>",
		"    <cloud-backup>",
		'        <exclude domain="sharedpref" path="device.xml" />',
		"    </cloud-backup>",
		"    <device-transfer>",
		'        <exclude domain="sharedpref" path="device.xml" />',
		"    </device-transfer>",
		"</data-extraction-rules>",
	})
	write(dir .. "/app/proguard-rules.pro", {
		"# Project-specific ProGuard rules.",
		"# Only read when isMinifyEnabled is true in app/build.gradle.kts.",
		"",
		"# Keep generic signatures; strip verbose logging.",
		"-keepattributes *Annotation*, Signature, InnerClasses, EnclosingMethod",
		"-assumenosideeffects",
		"    -logclosing",
	})

	-- Two activity templates, because they have genuinely different requirements.
	-- AppCompatActivity and ViewBinding need libraries that may not be ticked, so
	-- they are only used when they are available; otherwise the activity stays on
	-- framework APIs and needs nothing at all.
	if has.material or has.appcompat then
		-- ConstraintLayout only if it is actually on the classpath; otherwise fall
		-- back to the framework LinearLayout, so the layout never references a
		-- library the checklist did not add.
		local root, extra =
			"androidx.constraintlayout.widget.ConstraintLayout", {
				'    xmlns:app="http://schemas.android.com/apk/res-auto"',
			}
		local tv_open, tv_close
		if has.constraintlayout then
			tv_open = {
				"    <TextView",
				'        android:id="@+id/text"',
				'        android:layout_width="wrap_content"',
				'        android:layout_height="wrap_content"',
				'        android:text="@string/app_name"',
				'        app:layout_constraintBottom_toBottomOf="parent"',
				'        app:layout_constraintEnd_toEndOf="parent"',
				'        app:layout_constraintStart_toStartOf="parent"',
				'        app:layout_constraintTop_toTopOf="parent" />',
			}
		else
			root = "LinearLayout"
			tv_open = {
				"    <TextView",
				'        android:id="@+id/text"',
				'        android:layout_width="wrap_content"',
				'        android:layout_height="wrap_content"',
				'        android:text="@string/app_name" />',
			}
		end
		tv_close = { "</" .. root .. ">" }

		local layout = {
			'<?xml version="1.0" encoding="utf-8"?>',
			"<" .. root,
			'    xmlns:android="http://schemas.android.com/apk/res/android"',
		}
		vim.list_extend(layout, extra)
		vim.list_extend(layout, {
			'    android:layout_width="match_parent"',
			'    android:layout_height="match_parent"',
			'    android:orientation="vertical">',
			"",
		})
		vim.list_extend(layout, tv_open)
		vim.list_extend(layout, tv_close)
		write(dir .. "/app/src/main/res/layout/activity_main.xml", layout)

		write(main, {
			"package " .. pkg,
			"",
			"import android.os.Bundle",
			"import androidx.appcompat.app.AppCompatActivity",
			"import " .. pkg .. ".databinding.ActivityMainBinding",
			"",
			"class MainActivity : AppCompatActivity() {",
			"",
			"    private lateinit var binding: ActivityMainBinding",
			"",
			"    override fun onCreate(savedInstanceState: Bundle?) {",
			"        super.onCreate(savedInstanceState)",
			"        binding = ActivityMainBinding.inflate(layoutInflater)",
			"        setContentView(binding.root)",
			"        binding.text.text = getString(R.string.app_name)",
			"    }",
			"}",
		})
	else
		-- android.app.Activity + a programmatic TextView: no layout XML, and it needs
		-- none of the ticked libraries, so the template compiles whatever you select.
		write(main, {
			"package " .. pkg,
			"",
			"import android.app.Activity",
			"import android.os.Bundle",
			"import android.widget.TextView",
			"",
			"class MainActivity : Activity() {",
			"    override fun onCreate(savedInstanceState: Bundle?) {",
			"        super.onCreate(savedInstanceState)",
			"        val text = TextView(this)",
			'        text.text = "' .. name .. '"',
			"        setContentView(text)",
			"    }",
			"}",
		})
	end

	-- Test stubs, so a ticked test dependency is never a dependency with no test.
	if has.junit then
		write(dir .. "/app/src/test/java/" .. ppath .. "/ExampleUnitTest.kt", {
			"package " .. pkg,
			"",
			"import org.junit.Assert.assertEquals",
			"import org.junit.Test",
			"",
			"/**",
			" * Example local unit test.",
			" *",
			" * Runs on the JVM, no device needed: ./gradlew test",
			" */",
			"class ExampleUnitTest {",
			"    @Test",
			"    fun addition_isCorrect() {",
			"        assertEquals(4, 2 + 2)",
			"    }",
			"}",
		})
	end
	if has["androidx-junit"] then
		write(dir .. "/app/src/androidTest/java/" .. ppath .. "/ExampleInstrumentedTest.kt", {
			"package " .. pkg,
			"",
			"import androidx.test.ext.junit.runners.AndroidJUnit4",
			"import androidx.test.platform.app.InstrumentationRegistry",
			"import org.junit.Assert.assertEquals",
			"import org.junit.Test",
			"import org.junit.runner.RunWith",
			"",
			"/**",
			" * Instrumented test, which will execute on an Android device.",
			" *",
			" * Needs a connected device or emulator: ./gradlew connectedAndroidTest",
			" */",
			"@RunWith(AndroidJUnit4::class)",
			"class ExampleInstrumentedTest {",
			"    @Test",
			"    fun useAppContext() {",
			"        val appContext = InstrumentationRegistry.getInstrumentation().targetContext",
			'        assertEquals("' .. pkg .. '", appContext.packageName)',
			"    }",
			"}",
		})
	end

	-- local.properties is what points Gradle at the SDK. Generated from the
	-- env var AGENTS.md already documents, with backslashes flipped to forward
	-- slashes (Java properties treat \ as an escape).
	local sdk_dir = vim.env.ANDROID_HOME or vim.env.ANDROID_SDK_ROOT
	if sdk_dir and sdk_dir ~= "" then
		write(dir .. "/local.properties", { "sdk.dir=" .. (sdk_dir:gsub("\\", "/")) })
	end

	-- The Gradle distribution is pinned here, but `gradlew` itself is NOT generated:
	-- unlike Maven's wrapper, Gradle's hard-requires gradle/wrapper/gradle-wrapper.jar
	-- (verified: deleting it makes gradlew.bat die with "Unable to access jarfile"),
	-- and a jar cannot be written from a Lua string. Android Studio reads this file,
	-- so it pins the version for anyone who opens the project.
	write(dir .. "/gradle/wrapper/gradle-wrapper.properties", {
		"distributionBase=GRADLE_USER_HOME",
		"distributionPath=wrapper/dists",
		-- Must match AGP's documented minimum: 8.13 requires Gradle 8.13. Pinning
		-- something newer is not "forward compatible", it is unsupported.
		"distributionUrl=https\\://services.gradle.org/distributions/gradle-8.13-bin.zip",
		"networkTimeout=10000",
		"validateDistributionUrl=true",
		"zipStoreBase=GRADLE_USER_HOME",
		"zipStorePath=wrapper/dists",
	})

	notify(name .. " created at " .. dir)
	if sdk_dir and sdk_dir ~= "" then
		notify("local.properties written from ANDROID_HOME")
	else
		notify("no ANDROID_HOME - create local.properties with sdk.dir=<your SDK>", vim.log.levels.WARN)
	end
	if sdk_warning then
		notify(sdk_warning, vim.log.levels.WARN)
	end
	notify(
		"no gradlew yet - run `gradle wrapper` once (it needs a jar, so it cannot be written from a script)",
		vim.log.levels.WARN
	)
	vim.fn.chdir(dir)
	notify("cwd is now " .. dir .. " (`:cd -` to go back)")
	return dir
end

-- ---------------------------------------------------------------------------
-- Frontend generators: package.json plus the framework's own config files.
--
-- No `create-*` scaffolder runs and nothing touches the network. The checklist
-- that filled the screen is the same catalogue that writes package.json, so
-- what was ticked and what the manifest claims cannot drift apart. The
-- generator stops at the files: `npm install` stays the user's command, which
-- is the whole reason this works offline.
-- ---------------------------------------------------------------------------

---Shared `.gitignore` for all four npm tabs. Some lines only apply to some
---tabs (`node_modules/` matters everywhere, `.next/` only to Next), but an
---extra comment line costs nothing and a missing one costs a committed
---dependency tree.
local NPM_GITIGNORE = {
	"node_modules/",
	"dist/",
	"build/",
	".next/",
	".env",
	".env.local",
	"*.local",
}

---Split ticked rows into `dependencies` and `devDependencies`.
---
---Order follows `picked`, which walks `sections_for`, so two runs over the
---same ticks write byte-identical JSON - the stability the pom.xml and
---build.gradle generators already aim for. Deduped by package name because the
---same package can legitimately appear under two headings.
---@param picked table[]
---@return table[] deps, table[] dev
local function npm_split(picked)
	local deps, dev, seen = {}, {}, {}
	for _, e in ipairs(picked or {}) do
		if not seen[e.npm] then
			seen[e.npm] = true
			if e.dev then
				dev[#dev + 1] = e
			else
				deps[#deps + 1] = e
			end
		end
	end
	return deps, dev
end

---Write package.json.
---
---`scripts` is an array of pairs rather than a map: a Lua map has no order,
---and "dev" above "build" above "test" is the order a reader expects.
---@param dir string
---@param pkg string
---@param scripts string[][] { { name, command }, ... }; an empty list omits the block
---@param deps table[]
---@param dev table[]
---@param esm boolean|nil emit `"type": "module"` (Vite scaffolds do; a plain
---   Node loader would otherwise read `vite.config.js` as CommonJS and choke on
---   its `import` statements)
local function write_package_json(dir, pkg, scripts, deps, dev, esm)
	local props = {}

	props[#props + 1] = { '  "name": "' .. pkg .. '"' }
	props[#props + 1] = { '  "version": "0.1.0"' }
	props[#props + 1] = { '  "private": true' }
	if esm then
		props[#props + 1] = { '  "type": "module"' }
	end

	if #scripts > 0 then
		local s = { '  "scripts": {' }
		for i, p in ipairs(scripts) do
			s[#s + 1] = string.format('    "%s": "%s"%s', p[1], p[2], i < #scripts and "," or "")
		end
		s[#s + 1] = "  }"
		props[#props + 1] = s
	end

	for _, block in ipairs({ { "dependencies", deps }, { "devDependencies", dev } }) do
		if #block[2] > 0 then
			local b = { '  "' .. block[1] .. '": {' }
			for i, e in ipairs(block[2]) do
				b[#b + 1] = string.format('    "%s": "%s"%s', e.npm, e.v, i < #block[2] and "," or "")
			end
			b[#b + 1] = "  }"
			props[#props + 1] = b
		end
	end

	-- Commas go between properties, never after the last one - a trailing comma
	-- is not JSON and npm rejects it outright.
	local L = { "{" }
	for i, prop in ipairs(props) do
		vim.list_extend(L, prop)
		if i < #props then
			L[#L] = L[#L] .. ","
		end
	end
	L[#L + 1] = "}"
	write(dir .. "/package.json", L)
end

---Local bindings an `import` line introduces.
---
---Parsed from the catalogue's `imp` string rather than stored twice, so a row
---can never claim one import and bind another.
---@param imp string
---@return string[]
local function imp_bindings(imp)
	local names = {}
	local list = imp:match("import%s+{([^}]+)}%s+from")
	if list then
		for part in list:gmatch("[^,]+") do
			local n = part:match("^%s*([%w_$]+)")
			if n then
				names[#names + 1] = n
			end
		end
		return names
	end
	local one = imp:match("^import%s+([%w_$]+)%s+from")
	if one then
		names[#names + 1] = one
	end
	return names
end

---The `import` statements for everything ticked, in catalogue order.
---@param picked table[]
---@param omit string|nil package name to leave out (React's own core imports are hand-written)
---@return string[] lines
local function npm_imports(picked, omit)
	local out, seen = {}, {}
	for _, e in ipairs(picked or {}) do
		if e.imp and e.npm ~= omit and not seen[e.npm] then
			seen[e.npm] = true
			out[#out + 1] = e.imp
		end
	end
	return out
end

---Bindings for everything ticked, deduped - two rows binding the same name
---would otherwise emit a duplicate key or a redeclaration.
---@param picked table[]
---@param omit string|nil
---@return string[]
local function npm_binding_names(picked, omit)
	local out, seen = {}, {}
	for _, e in ipairs(picked or {}) do
		if e.imp and e.npm ~= omit and not seen[e.npm] then
			seen[e.npm] = true
			for _, b in ipairs(imp_bindings(e.imp)) do
				if not seen["bind:" .. b] then
					seen["bind:" .. b] = true
					out[#out + 1] = b
				end
			end
		end
	end
	return out
end

---Names for display, in catalogue order.
---@param picked table[]
---@param omit string|nil
---@return string[]
local function npm_names(picked, omit)
	local out, seen = {}, {}
	for _, e in ipairs(picked or {}) do
		if e.imp and e.npm ~= omit and not seen[e.npm] then
			seen[e.npm] = true
			out[#out + 1] = e.npm
		end
	end
	return out
end

---Tail shared by all four npm generators.
---@param name string
---@param dir string
---@param extra string[]|nil extra INFO lines, e.g. a "you must run X once" caveat
---@return string dir
local function npm_finish(name, dir, extra)
	notify(name .. " created at " .. dir)
	for _, m in ipairs(extra or {}) do
		notify(m, vim.log.levels.INFO)
	end
	notify("`npm install` next - this generator never runs it for you", vim.log.levels.INFO)
	vim.fn.chdir(dir)
	notify("cwd is now " .. dir .. " (`:cd -` to go back)")
	return dir
end

---Build the `scripts` block, skipping any script whose tool was not ticked.
---@param pairs string[][]
---@param has table<string, table>
---@return string[][]
local function scripts_for(pairs, has)
	local out = {}
	for _, p in ipairs(pairs) do
		-- p[3] is an optional gate: the id that must be ticked for this script.
		if not p[3] or has[p[3]] then
			out[#out + 1] = { p[1], p[2] }
		end
	end
	return out
end

---Everything a plain static site needs, with the libraries loaded as real
---`<script>` tags out of `node_modules`.
---
---There is no bundler and no import here on purpose - that is what the tab
---means. Each tag comes from the catalogue's `umd` path and each `main.js`
---probe from its `global`, both verified against an actual `npm install`, so
---a typo cannot produce a page that loads and silently shows nothing.
---@param name string
---@param pkg string
---@param picked table[]
---@param dir string|nil
---@return string|nil
function M.vanilla(name, pkg, picked, dir)
	local pname, perr = npm_name(pkg or "")
	if not pname then
		return notify(perr, vim.log.levels.ERROR)
	end
	if not dir then
		local d, err = resolve_dir(name)
		if not d then
			return notify(err, vim.log.levels.ERROR)
		end
		dir = d
	end

	local has = picked_set(picked)
	local deps, dev = npm_split(picked)

	write_package_json(
		dir,
		pname,
		scripts_for({ { "dev", "serve ." }, { "test", "vitest run", "vitest" } }, has),
		deps,
		dev
	)
	write(dir .. "/.gitignore", NPM_GITIGNORE)

	local tags, probes = {}, {}
	for _, e in ipairs(picked) do
		if e.umd and e.global then
			tags[#tags + 1] = '    <script src="./node_modules/' .. e.npm .. "/" .. e.umd .. '"></script>'
			probes[#probes + 1] = {
				'if (typeof window["' .. e.global .. '"] !== "undefined") {',
				'  loaded.push("' .. e.label .. '");',
				"}",
			}
		end
	end

	local html = {
		"<!doctype html>",
		'<html lang="en">',
		"  <head>",
		'    <meta charset="utf-8" />',
		'    <meta name="viewport" content="width=device-width, initial-scale=1" />',
		"    <title>" .. pname .. "</title>",
		'    <link rel="stylesheet" href="./styles.css" />',
		"  </head>",
		"  <body>",
		"    <main>",
		"      <h1>" .. pname .. "</h1>",
		'      <ul id="libs"></ul>',
		"    </main>",
	}
	vim.list_extend(html, tags)
	html[#html + 1] = '    <script src="./main.js"></script>'
	html[#html + 1] = "  </body>"
	html[#html + 1] = "</html>"
	write(dir .. "/index.html", html)

	local js = {
		"// Nothing above imports anything: these arrive as globals from the",
		"// <script> tags in index.html. That is the trade this tab makes - no",
		"// build step, and no module system either.",
		"",
		"const loaded = [];",
	}
	for _, probe in ipairs(probes) do
		vim.list_extend(js, probe)
	end
	vim.list_extend(js, {
		"",
		'const list = document.getElementById("libs");',
		'list.innerHTML = loaded.map((lib) => `<li>${lib}</li>`).join("") || "<li>no libraries ticked</li>";',
	})
	write(dir .. "/main.js", js)

	write(dir .. "/styles.css", {
		":root { color-scheme: light dark; }",
		"body {",
		"  font: 16px/1.6 system-ui, sans-serif;",
		"  margin: 0;",
		"  padding: 2rem;",
		"}",
		"h1 { margin: 0 0 1rem; }",
		"ul { padding-left: 1.25rem; }",
	})

	if has.vitest then
		local vc = { 'import { defineConfig } from "vitest/config";', "", "export default defineConfig({" }
		if has.jsdom then
			vc[#vc + 1] = '  test: { environment: "jsdom" },'
		end
		vc[#vc + 1] = "});"
		write(dir .. "/vitest.config.mjs", vc)

		-- A toolchain smoke test, and deliberately not a fake feature test: with
		-- no bundler there is no way to hand main.js's globals to vitest, so
		-- claiming to test the page would be a lie. What it does prove is that
		-- `npm test` runs and that the environment is the one you asked for.
		if has.jsdom then
			write(dir .. "/main.test.js", {
				'import { describe, expect, it } from "vitest";',
				"",
				'describe("jsdom environment", () => {',
				'  it("provides a document", () => {',
				'    expect(typeof document).toBe("object");',
				'    expect(document.createElement("ul")).not.toBeNull();',
				"  });",
				"});",
			})
		else
			write(dir .. "/main.test.js", {
				'import { describe, expect, it } from "vitest";',
				"",
				'describe("node environment", () => {',
				'  it("runs without a DOM", () => {',
				'    expect(typeof document).toBe("undefined");',
				"  });",
				"});",
			})
		end
	end

	return npm_finish(name, dir, { "open it with `npm run dev`, then edit index.html - there is nothing to compile" })
end

---Vite: the smallest project that still has a build step.
---@param name string
---@param pkg string
---@param picked table[]
---@param dir string|nil
---@return string|nil
function M.vite(name, pkg, picked, dir)
	local pname, perr = npm_name(pkg or "")
	if not pname then
		return notify(perr, vim.log.levels.ERROR)
	end
	if not dir then
		local d, err = resolve_dir(name)
		if not d then
			return notify(err, vim.log.levels.ERROR)
		end
		dir = d
	end

	local has = picked_set(picked)
	local deps, dev = npm_split(picked)

	write_package_json(
		dir,
		pname,
		scripts_for({
			{ "dev", "vite" },
			{ "build", "vite build" },
			{ "preview", "vite preview" },
			{ "test", "vitest run", "vitest" },
		}, has),
		deps,
		dev,
		true -- ESM: `npm create vite` always sets it, and vite.config.js is ESM
	)
	write(dir .. "/.gitignore", NPM_GITIGNORE)

	-- Vite needs no config file at all, so one is written only when a plugin is
	-- actually ticked: an empty `defineConfig({})` is a file the reader has to
	-- decode to learn it says nothing.
	local imports, plugins = {}, {}
	local function add(import_line, call)
		imports[#imports + 1] = import_line
		plugins[#plugins + 1] = call
	end
	if has["tw-vite"] then
		add('import tailwindcss from "@tailwindcss/vite";', "tailwindcss()")
	end
	if has.legacy then
		add('import legacy from "@vitejs/plugin-legacy";', "legacy()")
	end
	if #plugins > 0 then
		local cfg = { 'import { defineConfig } from "vite";' }
		vim.list_extend(cfg, imports)
		cfg[#cfg + 1] = ""
		cfg[#cfg + 1] = "export default defineConfig({"
		cfg[#cfg + 1] = "  plugins: ["
		for _, p in ipairs(plugins) do
			cfg[#cfg + 1] = "    " .. p .. ","
		end
		cfg[#cfg + 1] = "  ],"
		cfg[#cfg + 1] = "});"
		write(dir .. "/vite.config.js", cfg)
	end

	write(dir .. "/index.html", {
		"<!doctype html>",
		'<html lang="en">',
		"  <head>",
		'    <meta charset="UTF-8" />',
		'    <meta name="viewport" content="width=device-width, initial-scale=1.0" />',
		"    <title>" .. pname .. "</title>",
		"  </head>",
		"  <body>",
		'    <div id="app"></div>',
		'    <script type="module" src="/src/main.js"></script>',
		"  </body>",
		"</html>",
	})

	write(
		dir .. "/src/main.js",
		vim.list_extend(vim.list_extend({ 'import "./style.css";', "" }, npm_imports(picked)), {
			"",
			"// Every row you ticked, referenced so the bundler keeps them in the",
			"// build instead of tree-shaking modules nothing reads yet.",
			"export const libraries = [" .. table.concat(npm_binding_names(picked), ", ") .. "];",
			"export const libraryNames = [" .. table.concat(
				vim.tbl_map(function(n)
					return '"' .. n .. '"'
				end, npm_names(picked)),
				", "
			) .. "];",
			"",
			"// Guarded, because src/main.test.js imports this module under jsdom",
			"// where there is no #app. An unguarded write would throw at import time",
			"// and fail the whole suite before a single test ran.",
			'const root = document.querySelector("#app");',
			"if (root) {",
			"  root.innerHTML = `",
			"    <main>",
			"      <h1>" .. pname .. "</h1>",
			"      <p>${libraryNames.length} libraries installed</p>",
			"    </main>",
			"  `;",
			"}",
		})
	)

	write(dir .. "/src/style.css", has["tw-vite"] and {
		'@import "tailwindcss";',
		"",
		"body {",
		"  font-family: system-ui, sans-serif;",
		"  margin: 0;",
		"}",
	} or {
		":root { color-scheme: light dark; }",
		"body {",
		"  font: 16px/1.6 system-ui, sans-serif;",
		"  margin: 0;",
		"  padding: 2rem;",
		"}",
		"h1 { margin: 0 0 1rem; }",
	})

	if has.vitest then
		local vc = { 'import { defineConfig } from "vitest/config";', "", "export default defineConfig({" }
		if has.jsdom then
			vc[#vc + 1] = '  test: { environment: "jsdom" },'
		end
		vc[#vc + 1] = "});"
		write(dir .. "/vitest.config.mjs", vc)
		write(dir .. "/src/main.test.js", {
			'import { describe, expect, it } from "vitest";',
			'import { libraryNames } from "./main.js";',
			"",
			'describe("generated project", () => {',
			'  it("reports its installed libraries", () => {',
			"    expect(Array.isArray(libraryNames)).toBe(true);",
			"  });",
			"});",
		})
	end

	return npm_finish(name, dir)
end

---React on Vite: JSX, a component pair, and the same build machinery.
---@param name string
---@param pkg string
---@param picked table[]
---@param dir string|nil
---@return string|nil
function M.react(name, pkg, picked, dir)
	local pname, perr = npm_name(pkg or "")
	if not pname then
		return notify(perr, vim.log.levels.ERROR)
	end
	if not dir then
		local d, err = resolve_dir(name)
		if not d then
			return notify(err, vim.log.levels.ERROR)
		end
		dir = d
	end

	local has = picked_set(picked)
	local deps, dev = npm_split(picked)

	write_package_json(
		dir,
		pname,
		scripts_for({
			{ "dev", "vite" },
			{ "build", "vite build" },
			{ "preview", "vite preview" },
			{ "test", "vitest run", "vitest" },
		}, has),
		deps,
		dev,
		true -- ESM, same reason as M.vite
	)
	write(dir .. "/.gitignore", NPM_GITIGNORE)

	-- The React plugin is core, so unlike M.vite this project always has a
	-- config file - a React build with no plugin simply does not transform JSX.
	local cfg = { 'import { defineConfig } from "vite";', 'import react from "@vitejs/plugin-react";' }
	local plugins = { "react()" }
	if has["tw-vite"] then
		cfg[#cfg + 1] = 'import tailwindcss from "@tailwindcss/vite";'
		plugins[#plugins + 1] = "tailwindcss()"
	end
	if has.legacy then
		cfg[#cfg + 1] = 'import legacy from "@vitejs/plugin-legacy";'
		plugins[#plugins + 1] = "legacy()"
	end
	cfg[#cfg + 1] = ""
	cfg[#cfg + 1] = "export default defineConfig({"
	cfg[#cfg + 1] = "  plugins: ["
	for _, p in ipairs(plugins) do
		cfg[#cfg + 1] = "    " .. p .. ","
	end
	cfg[#cfg + 1] = "  ],"
	cfg[#cfg + 1] = "});"
	write(dir .. "/vite.config.js", cfg)

	write(dir .. "/index.html", {
		"<!doctype html>",
		'<html lang="en">',
		"  <head>",
		'    <meta charset="UTF-8" />',
		'    <meta name="viewport" content="width=device-width, initial-scale=1.0" />',
		"    <title>" .. pname .. "</title>",
		"  </head>",
		"  <body>",
		'    <div id="root"></div>',
		'    <script type="module" src="/src/main.jsx"></script>',
		"  </body>",
		"</html>",
	})

	write(dir .. "/src/main.jsx", {
		'import { StrictMode } from "react";',
		'import { createRoot } from "react-dom/client";',
		'import App from "./App.jsx";',
		'import "./style.css";',
		"",
		'createRoot(document.getElementById("root")).render(',
		"  <StrictMode>",
		"    <App />",
		"  </StrictMode>,",
		");",
	})

	local app = npm_imports(picked)
	vim.list_extend(app, {
		"",
		"// Referenced on purpose: an import nothing reads is tree-shaken out of",
		"// the production bundle, which would make the list below a lie.",
		"export const libraries = [" .. table.concat(npm_binding_names(picked), ", ") .. "];",
		'export const libraryNames = ["' .. table.concat(npm_names(picked), '","') .. '"];',
		"",
		"export default function App() {",
		"  return (",
		"    <main>",
		"      <h1>" .. pname .. "</h1>",
		"      <p>{libraryNames.length} libraries installed</p>",
		"    </main>",
		"  );",
		"}",
	})
	write(dir .. "/src/App.jsx", app)

	write(dir .. "/src/style.css", has["tw-vite"] and {
		'@import "tailwindcss";',
		"",
		"body {",
		"  font-family: system-ui, sans-serif;",
		"  margin: 0;",
		"}",
	} or {
		":root { color-scheme: light dark; }",
		"body {",
		"  font: 16px/1.6 system-ui, sans-serif;",
		"  margin: 0;",
		"  padding: 2rem;",
		"}",
		"h1 { margin: 0 0 1rem; }",
	})

	if has.vitest then
		local vc = { 'import { defineConfig } from "vitest/config";', "", "export default defineConfig({" }
		if has.jsdom then
			vc[#vc + 1] = '  test: { environment: "jsdom" },'
		end
		vc[#vc + 1] = "});"
		write(dir .. "/vitest.config.mjs", vc)

		-- Exercise whichever testing library was installed. The old template only
		-- asserted `Array.isArray(libraryNames)`, so @testing-library/react and
		-- jest-dom were ticked, installed, and never imported - a green `npm test`
		-- that proved nothing about the row the user had just chosen.
		local t
		if has["tl-react"] and has.jsdom then
			t = { 'import { describe, expect, it } from "vitest";' }
			if has["tl-jest"] then
				t[#t + 1] = 'import "@testing-library/jest-dom/vitest";'
			end
			vim.list_extend(t, {
				'import { render, screen } from "@testing-library/react";',
				'import App from "./App.jsx";',
				"",
				'describe("generated project", () => {',
				'  it("renders the heading the app renders", () => {',
				"    render(<App />);",
				'    const heading = screen.getByRole("heading", { level: 1 });',
			})
			-- Assert through the matcher the user actually installed: the jest-dom
			-- branch needs @testing-library/jest-dom/vitest imported above, so the
			-- two cannot drift apart.
			if has["tl-jest"] then
				t[#t + 1] = '    expect(heading).toHaveTextContent("' .. pname .. '");'
			else
				t[#t + 1] = '    expect(heading.textContent).toBe("' .. pname .. '");'
			end
			vim.list_extend(t, { "  });", "});" })
		else
			t = {
				'import { describe, expect, it } from "vitest";',
				'import { libraryNames } from "./App.jsx";',
				"",
				'describe("generated project", () => {',
				'  it("reports its installed libraries", () => {',
				"    expect(Array.isArray(libraryNames)).toBe(true);",
				"  });",
				"});",
			}
		end
		write(dir .. "/src/App.test.jsx", t)
	end

	return npm_finish(name, dir)
end

---Next.js (App Router): no index.html, no vite.config, no bundler config at
---all - `next build` owns those. What is generated is the App Router shape,
---the `@/` alias, an optional Tailwind PostCSS hook and an optional flat
---ESLint config.
---@param name string
---@param pkg string
---@param picked table[]
---@param dir string|nil
---@return string|nil
function M.next(name, pkg, picked, dir)
	local pname, perr = npm_name(pkg or "")
	if not pname then
		return notify(perr, vim.log.levels.ERROR)
	end
	if not dir then
		local d, err = resolve_dir(name)
		if not d then
			return notify(err, vim.log.levels.ERROR)
		end
		dir = d
	end

	local has = picked_set(picked)
	local deps, dev = npm_split(picked)

	write_package_json(
		dir,
		pname,
		scripts_for({
			{ "dev", "next dev" },
			{ "build", "next build" },
			{ "start", "next start" },
			{ "lint", "eslint .", "eslint" },
		}, has),
		deps,
		dev
	)
	write(dir .. "/.gitignore", NPM_GITIGNORE)

	write(dir .. "/next.config.mjs", {
		"/** @type {import('next').NextConfig} */",
		"const nextConfig = {};",
		"",
		"export default nextConfig;",
	})

	-- App Router has no jsconfig by default, and without the alias `import x
	-- from "@/..."` does not resolve - the alias is the reason this file exists.
	write(dir .. "/jsconfig.json", {
		"{",
		'  "compilerOptions": {',
		'    "paths": {',
		'      "@/*": ["./*"]',
		"    }",
		"  }",
		"}",
	})

	if has["tw-postcss"] then
		write(dir .. "/postcss.config.mjs", {
			"const config = {",
			'  plugins: ["@tailwindcss/postcss"],',
			"};",
			"",
			"export default config;",
		})
	end

	write(dir .. "/app/layout.jsx", {
		'import "./globals.css";',
		"",
		"export const metadata = {",
		'  title: "' .. pname .. '",',
		'  description: "Generated by projectgen",',
		"};",
		"",
		"export default function RootLayout({ children }) {",
		"  return (",
		'    <html lang="en">',
		"      <body>{children}</body>",
		"    </html>",
		"  );",
		"}",
	})

	-- "use client" is not optional here. Without it the App Router resolves every
	-- import under the `react-server` condition, and client-only libraries ship a
	-- *different* entry for that: react-hook-form's react-server build has no
	-- `useForm`, so `next build` failed with "Export useForm doesn't exist in
	-- target module". zustand, @tanstack/react-query and @mui/material are all
	-- client-only the same way, and the tick list is chosen by the user - so the
	-- boundary goes on unconditionally rather than guessing which rows need it.
	local page = { '"use client";', "" }
	vim.list_extend(page, npm_imports(picked))
	vim.list_extend(page, {
		"",
		"// Referenced on purpose: an unused import is tree-shaken out of the",
		"// production build, which would make the list below a lie.",
		"export const libraries = [" .. table.concat(npm_binding_names(picked), ", ") .. "];",
		'export const libraryNames = ["' .. table.concat(npm_names(picked), '","') .. '"];',
		"",
		"export default function Page() {",
		"  return (",
		"    <main>",
		"      <h1>" .. pname .. "</h1>",
		"      <p>{libraryNames.length} libraries installed</p>",
		"    </main>",
		"  );",
		"}",
	})
	write(dir .. "/app/page.jsx", page)

	write(dir .. "/app/globals.css", has["tw-postcss"] and {
		'@import "tailwindcss";',
		"",
		"body {",
		"  font-family: system-ui, sans-serif;",
		"  margin: 0;",
		"}",
	} or {
		":root { color-scheme: light dark; }",
		"body {",
		"  font: 16px/1.6 system-ui, sans-serif;",
		"  margin: 0;",
		"  padding: 2rem;",
		"}",
		"h1 { margin: 0 0 1rem; }",
	})

	if has.eslint then
		write(dir .. "/eslint.config.mjs", {
			'import coreWebVitals from "eslint-config-next/core-web-vitals";',
			"",
			"// eslint-config-next runs @next/next/no-html-link-for-pages against a",
			"// pages/ directory, and App Router projects have none - so the rule can",
			"// only ever report one missing. Off by default keeps `npm run lint`",
			"// clean when it actually passes.",
			"const config = [",
			"  ...coreWebVitals,",
			"  {",
			"    rules: {",
			'      "@next/next/no-html-link-for-pages": "off",',
			"    },",
			"  },",
			"];",
			"",
			"// Assigned to a variable before export: `export default [...]` trips",
			"// eslint's own import/no-anonymous-default-export, so a project's first",
			"// lint run would otherwise report against its own config file.",
			"export default config;",
		})
	end

	return npm_finish(name, dir, {
		"`next lint` no longer exists - lint with `npm run lint`, which is plain `eslint .`",
	})
end

-- ---------------------------------------------------------------------------
-- The wizard: one floating window drives the whole flow.
--
-- Pick the project type from the tab row, edit the name and package in place,
-- tick dependencies, press Create. It never blocks, so it behaves like a Mason
-- panel - you can move around, edit text, and it responds to every key.
-- ---------------------------------------------------------------------------

---Open the wizard. `start_run` picks the initial tab ("java" by default).
---@param start_run string|nil
---@return {win: integer, buf: integer}
function M.wizard(start_run)
	local state = {
		run = start_run or "java",
		name = "",
		pkg = "",
		-- id -> true, per tab. Reset when the tab changes so a Java pick does not
		-- silently carry into a Spring pom.
		enabled = {},
		msg = nil,
		level = vim.log.levels.INFO,
	}

	---Re-derive the fields and the default ticks for the active tab.
	local function sync_defaults()
		state.name = default_name(state.run)
		if is_js(state.run) then
			-- npm's name, not a Java package. Derived from the project name so the
			-- common case is already valid: slugify keeps [a-z0-9._-], and npm
			-- forbids uppercase, spaces and a leading dot/underscore.
			state.pkg = slugify(state.name):lower()
		else
			state.pkg = "com.example."
				.. (state.run == "java" and slugify(state.name):gsub("[%-_]", "") or state.name:gsub("[^%w]", ""))
		end
		state.enabled = {}

		-- Core rows first. The renderer force-draws their box as `[x]` because they
		-- are written regardless, but `create()` collects ticks from `state.enabled`
		-- - so skipping them here meant the checklist promised `next`, `react`,
		-- `vite` and `serve` and the package.json contained none of them. A box the
		-- UI paints for you is a claim the state has to back up.
		for _, section in ipairs(sections_for(state.run)) do
			for _, item in ipairs(section.items) do
				if item.core then
					state.enabled[item.id] = true
				end
			end
		end

		for _, id in ipairs(preselect_for(state.run)) do
			state.enabled[id] = true
		end

		-- Expand `implies` from the preselect too. `toggle()` already does this for
		-- a manual tick, so preselecting `tailwind` produced no `@tailwindcss/postcss`
		-- while ticking the same row by hand did - two paths, two package.jsons.
		-- Iterate to a fixpoint so a chain (a implies b implies c) still resolves,
		-- even though nothing chains today.
		local changed = true
		while changed do
			changed = false
			for _, section in ipairs(sections_for(state.run)) do
				for _, item in ipairs(section.items) do
					if state.enabled[item.id] and item.implies then
						for _, id in ipairs(item.implies) do
							if not state.enabled[id] then
								state.enabled[id] = true
								changed = true
							end
						end
					end
				end
			end
		end
	end
	sync_defaults()

	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].modifiable = true
	vim.bo[buf].filetype = "projectgen-wizard"

	local win ---@type integer|nil
	---@type table<integer, {kind:string, id:string?, field:string?}>
	local line_info = {}
	---@type table<string, integer>
	local field_line = {}
	local alive = true

	---Build the buffer contents plus the line -> row metadata the keymaps use.
	local function render()
		local L = {}
		line_info, field_line = {}, {}

		-- Tab row. The active tab is bracketed so it does not rely on colour alone.
		local parts = {}
		for i, t in ipairs(TABS) do
			parts[#parts + 1] = t.run == state.run and (" [" .. i .. " " .. t.tab .. "]")
				or (" " .. i .. " " .. t.tab .. " ")
		end
		L[#L + 1] = table.concat(parts, "  ")
		L[#L + 1] = ""

		-- Editable fields, written as `label: value` on one line so they can be
		-- edited in place with i/A/x like ordinary text.
		local function field(key, label, value)
			L[#L + 1] = " " .. label .. ": " .. value
			local lnum = #L
			line_info[lnum] = { kind = "field", field = key }
			field_line[key] = lnum
		end
		field("name", "Project name", state.name)
		-- Same line, different meaning: on the npm tabs this field holds the
		-- package.json `name`, so labelling it "Package" would describe a Java
		-- package the tab does not have.
		if is_js(state.run) then
			field("package", "npm name    ", state.pkg)
		else
			field("package", "Package     ", state.pkg)
		end
		L[#L + 1] = ""

		for _, section in ipairs(sections_for(state.run)) do
			L[#L + 1] = " " .. section.heading
			for _, item in ipairs(section.items) do
				local box = state.enabled[item.id] and "x" or " "
				-- Two different coordinate systems share one row renderer: Maven rows
				-- are g:a:v, npm rows are name@version. Reaching for `item.g` on an npm
				-- row would raise "attempt to concatenate a nil value" the moment a
				-- frontend tab rendered.
				local coord
				if item.npm then
					coord = item.npm .. " " .. item.v
				else
					coord = item.g .. ":" .. item.a
					if item.v then
						coord = coord .. ":" .. item.v
					elseif item.managed then
						coord = coord .. ":managed"
					end
				end
				-- A `core` row is always written and cannot be unticked, so the box is
				-- drawn as ticked regardless of state: an untickable row shown as
				-- empty would read as a bug rather than as a fixed requirement.
				if item.core then
					box = "x"
				end
				local note = item.note and ("  " .. item.note) or ""
				-- Show the effective scope, not the catalogue default: JPA silently
				-- promotes H2 to runtime, and a row that disagrees with the generated
				-- pom is worse than no row.
				if state.run == "spring" and item.id == "h2" and needs_datasource(state.enabled) then
					note = "  -> runtime scope, JPA needs a driver to boot"
				end
				L[#L + 1] = string.format(" [%s] %-26s %s%s", box, item.label, coord, note)
				line_info[#L] = { kind = "item", id = item.id }
			end
			L[#L + 1] = ""
		end

		local chosen = vim.tbl_keys(state.enabled)
		table.sort(chosen)
		L[#L + 1] = " Selected: " .. (#chosen > 0 and table.concat(chosen, ", ") or "(none)")
		L[#L + 1] = ""
		L[#L + 1] = " <Tab>/<S-Tab> or 1-" .. #TABS .. " tab   <Space>/x tick   i edit field   a all   n none"
		L[#L + 1] = " <CR> create                  q / <Esc> cancel   (arrows and h/j/k/l just move)"
		if state.msg then
			L[#L + 1] = " " .. state.msg
		end

		vim.api.nvim_buf_set_lines(buf, 0, -1, false, L)
		vim.bo[buf].modifiable = true

		-- Highlights, set by hand: the window was opened with noautocmd so nothing
		-- fired a colourscheme or syntax pass over this buffer.
		vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
		local hl = vim.api.nvim_buf_add_highlight
		hl(buf, ns, "TabLine", 0, 0, -1)
		for _, lnum in pairs(field_line) do
			hl(buf, ns, "Identifier", lnum - 1, 0, 15)
		end
		for lnum, info in pairs(line_info) do
			if info.kind == "item" then
				hl(buf, ns, state.enabled[info.id] and "DiagnosticOk" or "Comment", lnum - 1, 0, 4)
			end
		end
		if state.msg then
			hl(buf, ns, state.level == vim.log.levels.ERROR and "DiagnosticError" or "DiagnosticWarn", #L - 1, 0, -1)
		end
		return L
	end

	local function close()
		if not alive then
			return
		end
		alive = false
		if win and vim.api.nvim_win_is_valid(win) then
			pcall(vim.api.nvim_win_close, win, true)
		end
	end

	---Read a field row back out of the buffer after the user edits it.
	---@param field string
	local function sync_field(field)
		local lnum = field_line[field]
		if not lnum then
			return
		end
		local text = vim.api.nvim_buf_get_lines(buf, lnum - 1, lnum, false)[1] or ""
		local value = text:match("^%s*[^:]+:%s*(.*)$")
		if value then
			if field == "name" then
				state.name = value
			else
				state.pkg = value
			end
		end
	end

	---Re-render, then resize around the new content so a short tab (Android has
	---fewer rows than Spring) does not leave a tall empty box, and a long one is
	---never clipped.
	---
	---The two field rows are read back BEFORE rendering, because render() rewrites
	---every line from `state`. Without this, ticking a row right after typing a
	---name would silently discard the name: the buffer still held the edited text,
	---but `state` did not, so the redraw put the old default back.
	---
	---`sync = false` is for callers that have just changed `state` on purpose (a
	---tab switch re-derives both fields). In that direction `state` is
	---authoritative, so reading the buffer back would undo the change.
	---@param sync boolean|nil
	local function draw(sync)
		if sync ~= false then
			sync_field("name")
			sync_field("package")
		end
		local L = render()
		if win and vim.api.nvim_win_is_valid(win) then
			local width = 0
			for _, l in ipairs(L) do
				width = math.max(width, vim.fn.strdisplaywidth(l))
			end
			local height = vim.api.nvim_buf_line_count(buf)
			width = math.min(width + 2, vim.o.columns - 4)
			height = math.min(height, vim.o.lines - 6)
			-- `relative` MUST be repeated here: reconfiguring an existing float
			-- without it raises "Required: 'relative' when reconfiguring floating
			-- window". `noautocmd` is rejected the same way, so it is simply not
			-- passed again - it only mattered for the initial open.
			vim.api.nvim_win_set_config(win, {
				relative = "editor",
				row = math.max((vim.o.lines - height) / 2 - 1, 0),
				col = math.max((vim.o.columns - width) / 2, 0),
				width = width,
				height = height,
			})
			vim.cmd("redraw")
		end
	end

	---Move to the next/previous interactive row: a field or a checklist item.
	---@param step integer
	local function move(step)
		if not win then
			return
		end
		local n = step > 0 and 1 or -1
		local total = vim.api.nvim_buf_line_count(buf)
		local ln = vim.api.nvim_win_get_cursor(win)[1]
		for _ = 1, total do
			ln = ln + n
			if ln < 1 or ln > total then
				return
			end
			local info = line_info[ln]
			if info and (info.kind == "item" or info.kind == "field") then
				vim.api.nvim_win_set_cursor(win, { ln, 0 })
				return
			end
		end
	end

	---@return {kind:string, id:string?, field:string?}?, integer
	local function current()
		if not win then
			return nil, 0
		end
		local ln = vim.api.nvim_win_get_cursor(win)[1]
		return line_info[ln], ln
	end

	---Find a catalogue row by id across the current tab's sections.
	---@param id string
	---@return table|nil
	local function find_item(id)
		for _, section in ipairs(sections_for(state.run)) do
			for _, item in ipairs(section.items) do
				if item.id == id then
					return item
				end
			end
		end
		return nil
	end

	local function toggle()
		local info = current()
		if not info or info.kind ~= "item" then
			return
		end
		local item = find_item(info.id)
		-- `core` rows are written unconditionally by the generator. Letting one be
		-- unticked would desync the checklist from the package.json that is
		-- actually emitted, and the mismatch would only surface at build time.
		if item and item.core then
			state.msg = item.label .. " is required and cannot be removed"
			state.level = vim.log.levels.WARN
			draw()
			return
		end
		local on = not state.enabled[info.id]
		state.enabled[info.id] = on
		-- An implication is one-way and unconditional: ticking MUI without its
		-- emotion peers produces a package.json npm refuses to install, and
		-- unticking one would do the same. Unticking the implied row separately is
		-- not offered; the parent row is the control.
		if item and item.implies then
			for _, id in ipairs(item.implies) do
				state.enabled[id] = on and true or nil
			end
		end
		state.msg = nil
		draw()
	end

	---@param v boolean
	local function set_all(v)
		state.enabled = {}
		if v then
			for _, section in ipairs(sections_for(state.run)) do
				for _, item in ipairs(section.items) do
					state.enabled[item.id] = true
				end
			end
		else
			-- "none" means none of the *optional* rows: clearing `core` entries
			-- would be wrong twice over, since they are written regardless and the
			-- renderer draws their box as ticked anyway.
			for _, section in ipairs(sections_for(state.run)) do
				for _, item in ipairs(section.items) do
					if item.core then
						state.enabled[item.id] = true
					end
				end
			end
		end
		state.msg = nil
		draw()
	end

	---Validate before writing anything, so a bad package never leaves half a tree.
	---@return boolean
	local function validate()
		local name = vim.trim(state.name)
		local pkg = vim.trim(state.pkg)
		if name == "" then
			state.msg, state.level = "project name must not be empty", vim.log.levels.ERROR
			return false
		end
		if not class_name(name) then
			state.msg, state.level = "project name has no alphanumeric characters", vim.log.levels.ERROR
			return false
		end
		-- Two rules for one field. `pkg_path` validates a Java package and would
		-- reject an npm name for the wrong reasons (`com.example.demo` has valid
		-- segments but is not a legal npm name either); `npm_name` does the same
		-- in reverse. Only one applies per tab.
		--
		-- Deliberately an if/else and NOT `cond and npm_name(pkg) or pkg_path(pkg)`.
		-- Both validators return `(value, err)`, and Lua's `and`/`or` yield a single
		-- value: the `and` drops the error message, the `or` then sees `nil`, calls
		-- the other validator, and the assignment ends up with `perr = nil` either
		-- way. Validation silently never failed - `UPPERCASE-BAD` and `com..demo`
		-- both created a wizard that closed as if it had succeeded. Assign both
		-- values explicitly, and never `a and f() or g()` over a multi-return.
		local ok_p, perr
		if is_js(state.run) then
			ok_p, perr = npm_name(pkg)
		else
			ok_p, perr = pkg_path(pkg)
		end
		if not ok_p then
			state.msg, state.level = perr, vim.log.levels.ERROR
			return false
		end
		local _, derr = resolve_dir(name)
		if derr then
			state.msg, state.level = derr, vim.log.levels.ERROR
			return false
		end
		state.msg, state.level = nil, vim.log.levels.INFO
		return true
	end

	---Run the generator for the current tab and close the wizard.
	local function create()
		sync_field("name")
		sync_field("package")
		if not validate() then
			return draw()
		end

		local name = vim.trim(state.name)
		local dir, err = resolve_dir(name)
		if not dir then
			state.msg, state.level = err, vim.log.levels.ERROR
			return draw()
		end

		-- Collect the ticked entries in catalogue order, not set-iteration order, so
		-- the generated build file is byte-stable between runs.
		local picked = {}
		for _, section in ipairs(sections_for(state.run)) do
			for _, item in ipairs(section.items) do
				if state.enabled[item.id] then
					picked[#picked + 1] = item
				end
			end
		end

		close()
		M[state.run](name, vim.trim(state.pkg), picked, dir)
	end

	render()
	local width = 0
	for _, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
		width = math.max(width, vim.fn.strdisplaywidth(l))
	end
	local height = vim.api.nvim_buf_line_count(buf)
	width = math.min(width + 2, vim.o.columns - 4)
	height = math.min(height, vim.o.lines - 6)

	win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		row = math.max((vim.o.lines - height) / 2 - 1, 0),
		col = math.max((vim.o.columns - width) / 2, 0),
		width = width,
		height = height,
		style = "minimal",
		border = "rounded",
		title = " projectgen: new project ",
		title_pos = "center",
		noautocmd = true,
	})

	-- `wrap` and `cursorline` are WINDOW-local, so they cannot be set through
	-- vim.bo[buf] before the window exists; assigning one there raises
	-- "'buf' cannot be passed for window-local option".
	vim.wo[win].wrap = false
	vim.wo[win].cursorline = true
	vim.api.nvim_win_set_cursor(win, { field_line.name or 1, 0 })
	vim.cmd("redraw")
	vim.cmd("stopinsert")

	---@param mode string
	---@param key string
	---@param fn function
	local function map(mode, key, fn)
		vim.keymap.set(mode, key, fn, { buffer = buf, nowait = true, silent = true })
	end

	map("n", "<CR>", create)
	map("n", "q", close)
	map("n", "<Esc>", close)
	map("n", "<Space>", toggle)
	map("n", "x", toggle)
	map("n", "a", function()
		set_all(true)
	end)
	map("n", "n", function()
		set_all(false)
	end)
	-- <Left>/<Right>/<Up>/<Down> are deliberately NOT remapped: arrows move the
	-- cursor, like everywhere else in the editor. Binding <Left> to "previous tab"
	-- meant you could not step back through a field you had just edited, and it
	-- was invisible from the help line until you hit it. Tab navigation is <Tab>/
	-- <S-Tab> plus 1-<#>; h/l/j/k keep their built-in cursor motion too, so the
	-- only remaining structural keys are <Tab>, <S-Tab> and the digit row.
	-- j/k deliberately still skip heading/blank lines (move()), but <Up>/<Down>
	-- are left alone so normal cursor motion always remains reachable.
	local function go_tab(idx)
		if state.run ~= TABS[idx].run then
			state.run = TABS[idx].run
			sync_defaults()
			state.msg = nil
			draw(false)
			if field_line.name then
				vim.api.nvim_win_set_cursor(win, { field_line.name, 0 })
			end
		end
	end

	---@param step integer
	local function cycle(step)
		local idx = 1
		for i, t in ipairs(TABS) do
			if t.run == state.run then
				idx = i
			end
		end
		go_tab(((idx - 1 + step) % #TABS) + 1)
	end

	map("n", "<Tab>", function()
		cycle(1)
	end)
	map("n", "<S-Tab>", function()
		cycle(-1)
	end)

	for i = 1, #TABS do
		map("n", tostring(i), function()
			go_tab(i)
		end)
	end
	map("n", "j", function()
		move(1)
	end)
	map("n", "k", function()
		move(-1)
	end)
	map("n", "g?", function()
		state.msg = table.concat({
			"i/A edit a field",
			"<CR> create",
			"q cancel",
			"a/n all/none",
			"<Tab>/<S-Tab> tab",
			"1-" .. #TABS .. " jump to tab",
			"arrows just move the cursor",
		}, " | ")
		draw()
	end)

	-- Leaving insert mode on a field commits what was typed, so Create never
	-- picks up a half-typed value.
	vim.api.nvim_create_autocmd("InsertLeave", {
		buffer = buf,
		callback = function()
			local info = current()
			if info and info.kind == "field" then
				sync_field(info.field)
				draw()
			end
		end,
	})

	-- Closing the float any other way (:q, :bd, closing the tab) must not leave a
	-- stale wizard behind.
	vim.api.nvim_create_autocmd("BufWinLeave", {
		buffer = buf,
		once = true,
		callback = function()
			alive = false
		end,
	})

	return { win = win, buf = buf }
end

---Register the user commands. Called once from plugin/projectgen.lua when the
---plugin loads; idempotent, so calling it again from a config or a test suite
---is harmless instead of erroring with "command already exists".
---
---Each command opens the SAME wizard on its own tab, rather than prompting
---itself. There is deliberately no second, tab-less code path: one flow is one
---flow, and two would drift.
function M.setup()
	if M.setup_done then
		return
	end
	M.setup_done = true

	vim.api.nvim_create_user_command("NewProject", function()
		M.wizard()
	end, { desc = "New project wizard (Java / Spring Boot / Android)" })

	for _, t in ipairs(TABS) do
		-- `[^%w]` rather than `%s`: "Next.js" has no space, and stripping only
		-- spaces produced `NewNext.jsProject`, which Vim rejects because a
		-- user-command name may not contain `.`. The tab would have had no
		-- command at all, with no error at load time. `cmd` overrides the label
		-- when a nicer spelling exists.
		local suffix = t.cmd or (t.tab:gsub("[^%w]", ""))
		vim.api.nvim_create_user_command("New" .. suffix .. "Project", function()
			M.wizard(t.run)
		end, { desc = "New project wizard, starting on the " .. t.tab .. " tab" })
	end
end

return M
