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
                if recv in STDLIB_RECEIVERS or recv in LOVE_MODULES:
                    continue
                if meth in EXPLICIT_SELF_OK:
                    continue
                if first == "self":
                    continue
                if meth in colon_defs and meth not in dot_defs:
                    issues.append((str(f), ln, f"{recv}.{meth}()", f"{recv}:{meth}()", stripped))

            # 方向 2：点号定义的方法被冒号调用
            for recv, meth in re.findall(r"\b(\w+):(\w+)\s*\(", line):
                if recv in STDLIB_RECEIVERS or recv in LOVE_MODULES:
                    continue
                if meth in EXPLICIT_SELF_OK or meth in STDLIB_METHODS:
                    continue
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
