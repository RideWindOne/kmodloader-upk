#!/bin/sh
set -u

# 数据目录：安装参数选了共享文件夹时 compose 会多挂 /user-data，优先用它；
# 没选（参数留空）则用固定挂载的 /data。两条都不存在时 mkdir 兜底。
if [ -n "${DATA_DIR:-}" ]; then
    :
elif [ -d /user-data ]; then
    DATA_DIR=/user-data
else
    DATA_DIR=/data
fi
mkdir -p "$DATA_DIR" 2>/dev/null || true
LOG="$DATA_DIR/kmod.log"
STATE="$DATA_DIR/kmod.state"

log() {
    line="$(date '+%F %T') $*"
    printf '%s\n' "$line"
    printf '%s\n' "$line" >>"$LOG" 2>/dev/null || true
}

# insmod 幂等：/proc/modules 里已有就跳过；内核返回 File exists 也视为已加载
ensure_module() {
    mod="$1"
    ko="/opt/kmod/${mod}.ko"

    if grep -q "^${mod} " /proc/modules 2>/dev/null; then
        return 2   # 2 = 本来就已加载
    fi
    if [ ! -f "$ko" ]; then
        log "[$mod] 模块文件缺失: $ko"
        return 1
    fi

    out="$(insmod "$ko" 2>&1)"
    if [ $? -eq 0 ]; then
        log "[$mod] 加载成功"
        return 0
    fi
    case "$out" in
        *"File exists"*)
            log "[$mod] 已存在（File exists），视为已加载"
            return 2
            ;;
        *)
            log "[$mod] 加载失败: $out"
            return 1
            ;;
    esac
}

# 容器自己的 /dev 是 docker 私有 tmpfs，看不到宿主新注册的 dma heap；
# compose 把宿主 /dev/dma_heap 只读挂到 /host-dma-heap，这里优先读那份真状态
dma_heaps() {
    ls /host-dma-heap 2>/dev/null | tr '\n' ' ' || ls /dev/dma_heap 2>/dev/null | tr '\n' ' '
}

# UGOS 桌面/App 打开应用时先请求 /api/ugreen/auth?token=…&system_type=ugospro，
# 非 200 会被 shell 判定为"应用不可用"（桌面弹"无法访问，请联系技术支持"，App 弹"操作失败!"）。
# 本应用不需要 UGOS 身份，只需应答 200，因此放一个静态 JSON 文件即可。
mkdir -p /www/api/ugreen 2>/dev/null || true
printf '%s\n' '{"code":0,"success":true}' >/www/api/ugreen/auth 2>/dev/null || true

# busybox-extras 的 httpd 提供状态页，端口与 project.yaml 的 port 一致
if [ -x /usr/sbin/httpd ]; then
    /usr/sbin/httpd -p 8099 -h /www 2>>"$LOG" || log "状态页 httpd 启动失败"
else
    busybox httpd -p 8099 -h /www 2>>"$LOG" || log "状态页 httpd 不可用"
fi

log "kmod-loader 启动，内核 $(uname -r)，dma_heap: [$(dma_heaps)]"

# 伴生逻辑（原 open-fixer 容器已合并进来）：安装收尾后补 portInfo 并让 app_serv 重新注册。
# 后台跑，不影响下面的模块巡检主循环。
if [ -x /opt/bin/open-fixer.sh ]; then
    # 脚本自己就写 $DATA_DIR/fixer.log，这里再重定向会让每行重复两遍
    /opt/bin/open-fixer.sh >/dev/null 2>&1 &
fi

# 常驻：每 30 秒核对一次，模块被卸载（或被别的应用抢先加载）时自动补上
last=""
while :; do
    ensure_module binder_linux;  b=$?
    ensure_module rk_dma32_heap; d=$?
    # 模块是本轮才插进去的：若 redroid 已经先一步被 docker 自启动，它启动时没有 binder，
    # 表现就是投屏黑屏。这里把它重启一次，让新进程重新打开 /dev/binder 与 dma heap。
    if [ "$b" = "0" ] || [ "$d" = "0" ]; then
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx redroid; then
            log "模块刚加载，redroid 已先启动，重启它以拿到 binder / dma heap"
            docker restart redroid >>"$LOG" 2>&1 && log "redroid 重启完成"
        fi
    fi
    now="binder=${b} dma=${d} heaps=[$(dma_heaps)]"
    if [ "$now" != "$last" ]; then
        printf '%s\n' "$now" >"$STATE" 2>/dev/null || true
        log "状态 $now"
        last="$now"
    fi
    sleep 30
done
