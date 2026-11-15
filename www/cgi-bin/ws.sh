#!/bin/sh
# ws-scrcpy-web 容器页：状态、端口、域名白名单与部署操作
set -u

DATA_DIR="${DATA_DIR:-/data}"
CONF="$DATA_DIR/redroid.conf"
WCONF="$DATA_DIR/ws.conf"
WSS="ws-scrcpy-web"
WSS_IMAGE="ridewindone/ws-scrcpy-web:latest"
WS_PORT="8001"
WS_DOMAINS="*.ug.link,*.ugdocker.link,*.ugapp.link"
REMOTE_ADMIN="1"
DOCKER_BASE_CONF=""

urldecode() {
    printf '%b' "$(printf '%s' "$1" | sed -e 's/+/ /g' -e 's/%/\\x/g')"
}

# 只取 DOCKER_BASE，其余 redroid 配置与本页无关
[ -f "$CONF" ] && while IFS='=' read -r k v; do
    case "$k" in
        DOCKER_BASE) DOCKER_BASE_CONF="$v" ;;
    esac
done <"$CONF"

[ -f "$WCONF" ] && while IFS='=' read -r k v; do
    case "$k" in
        PORT) [ -n "$v" ] && WS_PORT="$v" ;;
        DOMAINS) [ -n "$v" ] && WS_DOMAINS="$v" ;;
        REMOTE_ADMIN) [ -n "$v" ] && REMOTE_ADMIN="$v" ;;
    esac
done <"$WCONF"

write_wsconf() {
    {
        echo "PORT=$WS_PORT"
        echo "DOMAINS=$WS_DOMAINS"
        echo "REMOTE_ADMIN=$REMOTE_ADMIN"
    } >"$WCONF"
}

ACTION=""; F_WPORT=""; F_WDOM=""; F_RADMIN=""

if [ "${REQUEST_METHOD:-GET}" = "POST" ] && [ "${CONTENT_LENGTH:-0}" -gt 0 ]; then
    body="$(dd bs=1 count="$CONTENT_LENGTH" 2>/dev/null)"
    old_ifs="$IFS"; IFS='&'
    for kv in $body; do
        k="${kv%%=*}"; v="${kv#*=}"
        case "$k" in
            action) ACTION="$(urldecode "$v")" ;;
            wss_port) F_WPORT="$(urldecode "$v")" ;;
            wss_domains) F_WDOM="$(urldecode "$v")" ;;
            remote_admin) F_RADMIN="$(urldecode "$v")" ;;
        esac
    done
    IFS="$old_ifs"

    [ -n "$F_WPORT" ] && WS_PORT="$F_WPORT"
    [ -n "$F_WDOM" ] && WS_DOMAINS="$F_WDOM"
    # 复选框未勾选时不会提交，因此按 0 处理
    case "$F_RADMIN" in
        1|on) REMOTE_ADMIN="1" ;;
        *) REMOTE_ADMIN="0" ;;
    esac
fi

case "$ACTION" in
    wss_install) write_wsconf; setsid /opt/bin/wsscrcpy-install.sh >/dev/null 2>&1 & ;;
    wss_stop) write_wsconf; docker stop "$WSS" >/dev/null 2>&1 ;;
    wss_remove) write_wsconf; docker rm -f "$WSS" >/dev/null 2>&1 ;;
esac

state_of() {
    n="$1"
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$n"; then echo "运行中"
    elif docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$n"; then echo "已停止"
    else echo "未部署"; fi
}

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
W_STATE="$(state_of "$WSS")"
W_IMG_OK="未拉取"; docker image inspect "$WSS_IMAGE" >/dev/null 2>&1 && W_IMG_OK="已就绪"

# 容器里实际生效的远程管理开关（以环境变量为准）
RA_LIVE="未知"
if [ "$W_STATE" = "运行中" ] || [ "$W_STATE" = "已停止" ]; then
    if docker inspect "$WSS" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
        | grep -q '^WS_SCRCPY_ALLOW_REMOTE_ADMIN=1'; then
        RA_LIVE="已开启"
    else
        RA_LIVE="已关闭"
    fi
fi
RA_CHECKED=""; [ "$REMOTE_ADMIN" = "1" ] && RA_CHECKED="checked"

# 展示用访问地址：App/域名场景用网关端口型域名（不拼端口），局域网 IP 场景才带端口
HOST="${HTTP_HOST:-}"
[ -z "$HOST" ] && HOST="${SERVER_NAME:-}"
HOST="${HOST%%:*}"
WS_URL=""
case "$HOST" in
    app-*-*)
        r="${HOST#app-}"
        r="${r#*-}"
        r="${r%.ugapp.link}"; r="${r%.ugdocker.link}"; r="${r%.ug.link}"
        [ -n "$r" ] && WS_URL="https://app-${WS_PORT}-${r}.ugdocker.link/"
        ;;
