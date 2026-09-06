#!/usr/bin/env bash
# qi-pkg 端到端对拍 —— 起一个假注册中心，两个客户端（qipkg 与 Rust 的 qi 包）
# 互相发布/安装，验证包体与 qi.lock 两边通吃。
#
# 全程不碰 pkg.qilang.org。要跑真注册中心的只读部分，见 跑测试.sh 里的 --联网。
#
# 注意 macOS 自带 bash 3.2：变量名一律 ASCII，别用数组高级特性。
set -uo pipefail
cd "$(dirname "$0")/.."

ROOT="$(cd .. && pwd)"
QI_BIN="${QI_BIN:-$ROOT/target/release/qi}"
export QI_RUNTIME_LIB="${QI_RUNTIME_LIB:-$ROOT/qi-runtime/target/release/libqi_runtime.a}"
PORT="${QIPKG_TEST_PORT:-43517}"
export QI_REGISTRY="http://127.0.0.1:$PORT"
export QI_REGISTRY_TOKEN="端到端测试用的假token"

WORK="$(mktemp -d)"
QIPKG="$WORK/qipkg"
SRV_PID=""
cleanup() {
    [ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT

fail=0
step() { echo "▶ $1"; }
ok()   { echo "  ✓ $1"; }
bad()  { echo "  ✗ $1"; fail=$((fail + 1)); }

step "编译 qipkg"
if ! "$QI_BIN" compile 命令行/主程序.qi -o "$QIPKG" >/dev/null 2>"$WORK/err"; then
    sed 's/^/    /' "$WORK/err"; echo "qipkg 编译失败"; exit 1
fi
ok "qipkg"

step "起假注册中心 :$PORT"
python3 测试/假注册中心.py "$WORK/store" "$PORT" >"$WORK/srv.log" 2>&1 &
SRV_PID=$!
for i in 1 2 3 4 5 6 7 8 9 10; do
    curl -s -o /dev/null "http://127.0.0.1:$PORT/api/v1/packages" && break
    sleep 0.3
done
if ! curl -s -o /dev/null "http://127.0.0.1:$PORT/api/v1/packages"; then
    cat "$WORK/srv.log"; echo "假注册中心起不来"; exit 1
fi
ok "已就绪"

# ── qipkg 发布 → Rust 安装 ────────────────────────────────────────
step "qipkg 发布 KV / Graph / 海龟（中文包名）"
for d in "$ROOT/qi-kv" "$ROOT/qi-graph" "$ROOT/qi-turtle"; do
    [ -d "$d" ] || continue
    if (cd "$d" && "$QIPKG" 发布 >"$WORK/pub.log" 2>&1); then
        ok "$(basename "$d") → $(grep -o '已发布.*' "$WORK/pub.log")"
    else
        sed 's/^/    /' "$WORK/pub.log"; bad "$(basename "$d") 发布失败"
    fi
done

step "重复发布同一版本应被拒（409，版本不可变）"
if (cd "$ROOT/qi-kv" && "$QIPKG" 发布 >"$WORK/dup.log" 2>&1); then
    bad "重复发布竟然成功了"
else
    grep -q "已发布过" "$WORK/dup.log" && ok "409 说了人话" || { sed 's/^/    /' "$WORK/dup.log"; bad "409 提示不对"; }
fi

step "Rust 的 qi 包 安装 装 qipkg 发上去的包"
P1="$WORK/项目甲"
mkdir -p "$P1"
cat > "$P1/qi.toml" <<'EOF'
[包]
名称 = "项目甲"
版本 = "0.1.0"
EOF
if (cd "$P1" && "$QI_BIN" 包 添加 海龟 0.1.0 >"$WORK/a.log" 2>&1); then
    [ -f "$P1/qi_packages/海龟/qi.toml" ] && ok "中文包名往返（Rust 装 qipkg 的包）" \
        || bad "海龟 没装进去"
else
    sed 's/^/    /' "$WORK/a.log"; bad "Rust 安装失败"
fi

# ── Rust 发布 → qipkg 安装 ────────────────────────────────────────
step "Rust 发布「组件」，qipkg 安装它"
if [ -d "$ROOT/qi-widgets" ]; then
    if (cd "$ROOT/qi-widgets" && "$QI_BIN" 包 发布 >"$WORK/rp.log" 2>&1); then
        ok "Rust 发布成功"
        P2="$WORK/项目乙"
        mkdir -p "$P2"
        cat > "$P2/qi.toml" <<'EOF'
[包]
名称 = "项目乙"
版本 = "0.1.0"
EOF
        if (cd "$P2" && "$QIPKG" 添加 组件 >"$WORK/b.log" 2>&1); then
            [ -f "$P2/qi_packages/组件/qi.toml" ] && ok "qipkg 装下了 Rust 发的包" \
                || bad "组件 没装进去"
        else
            sed 's/^/    /' "$WORK/b.log"; bad "qipkg 安装失败"
        fi
    else
        sed 's/^/    /' "$WORK/rp.log"; bad "Rust 发布失败"
    fi
fi

# ── 传递依赖 ──────────────────────────────────────────────────────
step "传递依赖：qipkg 添加 Graph 要把 KV 装进 Graph 自己的 qi_packages"
P3="$WORK/项目丙"
mkdir -p "$P3"
cat > "$P3/qi.toml" <<'EOF'
[包]
名称 = "项目丙"
版本 = "0.1.0"
入口 = "主程序.qi"

[源码]
目录 = ["."]
EOF
cat > "$P3/主程序.qi" <<'EOF'
包 主程序;
导入 标准库.输入输出 作为 IO;
导入 标准库.操作系统 作为 系统;
导入 Graph::{打开图, 关闭图, 加节点, 节点数};

函数 入口() {
    变量 库: 字符串 = 系统.临时目录() + "/qipkg端到端-" + 系统.进程ID() + ".kv";
    IO.删除文件(库);
    变量 图: 整数 = 打开图(库);
    加节点(图, "甲", "[\"人\"]", "{}");
    IO.打印行("节点 " + 节点数(图));
    关闭图(图);
    IO.删除文件(库);
}
EOF
if (cd "$P3" && "$QIPKG" 添加 Graph >"$WORK/c.log" 2>&1); then
    grep -q "已安装 Graph" "$WORK/c.log" && ok "Graph 装了" || bad "Graph 没装"
    [ -f "$P3/qi_packages/Graph/qi_packages/KV/qi.toml" ] \
        && ok "KV 落在 Graph/qi_packages 下（嵌套，不是平铺）" \
        || bad "传递依赖没装到嵌套位置"
    [ -d "$P3/qi_packages/KV" ] && bad "KV 不该平铺在项目根" || ok "没有平铺的 KV"
else
    sed 's/^/    /' "$WORK/c.log"; bad "qipkg 添加 Graph 失败"
fi

step "用装下来的 Graph 编译并跑一个程序"
if (cd "$P3" && "$QI_BIN" compile 主程序.qi -o "$WORK/丙" >"$WORK/d.log" 2>&1); then
    OUT="$("$WORK/丙")"
    [ "$OUT" = "节点 1" ] && ok "跑通：$OUT" || bad "输出不对：$OUT"
else
    grep -v '^警告' "$WORK/d.log" | sed 's/^/    /'; bad "编译失败"
fi

step "幂等：再装一次应全部跳过"
if (cd "$P3" && "$QIPKG" 安装 >"$WORK/e.log" 2>&1); then
    grep -q "新装 0，跳过 2" "$WORK/e.log" && ok "跳过 2 个" \
        || { sed 's/^/    /' "$WORK/e.log"; bad "不是全跳过"; }
else
    sed 's/^/    /' "$WORK/e.log"; bad "重装失败"
fi

step "两边的 qi.lock 互读"
cp "$P3/qi.lock" "$WORK/lock-qipkg.toml"
# Rust 那边「按 qi.lock 校验」只在 -v 下打
if (cd "$P3" && "$QI_BIN" 包 安装 -v >"$WORK/f.log" 2>&1); then
    grep -q "2 条锁定记录" "$WORK/f.log" && ok "Rust 读得懂 qipkg 写的 lock" \
        || { sed 's/^/    /' "$WORK/f.log"; bad "Rust 没认出 lock"; }
else
    sed 's/^/    /' "$WORK/f.log"; bad "Rust 安装失败"
fi
if (cd "$P3" && "$QIPKG" 安装 >"$WORK/g.log" 2>&1); then
    grep -q "2 条锁定记录" "$WORK/g.log" && ok "qipkg 读得懂 Rust 写的 lock" \
        || { sed 's/^/    /' "$WORK/g.log"; bad "qipkg 没认出 lock"; }
else
    sed 's/^/    /' "$WORK/g.log"; bad "qipkg 安装失败"
fi

step "lock 被改过要当场拒绝安装"
sed 's/sha256 = "[0-9a-f]*"/sha256 = "0000000000000000000000000000000000000000000000000000000000000000"/' \
    "$P3/qi.lock" > "$P3/qi.lock.new" && mv "$P3/qi.lock.new" "$P3/qi.lock"
rm -rf "$P3/qi_packages"
if (cd "$P3" && "$QIPKG" 安装 >"$WORK/h.log" 2>&1); then
    bad "被改过的 lock 竟然照装"
else
    grep -q "与注册中心当前的对不上" "$WORK/h.log" && ok "拒绝并说清了原因" \
        || { sed 's/^/    /' "$WORK/h.log"; bad "拒绝了但提示不对"; }
fi

step "搜索 / 列出"
"$QIPKG" 搜索 存储 >"$WORK/s.log" 2>&1
grep -q "KV" "$WORK/s.log" && ok "搜索命中 KV" || { cat "$WORK/s.log"; bad "搜索没命中"; }
"$QIPKG" 搜索 绝对不存在的关键词xyz >"$WORK/s2.log" 2>&1
grep -q "没有匹配" "$WORK/s2.log" && ok "空结果说了人话" || bad "空结果提示不对"

step "没有 token 时发布要提前拦住"
if (cd "$ROOT/qi-turtle" && QI_REGISTRY_TOKEN= "$QIPKG" 发布 >"$WORK/t.log" 2>&1); then
    bad "没 token 竟然发出去了"
else
    grep -q "QI_REGISTRY_TOKEN" "$WORK/t.log" && ok "提示去设环境变量" \
        || { sed 's/^/    /' "$WORK/t.log"; bad "提示不对"; }
fi

echo "════════════════════════════"
if [ "$fail" -gt 0 ]; then
    echo "端到端：$fail 项失败"
    exit 1
fi
echo "端到端：全部通过"
exit 0
