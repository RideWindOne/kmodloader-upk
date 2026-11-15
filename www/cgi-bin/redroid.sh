#!/bin/sh
# 控制面板：模块状态 + Redroid 部署 + ws-scrcpy-web 容器
set -u

DATA_DIR="${DATA_DIR:-/data}"
CONF="$DATA_DIR/redroid.conf"
LOG="$DATA_DIR/redroid.log"
WLOG="$DATA_DIR/wsscrcpy.log"
REDROID="redroid"
REDROID_IMAGE="cnflysky/redroid-rk3588:lineage-20"
WSS="ws-scrcpy-web"
WSS_IMAGE="ridewindone/ws-scrcpy-web:latest"
WSS_PORT="8001"

urldecode() {
    printf '%b' "$(printf '%s' "$1" | sed -e 's/+/ /g' -e 's/%/\\x/g')"
}

SN=""; MAGISK="0"; ADB_SECURE="0"; ADB_KEY=""
BRAND="Redmi"; MODEL="Redmi K30 Pro Zoom Edition"; DEVICE="lmipro"
WCONF="$DATA_DIR/ws.conf"
WS_PORT="8001"; WS_DOMAINS="*.ug.link,*.ugdocker.link,*.ugapp.link"; WS_RADMIN="1"

[ -f "$CONF" ] && while IFS='=' read -r k v; do
    # 配置里的值一律是 printf "KEY='%s'" 写出来的，读回来要先剥掉外层单引号。
    # 不剥的话面板 textarea 会显示成 'QAAAA…，用户再存一次就多一层引号，
    # adb_keys 写进 redroid 后第一个字符变成单引号，adbd 直接把整行当无效 key。
    while [ "${v#\'}" != "$v" ]; do v="${v#\'}"; done
    while [ "${v%\'}" != "$v" ]; do v="${v%\'}"; done
    case "$k" in
        SN) SN="$v" ;;
        MAGISK) MAGISK="$v" ;;
        ADB_SECURE) ADB_SECURE="$v" ;;
        ADB_KEY) ADB_KEY="$v" ;;
        BRAND) BRAND="$v" ;;
        MODEL) MODEL="$v" ;;
        DEVICE) DEVICE="$v" ;;
        DOCKER_BASE) DOCKER_BASE_CONF="$v" ;;
    esac
done <"$CONF"

[ -z "$SN" ] && SN="$(cat /proc/sys/kernel/random/uuid 2>/dev/null | tr -d '-' | cut -c1-16)"

[ -f "$WCONF" ] && while IFS='=' read -r k v; do
    case "$k" in
        PORT) [ -n "$v" ] && WS_PORT="$v" ;;
        DOMAINS) [ -n "$v" ] && WS_DOMAINS="$v" ;;
        REMOTE_ADMIN) [ -n "$v" ] && WS_RADMIN="$v" ;;
    esac
done <"$WCONF"

write_wsconf() {
    {
        echo "PORT=$WS_PORT"
        echo "DOMAINS=$WS_DOMAINS"
        echo "REMOTE_ADMIN=$WS_RADMIN"
    } >"$WCONF"
}

# 值一律用单引号包住：MODEL 是三个词、ADB_KEY 的公钥行末尾还带一个 " @host"，
# 直接 echo "ADB_KEY=$ADB_KEY" 写出去的那行，脚本 source 时会被当成
# "临时赋值 + 执行后面的词"，赋值不保留，ADB_KEY 读回来就是空的。
write_conf() {
    {
        printf "SN='%s'\n" "$SN"
        printf "MAGISK='%s'\n" "$MAGISK"
        printf "ADB_SECURE='%s'\n" "$ADB_SECURE"
        # 手动在 conf 里写过的 DOCKER_BASE 要保留，否则保存配置会把它丢掉
        [ -n "${DOCKER_BASE_CONF:-}" ] && printf "DOCKER_BASE='%s'\n" "$DOCKER_BASE_CONF"
        printf "ADB_KEY='%s'\n" "$ADB_KEY"
        printf "BRAND='%s'\n" "$BRAND"
        printf "MODEL='%s'\n" "$MODEL"
        printf "DEVICE='%s'\n" "$DEVICE"
    } >"$CONF"
}

ACTION=""; F_MAGISK=""; F_SECURE=""; F_KEY=""; F_BRAND=""; F_MODEL=""; F_DEVICE=""
F_SN=""; F_WPORT=""; F_WDOM=""; F_SCOPE=""

