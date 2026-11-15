#!/bin/sh
# 安装收尾之后补齐 config.json 的 baseAccessInfo.portInfo，同步 .check-upk 校验清单，
# 再重启宿主的 app_serv 让网关注册生效。原先是独立的 open-fixer 容器，现合并进主容器后台运行。
#
# 匹配一律用 [[:space:]]* 容忍冒号、逗号前后的空格：早期写死了 "baseAccessInfo":{，
# UGOS 生成的是 "baseAccessInfo": { 时 sed 静默匹配不上（&& 后没有分支），
# 表现就是"合并 open-fixer 之后不生效"。
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
PORT="${KMOD_PORT:-8099}"
PI="\"portInfo\": {\"httpsEnable\": false, \"port\": \"$PORT\", \"httpsPort\": \"\", \"urlPath\": \"\"}"

# 给某个 config.json 补/改 portInfo。返回 0=改动成功，1=失败，2=没有 baseAccessInfo 字段
patch_cfg() {
    f="$1"; tag="$2"
    [ -f "$f" ] || { log "$tag: 文件不存在，跳过"; return 1; }
    if grep -q '"portInfo"' "$f"; then
        sed -i "s|\"portInfo\"[[:space:]]*:[[:space:]]*{[^}]*}|$PI|" "$f" \
            && log "$tag: 已更新 portInfo(port=$PORT)" || { log "$tag: 更新 portInfo 失败"; return 1; }
    elif grep -qE '"baseAccessInfo"[[:space:]]*:[[:space:]]*\{' "$f"; then
        sed -i "s|\"baseAccessInfo\"[[:space:]]*:[[:space:]]*{|\"baseAccessInfo\":{$PI,|" "$f" \
            && log "$tag: 已补写 portInfo(port=$PORT)" || { log "$tag: 补写 portInfo 失败"; return 1; }
    else
        log "$tag: 配置里没有 baseAccessInfo 字段，跳过（格式可能变了，需人工核对）"
        return 2
    fi
    grep -q '"portInfo"' "$f" || { log "$tag: 写入后仍找不到 portInfo，放弃本次重启"; return 1; }
    return 0
}

log "open-fixer 启动，等待安装收尾（最多 70 秒）"

# ugcli 在装包尾声仍会改写 config.json；用 mtime 轮询判断"不再变化"再动手
touch /tmp/ugcf-mark
timeout 70 sh -c 'while find /cfg/ugb/config.json /cfg/appstore/config.json -newer /tmp/ugcf-mark 2>/dev/null | grep -q .; do touch /tmp/ugcf-mark; sleep 10; done'
sleep 4

patched=""
patch_cfg "$UGBCFG" "ugb" && patched=1

if patch_cfg "$APPCFG" "appstore"; then
    patched=1
    # .check-upk 是 MD5 清单，不同步会被判"被篡改"并回滚成包内原版
    if [ -f "$CHECKUPK" ]; then
        md5="$(md5sum "$APPCFG" | cut -c1-32)"
        sed -i "s|\"config.json\"[[:space:]]*:[[:space:]]*{\"hash\"[[:space:]]*:[[:space:]]*\"[a-f0-9]*\"|\"config.json\":{\"hash\":\"$md5\"|" "$CHECKUPK" \
            && log "synced-checkupk($md5)" || log "同步 .check-upk 失败（下次装包可能被判篡改）"
    else
        log "缺少 .check-upk，跳过 hash 同步"
    fi
elif [ ! -f "$CHECKUPK" ]; then
    log "缺少 .check-upk，跳过 hash 同步"
fi

if [ -z "$patched" ]; then
    log "没有需要补的 portInfo；不重启 app_serv（避免每次容器重启都动宿主服务）"
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
