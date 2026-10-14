# scripts/kconfig - ARES core configuration (menuconfig)

A small, dependency-free configuration tool for the ARES core RTL, modelled
after the `ysyx-workbench/npc` flow (`configs/Kconfig` → menuconfig →
generated `vsrc/include/autoconf.vh`), but implemented in one Python file so
the repository needs no kconfig/ncurses build and no python venv.

## Usage

```bash
make menuconfig      # interactive menu; writes configs/build/.config
make defconfig       # write the Kconfig defaults (no UI)
make oldconfig       # keep .config, fill in symbols added since
make savedefconfig   # write configs/defconfig (non-default values only)
make loaddefconfig   # restore configs/defconfig over the defaults
make showconfig      # print the effective configuration
make test-config     # self-test of the tool (see below)
```

The menu itself is `configs/Kconfig`; add entries there, not in the tool.

## What a selection does

| Artifact | Consumer |
|---|---|
| `configs/build/.config` | the selection itself (gitignored) |
| `configs/build/vsrc/include/ares_autoconf.vh` | ````ifdef CONFIG_*```` in RTL, Vivado projects |
| `ares_kconfig.py defs` (`-DCONFIG_*`) | `sim/Makefile` `V_DEF_MACRO` (Verilator) |

`rtl/common/ares_pkg.sv` reads the values with a fallback to the frozen C0
default, so a bare elaboration without the generated defines still works:

```systemverilog
````ifdef CONFIG_LINE_BYTES
    localparam int unsigned LINE_BYTES = ````CONFIG_LINE_BYTES;
````else
    localparam int unsigned LINE_BYTES = 32;   // menuconfig default
````endif
```

`make menuconfig` regenerates the header immediately; a build also refreshes it
whenever `configs/Kconfig`, the tool or `.config` is newer (the binary depends
on it, so a configuration change forces a rebuild).

## Rules for adding a configuration

1. Only **internal implementation parameters** may be configurable.  A symbol
   must not change the cross-boundary field layout frozen in
   `rtl/common/ares_pkg.sv` (`docs/c0_decisions.md` D-C0-02, SPEC-C5):
   separately compiled modules would then disagree about the same struct.
2. Keep the default equal to the frozen C0 value, and keep the fallback in the
   RTL equal to that default.
3. Constrain the domain in Kconfig (`range` / `choice`) and check the value in
   `rtl/common/test/tb_ares_pkg.sv`, which prints the effective configuration
   with every test run.

## Supported Kconfig subset

`mainmenu`, `menu`/`endmenu`, `source`, `config`, `choice`/`endchoice`,
`comment`, the `bool|int|hex|string` types, `prompt`, `default`, `range` and
`help` (keywords are indentation insensitive, exactly like the real grammar;
only help text is indentation delimited).

`depends on`, `select`, `imply` and `visible if` are **not implemented** -
the parser stops with an explicit error instead of silently mis-evaluating a
dependency.

Choice naming convention: a choice named `X` with members `X_<n>` emits both
`CONFIG_X=<n>` and `CONFIG_X_<n>=1`, so the RTL can use `CONFIG_X` directly.

## UI notes

`make menuconfig` opens a curses menu (UP/DOWN move, ENTER enter/toggle,
S save & exit, Q quit, ESC back, H help).  When `curses` or a tty is missing
it falls back to a line-based menu with the same effect; force it with
`ARES_KCONFIG_NOCURSES=1`.  `make test-config` exercises both paths (the
curses loop is driven through a mock screen, plus a real pty session when the
environment provides one).
