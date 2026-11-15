#!/bin/sh
# 在 kmod-loader 容器里通过宿主 docker.sock 部署 redroid
# 前置条件：两个内核模块必须先加载成功，否则 redroid 起不来
set -u

DATA_DIR="${DATA_DIR:-/data}"
CONF="$DATA_DIR/redroid.conf"
LOG="$DATA_DIR/redroid.log"
IMAGE="${REDROID_IMAGE:-cnflysky/redroid-rk3588:lineage-20}"
NAME="redroid"

# 宿主 docker 数据目录不一定是 /volume1，从 docker 根目录反推所在卷（/volumeN/@docker → /volumeN/docker）
detect_docker_base() {
    root="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null)"
    case "$root" in
        /volume*)
            v="${root#/volume}"
            v="${v%%/*}"
            printf '/volume%s/docker\n' "$v"
            ;;
        *) printf '%s\n' "${DOCKER_BASE_FALLBACK:-/volume1/docker}" ;;
    esac
}

log() {
    line="$(date '+%F %T') $*"
    printf '%s\n' "$line"
    printf '%s\n' "$line" >>"$LOG" 2>/dev/null || true
}

ensure_conf() {
    [ -f "$CONF" ] && return 0
    sn="$(cat /proc/sys/kernel/random/uuid 2>/dev/null | tr -d '-' | cut -c1-16)"
    {
        printf "SN='%s'\n" "${sn:-redroid00000000}"
        printf "MAGISK='0'\n"
        printf "ADB_SECURE='0'\n"
        printf "ADB_KEY=''\n"
        printf "BRAND='Redmi'\n"
        printf "MODEL='Redmi K30 Pro Zoom Edition'\n"
        printf "DEVICE='lmipro'\n"
    } >"$CONF"
    log "生成默认配置 $CONF（SN=${sn}）"
}

# 逐行取 KEY=VALUE，不再 source conf。
# 值里带空格（MODEL 是三个词）或末尾带 "@host"（adb 公钥行就长这样）时，
# . "$CONF" 会把整行解析成"临时赋值 + 执行后面的词"：赋值不会留在当前 shell，
# 于是 ADB_KEY 一直是空串，write_adb_key 直接走了"未开启鉴权"的清除分支 ——
# 表现就是公钥怎么填都写不进去、adb 仍然要授权。
conf_get() {
    [ -f "$CONF" ] || { printf '\n'; return 0; }
    awk -v k="$1" 'index($0, k "=") == 1 {
        v = substr($0, length(k) + 2)
        while (v ~ "^\047") v = substr(v, 2)
        while (v ~ "\047$") v = substr(v, 1, length(v) - 1)
        print v
        exit
    }' "$CONF"
}

ensure_conf
SN="$(conf_get SN)";                  : "${SN:=redroid00000000}"
MAGISK="$(conf_get MAGISK)";          : "${MAGISK:=0}"
ADB_SECURE="$(conf_get ADB_SECURE)";  : "${ADB_SECURE:=0}"
ADB_KEY="$(conf_get ADB_KEY)";        : "${ADB_KEY:=}"
BRAND="$(conf_get BRAND)";            : "${BRAND:=Redmi}"
MODEL="$(conf_get MODEL)";            : "${MODEL:=Redmi K30 Pro Zoom Edition}"
DEVICE="$(conf_get DEVICE)";          : "${DEVICE:=lmipro}"
DOCKER_BASE="$(conf_get DOCKER_BASE)"

# conf 里可以写 DOCKER_BASE 覆盖自动探测；不写就按 docker 根目录反推
DOCKER_BASE="${DOCKER_BASE:-$(detect_docker_base)}"
HOST_DATA="${DOCKER_BASE}/data"
log "docker 数据目录：${DOCKER_BASE}（redroid 的 /data → ${HOST_DATA}）"

# ---- 模块必须是已加载状态，redroid 才有 binder 与 dma heap ----
ensure_module() {
    mod="$1"; ko="/opt/kmod/${mod}.ko"
    if grep -q "^${mod} " /proc/modules 2>/dev/null; then
        log "[$mod] 已加载"
        return 0
    fi
    [ -f "$ko" ] || { log "[$mod] 模块文件缺失 $ko"; return 1; }
    out="$(insmod "$ko" 2>&1)"
    if [ $? -eq 0 ]; then
        log "[$mod] 加载成功"
        return 0
    fi
    case "$out" in
        *"File exists"*) log "[$mod] 已存在，视为已加载"; return 0 ;;
        *) log "[$mod] 加载失败: $out"; return 1 ;;
    esac
}

