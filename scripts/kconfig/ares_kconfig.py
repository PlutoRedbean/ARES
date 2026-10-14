#!/usr/bin/env python3
# =============================================================================
# ARES core configuration tool
# -----------------------------------------------------------------------------
# A dependency-free, Kconfig-style configuration tool for the ARES core RTL,
# modelled after the ysyx-workbench/npc flow (configs/Kconfig + menuconfig +
# generated vsrc/include/autoconf.vh), but implemented in a single Python file
# so the repository needs no kconfig/ncurses build and no python venv.
#
#   make menuconfig      interactive menu, saves configs/build/.config
#   make defconfig       write the defaults (no UI)
#   make savedefconfig   write configs/defconfig (non-default values only)
#   make loaddefconfig   restore configs/defconfig over the defaults
#   make oldconfig       keep the existing .config, fill in new symbols
#   make showconfig      print the effective configuration
#
# Outputs (both from the same .config):
#   configs/build/.config                        the saved selection
#   configs/build/vsrc/include/ares_autoconf.vh  SV defines for RTL/Vivado
#   ares_kconfig.py defs                         -DCONFIG_* for Verilator
#
# Supported Kconfig subset: mainmenu, menu/endmenu, source, config, choice/
# endchoice, comment, the bool|int|hex|string types, prompt, default, range and
# help.  depends on / select / imply are deliberately NOT implemented: the
# parser fails loudly instead of silently mis-evaluating a dependency.
# =============================================================================

import argparse
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ARES_HOME = os.path.abspath(os.path.join(HERE, os.pardir, os.pardir))
CONFIG_DIR = os.path.join(ARES_HOME, "configs")
KCONFIG_ROOT = os.path.join(CONFIG_DIR, "Kconfig")
BUILD_DIR = os.path.join(CONFIG_DIR, "build")
DOT_CONFIG = os.path.join(BUILD_DIR, ".config")
DEFCONFIG = os.path.join(CONFIG_DIR, "defconfig")
AUTOCONF_VH = os.path.join(BUILD_DIR, "vsrc", "include", "ares_autoconf.vh")

BT = chr(96)  # SystemVerilog compiler-directive prefix
SUPPORTED_UNSUPPORTED = ("depends on", "select ", "imply ", "visible if")
# Kconfig keywords are indentation insensitive in the real grammar; only the
# help text is indentation delimited.  Keeping the same rule here means an
# indented "config" inside a choice (or a copy/pasted Linux-style file) parses
# the same way it does with mconf.
BLOCK_KEYWORDS = ("mainmenu", "menu", "endmenu", "source", "config", "choice",
                  "endchoice", "comment")


# =============================================================================
# Data model
# =============================================================================
class Symbol:
    def __init__(self, name):
        self.name = name
        self.type = None          # bool | int | hex | string
        self.prompt = None
        self.default = None
        self.range = None
        self.help = ""
        self.value = None
        self.choice = None        # owning Choice when it is a choice member


class Choice:
    def __init__(self, name):
        self.name = name
        self.prompt = None
        self.default = None
        self.help = ""
        self.members = []
        self.selected = None


class Menu:
    def __init__(self, title=None):
        self.title = title
        self.entries = []


class Config:
    """The whole configuration: menu tree + symbols + effective values."""

    def __init__(self):
        self.title = "ARES Core Configuration"
        self.root = Menu(None)
        self.symbols = {}
        self.choices = {}


# =============================================================================
# Kconfig subset parser
# =============================================================================
def _quoted(text):
    m = re.search(r'"([^"]*)"', text)
    return m.group(1) if m else None


def _literal(token):
    token = token.strip()
    if token in ("y", "n"):
        return token == "y"
    if token.startswith('"') and token.endswith('"'):
        return token[1:-1]
    if re.fullmatch(r"0x[0-9a-fA-F]+", token):
        return int(token, 16)
    if re.fullmatch(r"-?[0-9]+", token):
        return int(token)
    return token  # symbol reference (bool / choice default)


