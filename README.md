# qi-pkg —— 用奇语写的 qi 包管理客户端

`qipkg` 是 pkg.qilang.org 的命令行客户端：装包、加依赖、发布、搜索、看已装。
**整个客户端是 qi 写的** —— tar、gzip 收尾、SHA-256、TOML、HTTP 协议对接，
一行 Rust 都没有。

服务端（[`qi-registry`](../qi-registry)）本来就是 qi 写的；把客户端也搬过来之后，
qi 的包管理从头到尾都由这门语言自己承担。

```
qi.toml            包清单（名称 = "Pkg"）
Pkg.qi             入口：把下面五层聚起来
哈希.qi            对字节切片算 SHA-256（FIPS 180-4）
归档.qi            tar 读写 + gzip + 打包排除规则 + 路径安全
清单.qi            qi.toml / qi.lock / 安装标记 的读写
注册中心.qi        五个 HTTP 端点 + percent-encode
安装.qi            下载 → 校验 sha256 → 落地 → 传递依赖
命令行/主程序.qi   qipkg 命令行
测试/              单测 + 假注册中心 + 端到端 + 与 Rust 版的字节对拍
```

## 装

```bash
export QI_RUNTIME_LIB=$(git rev-parse --show-toplevel)/qi-runtime/target/release/libqi_runtime.a
qi compile 命令行/主程序.qi -o ~/bin/qipkg
```

## 五个命令

```bash
qipkg 安装                 # 装齐当前项目 qi.toml [依赖] 里的注册中心包（含传递依赖）
qipkg 添加 Graph           # 写进 qi.toml [依赖] 并立即安装，省略版本取最新
qipkg 添加 海龟 0.1.0      # 指定版本
qipkg 发布 --只打包        # 打包当前目录，报字节数与 sha256，不上传
qipkg 发布                 # 真发布，token 读 QI_REGISTRY_TOKEN
qipkg 搜索 存储            # 按名称/描述过滤包列表
qipkg 列出                 # 本项目已装的注册中心包（含传递依赖，缩进显示）
```

加 `-v` 多打点东西（sha256、排除表）。

| 环境变量 | 默认 | 说明 |
|---|---|---|
| `QI_REGISTRY` | `https://pkg.qilang.org` | 注册中心地址 |
| `QI_REGISTRY_TOKEN` | 空 | 发布 token，由注册中心管理员签发 |

一次典型的安装长这样：

```
$ qipkg 添加 Graph
解析 Graph 最新版 → 0.1.0
已写入依赖: Graph = "0.1.0" → /path/演示项目/qi.toml
已安装 Graph 0.1.0 (24 个文件) → /path/演示项目/qi_packages/Graph
  已安装 KV 0.1.0 (16 个文件) → /path/演示项目/qi_packages/Graph/qi_packages/KV
共 1 个依赖：新装 2，跳过 0；已更新 /path/演示项目/qi.lock
```

`KV` 是 `Graph` 的依赖，落在 **Graph 自己的 qi_packages 下**（嵌套，不是平铺）——
编译期解析器只认包目录下的 qi_packages。

## 跟 `qi 包` 是什么关系

`qi 包 安装/添加/发布/搜索/列出` 还在，行为与 qipkg 一一对应，两边可以混着用：

- **包体互通**：qipkg 打出来的 tar.gz 与 Rust 版逐字节相同（见下），Rust 装得下 qipkg
  发的包，qipkg 也装得下 Rust 发的包。
- **qi.lock 互通**：两边读写同一份 lock，混用不会互相搞坏。测试里两个方向都钉着。
- **安装标记互通**：`.qi_registry.toml` 字段一致，所以幂等判断跨客户端有效 ——
  用 `qi 包 安装` 装的包，`qipkg 安装` 会正确地跳过。

**编译期依赖解析仍在 Rust，也只能在 Rust。** 编译器读 qi.toml、找 qi_packages、
决定 `导入 Graph` 解析到哪个文件，这些发生在编译过程中间（`qi/src/package.rs` 的
`resolve_local_manifest_package_path`），甩不到外部进程去。qi-pkg 不碰那条路。

## tar 是自己写的

标准库有 gzip（`压缩.压缩字节` / `解压字节`，走字节切片句柄，二进制安全），
**没有 tar**。所以 `归档.qi` 用 qi 实现了一遍：512 字节定长头 + 512 对齐数据块 +
两个全零块收尾，头里是名字、若干八进制数字和一个校验和。

