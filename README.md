# 内核模块补全 · UGOS Pro 打包项目

给绿联 DH4300 Plus（aarch64）打一个 `.upk`，把 `binder_linux.ko`、`rk_dma32_heap.ko`
注册进内核，让容器里的 Redroid 能跑起来，并在应用窗口内提供控制页
（运行状态 / Redroid 控制 / WS 投屏容器 / 日志 四个标签页）。

当前产物：`arm64_nasync_com.ridewind.kmodloader_1.0.0.0023.upk`（见 Release）。

## 单容器结构

`kmod-loader` 一个容器承载全部逻辑，原 `open-fixer` 伴生容器已合并进来：

```
entrypoint.sh（前台）
  ├─ 装载 binder / dma_heap 模块，写 /data 状态与日志
  ├─ 起控制页（8099）
  └─ 后台跑 /opt/bin/open-fixer.sh
       等 ugcli 收尾 → 补 config.json 的 baseAccessInfo.portInfo
       → 同步 .check-upk 的 config.json hash
       → nsenter -t 1 … systemctl restart app_serv.service
```

合并的必要性：UGOS 在 `proxy_path=/` 时不生成 `portInfo`，重装后网关注册失败，点开应用报
"无法访问"。补写动作必须在装包收尾之后、由容器自己完成，所以它没法作为独立的一次性容器存在。

`privileged` + 挂 `/var/run/docker.sock`：控制页要 pull / 部署 Redroid；挂
`/var/lib/ugb/com.ridewind.kmodloader` 与 `/volume1/@appstore/com.ridewind.kmodloader`
是 open-fixer 读写 `config.json` 用的。

## 构建

镜像不进仓库（55M，且仍可用 Hub 拉取），构建前准备：

```bash
docker pull ridewindone/ugkmodloader:dh4300plus
docker save ridewindone/ugkmodloader:dh4300plus -o rootfs_arm64/images/ugkmodloader-dh4300plus.tar
```

校验与打包：

```bash
ugcli check --path .
ugcli pack --arch arm64 --build 23      # --build 传整数，传 0023 不生效
```

产物在 `build_dir/pkgs/upk/arm64_nasync_com.ridewind.kmodloader_1.0.0.0023.upk`。

## 镜像

`ridewindone/ugkmodloader:dh4300plus` —— 只有一个 tag，没有版本号分层，更新即覆盖同一 tag：

```bash
docker pull ridewindone/ugkmodloader:dh4300plus
```

| 项 | 值 |
|---|---|
| 基础 | `alpine:latest` + `busybox-extras`、`docker-cli` |
| 体积 | 57.3MB |
| 上次构建 | 2026-11-14 |
| digest | `sha256:40fbe9b6…` |

## 目录

| 路径 | 用途 |
|---|---|
| `project.yaml` | 应用元信息：`port: 8099`、`proxy_path: /`、`open_type: inner` |
| `Dockerfile` | alpine + 模块文件 + `scripts/` + `www/` |
| `entrypoint.sh` | 前台入口：装模块、起控制页、后台拉起 open-fixer |
| `scripts/open-fixer.sh` | 安装收尾补丁（portInfo、check-upk hash、重启 app_serv） |
| `scripts/redroid-install.sh` | Redroid 容器部署 |
| `scripts/wsscrcpy-install.sh` | 联动部署安卓投屏容器 |
| `www/` | 控制页（4 个标签页） |
| `assets/` | `binder_linux.ko`、`rk_dma32_heap.ko` |
| `rootfs_arm64/images/` | 镜像 tar（构建时生成，不入库） |
| `apps.json` | UGOS 三方商店源，收录本仓库与安卓投屏两个应用 |

## 三方商店源（apps.json）

仓库根目录的 `apps.json` 是给 UGOS 三方应用商店用的应用源，格式来自绿联社区帖
[tid=6529](https://club.ugnas.com/forum.php?mod=viewthread&tid=6529)，商店在「设置」里添加这个地址即可：

```
https://raw.githubusercontent.com/RideWindOne/kmodloader-upk/main/apps.json
```

收录两个应用：

| 应用 | app_id | upk_version | 端口 | 适用机型 |
|---|---|---|---|---|
| 安卓投屏 | `com.ridewind.wsscrcpyweb` | 0.5.11.0025 | 8000 | 所有 arm64 |
| 内核模块补全 | `com.ridewind.kmodloader` | 1.0.0.0023 | 8099 | 仅 DH4300 Plus |

维护要点：

- `appname` 必须与包内 `project.yaml` 的 `app_id` 完全一致，商店安装时会解析 upk 内的 appId 比对，不一致直接拒绝；
- `upk_version` 是四段 `x.y.z.构建号`，也是更新判定的唯一依据——发新版忘了调大，商店就看不到更新；
- `platforms` 目前只有 `arm64`（amd64 镜像尚未构建），标全平台会让 x86 机型装上后跑不起来；
- 内核模块是按 DH4300 Plus 的内核版本编译的，换机型无法加载，这条写在 `description` 与 `post_install_note` 里。

## 踩过的坑

- `open-fixer` 与 `kmod-loader` 两个 fixer 曾经互相触发 `app_serv` 重启，形成循环；公用的
  `patched` 守卫因此必须落在持久卷上
- `nsenter` 重启 `app_serv` 需要 `privileged` + `pid: host`
- 宿主的 `/dev` 看不到新注册的 dma heap 节点，要单独挂 `/dev/dma_heap` 只读给状态页