class Parser:
    def __init__(self):
        self.cfg = Config()
        self._seen = set()

    def parse(self, path):
        self._parse_file(os.path.abspath(path), [self.cfg.root])
        return self.cfg

    def _parse_file(self, path, menu_stack):
        if path in self._seen:
            return
        self._seen.add(path)
        try:
            with open(path, "r", encoding="utf-8") as fh:
                lines = fh.read().splitlines()
        except OSError as exc:
            raise SystemExit("ares_kconfig: cannot read %s: %s" % (path, exc))

        cur = None          # current Symbol
        cur_choice = None   # current Choice
        i = 0

        while i < len(lines):
            raw = lines[i]
            i += 1
            text = raw.strip()
            if not text or text.startswith("#"):
                continue
            word = text.split()[0]

            if word in BLOCK_KEYWORDS:
                if word == "mainmenu":
                    self.cfg.title = _quoted(text) or self.cfg.title
                    cur, cur_choice = None, None
                elif word == "menu":
                    menu = Menu(_quoted(text) or "menu")
                    menu_stack[-1].entries.append(menu)
                    menu_stack.append(menu)
                    cur, cur_choice = None, None
                elif word == "endmenu":
                    if len(menu_stack) > 1:
                        menu_stack.pop()
                    cur, cur_choice = None, None
                elif word == "source":
                    target = _quoted(text)
                    if target is None:
                        raise SystemExit("ares_kconfig: source without a path: %s" % text)
                    self._parse_file(os.path.join(os.path.dirname(path), target), menu_stack)
                elif word == "comment":
                    cur, cur_choice = None, None
                elif word == "config":
                    if len(text.split()) < 2:
                        raise SystemExit("ares_kconfig: config without a name: %s" % text)
                    sym = Symbol(text.split()[1])
                    self.cfg.symbols[sym.name] = sym
                    if cur_choice is not None:
                        sym.choice = cur_choice
                        cur_choice.members.append(sym)
                    else:
                        menu_stack[-1].entries.append(sym)
                    cur = sym
                elif word == "choice":
                    name = text.split()[1] if len(text.split()) > 1 else None
                    ch = Choice(name)
                    self.cfg.choices[name] = ch
                    menu_stack[-1].entries.append(ch)
                    cur, cur_choice = None, ch
                elif word == "endchoice":
                    cur, cur_choice = None, None
                else:
                    raise SystemExit("ares_kconfig: unsupported keyword '%s' in %s" % (word, path))
                continue

            # ---- properties -------------------------------------------------
            target = cur if cur is not None else cur_choice
            if target is None:
                raise SystemExit("ares_kconfig: property outside a block: %s" % text)

            for bad in SUPPORTED_UNSUPPORTED:
                if text.startswith(bad):
                    raise SystemExit(
                        "ares_kconfig: '%s' is not in the supported Kconfig subset "
                        "(see the header of this file): %s" % (bad.strip(), text))

            if word in ("bool", "int", "hex", "string"):
                target.type = word
                prompt = _quoted(text)
                if prompt is not None:
                    target.prompt = prompt
            elif word == "prompt":
                target.prompt = _quoted(text)
            elif word == "default":
                value = text[len("default"):].strip()
                value = re.split(r"\s+if\s+", value)[0]
                target.default = _literal(value)
            elif word == "range":
                parts = text.split()
                target.range = (int(parts[1], 0), int(parts[2], 0))
            elif word in ("help", "---help---"):
                block = []
                help_indent = None
                while i < len(lines):
                    nxt = lines[i]
                    if nxt.strip() == "":
                        block.append("")
                        i += 1
                        continue
                    if nxt.split()[0] in BLOCK_KEYWORDS:
                        break
                    indent = len(nxt) - len(nxt.lstrip())
                    if indent == 0:
                        break
                    if help_indent is None:
                        help_indent = indent
                    elif indent < help_indent:
                        break
                    block.append(nxt.strip())
                    i += 1
                while block and block[-1] == "":
                    block.pop()
                target.help = "\n".join(block)
            else:
                raise SystemExit("ares_kconfig: unsupported property '%s'" % word)


