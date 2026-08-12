# Seguridad del instalador

- No almacena PAT de GitHub en repositorios, archivos de configuración permanentes ni URLs de clone.
- Prefiere deploy key SSH; el fallback de PAT usa `GIT_ASKPASS` con archivo temporal `0600` en `/run` y cleanup por trap.
- Los secretos de aplicación se crean fuera de Git y con modo `0600`.
- La contraseña inicial del admin se pide sin eco y no se guarda en el environment file.
- El token NODE se genera con `openssl rand -hex 32`.
- Los upgrades construyen código/venv en staging antes del swap.
- El layout separa código de estado para que actualizar `/opt` no borre biblioteca/DB.
- El corte desde MediaVPS intenta rollback si el servicio nuevo o su health check fallan.
- El firewall nunca se resetea globalmente.

Usa un Fine-grained GitHub token limitado a los repos TimesMedia y con Contents: Read-only. Para servidores permanentes es preferible una deploy key de solo lectura por repositorio.
