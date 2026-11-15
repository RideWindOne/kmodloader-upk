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
        echo "SN=${sn:-redroid00000000}"
        echo "MAGISK=0"
        echo "ADB_SECURE=0"
        echo "ADB_KEY="
        echo "BRAND=Redmi"
        echo "MODEL=Redmi K30 Pro Zoom Edition"
        echo "DEVICE=lmipro"
    } >"$CONF"
    log "生成默认配置 $CONF（SN=${sn}）"
}

ensure_conf
# shellcheck disable=SC1090
. "$CONF"
: "${SN:=redroid00000000}"
: "${MAGISK:=0}"
: "${ADB_SECURE:=0}"
: "${ADB_KEY:=}"
: "${BRAND:=Redmi}"
: "${MODEL:=Redmi K30 Pro Zoom Edition}"
: "${DEVICE:=lmipro}"

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

# adb 鉴权：开了 secure 且有密钥，就写到 /data/misc/adb/adb_keys（redroid 的 /data 就是这个宿主目录）
if [ "$ADB_SECURE" = "1" ] && [ -n "$ADB_KEY" ]; then
    mkdir -p "$HOST_DATA/misc/adb" 2>/dev/null || true
    printf '%s\n' "$ADB_KEY" >"$HOST_DATA/misc/adb/adb_keys" 2>/dev/null \
        && chmod 600 "$HOST_DATA/misc/adb/adb_keys" 2>/dev/null \
        && log "已写入 adb_keys（鉴权开启）"
else
    rm -f "$HOST_DATA/misc/adb/adb_keys" 2>/dev/null || true
fi

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
else
    log "容器创建失败，见 $LOG"
fi