# =============================================================================
# .config load / resolve / store
# =============================================================================
def load_dot_config(path):
    values = {}
    if not os.path.exists(path):
        return values
    with open(path, "r", encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            m = re.match(r"^CONFIG_([A-Za-z0-9_]+)=(.*)$", line)
            if m:
                values[m.group(1)] = _literal(m.group(2))
                continue
            m = re.match(r"^# CONFIG_([A-Za-z0-9_]+) is not set$", line)
            if m:
                values[m.group(1)] = None
    return values


def resolve(cfg, saved):
    """Fill in every effective value; saved is the raw .config mapping."""
    for ch in cfg.choices.values():
        selected = None
        for member in ch.members:
            if saved.get(member.name) in (True, 1):  # tolerate y and 1
                selected = member.name
                break
        if selected is None and isinstance(ch.default, str):
            names = [m.name for m in ch.members]
            if ch.default in names:
                selected = ch.default
        if selected is None and ch.members:
            selected = ch.members[0].name
        ch.selected = selected
        for member in ch.members:
            member.value = (member.name == selected)

    for name, sym in cfg.symbols.items():
        if sym.choice is not None:
            continue
        raw = saved.get(name, _MISSING)
        if sym.type == "bool":
            sym.value = (raw in (True, 1)) if raw is not _MISSING else bool(sym.default)
        elif sym.type in ("int", "hex"):
            value = raw if isinstance(raw, int) else sym.default
            if not isinstance(value, int):
                value = 0
            if sym.range:
                value = max(sym.range[0], min(sym.range[1], value))
            sym.value = value
        elif sym.type == "string":
            value = raw if isinstance(raw, str) else sym.default
            sym.value = value if isinstance(value, str) else ""
        elif sym.type is None:
            sym.value = None
        else:
            raise SystemExit("ares_kconfig: symbol %s has no type" % name)


_MISSING = object()


def emitted_symbols(cfg):
    """The CONFIG_* name -> value mapping used by both generators."""
    out = {}
    for ch in cfg.choices.values():
        if not ch.name or not ch.selected:
            continue
        suffix = ch.selected
        if ch.name and ch.selected.startswith(ch.name + "_"):
            suffix = ch.selected[len(ch.name) + 1:]
        out[ch.name] = int(suffix) if suffix.isdigit() else 1
        out[ch.selected] = 1
    for name, sym in cfg.symbols.items():
        if sym.choice is not None:
            continue
        if sym.type == "bool":
            if sym.value:
                out[name] = 1
        elif sym.type in ("int", "hex"):
            if sym.value is not None:
                out[name] = sym.value
        elif sym.type == "string":
            out[name] = sym.value
    return out


def write_dot_config(cfg, path):
    lines = ["#", "# Automatically generated file; DO NOT EDIT.", "# %s" % cfg.title, "#", ""]

    def emit(entries):
        for entry in entries:
            if isinstance(entry, Menu):
                lines.append("#")
                lines.append("# %s" % entry.title)
                lines.append("#")
                emit(entry.entries)
                lines.append("")
            elif isinstance(entry, Choice):
                lines.append("#")
                lines.append("# %s" % (entry.prompt or entry.name or "choice"))
                lines.append("#")
                for member in entry.members:
                    if member.value:
                        lines.append("CONFIG_%s=y" % member.name)
                    else:
                        lines.append("# CONFIG_%s is not set" % member.name)
                if entry.name and entry.selected:
                    suffix = entry.selected
                    if entry.selected.startswith(entry.name + "_"):
                        suffix = entry.selected[len(entry.name) + 1:]
                    if suffix.isdigit():
                        lines.append("CONFIG_%s=%s" % (entry.name, suffix))
                lines.append("")
            elif isinstance(entry, Symbol):
                if entry.type == "bool":
                    if entry.value:
                        lines.append("CONFIG_%s=y" % entry.name)
                    else:
                        lines.append("# CONFIG_%s is not set" % entry.name)
                elif entry.type in ("int", "hex"):
                    lines.append("CONFIG_%s=%s" % (entry.name, entry.value))
                elif entry.type == "string":
                    lines.append('CONFIG_%s="%s"' % (entry.name, entry.value))

    emit(cfg.root.entries)
    write_if_changed(path, "\n".join(lines).rstrip("\n") + "\n")


def sv_value(value):
    if isinstance(value, str):
        return '"%s"' % value
    return str(value)


def write_autoconf(cfg, path):
    body = [
        "/** Auto-generated by scripts/kconfig/ares_kconfig.py - DO NOT EDIT **/",
        "",
        BT + "ifndef __ARES_AUTOCONF_VH__",
        BT + "define __ARES_AUTOCONF_VH__",
        "",
    ]
    for name in sorted(emitted_symbols(cfg)):
        body.append("%sifndef CONFIG_%s" % (BT, name))
        body.append("%sdefine CONFIG_%s %s" % (BT, name, sv_value(emitted_symbols(cfg)[name])))
        body.append("%sendif" % BT)
    body += ["", BT + "endif", ""]
    write_if_changed(path, "\n".join(body))


def write_if_changed(path, text):
    try:
        with open(path, "r", encoding="utf-8") as fh:
            if fh.read() == text:
                return False
    except OSError:
        pass
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)
    return True


