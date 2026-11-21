#!/bin/sh
# Cloudflared Docker updater with HTTPS checks and automatic rollback.
# Copyright (c) 2026 Alejandro Romero (@aguilarbucket)
# SPDX-License-Identifier: MIT
set -eu

COMPOSE="${COMPOSE:-/opt/cloudflared/compose.yaml}"
SERVICE="${SERVICE:-cloudflared}"
CONTAINER="${CONTAINER:-cloudflared}"
IMAGE="${IMAGE:-cloudflare/cloudflared:latest}"
URL="${URL:-https://tunnel.example.com/health}"
STATE_DIR="${STATE_DIR:-/var/lib/update-cloudflared}"
LOCK_DIR="${LOCK_DIR:-/run/update-cloudflared.lock}"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-6}"
RETRY_SECONDS="${RETRY_SECONDS:-10}"

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
die() { log "ERROR: $*"; exit 1; }

case "$MAX_ATTEMPTS:$RETRY_SECONDS" in
    *[!0-9:]*|:*|*:|*:*:*) die "MAX_ATTEMPTS y RETRY_SECONDS deben ser enteros";;
esac
[ "$MAX_ATTEMPTS" -gt 0 ] || die "MAX_ATTEMPTS debe ser mayor que cero"
[ -f "$COMPOSE" ] || die "No existe Compose: $COMPOSE"

# mkdir es una operación atómica; no borres manualmente un lock sin revisar el proceso.
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    die "Otra ejecución parece estar en curso (o existe un lock huérfano): $LOCK_DIR"
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' 0
trap 'exit 130' 1 2 3 15

mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"
FAILED_IMAGE="$STATE_DIR/failed-image-id"

current_image() {
    docker inspect --format '{{.Image}}' "$CONTAINER"
}
check_https() {
    attempts="$1"
    i=1
    while [ "$i" -le "$attempts" ]; do
        log "HTTPS: intento $i/$attempts"
        # La consulta única reduce la posibilidad de respuestas cacheadas.
        status=$(curl --silent --show-error --connect-timeout 5 --max-time 12 \
            -H 'Cache-Control: no-cache' -o /dev/null -w '%{http_code}' \
            "$URL?update_probe=$(date +%s)-$i" 2>/dev/null) || status=000
        if [ "$status" = 200 ]; then
            log "HTTPS OK (HTTP 200)"
            return 0
        fi
        log "HTTPS no disponible (HTTP $status)"
        [ "$i" -eq "$attempts" ] || sleep "$RETRY_SECONDS"
        i=$((i + 1))
    done
    return 1
}

# Si la actualización falla, el rollback exitoso también termina con estado
# distinto de cero: el servicio se recuperó, pero la actualización falló.
rollback() {
    reason="$1"
    log "ALERTA: $reason — iniciando rollback"
    printf '%s\n' "$NEW_IMAGE" > "$FAILED_IMAGE"
    if ! docker tag "$OLD_IMAGE" "$IMAGE"; then
        die "Fallo crítico: no se pudo restaurar la etiqueta local $IMAGE"
    fi
    if ! docker compose -f "$COMPOSE" up -d --no-deps --pull never --force-recreate "$SERVICE"; then
        die "Fallo crítico: no se pudo recrear $SERVICE durante rollback"
    fi
    restored=$(current_image) || die "Fallo crítico: el contenedor no existe tras rollback"
    [ "$restored" = "$OLD_IMAGE" ] || die "Fallo crítico: imagen inesperada tras rollback"
    if check_https "$MAX_ATTEMPTS"; then
        log "ROLLBACK EXITOSO: servicio recuperado; actualización FALLIDA"
        exit 1
    fi
    die "Fallo crítico: HTTPS sigue sin responder después del rollback"
}

log "===== INICIO ACTUALIZACIÓN CLOUDFLARED ====="
OLD_IMAGE=$(current_image) || die "No se pudo identificar imagen actual"
log "Imagen actual: $OLD_IMAGE"

# Un servicio ya caído no se usa como referencia para validar una actualización.
check_https 3 || die "HTTPS no estaba disponible ANTES de actualizar; operación cancelada"

log "Buscando nueva imagen..."
docker compose -f "$COMPOSE" pull "$SERVICE" || die "Fallo al descargar imagen"
NEW_IMAGE=$(docker image inspect --format '{{.Id}}' "$IMAGE") || die "No se encontró $IMAGE"

if [ "$OLD_IMAGE" = "$NEW_IMAGE" ]; then
    log "Sin cambios; contenedor ya utiliza la imagen disponible"
    exit 0
fi

if [ -f "$FAILED_IMAGE" ] && [ "$(cat "$FAILED_IMAGE")" = "$NEW_IMAGE" ]; then
    # Evita dejar latest apuntando a una imagen previamente rechazada.
    docker tag "$OLD_IMAGE" "$IMAGE" || die "No se pudo restaurar etiqueta de versión vigente"
    log "Imagen previamente fallida ($NEW_IMAGE): no se reinstala"
    exit 0
fi

log "Actualizando de $OLD_IMAGE a $NEW_IMAGE"
if ! docker compose -f "$COMPOSE" up -d --no-deps --pull never "$SERVICE"; then
    rollback "Docker Compose falló"
fi

running=$(current_image) || rollback "No se pudo inspeccionar el contenedor actualizado"
[ "$running" = "$NEW_IMAGE" ] || rollback "La imagen activa no coincide con la nueva"
sleep 10

if check_https "$MAX_ATTEMPTS"; then
    rm -f "$FAILED_IMAGE"
    log "ACTUALIZACIÓN EXITOSA (imagen: $NEW_IMAGE)"
    docker exec "$CONTAINER" cloudflared version || log "Advertencia: no se pudo leer la versión"
    exit 0
fi

rollback "HTTPS falló tras la actualización"
