#!/usr/bin/env python3
"""检测 Lua 里「方法定义与调用语法不匹配」的错误。

本项目踩过两次的坑，两种方向都会出错：

  1) 冒号定义、点号调用 —— 实参错位，形参收到 nil
        function Scene:handCardRect(i) ... end
        self.handCardRect(idx)        -- 错！应写 self:handCardRect(idx)
     症状：莫名其妙的 "attempt to perform arithmetic on a nil value"，
     报错位置离真正的调用点很远，极易被误判成编译器/解释器 bug。

  2) 点号定义、冒号调用 —— 实参整体右移一位
        function cls.create(...) ... end
        TriggerSkill:create("奸雄", ev, fn, opts)   -- 错！应写 TriggerSkill.create(...)
     症状："attempt to index local 'opts' (a function value)"。

用法：
    python3 tools/lint_methods.py              # 检查 src/ 与 tests/
    python3 tools/lint_methods.py path/to/dir

退出码：发现问题为 1，否则 0。
"""
import re
import sys
import pathlib

# 显式传 self 的父类构造调用属于正确用法
EXPLICIT_SELF_OK = {"init"}

STDLIB_RECEIVERS = {
    "string", "table", "math", "os", "io", "love", "coroutine", "debug",
    "require", "utf8", "arg", "jit",
}

# love 的子模块：love.graphics.draw() / love.audio.play() 这类是库函数，
# 点号调用才是对的，不能因为项目里存在同名的冒号方法就报错。
LOVE_MODULES = {
    "graphics", "audio", "window", "event", "filesystem", "timer",
    "mouse", "keyboard", "image", "sound", "system", "math",
    "physics", "touch", "joystick", "thread", "data", "font",
}

# LuaSocket 的模块名。它的 API 是**函数式**的（socket.bind / http.request /
# ltn12.sink.table），点号调用才是正确写法；不加进来的话，一旦项目里
# 存在同名的冒号方法（本项目就有 Curl:request / Proxy:request），
# 就会被误报成「应改为冒号调用」。
LUA_MODULES = {"socket", "http", "ltn12", "mime", "ssl", "url", "ftp", "smtp"}

# 标准库/常见方法名：本仓库里若有同名定义也不该据此报错
# （例如自己写了 ExpPattern.match，不代表 s:match() 这种字符串调用有错）
STDLIB_METHODS = {
    "match", "gmatch", "gsub", "find", "sub", "upper", "lower", "rep", "len",
    "byte", "char", "format", "reverse", "insert", "remove", "sort", "concat",
    "unpack", "pack", "getn", "random", "randomseed", "floor", "ceil", "max",
    "min", "abs", "sqrt", "create", "resume", "yield", "status", "wrap",
    "time", "clock", "date", "tostring", "tonumber", "error", "assert",
    "pcall", "xpcall", "select", "type", "rawget", "rawset", "setmetatable",
    "getmetatable", "next", "pairs", "ipairs", "open", "close", "read",
    "write", "lines", "seek", "setvbuf",
}


def collect(root):
    colon_defs, dot_defs = set(), set()
    for f in pathlib.Path(root).rglob("*.lua"):
        txt = f.read_text(encoding="utf-8")
        colon_defs |= set(re.findall(r"function\s+[\w.]+:(\w+)\s*\(", txt))
        dot_defs |= set(re.findall(r"function\s+[\w.]+\.(\w+)\s*\(", txt))
    return colon_defs, dot_defs


# 同一个类里重复定义同名方法：后写的静默覆盖先写的，是极难查的一类 bug。
# 本项目踩过：scene_room.lua 里 anchorOf 定义了两次（一份返回 {x,y} 表、
# 一份返回两个数字），后者覆盖前者 → panelAt 拿到 (table, nil)，
# 表现为点牌时报 "attempt to compare table with number"。
# 只检查大写开头的接收者（真正的类）；`function s:filter()` 这类
# 技能闭包里的局部方法不参与（同名出现多次是合法的）。
CLASS_DEF = re.compile(r"function\s+([A-Z]\w*)[:.](\w+)\s*\(")


def duplicates(root):
    seen = {}
    for f in sorted(pathlib.Path(root).rglob("*.lua")):
        if ".git" in str(f):
            continue
        for ln, line in enumerate(f.read_text(encoding="utf-8").splitlines(), 1):
            if line.strip().startswith("--"):
                continue
            m = CLASS_DEF.search(line)
            if m:
                seen.setdefault(m.groups(), []).append(f"{f}:{ln}")
    return {k: v for k, v in seen.items() if len(v) > 1}


def scan(root, colon_defs, dot_defs):
    issues = []
    for f in sorted(pathlib.Path(root).rglob("*.lua")):
        if ".git" in str(f):
            continue
        for ln, line in enumerate(f.read_text(encoding="utf-8").splitlines(), 1):
            stripped = line.strip()
            if stripped.startswith("--"):
                continue

            # 方向 1：冒号定义的方法被点号调用
            # `X.method(self, ...)` 是显式传 self 的合法写法（如 spec 表回调），不报错
            for recv, meth, first in re.findall(
                r"\b(\w+)\.(\w+)\s*\(\s*([\w.]+)?", line
            ):
                if recv in STDLIB_RECEIVERS or recv in LOVE_MODULES or recv in LUA_MODULES:
                    continue
                if meth in EXPLICIT_SELF_OK:
                    continue
                if first == "self":
                    continue
                if meth in colon_defs and meth not in dot_defs:
                    issues.append((str(f), ln, f"{recv}.{meth}()", f"{recv}:{meth}()", stripped))

            # 方向 2：点号定义的方法被冒号调用
            for recv, meth in re.findall(r"\b(\w+):(\w+)\s*\(", line):
                if recv in STDLIB_RECEIVERS or recv in LOVE_MODULES or recv in LUA_MODULES:
                    continue
                if meth in EXPLICIT_SELF_OK or meth in STDLIB_METHODS:
                    continue
                if meth in dot_defs and meth not in colon_defs:
                    issues.append((str(f), ln, f"{recv}:{meth}()", f"{recv}.{meth}()", stripped))
    return issues


def main():
    roots = sys.argv[1:] or ["src", "tests"]
    colon_defs, dot_defs = set(), set()
    for r in roots:
        c, d = collect(r)
        colon_defs |= c
        dot_defs |= d

    issues = []
    for r in roots:
        issues += scan(r, colon_defs, dot_defs)

    dupes = {}
    for r in roots:
        dupes.update(duplicates(r))

    if dupes:
        print("发现同一个类的同名方法被重复定义（后者会静默覆盖前者）：")
        for (cls, meth), locs in sorted(dupes.items()):
            print(f"  {cls}:{meth}  ->  {', '.join(locs)}")
        print("  修法：删掉多余的那份，或改名。\n")

    if issues:
        print("发现方法定义与调用语法不匹配：")
        for f, ln, wrong, right, line in issues:
            print(f"  {f}:{ln}  {wrong}  应改为 {right}")
            print(f"      | {line}")
        print(f"\n共 {len(issues)} 处。")
        return 1
    print("未发现方法定义/调用语法错配")
    return 0


if __name__ == "__main__":
    sys.exit(main())