def kconfig_values(cfg):
    """The CONFIG_* values as they appear in a .config / defconfig file."""
    out = {}
    for name, sym in cfg.symbols.items():
        if sym.choice is not None:
            out[name] = "y" if sym.value else "n"
        elif sym.type == "bool":
            out[name] = "y" if sym.value else "n"
        elif sym.type in ("int", "hex"):
            out[name] = sym.value
        elif sym.type == "string":
            out[name] = sym.value
    for ch in cfg.choices.values():
        if ch.name and ch.selected:
            suffix = ch.selected
            if ch.selected.startswith(ch.name + "_"):
                suffix = ch.selected[len(ch.name) + 1:]
            if suffix.isdigit():
                out[ch.name] = int(suffix)
    return out


def kconfig_text(value):
    if isinstance(value, str) and value not in ("y", "n"):
        return '"%s"' % value
    return str(value)


def write_defconfig(cfg, path):
    """Only the values that differ from the defaults (kconfig savedefconfig)."""
    defaults = build_config()
    resolve(defaults, {})
    now = kconfig_values(cfg)
    base = kconfig_values(defaults)
    lines = ["# ARES defconfig: only values that differ from the Kconfig defaults"]
    for name in sorted(now):
        if now[name] == "n":
            continue  # absence means "not selected"; keeps the file minimal
        if base.get(name) != now[name]:
            lines.append("CONFIG_%s=%s" % (name, kconfig_text(now[name])))
    write_if_changed(path, "\n".join(lines) + "\n")


# =============================================================================
# Interactive UI
# =============================================================================
def item_label(entry):
    if isinstance(entry, Menu):
        return "-> %s" % entry.title
    if isinstance(entry, Choice):
        selected = None
        for member in entry.members:
            if member.value:
                selected = member
        text = entry.prompt or entry.name or "choice"
        return "%s: %s" % (text, selected.prompt if selected else "?")
    if entry.type == "bool":
        return "[%s] %s" % ("X" if entry.value else " ", entry.prompt or entry.name)
    return "(%s) %s" % (entry.value, entry.prompt or entry.name)


def set_symbol(sym, raw):
    if sym.type == "bool":
        sym.value = not sym.value
        return True, ""
    if sym.type in ("int", "hex"):
        try:
            value = int(raw, 0)
        except ValueError:
            return False, "not a number: %s" % raw
        if sym.range and not (sym.range[0] <= value <= sym.range[1]):
            return False, "out of range %d..%d" % sym.range
        sym.value = value
        return True, ""
    if sym.type == "string":
        sym.value = raw
        return True, ""
    return False, "symbol %s has no type" % sym.name


def select_choice(choice, member):
    for m in choice.members:
        m.value = (m is member)
    choice.selected = member.name


SAVE = "save"
DISCARD = "discard"


