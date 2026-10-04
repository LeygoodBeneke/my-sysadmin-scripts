#!/usr/bin/env bash
# Поднимает стенд ДЗ2 с нуля на Ubuntu 22.04: Docker-контейнер, RAID 1 и LVM на loop-устройствах,
# Nginx reverse proxy с self-signed TLS и systemd-службу. Повторный запуск безопасен.
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    exec sudo "$0" "$@"
fi

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
APP=my-app
IMAGE=my-script
LAB_DIR=/mnt/raid-lab

log() { echo -e "\n==> $*"; }

attach_loop() {
    local dev
    dev=$(losetup -j "$1" | cut -d: -f1 | head -n1)
    [[ -n "$dev" ]] || dev=$(losetup --show -fP "$1")
    echo "$dev"
}

log "Пакеты"
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q docker.io docker-compose-v2 mdadm lvm2 nginx openssl curl
systemctl enable --now docker
usermod -aG docker "${SUDO_USER:-ubuntu}"

log "Образ $IMAGE"
docker build -t "$IMAGE" "$REPO_DIR"

log "Контейнер $APP на :8080"
systemctl stop "$APP" 2>/dev/null || true
docker rm -f "$APP" >/dev/null 2>&1 || true
docker run -d -p 8080:8080 --name "$APP" "$IMAGE"

log "Loop-устройства"
mkdir -p "$LAB_DIR"
for i in 1 2 3; do
    [[ -f "$LAB_DIR/disk$i.img" ]] || dd if=/dev/zero of="$LAB_DIR/disk$i.img" bs=1M count=512 status=none
done
LOOP1=$(attach_loop "$LAB_DIR/disk1.img")
LOOP2=$(attach_loop "$LAB_DIR/disk2.img")
LOOP3=$(attach_loop "$LAB_DIR/disk3.img")
losetup -a

log "RAID 1 на $LOOP1 + $LOOP2"
# udev может сам собрать массив под другим именем (md127), поэтому ищем его через lsblk, а не по имени
MD=$(lsblk -nro NAME,TYPE "$LOOP1" | awk '$2 == "raid1" { print "/dev/" $1; exit }')
if [[ -z "$MD" ]]; then
    MD=/dev/md0
    if mdadm --examine "$LOOP1" >/dev/null 2>&1; then
        mdadm --assemble "$MD" "$LOOP1" "$LOOP2"
    else
        mdadm --create "$MD" --level=1 --raid-devices=2 --run "$LOOP1" "$LOOP2"
        mkfs.ext4 -q "$MD"
    fi
fi
mkdir -p /mnt/raid
mountpoint -q /mnt/raid || mount "$MD" /mnt/raid
cat /proc/mdstat

log "LVM на $LOOP3"
if ! vgs vg_data >/dev/null 2>&1; then
    pvcreate -y "$LOOP3"
    vgcreate vg_data "$LOOP3"
fi
if ! lvs vg_data/lv_logs >/dev/null 2>&1; then
    lvcreate -y -L 200M -n lv_logs vg_data
    mkfs.ext4 -q /dev/vg_data/lv_logs
fi
vgchange -ay vg_data >/dev/null
mkdir -p /mnt/logs
mountpoint -q /mnt/logs || mount /dev/vg_data/lv_logs /mnt/logs
lvs
df -h /mnt/raid /mnt/logs

log "TLS-сертификат"
if [[ ! -f /etc/ssl/certs/my-app.crt ]]; then
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout /etc/ssl/private/my-app.key \
        -out /etc/ssl/certs/my-app.crt \
        -subj "/CN=my-app.local"
fi

log "Nginx"
install -m 644 "$REPO_DIR/deploy/nginx-my-app.conf" /etc/nginx/sites-available/my-app
ln -sf /etc/nginx/sites-available/my-app /etc/nginx/sites-enabled/my-app
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl enable nginx
systemctl reload-or-restart nginx

log "systemd-служба $APP"
install -m 644 "$REPO_DIR/deploy/my-app.service" /etc/systemd/system/my-app.service
systemctl daemon-reload
systemctl enable --now "$APP"

log "Проверка"
sleep 3
curl -fsS http://127.0.0.1:8080/monitor.log | head -n 5
curl -kIsS https://127.0.0.1 | head -n 1
systemctl is-active "$APP"
systemctl is-enabled "$APP"
