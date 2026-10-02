#!/usr/bin/env python3
"""Rust 语法自检（tree-sitter）—— **类型错误查不出来，只查语法**。

为什么需要：开发沙箱里没有 Rust 工具链（`cargo` 不在镜像里，也装不上：
static.rust-lang.org 不通、apt 没有 root）。于是"改一行 Rust"的最小验证闭环是
5 分钟的 GitHub Actions 往返，而绝大多数低级错误（括号没闭合、分号漏了、
字符串没结束）根本不需要编译器 —— 用 tree-sitter 在本地就能抓到。

用法：
    pip install --break-system-packages tree-sitter tree-sitter-rust
    python3 tools/rs_syntax_check.py            # 检查仓库里所有 *.rs
    python3 tools/rs_syntax_check.py a.rs b.rs  # 只检查指定的

退出码 0 = 没语法问题；1 = 有（会打印出错行）。
它**不能**替代 `cargo check`：类型、生命周期、借用、宏展开一概查不出来。
"""
import glob
import subprocess
import sys


def main() -> int:
    try:
        import tree_sitter  # noqa: F401
        import tree_sitter_rust as tsr
        from tree_sitter import Language, Parser
    except ImportError:
        print("需要 tree-sitter：pip install --break-system-packages tree-sitter tree-sitter-rust")
        return 2

    parser = Parser(Language(tsr.language()))
    files = sys.argv[1:]
    if not files:
        out = subprocess.run(
            ["git", "ls-files", "*.rs"], capture_output=True, text=True, check=True
        )
        files = out.stdout.split()
        # 还没 git add 的新文件也要查
        for f in glob.glob("**/*.rs", recursive=True):
            if f not in files:
                files.append(f)

    bad = 0
    for f in sorted(files):
        src = open(f, "rb").read()
        errs = []

        def walk(node):
            if node.type == "ERROR" or node.is_missing:
                errs.append((node.start_point, node.type))
            for c in node.children:
                walk(c)

        walk(parser.parse(src).root_node)
        if errs:
            bad += 1
            print(f"❌ {f}: {len(errs)} 处语法问题")
            for (pos, kind) in errs[:8]:
                line = src.split(b"\n")[pos[0]].decode("utf-8", "replace")[:100]
                print(f"   行 {pos[0] + 1}:{pos[1]} [{kind}] {line}")
        else:
            print(f"✅ {f}")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