按 **GNU tar** 排（magic `ustar `、version ` \0`），路径超过 99 字节走 GNU 长名扩展
（typeflag `'L'` + `././@LongLink` 条目）—— 这个仓里中文文件名遍地都是，一个中文字
3 字节，33 个字就撞线，只支持 ustar 短名根本不够用。mtime/uid/gid 一律 0，文件按
**路径序**（`/` 当作比任何字节都小）排序，所以同样的目录内容打两次字节一致。

### 与 Rust 版的字节对拍

`测试/打包对拍.sh` 拿 qipkg 和 `qi 包 发布 --只打包` 打同一个目录比 sha256。
monorepo 里 17 个包，**11 个逐字节相同**，6 个只差权限位：

```
✓ qi-kv  094593ac856fe193251f37e8a09da6bcaccc9f89385156c082f1683023faa20a
✓ qi-graph / qi-turtle / qi-cli / qi-registry / qi-widgets / qi-grpc / …
~ qi-harness 只差权限位（5 个条目的 #! 猜测与真实 chmod 不符）
```

权限位是**已知且唯一**的差异来源：qi 没有「读文件权限位」的原语，
`归档.qi` 的 `文件权限()` 用「内容以 `#!` 开头就当 0755」猜。猜错只会让 tar 头里
差几个字节 —— 两边的解包都用 `fs::write` 落地，本来就不还原权限位。
运行时哪天补上「取文件权限」，这里换成真读，对拍就能全绿。
`测试/权限差异.py` 会给每一处不同定性，确认它确实只是权限位。

其余细节也都对齐了：校验和写成「7 位零填充八进制 + NUL」（Rust 的 tar crate
就是这么写的，不是老式的「6 位 + NUL + 空格」）；符号链接一律不打进包
（qi 没有 lstat，用「规范化后还是不是原路径」来认 —— 不这么判的话
qi-harness 里那个指向编译器的 `.qibin/qi` 软链会把 50 MB 二进制打进包，
实测 412 KB → 58 MB）。

## 协议里那处偏差：上行是 base64

`PUT` 的 body 是 **base64(tar.gz)**，不是裸字节。注册中心是 qi-web 写的，
收请求体时会把内嵌的 `0x00` 逐个换成空格以维持 C 串约定 —— gzip 里遍地 `0x00`，
裸传上去长度不变、只坏几个字节，**只有 sha256 才露馅**。下行不受影响
（服务端 sendfile 绕开 qi 字符串），但客户端这边同样不能让包体过 qi 字符串：
下载走 `HTTP.下载文件` 直接落盘，再用 `字节切片.读取文件` 读回来。

来龙去脉见 [`qi-registry/README.md`](../qi-registry/README.md) 的「与协议的一处偏差」。

## 完整性

- 版本必须是「主.次.补」三段数字（v1 不做 `^1.2` 这类范围解析）
- 下载后一定对 sha256：先问单版本元数据拿权威值，下完再算一遍，对不上就丢掉
- `qi.lock` 里钉死的 sha256 与注册中心当前给的不一致 → **不下载就先停**，
  并把两个值都打出来（版本内容一旦发布就不可变，对不上只能是 lock 被改过
  或注册中心换了包体）
- 解包拒绝越界路径：绝对路径、`..`、反斜杠、盘符一律拒。判定不问宿主系统只看
  路径长什么样 —— 同一个包在 Linux 上装得下、在 Windows 上逃逸是最难查的一类
- 先解到同级临时目录，成功了才整体 rename 过去；换版本时整个目录换掉而不是
  覆盖同名文件（旧版本多出来的文件留着会撞出重复符号）

## 测

```bash
./跑测试.sh              # 单测 + 端到端（起假注册中心，不碰线上）
./跑测试.sh --对拍       # 再加与 Rust 版的打包字节对拍
./跑测试.sh --联网       # 再加对 pkg.qilang.org 的只读检查
```

`测试/假注册中心.py` 是一个够用的 pkg.qilang.org 替身（五个端点 + base64 上行 +
409 版本不可变 + 包内 qi.toml 与 URL 一致性校验），端到端测试全程只跟它说话。
**不要拿测试往真注册中心发东西** —— 版本不可变，发错了删不掉。

## 没做的

- 没有 `qipkg 删除/更新` —— 改 qi.toml 再 `qipkg 安装` 就是更新，删依赖同理
- 不解析版本范围，不做依赖求解；同名不同版本在树里各自落一份（嵌套安装天然如此）
- 权限位见上
- Windows 没验过（路径拼接一律用 `/`，`路径越界` 判定已按 Windows 形态拦盘符和反斜杠，
  但没在 Windows 上真跑过）
