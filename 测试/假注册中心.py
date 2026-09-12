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


def versions(title_name):
    d = os.path.join(STORE, title_name)
    if not os.path.isdir(d):
        return []
    out = []
    for f in sorted(os.listdir(d)):
        if f.endswith(".tar.gz"):
            ver = f[: -len(".tar.gz")]
            body = open(os.path.join(d, f), "rb").read()
            out.append(
                {
                    "version": ver,
                    "sha256": hashlib.sha256(body).hexdigest(),
                    "size": len(body),
                    "uploaded_at": "2026-09-06T00:00:00Z",
                }
            )
    out.sort(key=lambda v: [int(x) for x in v["version"].split(".")])
    return out


def desc(title_name):
    """从包体里的 qi.toml 抠 [元数据] 描述 —— 真注册中心是入库时抠的。"""
    table = versions(title_name)
    if not table:
        return ""
    import io
    import tarfile

    file_path = os.path.join(STORE, title_name, table[-1]["version"] + ".tar.gz")
    try:
        with tarfile.open(file_path) as t:
            f = t.extractfile("qi.toml")
            text = f.read().decode("utf-8")
    except Exception:
        return ""
    in_meta = False
    for line in text.splitlines():
        line = line.strip()
        if line.startswith("["):
            in_meta = line.strip("[]\"") == "元数据"
        elif in_meta and line.startswith("描述"):
            return line.split("=", 1)[1].strip().strip('"')
    return ""


class handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def reply(self, status_code, body, kind="application/json; charset=utf-8"):
        if isinstance(body, str):
            body = body.encode("utf-8")
        self.send_response(status_code)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def err(self, status_code, reason):
        self.reply(status_code, json.dumps({"error": reason}, ensure_ascii=False))

    def do_GET(self):
        seg = [unquote(x) for x in self.path.split("?")[0].strip("/").split("/")]
        if seg[:3] != ["api", "v1", "packages"]:
            return self.err(404, "没有这个端点")
        rest = seg[3:]
        if not rest:
            pkg = []
            for name in sorted(os.listdir(STORE)) if os.path.isdir(STORE) else []:
                table = versions(name)
                pkg.append(
                    {
                        "name": name,
                        "latest": table[-1]["version"] if table else None,
                        "description": desc(name),
                        "downloads": 0,
                    }
                )
            return self.reply(200, json.dumps({"packages": pkg}, ensure_ascii=False))
        title_name = rest[0]
        table = versions(title_name)
        if not table:
            return self.err(404, f"没有名为 {title_name} 的包")
        if len(rest) == 1:
            return self.reply(
                200,
                json.dumps(
                    {
                        "name": title_name,
                        "description": desc(title_name),
                        "latest": table[-1]["version"],
                        "downloads": 0,
                        "versions": table,
                    },
                    ensure_ascii=False,
                ),
            )
        ver = rest[1]
        hit = [v for v in table if v["version"] == ver]
        if not hit:
            return self.err(404, f"{title_name} 没有 {ver} 这个版本")
        if len(rest) == 2:
            return self.reply(200, json.dumps(hit[0], ensure_ascii=False))
        if len(rest) == 3 and rest[2] == "download":
            body = open(os.path.join(STORE, title_name, ver + ".tar.gz"), "rb").read()
            return self.reply(200, body, "application/gzip")
        return self.err(404, "没有这个端点")

    def do_PUT(self):
        seg = [unquote(x) for x in self.path.split("?")[0].strip("/").split("/")]
        if seg[:3] != ["api", "v1", "packages"] or len(seg) != 5:
            return self.err(404, "没有这个端点")
        title_name, ver = seg[3], seg[4]
        token = self.headers.get("Authorization", "")
        if not token.startswith("Bearer ") or not token[7:].strip():
            return self.err(401, "缺少或无效的发布 token")
        length = int(self.headers.get("Content-Length", "0"))
        body_text = self.rfile.read(length)
        try:
            body = base64.b64decode(body_text, validate=True)
        except Exception as e:
            return self.err(400, f"请求体不是合法 base64：{e}")
        if body[:2] != b"\x1f\x8b":
            return self.err(400, "解出来的不是 gzip")
        dir_name = os.path.join(STORE, title_name)
        os.makedirs(dir_name, exist_ok=True)
        file_path = os.path.join(dir_name, ver + ".tar.gz")
        if os.path.exists(file_path):
            return self.err(409, f"{title_name} {ver} 已经发布过，版本不可变")
        # 校验包里 qi.toml 的 名称/版本 与 URL 一致（真服务端也做这一步）
        import io
        import tarfile

        try:
            with tarfile.open(fileobj=io.BytesIO(body)) as t:
                text = t.extractfile("qi.toml").read().decode("utf-8")
        except Exception as e:
            return self.err(400, f"包体解不开或没有包根 qi.toml：{e}")
        fetch = lambda k: next(
            (
                l.split("=", 1)[1].strip().strip('"')
                for l in text.splitlines()
                if l.strip().startswith(k)
            ),
            "",
        )
        if fetch("名称") != title_name or fetch("版本") != ver:
            return self.err(
                400,
                f'包里 qi.toml 是 {fetch("名称")} {fetch("版本")}，跟发布地址 {title_name} {ver} 不符',
            )
        open(file_path, "wb").write(body)
        return self.reply(
            201,
            json.dumps(
                {"name": title_name, "version": ver, "sha256": hashlib.sha256(body).hexdigest()},
                ensure_ascii=False,
            ),
        )


if __name__ == "__main__":
    os.makedirs(STORE, exist_ok=True)
    svc = ThreadingHTTPServer(("127.0.0.1", PORT), handler)
    print(f"假注册中心听 http://127.0.0.1:{PORT}，包体存 {STORE}", flush=True)
    svc.serve_forever()
