# projectgen.nvim

An IntelliJ-style **New Project** wizard for Neovim. One floating window, seven tabs — Java, Spring Boot, Android, Vanilla JS, Vite, React, Next.js — where you type the project name, tick the dependencies you want, and press Create. Every tick becomes a real coordinate in the build file (a Maven `<dependency>`, a Gradle dependency, or an npm entry), so the generated project opens with its dependencies already resolved.

No third-party Neovim dependencies. Nothing generates, downloads, or writes until you press Create. The frontend tabs print the `npm install` command instead of running it — generation is fully offline.

```
:NewProject             open the wizard (Java tab)          <Leader>pn
:NewJavaProject         open it on the Java tab             <Leader>pv
:NewSpringBootProject   open it on the Spring Boot tab      <Leader>ps
:NewAndroidProject      open it on the Android tab          <Leader>pa
:NewVanillaJSProject    open it on the Vanilla JS tab       <Leader>pb
:NewViteProject         open it on the Vite tab             <Leader>pt
:NewReactProject        open it on the React tab            <Leader>pr
:NewNextJSProject       open it on the Next.js tab          <Leader>px
```

## Installation

**lazy.nvim**

```lua
{
  "ihabau/projectgen.nvim",
  cmd = { "NewProject", "NewJavaProject", "NewSpringBootProject",
          "NewAndroidProject", "NewVanillaJSProject", "NewViteProject",
          "NewReactProject", "NewNextJSProject" },
}
```

**vim-plug**

```vim
Plug 'ihabau/projectgen.nvim'
```

**packer / mini.deps / manual** — clone it onto `runtimepath` and let `plugin/projectgen.lua` load. `git clone https://github.com/ihabau/projectgen.nvim ~/.vim/pack/plugins/start/projectgen.nvim` works for the no-manager case.

`require("projectgen").setup()` registers the commands and is idempotent; the plugin loader already calls it, so no config is required.

## Usage

- Run any command above; the wizard opens on that tab.
- `Project name`, `package`/`group`, and `npm name` are **real buffer text** — edit them with `i`/`A`/`x`.
- Tick the dependency checklist; every ticked row becomes a dependency or import in the output.
- Keys: `<Tab>`/`<S-Tab>` or digits `1..7` switch tabs, `g?` shows help, `a`/`n` tick all / clear all, `<CR>` generates, `q`/`<Esc>` abandons. Arrow keys stay plain cursor motion (by design).
- The wizard runs in the current working directory — `:cd` there first if needed.
- **An existing non-empty directory is always refused.** There is no `--force`, and never will be.

For the keymap bindings above (`<Leader>pn/pr/px/...`), see `:help projectgen-keymaps`.

## What it generates

| Tab | Output |
| --- | --- |
| **Java** | `pom.xml` (Maven, release 21), `Main.java`, JUnit 5 test, Maven wrapper |
| **Spring Boot** | `pom.xml` (Boot parent, release 17), `@SpringBootApplication` class, `application.properties`, `@SpringBootTest`, Maven wrapper |
| **Android** | Gradle `kotlin` build files, app module, manifest, themed `MainActivity`, layouts, ProGuard/test stubs |
| **Vanilla JS** | `package.json` + HTML/CSS/JS, `serve` for local serving, vitest+jsdom tests |
| **Vite** | Vite app (optional React stays off), Tailwind, vitest+jsdom, `:ts-imports`-style sharing |
| **React** | Vite + React + react-router, MUI, zustand, `@tanstack/react-query`, RTL tests |
| **Next.js** | App Router app with `"use client"` boundary, ESLint config, Tailwind |

The npm catalogue pins every version (`^8.3.2`, `^19.3.0`, ...) so output is reproducible; generated projects are verified by generating each frontend tab at maximum tick count and running real `npm install` / `npm run build` / `npm test`.

## Requirements

- Neovim 0.9+ (user commands, floating windows).
- JDK/Maven or Android SDK only if you want to *run* the Java/Spring/Android output; Node/npm for the frontend tabs. The plugin itself needs nothing.

## Testing

Headless suites run from the repo root (`ALL PASSED` + exit 0 on success):

```bash
nvim --headless -u test/init.lua -l test/pg_verify2.lua -c "qa!"
nvim --headless -u test/init.lua -l test/pg_verify3.lua -c "qa!"
```

`pg_verify2` covers Java/Spring/Android (188 assertions), `pg_verify3` covers the frontend tabs and the cross-framework compatibility rules documented in `:help projectgen-generation` (zustand only on React tabs, no `@testing-library/react` on Vite, no jQuery on Next.js).

## License

MIT — see [LICENSE](LICENSE).