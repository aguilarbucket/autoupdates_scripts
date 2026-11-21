# Cloudflare Tunnel (`cloudflared`) — actualizaciones automáticas con rollback

**Autor:** Alejandro Romero ([@aguilarbucket](https://github.com/aguilarbucket)) · **Licencia:** [MIT](../LICENSE)

Actualizador en **POSIX sh** para el conector `cloudflared` desplegado con **Docker Compose**. Comprueba la disponibilidad HTTPS, actualiza la imagen del conector y ejecuta rollback si falla la comprobación posterior. No requiere Watchtower ni contenedores auxiliares.

> **Alcance:** este proyecto gestiona **exclusivamente el conector `cloudflared`**. No actualiza ni configura servidores web, proxies inversos, aplicaciones, reglas de Cloudflare o el origen del túnel.

> **Privacidad de ejemplos:** todos los dominios `example.com`, nombres de host, rutas de despliegue y direcciones del segmento `10.0.0.0/8` de esta documentación son **ficticios e ilustrativos**. No representan infraestructura real.

## Arquitectura genérica

```text
                  Clientes de Internet
                           |
                           | HTTPS
                           v
                    Cloudflare Edge
                           |
                           | Cloudflare Tunnel
                           | conexión saliente cifrada
                           v
               +-------------------------+
               | cloudflared             | <---- Script actualizador
               | Docker Compose          |       - pull de imagen
               +-------------------------+       - recreación del conector
                           |                     - validación HTTPS
                           |                     - rollback
                           v
                   Origen configurado
                           |
                +----------+----------+
                |                     |
                v                     v
         Aplicación directa    Proxy inverso opcional
                                (Caddy / Nginx /
                                 Apache / otros)
                                      |
                                      v
                                Aplicación(es)
```

**La arquitectura del origen es irrelevante para el actualizador.** `cloudflared` puede comunicar con una aplicación directamente o con un proxy inverso. El origen también puede encontrarse en otra red o equipo, siempre que sea accesible para el conector según la configuración del túnel. El script **no necesita identificar** ese software ni modificarlo.

### Ejemplo didáctico de direccionamiento (no es un despliegue real)

| Elemento | Valor de ejemplo | Función |
| --- | --- | --- |
| Red privada ilustrativa | `10.10.10.0/24` | Segmento RFC 1918 usado únicamente en el diagrama lógico |
| Origen ilustrativo | `10.10.10.20:8080` | Aplicación o proxy al que podría apuntar el túnel |
| URL pública de comprobación | `https://tunnel.example.com/health` | Endpoint HTTPS de salud esperado: HTTP 200 |

El direccionamiento es **opcional** y no forma parte de la lógica del script: el destino efectivo lo determina la configuración de Cloudflare Tunnel, que queda fuera del alcance de este proyecto. El ejemplo `10.10.10.20` no es la dirección del conector ni un valor que haya que introducir en el actualizador.

### Separación de responsabilidades

- **Actualizador:** obtiene la imagen nueva de `cloudflared`, compara IDs, recrea el servicio elegido y verifica el endpoint público.
- **Cloudflare Tunnel:** establece y mantiene el enlace cifrado hacia Cloudflare Edge y enruta las solicitudes según su configuración.
- **Proxy inverso o aplicación:** atiende las solicitudes del origen. Puede ser Caddy, Nginx, Apache, Traefik, HAProxy, una aplicación directa u otra solución compatible.

El comando de recreación usa `docker compose up -d --no-deps --pull never`, por lo que **no recrea deliberadamente los servicios dependientes**. El script no crea ni administra el origen.

**Cifrado:** Cloudflare cifra la conexión con el conector. El protocolo entre `cloudflared` y el origen (por ejemplo, HTTP o HTTPS) depende de la configuración del túnel; no se puede inferir de la conexión pública HTTPS ni del modo SSL/TLS del dashboard.

## Funcionamiento

1. Inspecciona la imagen del contenedor `cloudflared` actualmente desplegado.
2. Comprueba la `URL` pública: debe responder **HTTP 200** (hasta tres intentos antes de actualizar).
3. Descarga la imagen declarada en Docker Compose.
4. Compara el ID de la imagen descargada con el ID del contenedor en ejecución. **Si son iguales, no recrea nada.**
5. Si existe una imagen nueva y no está marcada como fallida, recrea **únicamente** el servicio `cloudflared`.
6. Espera diez segundos y comprueba HTTPS (seis intentos predeterminados, con intervalos de diez segundos).
7. Si la validación falla, reetiqueta la imagen anterior por ID y fuerza la recreación para recuperarla.
8. Comprueba la recuperación, registra el ID rechazado para evitar reinstalar la misma imagen y libera el bloqueo de ejecución.

Un **rollback exitoso devuelve código 1**: se recuperó la disponibilidad, pero la actualización falló. El código `0` también puede significar que se omitió una versión previamente rechazada; consulta los logs para distinguir cada escenario.

## Requisitos

- Docker Engine y plugin **Docker Compose** (`docker compose`).
- Servicio `cloudflared` ya desplegado mediante un archivo Compose con imagen etiquetada (por ejemplo, `cloudflare/cloudflared:latest`).
- `/bin/sh` POSIX, `curl` y utilidades estándar usadas por el script.
- Permisos para Docker, directorio de estado y directorio de bloqueo.
- URL pública HTTPS sin autenticación ni redirección, que responda **HTTP 200** y admita el parámetro de consulta `update_probe`.
- Imagen anterior conservada localmente en Docker para poder restaurarla. **No ejecutar `docker image prune` concurrentemente.**

El script fue desarrollado en un entorno Alpine Linux con OpenRC/crond. **Alpine, OpenRC y la elección del servidor web no son dependencias arquitectónicas.** Puede invocarse con un programador de tareas adecuado al sistema.

## Variables de configuración

Configura las variables de entorno para **tu propio despliegue**. Los valores siguientes son **ejemplos**, no una transcripción de la configuración de ningún servidor ni necesariamente los valores por defecto incluidos en el script.

| Variable | Significado | Ejemplo ficticio |
| --- | --- | --- |
| `COMPOSE` | Ruta del archivo Compose que define el servicio | `/opt/cloudflared/compose.yaml` |
| `SERVICE` | Nombre del servicio Compose | `cloudflared` |
| `CONTAINER` | Nombre real del contenedor en Docker | `cloudflared` |
| `IMAGE` | Referencia de imagen usada por Compose | `cloudflare/cloudflared:latest` |
| `URL` | Endpoint público de comprobación | `https://tunnel.example.com/health` |
| `STATE_DIR` | Directorio de estado local | `/var/lib/update-cloudflared` |
| `LOCK_DIR` | Directorio de bloqueo | `/run/update-cloudflared.lock` |
| `MAX_ATTEMPTS` | Intentos de verificación después del cambio | `6` |
| `RETRY_SECONDS` | Intervalo entre intentos en segundos | `10` |

**Atención:** declara explícitamente `COMPOSE`, `CONTAINER` y `URL` (y cualquier otra variable diferente a tu despliegue), porque el script trae valores predeterminados orientados a su entorno de desarrollo. `IMAGE` debe coincidir con la referencia que aparece en el Compose: cambiar solo la variable de entorno no modifica la imagen declarada en el YAML.

El script construye cada comprobación agregando `?update_probe=...` a `URL`; por ello, usa una URL **sin parámetros de consulta previos**. La ruta debe admitirlos y devolver HTTP 200 en condiciones normales.

## Instalación

Descarga el script de este mismo directorio y revísalo antes de instalarlo:

```sh
install -m 700 update-cloudflared.sh /usr/local/sbin/update-cloudflared
sh -n /usr/local/sbin/update-cloudflared
```

Identifica el nombre real de tu contenedor:

```sh
docker compose -f /opt/cloudflared/compose.yaml ps
```

Comprueba primero el endpoint:

```sh
curl -sS -o /dev/null -w 'HTTP %{http_code}\n' \
  https://tunnel.example.com/health
```

Ejemplo de primera ejecución (reemplaza todos los datos ficticios por valores propios):

```sh
COMPOSE=/opt/cloudflared/compose.yaml \
SERVICE=cloudflared \
CONTAINER=cloudflared \
IMAGE=cloudflare/cloudflared:latest \
URL=https://tunnel.example.com/health \
/usr/local/sbin/update-cloudflared
```

El script inspecciona el contenedor ya existente: no sirve para crear un túnel nuevo desde cero.

### Programación con cron (ejemplo)

En Alpine/OpenRC, si `crond` todavía no está habilitado:

```sh
rc-service crond start
rc-update add crond default
crontab -e
```

Ejemplo para las **04:15**, hora local del host:

```cron
15 4 * * * COMPOSE=/opt/cloudflared/compose.yaml SERVICE=cloudflared CONTAINER=cloudflared IMAGE=cloudflare/cloudflared:latest URL=https://tunnel.example.com/health /usr/local/sbin/update-cloudflared >> /var/log/update-cloudflared.log 2>&1
```

Si usas otro sistema operativo, invoca el mismo comando con su programador equivalente. No programes múltiples actualizadores concurrentes sobre el mismo servicio.

### Verificación

```sh
docker exec cloudflared cloudflared version
docker inspect cloudflared --format '{{.Image}} {{.State.Status}}'
curl -sS -o /dev/null -w 'HTTP %{http_code}\n' \
  https://tunnel.example.com/health
tail -n 100 /var/log/update-cloudflared.log
```

Estos comandos son **ilustrativos**: ajusta sus identificadores a tu propio entorno.

## Rollback y validación

El actualizador conserva el ID de la imagen previa y, si falla la comprobación posterior, intenta restaurarla con `docker tag` y `docker compose up -d --no-deps --pull never --force-recreate`. Guarda el ID de una imagen rechazada en `STATE_DIR/failed-image-id` para evitar redesplegarla automáticamente.

### Evidencia funcional (sin datos del entorno)

Durante el desarrollo se realizó una prueba controlada en la que el **algoritmo previo** de recuperación restauró la imagen anterior y la URL volvió a responder HTTP 200 después de un fallo HTTPS simulado.

El script publicado incluye cambios posteriores a ese ensayo. **La versión publicada no queda validada por esa prueba histórica** y requiere una prueba controlada antes de su adopción en producción. No se publican topologías, identificadores, direcciones ni detalles operativos del entorno de prueba.

### Recuperación manual (ejemplo)

Si la recuperación automática falla, verifica logs e imágenes locales. Una vez identificado correctamente el ID de imagen anterior:

```sh
# Sustituir por el ID REAL de la imagen previa, todavía presente en Docker.
OLD_IMAGE=sha256:ID_DE_EJEMPLO
docker tag "$OLD_IMAGE" cloudflare/cloudflared:latest
docker compose -f /opt/cloudflared/compose.yaml \
  up -d --no-deps --pull never --force-recreate cloudflared
```

**No ejecutes el ejemplo literalmente**: comprueba el ID y adapta el Compose, servicio e imagen a tu configuración. Después verifica la versión desplegada y el endpoint público.

## Límites y precauciones

- Un HTTP 200 de la URL pública **no prueba por sí mismo** que contestó el conector recién desplegado si existen varios conectores, cachés, balanceo o rutas alternativas.
- El endpoint elegido puede fallar por problemas del origen no relacionados con `cloudflared`, lo que podría provocar un rollback innecesario.
- El rollback depende de que Docker pueda recrear el contenedor y de que la imagen anterior siga almacenada localmente.
- El bloqueo por directorio puede quedar huérfano tras un apagado brusco; comprueba que no hay otra ejecución antes de retirarlo.
- El etiquetado local puede entrar en conflicto con otros procesos que actualicen la misma imagen; no ejecutes automatizadores concurrentes.
- Una etiqueta mutable como `latest` permite cambios sin revisión previa y puede provocar breves interrupciones de servicio.
- Los tokens de Cloudflare Tunnel son secretos: no los publiques ni los incorpores a repositorios o ejemplos.
- Este proyecto proporciona una rutina de actualización y recuperación, **no alta disponibilidad ni una auditoría TLS de extremo a extremo**.

## Apoya el proyecto

☕ **¿Te gustó el proyecto y quieres invitarme un café en la Web3?** 😎

- 💚 **ENS** `vibe.basempc.eth`
- 💚 **Dirección** `0x9455B16A0A30E7198d37EC723911B93Ff1D4075b`

¡Gracias por apoyar el desarrollo open source! 🚀

## Atribución

**Autor y mantenedor:** Alejandro Romero — [@aguilarbucket](https://github.com/aguilarbucket).

El código está bajo **MIT**, que permite reutilizarlo, modificarlo y distribuirlo mientras se conserve el aviso de copyright y la licencia. Agradecemos una mención adicional al proyecto original, aunque no es una obligación más allá de los requisitos de MIT.
