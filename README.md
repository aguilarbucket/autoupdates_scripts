# Auto-updates Scripts

Scripts de actualización para servicios autohospedados, con foco en operaciones previsibles, comprobaciones y recuperación.

## Proyectos

### [Cloudflared — Docker Compose con rollback automático](cloudflared/README.md)

Actualiza el conector de Cloudflare Tunnel, valida el servicio HTTPS, reintenta durante la reconexión y revierte a la imagen anterior si la nueva versión falla.

El proyecto nació de una implementación real sobre Alpine Linux + OpenRC + Docker Compose, con un rollback controlado probado el **20 de noviembre de 2026**.

> **Advertencia:** automatizar despliegues de imágenes `latest` implica aceptar cambios no revisados y posibles interrupciones breves. El chequeo HTTPS demuestra disponibilidad del dominio, pero no atribuye inequívocamente la respuesta al conector actualizado cuando existen varios conectores.

## Autor y atribución

**Alejandro Romero — [@aguilarbucket](https://github.com/aguilarbucket)**

Si este proyecto te sirve, agradeceremos que menciones o enlaces el repositorio original. La atribución legal mínima está descrita en la [licencia MIT](LICENSE).

## Apoya el proyecto

☕ **¿Te gustó el proyecto y quieres invitarme un café en la Web3?** 😎

- 💚 **ENS** `vibe.basempc.eth`
- 💚 **Dirección** `0x9455B16A0A30E7198d37EC723911B93Ff1D4075b`

¡Gracias por apoyar el desarrollo open source! 🚀

## Licencia

[MIT](LICENSE) © 2026 Alejandro Romero.