ensure_module binder_linux  || { log "binder_linux 不可用，放弃启动 redroid"; exit 1; }
ensure_module rk_dma32_heap || { log "rk_dma32_heap 不可用，放弃启动 redroid"; exit 1; }

# adb 鉴权：adb_keys 只能写进 redroid 容器里的 /data/misc/adb。
#   1) 写宿主 ${HOST_DATA}/misc/adb 是错的：kmod-loader 没挂宿主 /volume1/docker，
#      那个路径落进本容器自己的文件系统，redroid 看不到。
#   2) docker cp 在本容器上不可用：redroid 绑了 /dev/mali0、/dev/rga 等设备节点，
#      daemon 遍历容器 rootfs 时直接报 "openat dev/mali0: read-only file system"。
#   3) cat > 嵌套在 docker exec 里也读到过空内容（写出 0 字节 adb_keys）。
# 现在用 printf | docker exec -i ... tee：内容是纯文本、走 stdin，浏览器粘贴的
# 换行/空格都不会破坏它。写完对齐 owner/perm/SELinux 标签，再重启 redroid
#（adbd 只在开机时读一次 adb_keys，不重启不重新加载）。
write_adb_key() {
    if [ "$ADB_SECURE" != "1" ] || [ -z "$ADB_KEY" ]; then
        docker exec -u 0 "$NAME" sh -c 'rm -f /data/misc/adb/adb_keys' >/dev/null 2>&1 || true
        log "adb 鉴权未开启（secure=$ADB_SECURE），已清除 adb_keys"
        return 0
    fi
    # 逐行清洗后保留全部公钥行。adb_keys 是每行一把 key、adbd 逐行解析，
    # 所以多台电脑的公钥可以一次性全部写进去（旧版 head -n 1 只留第一把，其余丢）。
    # 清洗：去 CR、剥掉历史遗留的层层单引号、去首尾空白、丢弃说明文字行。
    keys="$(printf '%s\n' "$ADB_KEY" | tr -d '\r' | while IFS= read -r line; do
        while [ "${line#\'}" != "$line" ]; do line="${line#\'}"; done
        while [ "${line%\'}" != "$line" ]; do line="${line%\'}"; done
        line="$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        [ -n "$line" ] && printf '%s\n' "$line"
    done | awk '($1 ~ /^(ssh-|ecdsa-|sk-)/) || ($0 ~ /^[A-Za-z0-9+\/=]+([[:space:]].*)?$/)')"
    if [ -z "$keys" ]; then
        keys="$(printf '%s' "$ADB_KEY" | tr -d '\r')"
        log "公钥里没识别到标准 key 行，按原文写入"
    fi

    # 容器刚 run 出来时 exec 可能还没就绪，短暂重试（只等容器可用，不等系统 boot 完成）
    i=0
    until docker exec -u 0 "$NAME" true >/dev/null 2>&1; do
        i=$((i+1))
        if [ "$i" -ge 12 ]; then
            log "redroid 容器 exec 不可用，adb_keys 未写入"
            return 1
        fi
        sleep 2
    done

    docker exec -u 0 "$NAME" sh -c 'mkdir -p /data/misc/adb' >/dev/null 2>&1
    if ! printf '%s\n' "$keys" | docker exec -i -u 0 "$NAME" tee /data/misc/adb/adb_keys >/dev/null 2>&1; then
        log "写入 /data/misc/adb/adb_keys 失败"
        return 1
    fi

    # 权限和属组：adbd 进程以 shell(uid 2000) 身份跑，文件必须是 root:shell 0640。
    # 写成 root:root 时 group 不对，shell 读不到，adbd 就一直要求授权（unauthorized）。
    # 真机上 /data/misc/adb/adb_keys 也是这个属组。
    docker exec -u 0 "$NAME" sh -c '
        chown 0:2000 /data/misc/adb/adb_keys
        chmod 640 /data/misc/adb/adb_keys
        chcon u:object_r:adb_keys_file:s0 /data/misc/adb/adb_keys 2>/dev/null || true
    ' >/dev/null 2>&1

    # 回读校验：写进去必须是非空文本，否则说明这条链路又断了
    got="$(docker exec -u 0 "$NAME" sh -c 'wc -c < /data/misc/adb/adb_keys' 2>/dev/null | tr -d ' \r\n')"
    if [ -z "$got" ] || [ "$got" = "0" ]; then
        log "adb_keys 写入后是空文件，鉴权不会生效"
        return 1
    fi

    # 重启生效
    cnt="$(printf '%s\n' "$keys" | grep -c . 2>/dev/null | tr -d ' ')"
    if docker restart "$NAME" >/dev/null 2>&1; then
        log "已写入 ${cnt:-1} 把公钥并重启 redroid 生效（鉴权开启）"
    else
        log "已写入 adb_keys，但重启失败，请手动执行 docker restart $NAME"
    fi
    return 0
}

