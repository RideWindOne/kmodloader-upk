#!/bin/sh
# 安装收尾之后补齐 config.json 的 baseAccessInfo.portInfo，同步 .check-upk 校验清单，
# 再重启宿主的 app_serv 让网关注册生效。原先是独立的 open-fixer 容器，现合并进主容器后台运行。
set -u

DATA_DIR="${DATA_DIR:-/data}"
LOG="$DATA_DIR/fixer.log"

log() {
    line="$(date '+%F %T') $*"
    printf '%s\n' "$line"
    printf '%s\n' "$line" >>"$LOG" 2>/dev/null || true
}

UGBCFG=/cfg/ugb/config.json
APPCFG=/cfg/appstore/config.json
CHECKUPK=/cfg/appstore/.check-upk

log "open-fixer 启动，等待安装收尾（最多 70 秒）"

# ugcli 在装包尾声仍会改写 config.json；用 mtime 轮询判断"不再变化"再动手
touch /tmp/ugcf-mark
timeout 70 sh -c 'while find /cfg/ugb/config.json /cfg/appstore/config.json -newer /tmp/ugcf-mark 2>/dev/null | grep -q .; do touch /tmp/ugcf-mark; sleep 10; done'
sleep 4

patched=""

if [ -f "$UGBCFG" ] && ! grep -q '"portInfo"' "$UGBCFG"; then
    sed -i 's/"baseAccessInfo":{/"baseAccessInfo":{"portInfo": {"httpsEnable": false, "port": "8099", "httpsPort": "", "urlPath": ""},/' "$UGBCFG" && log "patched-ugb"
    patched=1
fi

if [ -f "$APPCFG" ] && ! grep -q '"portInfo"' "$APPCFG"; then
    sed -i 's/"baseAccessInfo":{/"baseAccessInfo":{"portInfo": {"httpsEnable": false, "port": "8099", "httpsPort": "", "urlPath": ""},/' "$APPCFG" && log "patched-appstore"
    # .check-upk 是 MD5 清单，不同步会被判"被篡改"并回滚成包内原版
    if [ -f "$CHECKUPK" ]; then
        md5sum "$APPCFG" | cut -c1-32 | xargs -I{} sed -i 's/"config.json":{"hash":"[a-f0-9]*"/"config.json":{"hash":"{}"/' "$CHECKUPK" && log "synced-checkupk"
    else
        log "缺少 .check-upk，跳过 hash 同步"
    fi
    patched=1
fi

if [ -z "$patched" ]; then
    log "portInfo 已存在，无需补写；不重启 app_serv（避免每次容器重启都动宿主服务）"
    exit 0
fi

# 用自身镜像起一个临时容器 nsenter 到宿主 PID 1 重启 app_serv；
# 镜像 id 来自本容器（比依赖 tag 更稳）
img="$(docker inspect --format '{{.Image}}' "$(hostname)" 2>/dev/null)"
[ -z "$img" ] && img="ridewindone/ugkmodloader:dh4300plus"

log "重启 app_serv 以重新注册应用（image=$img）"
if docker run --rm --privileged --pid=host --entrypoint nsenter "$img" \
        -t 1 -m -u -i -n -p systemctl restart app_serv.service >>"$LOG" 2>&1; then
    log "open-fixer done"
else
    log "app_serv 重启失败，见 $LOG"
fi
