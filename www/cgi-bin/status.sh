#!/bin/sh
# busybox httpd CGI：输出模块当前状态
echo "Content-Type: text/html; charset=utf-8"
echo "Cache-Control: no-store"
echo ""

mod_state() {
    if grep -q "^$1 " /proc/modules 2>/dev/null; then
        echo "<span class='ok'>已加载</span>"
    else
        echo "<span class='bad'>未加载</span>"
    fi
}

heaps="$(ls /host-dma-heap 2>/dev/null || ls /dev/dma_heap 2>/dev/null)"
heaps="$(printf '%s' "$heaps" | tr '\n' ' ')"
[ -z "$heaps" ] && heaps="（空）"

logtail="$(tail -n 8 /data/kmod.log 2>/dev/null | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')"
[ -z "$logtail" ] && logtail="（暂无日志）"

# 真实宿主目录。容器已挂宿主 docker socket，直接问 docker 拿自己的挂载源，
# 这样得到的是完整宿主路径（/data 常是 btrfs 子卷里的 bind mount，mountinfo 的 root
# 字段只有相对部分，会丢掉 /volume1 这类上级挂载点）。
# 安装参数选了共享文件夹时数据在 /user-data，否则在固定兜底的 /data，两个都要查。
data_src=""
cid="$(cat /etc/hostname 2>/dev/null)"
if [ -n "$cid" ] && [ -S /var/run/docker.sock ]; then
    for dst in /user-data /data; do
        src="$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "'"$dst"'"}}{{.Source}}{{end}}{{end}}' "$cid" 2>/dev/null)"
        if [ -n "$src" ]; then
            data_src="$src"
            break
        fi
    done
fi
if [ -n "$data_src" ]; then
    data_hint="$(printf '日志位置 %s/kmod.log' "$data_src" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')"
elif awk '$5 == "/user-data" || $5 == "/data" { found = 1 } END { exit !found }' /proc/self/mountinfo 2>/dev/null; then
    data_hint="数据目录已挂载（宿主路径不可见）"
else
    data_hint="未选择数据目录，日志在容器内层，重启会丢失"
fi

cat <<EOF
<!DOCTYPE html>
<html lang="zh-CN"><head>
<meta charset="utf-8">
<meta http-equiv="refresh" content="5">
<style>
  body{margin:0;padding:14px 16px;background:#171b21;color:#e6e9ef;
    font:13px/1.7 -apple-system,"PingFang SC","Microsoft YaHei",sans-serif;}
  table{width:100%;border-collapse:collapse;margin-bottom:12px;}
  td{padding:7px 0;border-bottom:1px solid #232830;}
  td.k{color:#9aa3b2;width:44%;}
  .ok{color:#5bd18b;font-weight:600;}
  .bad{color:#f0616d;font-weight:600;}
  .log{background:#12161b;border-radius:8px;padding:10px 12px;color:#a9b3c1;
    font:12px/1.6 ui-monospace,Menlo,Consolas,monospace;white-space:pre-wrap;word-break:break-all;}
  .foot{color:#6f7887;font-size:11px;margin-top:8px;}
</style></head>
<body>
<table>
  <tr><td class="k">binder_linux</td><td>$(mod_state binder_linux)</td></tr>
  <tr><td class="k">rk_dma32_heap</td><td>$(mod_state rk_dma32_heap)</td></tr>
  <tr><td class="k">/dev/dma_heap</td><td>$heaps</td></tr>
</table>
<div class="log">$logtail</div>
<div class="foot">每 5 秒自动刷新 · $data_hint</div>
</body></html>
EOF