def ui_line(cfg):
    """Line based fallback (no curses / not a tty / ARES_KCONFIG_NOCURSES)."""
    stack = [cfg.root]
    print("%s - line mode" % cfg.title)
    while True:
        menu = stack[-1]
        print()
        print("--- %s ---" % (menu.title or cfg.title))
        for index, entry in enumerate(menu.entries):
            print("  %2d) %s" % (index + 1, item_label(entry)))
        print("  commands: <n> select, b = back, s = save & exit, q = quit, ? = help")
        try:
            cmd = input("> ").strip()
        except EOFError:
            return DISCARD
        if cmd in ("s", "save"):
            return SAVE
        if cmd in ("q", "quit"):
            return DISCARD
        if cmd == "?":
            for entry in menu.entries:
                print()
                print(item_label(entry))
                if getattr(entry, "help", ""):
                    print(entry.help)
            continue
        if cmd in ("b", "back"):
            if len(stack) > 1:
                stack.pop()
            continue
        if not cmd.isdigit() or not (1 <= int(cmd) <= len(menu.entries)):
            print("  ? unknown command")
            continue
        entry = menu.entries[int(cmd) - 1]
        if isinstance(entry, Menu):
            stack.append(entry)
        elif isinstance(entry, Choice):
            print("  %s" % (entry.prompt or entry.name))
            for index, member in enumerate(entry.members):
                mark = "*" if member.value else " "
                print("    %d) [%s] %s" % (index + 1, mark, member.prompt or member.name))
            pick = input("  select [1-%d, empty = cancel]: " % len(entry.members)).strip()
            if pick.isdigit() and 1 <= int(pick) <= len(entry.members):
                select_choice(entry, entry.members[int(pick) - 1])
        elif entry.type == "bool":
            entry.value = not entry.value
            print("  %s = %s" % (entry.name, entry.value))
        else:
            raw = input("  %s [%s]: " % (entry.prompt or entry.name, entry.value)).strip()
            if raw:
                ok, message = set_symbol(entry, raw)
                print("  %s" % ("ok" if ok else message))


