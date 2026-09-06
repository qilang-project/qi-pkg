#!/usr/bin/env python3
"""一个够用的假 pkg.qilang.org —— 端到端测试用，不碰数据库、不碰真注册中心。

    python3 测试/假注册中心.py <包体目录> [端口]

实现 qi/docs/包管理设计.md 里的五个端点（含「上行 body 是 base64」那处偏差）。
包体存 <包体目录>/<名称>/<版本>.tar.gz，元数据现算（sha256 直接对文件算）。
token：Bearer 后面非空即通过（真注册中心由管理员签发，这里不是测认证的地方）。
"""
import base64
import hashlib
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote

STORE = sys.argv[1] if len(sys.argv) > 1 else "store"
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 43517


def 版本表(名称):
    d = os.path.join(STORE, 名称)
    if not os.path.isdir(d):
        return []
    出 = []
    for f in sorted(os.listdir(d)):
        if f.endswith(".tar.gz"):
            版本 = f[: -len(".tar.gz")]
            体 = open(os.path.join(d, f), "rb").read()
            出.append(
                {
                    "version": 版本,
                    "sha256": hashlib.sha256(体).hexdigest(),
                    "size": len(体),
                    "uploaded_at": "2026-09-06T00:00:00Z",
                }
            )
    出.sort(key=lambda v: [int(x) for x in v["version"].split(".")])
    return 出


def 说明(名称):
    """从包体里的 qi.toml 抠 [元数据] 描述 —— 真注册中心是入库时抠的。"""
    表 = 版本表(名称)
    if not 表:
        return ""
    import io
    import tarfile

    路径 = os.path.join(STORE, 名称, 表[-1]["version"] + ".tar.gz")
    try:
        with tarfile.open(路径) as t:
            f = t.extractfile("qi.toml")
            文本 = f.read().decode("utf-8")
    except Exception:
        return ""
    在元数据 = False
    for 行 in 文本.splitlines():
        行 = 行.strip()
        if 行.startswith("["):
            在元数据 = 行.strip("[]\"") == "元数据"
        elif 在元数据 and 行.startswith("描述"):
            return 行.split("=", 1)[1].strip().strip('"')
    return ""


class 处理器(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def 回(self, 码, 体, 类型="application/json; charset=utf-8"):
        if isinstance(体, str):
            体 = 体.encode("utf-8")
        self.send_response(码)
        self.send_header("Content-Type", 类型)
        self.send_header("Content-Length", str(len(体)))
        self.end_headers()
        self.wfile.write(体)

    def 错(self, 码, 原因):
        self.回(码, json.dumps({"error": 原因}, ensure_ascii=False))

    def do_GET(self):
        段 = [unquote(x) for x in self.path.split("?")[0].strip("/").split("/")]
        if 段[:3] != ["api", "v1", "packages"]:
            return self.错(404, "没有这个端点")
        余 = 段[3:]
        if not 余:
            包 = []
            for 名 in sorted(os.listdir(STORE)) if os.path.isdir(STORE) else []:
                表 = 版本表(名)
                包.append(
                    {
                        "name": 名,
                        "latest": 表[-1]["version"] if 表 else None,
                        "description": 说明(名),
                        "downloads": 0,
                    }
                )
            return self.回(200, json.dumps({"packages": 包}, ensure_ascii=False))
        名称 = 余[0]
        表 = 版本表(名称)
        if not 表:
            return self.错(404, f"没有名为 {名称} 的包")
        if len(余) == 1:
            return self.回(
                200,
                json.dumps(
                    {
                        "name": 名称,
                        "description": 说明(名称),
                        "latest": 表[-1]["version"],
                        "downloads": 0,
                        "versions": 表,
                    },
                    ensure_ascii=False,
                ),
            )
        版本 = 余[1]
        命中 = [v for v in 表 if v["version"] == 版本]
        if not 命中:
            return self.错(404, f"{名称} 没有 {版本} 这个版本")
        if len(余) == 2:
            return self.回(200, json.dumps(命中[0], ensure_ascii=False))
        if len(余) == 3 and 余[2] == "download":
            体 = open(os.path.join(STORE, 名称, 版本 + ".tar.gz"), "rb").read()
            return self.回(200, 体, "application/gzip")
        return self.错(404, "没有这个端点")

    def do_PUT(self):
        段 = [unquote(x) for x in self.path.split("?")[0].strip("/").split("/")]
        if 段[:3] != ["api", "v1", "packages"] or len(段) != 5:
            return self.错(404, "没有这个端点")
        名称, 版本 = 段[3], 段[4]
        令牌 = self.headers.get("Authorization", "")
        if not 令牌.startswith("Bearer ") or not 令牌[7:].strip():
            return self.错(401, "缺少或无效的发布 token")
        长度 = int(self.headers.get("Content-Length", "0"))
        体文本 = self.rfile.read(长度)
        try:
            体 = base64.b64decode(体文本, validate=True)
        except Exception as e:
            return self.错(400, f"请求体不是合法 base64：{e}")
        if 体[:2] != b"\x1f\x8b":
            return self.错(400, "解出来的不是 gzip")
        目录 = os.path.join(STORE, 名称)
        os.makedirs(目录, exist_ok=True)
        路径 = os.path.join(目录, 版本 + ".tar.gz")
        if os.path.exists(路径):
            return self.错(409, f"{名称} {版本} 已经发布过，版本不可变")
        # 校验包里 qi.toml 的 名称/版本 与 URL 一致（真服务端也做这一步）
        import io
        import tarfile

        try:
            with tarfile.open(fileobj=io.BytesIO(体)) as t:
                文本 = t.extractfile("qi.toml").read().decode("utf-8")
        except Exception as e:
            return self.错(400, f"包体解不开或没有包根 qi.toml：{e}")
        取 = lambda k: next(
            (
                l.split("=", 1)[1].strip().strip('"')
                for l in 文本.splitlines()
                if l.strip().startswith(k)
            ),
            "",
        )
        if 取("名称") != 名称 or 取("版本") != 版本:
            return self.错(
                400,
                f'包里 qi.toml 是 {取("名称")} {取("版本")}，跟发布地址 {名称} {版本} 不符',
            )
        open(路径, "wb").write(体)
        return self.回(
            201,
            json.dumps(
                {"name": 名称, "version": 版本, "sha256": hashlib.sha256(体).hexdigest()},
                ensure_ascii=False,
            ),
        )


if __name__ == "__main__":
    os.makedirs(STORE, exist_ok=True)
    服务 = ThreadingHTTPServer(("127.0.0.1", PORT), 处理器)
    print(f"假注册中心听 http://127.0.0.1:{PORT}，包体存 {STORE}", flush=True)
    服务.serve_forever()
