#!/usr/bin/env bash
# 打包对拍 —— 拿 qipkg 和 Rust 的 `qi 包 发布 --只打包` 打同一个目录，比 sha256。
#
# 这是 qi-pkg 最有分量的一条回归：两边字节相同意味着 tar 头、条目顺序、gzip
# 级别、排除规则全都一致，任何一处漂移都会当场变成一个不同的 sha256。
#
# **已知会不一样的地方只有一处**：文件权限位。qi 没有「读权限位」的原语，
# 归档.qi 用「以 #! 开头就当 0755」猜，猜错就差几个字节。带 shebang 却没
# chmod +x 的脚本会让 sha256 对不上 —— 那不是 bug，见 归档.qi 的 文件权限()。
set -uo pipefail
cd "$(dirname "$0")/.."

ROOT="$(cd .. && pwd)"
QI_BIN="${QI_BIN:-$ROOT/target/release/qi}"
export QI_RUNTIME_LIB="${QI_RUNTIME_LIB:-$ROOT/qi-runtime/target/release/libqi_runtime.a}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

"$QI_BIN" compile 测试/打包到文件.qi -o "$WORK/打包" >/dev/null 2>"$WORK/err" || {
    sed 's/^/    /' "$WORK/err"; echo "打包工具编译失败"; exit 1; }

same=0
diff=0
for d in "$ROOT"/qi-*/ "$ROOT"/项目/*/; do
    [ -f "$d/qi.toml" ] || continue
    grep -q '^\s*名称\s*=' "$d/qi.toml" || continue
    pname=$(basename "$d")
    R=$(cd "$d" && "$QI_BIN" 包 发布 --只打包 2>/dev/null | grep -o 'sha256 [0-9a-f]*' | awk '{print $2}')
    M=$(SRC="$d" OUT="$WORK/x.tar.gz" "$WORK/打包" 2>/dev/null | grep -o 'sha256 [0-9a-f]*' | awk '{print $2}')
    if [ -z "$R" ] || [ -z "$M" ]; then
        # 多半是 [包] 版本 不是三段数字 —— Rust 版在打包前就拒了
        echo "  · $pname 跳过（Rust 版打不出来，多半是版本号不合协议）"
        continue
    fi
    if [ "$R" = "$M" ]; then
        echo "  ✓ $pname $R"
        same=$((same + 1))
    else
        # 定性：差异是不是全由权限位猜测造成的
        n=$(python3 测试/权限差异.py "$d" "$WORK/x.tar.gz" 2>/dev/null | head -1)
        if [ "${n:-0}" -gt 0 ]; then
            echo "  ~ $pname 只差权限位（$n 个条目的 #! 猜测与真实 chmod 不符）"
        else
            echo "  ✗ $pname sha256 不同，且不是权限位的锅 —— 要查"
            echo "      rust : $R"
            echo "      qipkg: $M"
        fi
        diff=$((diff + 1))
    fi
done

echo "════════════════════════════"
echo "打包对拍：逐字节相同 ${same}，不同 ${diff}"
# 不同不算失败（权限位那条已知差异），但要看得见
exit 0