if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$NAME"; then
    log "发现同名容器，先删除"
    docker rm -f "$NAME" >/dev/null 2>&1 || true
fi

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    log "本地无镜像，开始拉取 $IMAGE（可能耗时较久）"
    if ! docker pull "$IMAGE" >>"$LOG" 2>&1; then
        log "镜像拉取失败，见 $LOG"
        exit 1
    fi
    log "镜像拉取完成"
fi

log "创建容器（magisk=$MAGISK adb_secure=$ADB_SECURE SN=$SN 机型=$BRAND $MODEL/$DEVICE）"
# 只挂 system / cma 两个堆，其余堆由 redroid 自己按需处理；不指定 gpu_mode，交给它自动选
docker run -d --name "$NAME" \
    --privileged \
    --restart unless-stopped \
    -p 5555:5555 \
    -v "$HOST_DATA:/data" \
    -v /dev/mali0:/dev/mali0 \
    -v /dev/mpp_service:/dev/mpp_service \
    -v /dev/rga:/dev/rga \
    -v /dev/dma_heap/system:/dev/dma_heap/system \
    -v /dev/dma_heap/cma:/dev/dma_heap/cma \
    "$IMAGE" \
    androidboot.redroid_width=1080 \
    androidboot.redroid_height=2400 \
    androidboot.redroid_dpi=440 \
    androidboot.redroid_fps=60 \
    androidboot.redroid_magisk="$MAGISK" \
    androidboot.redroid_fake_wifi=1 \
    androidboot.redroid_fake_wifi_ssid=ASUS_5G \
    androidboot.redroid_fake_wifi_mac=b2:1c:5e:c6:e0:50 \
    androidboot.redroid_enable_input_subsys=1 \
    ro.adb.secure="$ADB_SECURE" \
    ro.build.characteristics=default \
    androidboot.serialno="$SN" \
    ro.product.brand="$BRAND" \
    ro.product.model="$MODEL" \
    ro.product.device="$DEVICE" \
    ro.product.name="$DEVICE" \
    ro.product.manufacturer=Xiaomi \
    ro.product.product.device="$DEVICE" \
    ro.product.product.name="$DEVICE" \
    ro.product.product.model="$MODEL" \
    ro.product.product.manufacturer=Xiaomi \
    ro.product.system.device="$DEVICE" \
    ro.product.system.model="$MODEL" \
    ro.product.system.manufacturer=Xiaomi \
    ro.product.system.name="$DEVICE" \
    ro.product.system_ext.device="$DEVICE" \
    ro.product.system_ext.model="$MODEL" \
    ro.product.system_ext.manufacturer=Xiaomi \
    ro.product.system_ext.name="$DEVICE" \
    ro.product.vendor.device="$DEVICE" \
    ro.product.vendor.model="$MODEL" \
    ro.product.vendor.manufacturer=Xiaomi \
    ro.product.vendor.name="$DEVICE" \
    ro.product.odm.device="$DEVICE" \
    ro.product.odm.model="$MODEL" \
    ro.product.odm.manufacturer=Xiaomi \
    ro.product.odm.name="$DEVICE" \
    ro.build.fingerprint="${BRAND}/${DEVICE}/${DEVICE}:13/BP2A.250605.031.A3/OS3.0.301.0.WJKCNXM:user/release-keys" \
    ro.vendor.build.fingerprint="${BRAND}/${DEVICE}/${DEVICE}:13/RKQ1.211001.001/OS3.0.301.0.WJKCNXM:user/release-keys" \
    ro.bootimage.build.fingerprint="${BRAND}/${DEVICE}/${DEVICE}:13/RKQ1.211001.001/OS3.0.301.0.WJKCNXM:user/release-keys" \
    ro.build.version.security_patch=2026-02-01 \
    ro.build.version.incremental=OS3.0.301.0.WJKCNXM \
    ro.build.id=BP2A.250605.031.A3 \
    ro.build.type=user \
    ro.build.tags=release-keys \
    ro.build.user=android-build \
    ro.build.host=b33c64k4a \
    >>"$LOG" 2>&1

if [ $? -eq 0 ]; then
    log "redroid 容器已启动，adb 端口 5555"
    write_adb_key
else
    log "容器创建失败，见 $LOG"
fi
