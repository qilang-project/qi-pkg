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

根, 包 = sys.argv[1], sys.argv[2]
b = gzip.decompress(open(包, "rb").read())
i = 0
长名 = None
不符 = []
while i + 512 <= len(b):
    h = b[i : i + 512]
    if h[0] == 0:
        break
    名 = h[:100].split(b"\0")[0].decode("utf-8", "replace")
    if 长名:
        名, 长名 = 长名, None
    大小 = int((h[124:135].decode().strip("\0 ") or "0"), 8)
    if h[156:157] == b"L":
        长名 = b[i + 512 : i + 512 + 大小 - 1].decode("utf-8", "replace")
    else:
        猜的 = h[100:107].decode() == "0000755"
        真的 = os.access(os.path.join(根, 名), os.X_OK)
        if 猜的 != 真的:
            不符.append(名)
    i += 512 + ((大小 + 511) // 512) * 512
print(len(不符))
for n in 不符[:5]:
    print("      " + n, file=sys.stderr)
