FROM alpine:latest

# 两个内核模块随镜像提供，不依赖宿主文件系统
COPY assets/binder_linux.ko /opt/kmod/binder_linux.ko
COPY assets/rk_dma32_heap.ko /opt/kmod/rk_dma32_heap.ko

COPY entrypoint.sh /entrypoint.sh
COPY scripts /opt/bin
COPY www /www

# alpine 主 busybox 未编译 httpd applet，busybox-extras 才有 /usr/sbin/httpd
# docker-cli 用于从控制页直接 pull/部署 redroid（容器挂宿主 docker.sock）
RUN apk add --no-cache busybox-extras docker-cli \
 && chmod 0755 /entrypoint.sh /www/cgi-bin/*.sh /opt/bin/*.sh \
 && chmod 0644 /opt/kmod/*.ko /www/index.html

EXPOSE 8099
ENTRYPOINT ["/entrypoint.sh"]