esac
[ -z "$WS_URL" ] && [ -n "$HOST" ] && WS_URL="http://${HOST}:${WS_PORT}"

echo "Content-Type: text/html; charset=utf-8"
echo "Cache-Control: no-store"
echo ""
cat <<EOF
<!DOCTYPE html>
<html lang="zh-CN"><head><meta charset="utf-8">
<style>
  body{margin:0;padding:14px 16px 20px;background:#171b21;color:#e6e9ef;
    font:13px/1.7 -apple-system,"PingFang SC","Microsoft YaHei",sans-serif;}
  .row{display:flex;justify-content:space-between;padding:6px 0;border-bottom:1px solid #232830;gap:12px;}
  .k{color:#9aa3b2;} .v{text-align:right;word-break:break-all;}
  a{color:#6fa8ff;text-decoration:none;}
  .on{color:#5bd18b;font-weight:600;} .off{color:#f0616d;font-weight:600;}
  .sec{margin:16px 0 8px;color:#8b93a1;font-size:12px;letter-spacing:.5px;}
  input[type=text]{width:100%;box-sizing:border-box;background:#12161b;color:#e6e9ef;
    border:1px solid #2a3040;border-radius:8px;padding:9px 10px;font-size:13px;}
  textarea{width:100%;box-sizing:border-box;background:#12161b;color:#e6e9ef;
    border:1px solid #2a3040;border-radius:8px;padding:8px;font:12px/1.5 ui-monospace,monospace;}
  .btns{display:flex;flex-wrap:wrap;gap:8px;margin-top:10px;}
  button{flex:1 1 42%;min-height:42px;background:#2565d8;color:#fff;border:0;border-radius:8px;
    font-size:14px;font-weight:600;cursor:pointer;}
  button.ghost{background:#2a3040;} button.danger{background:#8c3a42;}
  .hint{color:#6f7887;font-size:11px;margin-top:4px;}
  .chk{display:flex;align-items:center;gap:10px;padding:10px 12px;background:#12161b;
    border:1px solid #2a3040;border-radius:8px;cursor:pointer;font-size:13px;}
  .chk input{width:20px;height:20px;accent-color:#2565d8;flex:0 0 auto;}
  .chk span{flex:1;}
  .foot{margin-top:16px;color:#6f7887;font-size:11px;border-top:1px solid #232830;padding-top:8px;}
</style></head><body>

<div class="row"><span class="k">容器状态</span>
  <span class="$([ "$W_STATE" = "运行中" ] && echo on || echo off)">$W_STATE</span></div>
<div class="row"><span class="k">镜像（${WSS_IMAGE}）</span>
  <span class="$([ "$W_IMG_OK" = "已就绪" ] && echo on || echo off)">$W_IMG_OK</span></div>
<div class="row"><span class="k">宿主端口</span><span class="v">${WS_PORT}</span></div>
<div class="row"><span class="k">访问地址</span>
  <span class="v"><a href="$WS_URL" target="_blank" rel="noopener">$WS_URL</a></span></div>
<div class="row"><span class="k">远程客户端管理</span>
  <span class="$([ "$RA_LIVE" = "已开启" ] && echo on || echo off)">$RA_LIVE</span></div>
<div class="row"><span class="k">数据目录</span><span class="v">${DBASE}/wsdata</span></div>

<form method="post" action="ws.sh">
  <div class="sec">宿主端口</div>
  <input type="text" name="wss_port" value="$WS_PORT">

  <div class="sec">远程客户端管理</div>
  <label class="chk">
    <input type="checkbox" name="remote_admin" value="1" $RA_CHECKED>
    <span>允许远程客户端执行管理操作</span>
  </label>
  <div class="hint">对应容器环境变量 WS_SCRCPY_ALLOW_REMOTE_ADMIN=1。关闭后，从远程地址打开 ws 页面时，「设置 / 用户」里的服务器管理项会变灰（提示“远程客户端的管理操作已禁用”）。改动需重建容器才生效。</div>

  <div class="sec">域名白名单（逗号分隔，可用 * 通配）</div>
  <textarea name="wss_domains" rows="3">$(printf '%s' "$WS_DOMAINS" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g')</textarea>
  <div class="hint">默认放行 *.ug.link / *.ugdocker.link / *.ugapp.link；从 UGOS App 内嵌打开时使用的域名也要写在这里，否则会报 host not allowed。</div>

  <div class="btns">
    <button type="submit" name="action" value="wss_install">新建 / 重建容器</button>
    <button type="submit" name="action" value="wss_stop" class="ghost">停止</button>
    <button type="submit" name="action" value="wss_remove" class="danger">删除容器</button>
  </div>
</form>

<div class="foot">重建会按新端口与白名单重新起容器，/wsdata 数据保留；日志在“日志”页签查看。</div>

</body></html>
EOF