if [ "${REQUEST_METHOD:-GET}" = "POST" ] && [ "${CONTENT_LENGTH:-0}" -gt 0 ]; then
    body="$(dd bs=1 count="$CONTENT_LENGTH" 2>/dev/null)"
    old_ifs="$IFS"; IFS='&'
    for kv in $body; do
        k="${kv%%=*}"; v="${kv#*=}"
        case "$k" in
            action) ACTION="$(urldecode "$v")" ;;
            magisk) F_MAGISK="$(urldecode "$v")" ;;
            adb_secure) F_SECURE="$(urldecode "$v")" ;;
            adb_key) F_KEY="$(urldecode "$v")" ;;
            brand) F_BRAND="$(urldecode "$v")" ;;
            model) F_MODEL="$(urldecode "$v")" ;;
            device) F_DEVICE="$(urldecode "$v")" ;;
            sn) F_SN="$(urldecode "$v")" ;;
            wss_port) F_WPORT="$(urldecode "$v")" ;;
            wss_domains) F_WDOM="$(urldecode "$v")" ;;
            scope) F_SCOPE="$(urldecode "$v")" ;;
        esac
    done
    IFS="$old_ifs"

    # ws 表单不提 redroid 字段，只更新自己的两项，避免把 redroid 配置清空
    if [ "$F_SCOPE" = "ws" ]; then
        [ -n "$F_WPORT" ] && WS_PORT="$F_WPORT"
        [ -n "$F_WDOM" ] && WS_DOMAINS="$F_WDOM"
    else
        # redroid 表单提交时以界面值为准：checkbox 未勾选就不提交，等同 0
        MAGISK="${F_MAGISK:-0}"; [ "$MAGISK" = "on" ] && MAGISK=1
        ADB_SECURE="${F_SECURE:-0}"; [ "$ADB_SECURE" = "on" ] && ADB_SECURE=1
        ADB_KEY="$F_KEY"
        # 粘贴进来的值可能已经被上一轮多包了引号，这里剥干净再存，
        # 否则每存一次就多一层，最后 adb_keys 首字符变成单引号
        while [ "${ADB_KEY#\'}" != "$ADB_KEY" ]; do ADB_KEY="${ADB_KEY#\'}"; done
        while [ "${ADB_KEY%\'}" != "$ADB_KEY" ]; do ADB_KEY="${ADB_KEY%\'}"; done
        [ -n "$F_BRAND" ] && BRAND="$F_BRAND"
        [ -n "$F_MODEL" ] && MODEL="$F_MODEL"
        [ -n "$F_DEVICE" ] && DEVICE="$F_DEVICE"
        [ -n "$F_SN" ] && SN="$F_SN"
    fi
fi

case "$ACTION" in
    save) write_conf; write_wsconf ;;
    new_sn)
        SN="$(cat /proc/sys/kernel/random/uuid 2>/dev/null | tr -d '-' | cut -c1-16)"
        write_conf; write_wsconf
        ;;
    install) write_conf; write_wsconf; setsid /opt/bin/redroid-install.sh >/dev/null 2>&1 & ;;
    stop) docker stop "$REDROID" >/dev/null 2>&1 ;;
    remove) docker rm -f "$REDROID" >/dev/null 2>&1 ;;
    wss_install) write_conf; write_wsconf; setsid /opt/bin/wsscrcpy-install.sh >/dev/null 2>&1 & ;;
    wss_stop) write_conf; write_wsconf; docker stop "$WSS" >/dev/null 2>&1 ;;
    wss_remove) write_conf; write_wsconf; docker rm -f "$WSS" >/dev/null 2>&1 ;;
esac

state_of() {
    n="$1"
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$n"; then echo "运行中"
    elif docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$n"; then echo "已停止"
    else echo "未部署"; fi
}

# docker 数据目录不一定在 volume1：从 docker 根目录（/volumeN/@docker）反推所在卷
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
DBASE="${DOCKER_BASE_CONF:-$(detect_docker_base)}"
DROOT="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null)"
[ -z "$DROOT" ] && DROOT="未知"
R_STATE="$(state_of "$REDROID")"
W_STATE="$(state_of "$WSS")"

IMG_OK="未拉取"; docker image inspect "$REDROID_IMAGE" >/dev/null 2>&1 && IMG_OK="已就绪"
W_IMG_OK="未拉取"; docker image inspect "$WSS_IMAGE" >/dev/null 2>&1 && W_IMG_OK="已就绪"

tail_of() {
    tail -n 5 "$1" 2>/dev/null | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}
RT="$(tail_of "$LOG")"; [ -z "$RT" ] && RT="（暂无记录）"
WT="$(tail_of "$WLOG")"; [ -z "$WT" ] && WT="（暂无记录）"

cm=""; ca=""
[ "$MAGISK" = "1" ] && cm="checked"
[ "$ADB_SECURE" = "1" ] && ca="checked"

