#!/usr/bin/env bash
# qi-pkg 测试运行器
#
#   ./跑测试.sh            单测 + 端到端（假注册中心，不联网）
#   ./跑测试.sh --对拍     再加一遍与 Rust 版 `qi 包 发布 --只打包` 的字节对拍
#   ./跑测试.sh --联网     再加一遍对着真 pkg.qilang.org 的只读检查（搜索/装 Graph）
#   QI_BIN=/path/to/qi ./跑测试.sh
#
# 注意 macOS 自带 bash 3.2：shell 变量名一律 ASCII，别用数组高级特性。
set -uo pipefail
cd "$(dirname "$0")"

ROOT="$(cd .. && pwd)"
QI_BIN="${QI_BIN:-$ROOT/target/release/qi}"
# 归档跟编译器要配套：链着旧运行时会出「符号不存在」这种看不懂的错
export QI_RUNTIME_LIB="${QI_RUNTIME_LIB:-$ROOT/qi-runtime/target/release/libqi_runtime.a}"

[ -x "$QI_BIN" ] || { echo "找不到 qi 二进制：$QI_BIN" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

total=0
fail=0

for f in 测试/*_测.qi; do
    [ -e "$f" ] || continue
    name="$(basename "$f" .qi)"
    total=$((total + 1))
    echo "▶ $name"
    if ! "$QI_BIN" compile "$f" -o "$TMP/suite" >/dev/null 2>"$TMP/err"; then
        echo "  ✗ 编译失败"; grep -v '^警告' "$TMP/err" | sed 's/^/    /'
        fail=$((fail + 1)); continue
    fi
    if "$TMP/suite"; then echo "  ✓ 通过"; else echo "  ✗ 失败"; fail=$((fail + 1)); fi
    echo ""
done

# 命令行工具也要能编过 —— README 里写着的东西不能是编不过的
total=$((total + 1))
if "$QI_BIN" compile 命令行/主程序.qi -o "$TMP/qipkg" >/dev/null 2>"$TMP/err"; then
    echo "✓ 编译 命令行/主程序.qi"
else
    echo "✗ 编译 命令行/主程序.qi"; grep -v '^警告' "$TMP/err" | sed 's/^/    /'
    fail=$((fail + 1))
fi
echo ""

# 端到端（假注册中心，不碰线上）
total=$((total + 1))
echo "▶ 端到端（假注册中心）"
if ./测试/端到端.sh; then :; else fail=$((fail + 1)); fi
echo ""

for arg in "$@"; do
    if [ "$arg" = "--对拍" ]; then
        echo "▶ 与 Rust 版打包字节对拍"
        ./测试/打包对拍.sh
        echo ""
    fi
    if [ "$arg" = "--联网" ]; then
        echo "▶ 真注册中心只读检查（pkg.qilang.org）"
        total=$((total + 1))
        if "$TMP/qipkg" 搜索 存储 | grep -q KV; then
            echo "  ✓ 搜索 命中 KV"
        else
            echo "  ✗ 搜索 没命中"; fail=$((fail + 1))
        fi
        P="$TMP/联网项目"
        mkdir -p "$P"
        printf '[包]\n名称 = "联网项目"\n版本 = "0.1.0"\n' > "$P/qi.toml"
        total=$((total + 1))
        if (cd "$P" && "$TMP/qipkg" 添加 Graph >"$TMP/net.log" 2>&1) \
           && [ -f "$P/qi_packages/Graph/qi_packages/KV/qi.toml" ]; then
            echo "  ✓ 装 Graph 并带出嵌套 KV"
        else
            sed 's/^/    /' "$TMP/net.log"; echo "  ✗ 装 Graph 失败"; fail=$((fail + 1))
        fi
        echo ""
    fi
done

echo "════════════════════════════"
echo "qi-pkg: $((total - fail))/$total 通过"
[ "$fail" -gt 0 ] && exit 1
exit 0