def ui_curses(cfg):
    import curses

    def draw(stdscr, stack, status):
        stdscr.erase()
        height, width = stdscr.getmaxyx()
        menu = stack[-1]
        title = "%s  [%s]" % (cfg.title, menu.title or "root")
        stdscr.addstr(0, 0, title[:width - 1], curses.A_REVERSE)
        for index, entry in enumerate(menu.entries):
            if index + 2 >= height - 2:
                break
            attr = curses.A_NORMAL
            if index == stack[-1].index:
                attr = curses.A_REVERSE
            stdscr.addstr(index + 2, 1, item_label(entry)[:width - 3], attr)
        keyline = "UP/DOWN move  ENTER enter/toggle  S save&exit  Q quit  ESC back  H help"
        stdscr.addstr(height - 2, 0, keyline[:width - 1], curses.A_REVERSE)
        stdscr.addstr(height - 1, 0, status[:width - 1])
        stdscr.refresh()

    def popup(stdscr, message):
        height, width = stdscr.getmaxyx()
        win = curses.newwin(3, width - 4, height // 2 - 1, 2)
        win.box()
        win.addstr(1, 2, message[:width - 8])
        win.refresh()
        win.getch()

    def edit(stdscr, prompt, initial):
        height, width = stdscr.getmaxyx()
        stdscr.addstr(height - 1, 0, " " * (width - 1))
        stdscr.addstr(height - 1, 0, prompt[:width - 20])
        stdscr.refresh()
        curses.echo()
        curses.curs_set(1)
        try:
            raw = stdscr.getstr(height - 1, min(len(prompt), width - 20), 40).decode()
        except Exception:
            raw = ""
        curses.noecho()
        curses.curs_set(0)
        return raw.strip()

    return curses.wrapper(_curses_main, cfg, draw, popup, edit)


def _curses_main(stdscr, cfg, draw, popup, edit):
    import curses

    try:
        curses.curs_set(0)
    except curses.error:  # no terminal (unit test / redirected output)
        pass
    stdscr.keypad(True)
    stack = [cfg.root]
    stack[-1].index = 0
    status = "SPACE/ENTER toggles or edits; S saves."
    while True:
        draw(stdscr, stack, status)
        key = stdscr.getch()
        menu = stack[-1]
        count = len(menu.entries)
        if key in (curses.KEY_UP, ord("k")):
            menu.index = (menu.index - 1) % max(count, 1)
        elif key in (curses.KEY_DOWN, ord("j")):
            menu.index = (menu.index + 1) % max(count, 1)
        elif key in (curses.KEY_LEFT, 27):
            if len(stack) > 1:
                stack.pop()
                status = "back"
            else:
                answer = edit(stdscr, "Save configuration before exit? [y/N] ", "")
                return SAVE if answer.lower().startswith("y") else DISCARD
        elif key in (ord("s"),):
            return SAVE
        elif key in (ord("q"),):
            return DISCARD
        elif key in (ord("h"), ord("?")):
            entry = menu.entries[menu.index] if count else None
            popup(stdscr, getattr(entry, "help", "") or item_label(entry))
        elif key in (curses.KEY_ENTER, 10, 13, ord(" ")):
            if not count:
                continue
            entry = menu.entries[menu.index]
            if isinstance(entry, Menu):
                entry.index = 0
                stack.append(entry)
            elif isinstance(entry, Choice):
                # A choice is presented as one line showing the current member;
                # ENTER and SPACE both advance to the next one (the members are
                # listed in the line-mode UI and in the item help).
                current = 0
                for index, member in enumerate(entry.members):
                    if member.value:
                        current = index
                selected = entry.members[(current + 1) % len(entry.members)]
                select_choice(entry, selected)
                status = "%s = %s" % (entry.prompt or entry.name, selected.prompt)
            elif entry.type == "bool":
                entry.value = not entry.value
                status = "%s = %s" % (entry.name, entry.value)
            else:
                raw = edit(stdscr, "%s: " % (entry.prompt or entry.name), str(entry.value))
                if raw:
                    ok, message = set_symbol(entry, raw)
                    status = message if not ok else "%s = %s" % (entry.name, entry.value)


# =============================================================================
# Commands
# =============================================================================
def build_config():
    parser = Parser()
    cfg = parser.parse(KCONFIG_ROOT)
    return cfg


def cmd_defconfig(args):
    cfg = build_config()
    resolve(cfg, {})
    write_dot_config(cfg, DOT_CONFIG)
    write_autoconf(cfg, AUTOCONF_VH)
    print("ares_kconfig: wrote defaults to %s" % os.path.relpath(DOT_CONFIG, ARES_HOME))
    return 0


def cmd_menuconfig(args):
    cfg = build_config()
    resolve(cfg, load_dot_config(DOT_CONFIG))
    if os.environ.get("ARES_KCONFIG_NOCURSES") or not (sys.stdin.isatty() and sys.stdout.isatty()):
        result = ui_line(cfg)
    else:
        try:
            result = ui_curses(cfg)
        except ImportError:
            print("ares_kconfig: curses unavailable, falling back to line mode")
            result = ui_line(cfg)
    if result != SAVE:
        print("ares_kconfig: configuration unchanged")
        return 0
    write_dot_config(cfg, DOT_CONFIG)
    write_autoconf(cfg, AUTOCONF_VH)
    print("ares_kconfig: saved %s" % os.path.relpath(DOT_CONFIG, ARES_HOME))
    show(cfg)
    return 0


def cmd_oldconfig(args):
    cfg = build_config()
    resolve(cfg, load_dot_config(DOT_CONFIG))
    write_dot_config(cfg, DOT_CONFIG)
    write_autoconf(cfg, AUTOCONF_VH)
    print("ares_kconfig: %s refreshed (unknown symbols took their defaults)"
          % os.path.relpath(DOT_CONFIG, ARES_HOME))
    show(cfg)
    return 0


def cmd_savedefconfig(args):
    cfg = build_config()
    resolve(cfg, load_dot_config(DOT_CONFIG))
    write_defconfig(cfg, DEFCONFIG)
    print("ares_kconfig: wrote %s" % os.path.relpath(DEFCONFIG, ARES_HOME))
    return 0


def cmd_loaddefconfig(args):
    cfg = build_config()
    saved = load_dot_config(DEFCONFIG)
    resolve(cfg, saved)
    write_dot_config(cfg, DOT_CONFIG)
    write_autoconf(cfg, AUTOCONF_VH)
    print("ares_kconfig: restored %s" % os.path.relpath(DEFCONFIG, ARES_HOME))
    show(cfg)
    return 0


def cmd_gen(args):
    cfg = build_config()
    saved = load_dot_config(DOT_CONFIG)
    if not os.path.exists(DOT_CONFIG):
        resolve(cfg, {})
        write_dot_config(cfg, DOT_CONFIG)
        if not args.quiet:
            print("ares_kconfig: no %s, generated the defaults"
                  % os.path.relpath(DOT_CONFIG, ARES_HOME))
    else:
        resolve(cfg, saved)
    changed = write_autoconf(cfg, AUTOCONF_VH)
    if not args.quiet and changed:
        print("ares_kconfig: generated %s" % os.path.relpath(AUTOCONF_VH, ARES_HOME))
    return 0


def cmd_defs(args):
    """Print the Verilator -D flags (read only - safe inside a Makefile)."""
    cfg = build_config()
    resolve(cfg, load_dot_config(DOT_CONFIG))
    flags = []
    for name in sorted(emitted_symbols(cfg)):
        value = emitted_symbols(cfg)[name]
        if isinstance(value, str):
            continue  # strings cannot be passed through -D portably
        flags.append("-DCONFIG_%s=%s" % (name, value))
    print(" ".join(flags))
    return 0


def cmd_set(args):
    cfg = build_config()
    resolve(cfg, load_dot_config(DOT_CONFIG))
    for assignment in args.assignments:
        if "=" not in assignment:
            raise SystemExit("ares_kconfig: expected NAME=VALUE, got %s" % assignment)
        name, raw = assignment.split("=", 1)
        name = name[7:] if name.startswith("CONFIG_") else name
        sym = cfg.symbols.get(name)
        if sym is not None and sym.choice is None:
            ok, message = set_symbol(sym, raw)
            if not ok:
                raise SystemExit("ares_kconfig: %s: %s" % (name, message))
            continue
        # choice: either the choice name with a numeric value, or a member name
        matched = False
        for ch in cfg.choices.values():
            if ch.name == name and raw.isdigit():
                for member in ch.members:
                    if member.name.endswith("_" + raw):
                        select_choice(ch, member)
                        matched = True
                break
            if any(member.name == name for member in ch.members):
                for member in ch.members:
                    if member.name == name:
                        select_choice(ch, member)
                        matched = True
                break
        if not matched:
            raise SystemExit("ares_kconfig: unknown symbol or choice value: %s=%s"
                             % (name, raw))
    write_dot_config(cfg, DOT_CONFIG)
    write_autoconf(cfg, AUTOCONF_VH)
    show(cfg)
    return 0


def cmd_show(args):
    cfg = build_config()
    resolve(cfg, load_dot_config(DOT_CONFIG))
    show(cfg)
    return 0


def show(cfg):
    print("%s:" % cfg.title)
    for name in sorted(emitted_symbols(cfg)):
        print("  CONFIG_%s = %s" % (name, emitted_symbols(cfg)[name]))


def main(argv=None):
    parser = argparse.ArgumentParser(description="ARES core configuration tool")
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("menuconfig", help="interactive configuration menu").set_defaults(
        func=cmd_menuconfig)
    sub.add_parser("defconfig", help="write the defaults").set_defaults(func=cmd_defconfig)
    sub.add_parser("oldconfig", help="refresh .config with new symbols").set_defaults(
        func=cmd_oldconfig)
    sub.add_parser("savedefconfig", help="write configs/defconfig").set_defaults(
        func=cmd_savedefconfig)
    sub.add_parser("loaddefconfig",
                   help="restore configs/defconfig over the defaults").set_defaults(
        func=cmd_loaddefconfig)
    gen = sub.add_parser("gen", help="regenerate the outputs from .config")
    gen.add_argument("--quiet", action="store_true")
    gen.set_defaults(func=cmd_gen)
    sub.add_parser("defs", help="print the Verilator -D flags").set_defaults(func=cmd_defs)
    sub.add_parser("show", help="print the effective configuration").set_defaults(func=cmd_show)
    setter = sub.add_parser("set", help="set symbols non-interactively (NAME=VALUE)")
    setter.add_argument("assignments", nargs="+")
    setter.set_defaults(func=cmd_set)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
