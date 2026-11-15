#!/bin/sh
# 在 kmod-loader 容器里通过宿主 docker.sock 新建/重建 ws-scrcpy-web 容器
# 端口与域名白名单从 /data/ws.conf 读（面板可改）
set -u

DATA_DIR="${DATA_DIR:-/data}"
LOG="$DATA_DIR/wsscrcpy.log"
WCONF="$DATA_DIR/ws.conf"

NAME="ws-scrcpy-web"
IMAGE="${WSS_IMAGE:-ridewindone/ws-scrcpy-web:latest}"

# 宿主 docker 数据目录不一定是 /volume1，从 docker 根目录反推所在卷
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

PORT="8001"
DOMAINS="*.ug.link,*.ugdocker.link,*.ugapp.link"
REMOTE_ADMIN="1"

if [ -f "$WCONF" ]; then
    while IFS='=' read -r k v; do
        case "$k" in
            PORT) [ -n "$v" ] && PORT="$v" ;;
            DOMAINS) [ -n "$v" ] && DOMAINS="$v" ;;
            REMOTE_ADMIN) [ -n "$v" ] && REMOTE_ADMIN="$v" ;;
        esac
    done <"$WCONF"
fi

DOCKER_BASE="${DOCKER_BASE:-$(detect_docker_base)}"
HOST_DATA="${WSS_DATA:-${DOCKER_BASE}/wsdata}"
log "docker 数据目录：${DOCKER_BASE}（ws-scrcpy-web 的 /data → ${HOST_DATA}）"

# 端口被占时自动让位（避免和 UGOS 自带应用抢 8000）
if docker ps --format '{{.Ports}}' 2>/dev/null | grep -q "0.0.0.0:${PORT}->"; then
    log "端口 ${PORT} 已被其它容器占用，放弃创建"
    exit 1
fi

if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$NAME"; then
    log "发现同名容器，先删除"
    docker rm -f "$NAME" >/dev/null 2>&1 || true
fi

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    log "本地无 $IMAGE，尝试拉取"
    if ! docker pull "$IMAGE" >>"$LOG" 2>&1; then
        log "镜像拉取失败，见 $LOG"
        exit 1
    fi
fi

mkdir -p "$HOST_DATA" 2>/dev/null || true

log "创建 ws-scrcpy-web（宿主 ${PORT} → 容器 8000，数据 ${HOST_DATA}，白名单 ${DOMAINS}，远程管理 ${REMOTE_ADMIN}）"
RA_ENV=""
[ "$REMOTE_ADMIN" = "1" ] && RA_ENV="-e WS_SCRCPY_ALLOW_REMOTE_ADMIN=1"
docker run -d --name "$NAME" \
    --restart unless-stopped \
    -p "${PORT}:8000" \
    -v "${HOST_DATA}:/data" \
    -e "DOMAINS=${DOMAINS}" \
    ${RA_ENV} \
    -e "PORT=8000" \
    "$IMAGE" \
    >>"$LOG" 2>&1

if [ $? -eq 0 ]; then
    log "ws-scrcpy-web 已启动：http://<NAS-IP>:${PORT}"
else
    log "容器创建失败，见 $LOG"
fi