echo "Content-Type: text/html; charset=utf-8"
echo "Cache-Control: no-store"
echo ""
cat <<EOF
<!DOCTYPE html>
<html lang="zh-CN"><head><meta charset="utf-8">
<style>
  body{margin:0;padding:14px 16px 20px;background:#171b21;color:#e6e9ef;
    font:13px/1.7 -apple-system,"PingFang SC","Microsoft YaHei",sans-serif;}
  .row{display:flex;justify-content:space-between;padding:6px 0;border-bottom:1px solid #232830;}
  .k{color:#9aa3b2;} .on{color:#5bd18b;font-weight:600;} .off{color:#f0616d;font-weight:600;}
  .sec{margin:16px 0 8px;color:#8b93a1;font-size:12px;letter-spacing:.5px;}
  label{display:flex;align-items:center;gap:8px;padding:5px 0;}
  input[type=checkbox]{width:18px;height:18px;}
  input[type=text]{width:100%;box-sizing:border-box;background:#12161b;color:#e6e9ef;
    border:1px solid #2a3040;border-radius:8px;padding:9px 10px;font-size:13px;margin-bottom:8px;}
  textarea{width:100%;box-sizing:border-box;background:#12161b;color:#e6e9ef;
    border:1px solid #2a3040;border-radius:8px;padding:8px;font:12px/1.5 ui-monospace,monospace;}
  .btns{display:flex;flex-wrap:wrap;gap:8px;margin-top:10px;}
  button{flex:1 1 42%;min-height:42px;background:#2565d8;color:#fff;border:0;border-radius:8px;
    font-size:14px;font-weight:600;cursor:pointer;}
  button.ghost{background:#2a3040;} button.danger{background:#8c3a42;}
  .log{background:#12161b;border-radius:8px;padding:9px 12px;color:#a9b3c1;
    font:12px/1.6 ui-monospace,monospace;white-space:pre-wrap;word-break:break-all;margin-top:8px;
    max-height:170px;overflow-y:auto;}
  .hint{color:#6f7887;font-size:11px;margin-top:4px;}
  .field{margin-bottom:2px;color:#9aa3b2;font-size:12px;}
</style></head><body>

<div class="row"><span class="k">Redroid 容器</span>
  <span class="$([ "$R_STATE" = "运行中" ] && echo on || echo off)">$R_STATE</span></div>
<div class="row"><span class="k">镜像（${REDROID_IMAGE}）</span>
  <span class="$([ "$IMG_OK" = "已就绪" ] && echo on || echo off)">$IMG_OK</span></div>
<div class="row"><span class="k">adb 端口</span><span>5555</span></div>
<div class="row"><span class="k">docker 根目录</span><span>${DROOT}</span></div>
<div class="row"><span class="k">Android 数据目录</span><span>${DBASE}/data</span></div>

<form method="post" action="redroid.sh">
  <div class="sec">设备序列号（可直接改，或用下面按钮重新生成）</div>
  <input type="text" name="sn" value="$(printf '%s' "$SN" | sed -e 's/"/\&quot;/g')">

  <div class="sec">启动参数</div>
  <label><input type="checkbox" name="magisk" value="1" $cm> Magisk（androidboot.redroid_magisk）</label>
  <label><input type="checkbox" name="adb_secure" value="1" $ca> 开启 adb 鉴权（ro.adb.secure=1）</label>

  <div class="sec">adb 公钥（鉴权开启时写入 /data/misc/adb/adb_keys）</div>
  <textarea name="adb_key" rows="2" placeholder="ssh-rsa AAAAB3... 留空则清除">$(printf '%s' "$ADB_KEY" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g')</textarea>

  <div class="sec">机型伪装</div>
  <div class="field">品牌 ro.product.brand</div>
  <input type="text" name="brand" value="$(printf '%s' "$BRAND" | sed -e 's/"/\&quot;/g')">
  <div class="field">型号 ro.product.model</div>
  <input type="text" name="model" value="$(printf '%s' "$MODEL" | sed -e 's/"/\&quot;/g')">
  <div class="field">设备代号 ro.product.device</div>
  <input type="text" name="device" value="$(printf '%s' "$DEVICE" | sed -e 's/"/\&quot;/g')">
  <div class="hint">改机型后需重新部署才生效；fingerprint 会按 品牌/代号 重新拼接</div>

  <div class="btns">
    <button type="submit" name="action" value="install">部署 / 重建 Redroid</button>
    <button type="submit" name="action" value="save" class="ghost">仅保存配置</button>
    <button type="submit" name="action" value="new_sn" class="ghost">重新生成 SN</button>
    <button type="submit" name="action" value="stop" class="ghost">停止</button>
    <button type="submit" name="action" value="remove" class="danger">删除容器</button>
  </div>
</form>

</body></html>
EOF
