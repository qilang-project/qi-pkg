#!/usr/bin/env python3
"""数一数 qipkg 打出来的 tar 里，有几个条目的权限位跟真实文件对不上。

    python3 测试/权限差异.py <包根目录> <qipkg 打出来的 tar.gz>

打包对拍.sh 用它给「两边 sha256 不同」定性：如果不一致的条目数 > 0，
差异就由 归档.qi 里那条「以 #! 开头当 0755」的猜测解释得通；如果是 0，
那就是真出问题了，得查。
"""
import gzip
import os
import sys

root, pkg = sys.argv[1], sys.argv[2]
b = gzip.decompress(open(pkg, "rb").read())
i = 0
long_name = None
mismatch = []
while i + 512 <= len(b):
    h = b[i : i + 512]
    if h[0] == 0:
        break
    name = h[:100].split(b"\0")[0].decode("utf-8", "replace")
    if long_name:
        name, long_name = long_name, None
    size = int((h[124:135].decode().strip("\0 ") or "0"), 8)
    if h[156:157] == b"L":
        long_name = b[i + 512 : i + 512 + size - 1].decode("utf-8", "replace")
    else:
        guessed = h[100:107].decode() == "0000755"
        actual = os.access(os.path.join(root, name), os.X_OK)
        if guessed != actual:
            mismatch.append(name)
    i += 512 + ((size + 511) // 512) * 512
print(len(mismatch))
for n in mismatch[:5]:
    print("      " + n, file=sys.stderr)
