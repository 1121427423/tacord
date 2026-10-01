#!/usr/bin/env bash
# 统一"带超时地跑一条命令"。
#
# 为什么需要：CI 里跑 Godot 的 --script 冒烟，脚本一旦抛异常就到不了 quit()，
# Godot 会一直跑下去 —— 真的把 CI 步骤挂死过 14 分钟。所以每个 Godot 调用都得套超时。
#
# 为什么不用现成的 timeout：macOS runner 上**没有** GNU coreutils 的 timeout
# （照抄过来就是 "timeout: command not found" / 退出码 127）。
# 退路用 perl 的 alarm：macOS 和 Linux 都自带 perl。
#
# 用法：bash tools/ci_timeout.sh <秒数> <命令> [参数...]
set -u

if [ "$#" -lt 2 ]; then
	echo "用法: $0 <秒数> <命令> [参数...]" >&2
	exit 2
fi

secs="$1"
shift

if command -v timeout >/dev/null 2>&1; then
	timeout "$secs" "$@"
else
	perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
fi
