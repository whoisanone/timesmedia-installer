# TimesMedia Installer 8.1.0

Instalador y CLI de mantenimiento para los repositorios privados de TimesMedia.

## Uso

Desde este repositorio o desde el ZIP de instalación:

```bash
sudo ./install-timesmedia.sh
```

El menú instala WEB, NODE o ambos. Los repos `timesmedia-web` y `timesmedia-node` permanecen privados: el instalador intenta primero una clave SSH/deploy key ya configurada y, si no existe, solicita un Fine-grained GitHub token con **Contents: Read-only**. El token se guarda únicamente en un archivo temporal `0600` bajo `/run`, se usa a través de `GIT_ASKPASS` y se elimina al terminar; no se inserta en la URL de Git ni en la línea de comandos.

## Layout

WEB: código `/opt/timesmedia-web`, estado `/var/lib/timesmedia-web`, secretos `/etc/timesmedia/web.env`.

NODE: código `/opt/timesmedia-node`, estado `/var/lib/timesmedia-node`, media `/srv/timesmedia/media`, secretos `/etc/timesmedia/node.env`.

## CLI

```text
timesmedia status
timesmedia logs [web|scheduler|node|worker|all]
timesmedia health
timesmedia security-check
timesmedia update [web|node|all]
timesmedia repair [web|node|all]
timesmedia backup [--with-media]
timesmedia restore /ruta/backup.tar.gz
timesmedia node-token
timesmedia uninstall [--purge-data]
```

`uninstall` conserva los datos salvo que se pase explícitamente `--purge-data` y se confirme de nuevo.

El instalador no ejecuta `ufw reset` ni habilita un firewall inactivo a ciegas. En NODE elimina la regla global común de 5100, añade la regla limitada a la IP WEB y conserva el puerto BitTorrent TCP/UDP. Además instala una política de red de systemd para que la API acepte tráfico solamente desde loopback y la IP del controlador incluso si UFW queda inactivo.

`bootstrap.sh` permite arrancar desde una copia local mínima: usa primero una deploy key SSH y, si no existe, solicita el token por entrada oculta. Como `timesmedia-installer` es privado, un `curl` anónimo desde GitHub no puede ser el primer paso sin publicar un bootstrap separado; el repositorio no debilita esa privacidad para conseguir una URL bonita.
