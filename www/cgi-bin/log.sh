#!/bin/sh
# 供面板轮询的纯文本日志端点：log.sh?which=redroid|ws
# 追加 action=clear 并用 POST 提交时，直接清空对应日志文件
set -u
DATA_DIR="${DATA_DIR:-/data}"
qs="${QUERY_STRING:-}"

case "$qs" in
    *redroid*) f="$DATA_DIR/redroid.log" ;;
    *ws*) f="$DATA_DIR/wsscrcpy.log" ;;
    *) f="" ;;
esac

echo "Content-Type: text/plain; charset=utf-8"
echo "Cache-Control: no-store"
echo ""

case "$qs" in
    *action=clear*)
        if [ -z "$f" ]; then
            echo "（未识别日志类型）"
        elif [ -e "$f" ]; then
            if : >"$f" 2>/dev/null; then
                echo "（已清空 $(basename "$f")）"
            else
                echo "（清空失败，文件被占用或权限不足）"
            fi
        else
            echo "（暂无日志文件）"
        fi
        exit 0
        ;;
esac

if [ -n "$f" ] && [ -f "$f" ]; then
    tail -n 40 "$f" 2>/dev/null || echo "（暂无记录）"
else
    echo "（暂无记录）"
fi
