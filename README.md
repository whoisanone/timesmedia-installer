# TimesMedia Installer 8.1.5

Instalador y CLI de mantenimiento para los repositorios privados de TimesMedia.

## Uso

Instalación directa del NODE con un único comando:

```bash
curl -fsSL https://raw.githubusercontent.com/whoisanone/timesmedia-installer/main/bootstrap.sh | sudo bash -s -- node
```

Limpieza independiente de MediaVPS NODE y TimesMedia NODE:

```bash
curl -fsSL https://raw.githubusercontent.com/whoisanone/timesmedia-installer/main/purge-node.sh | sudo bash -s -- --yes
```

La limpieza elimina solamente servicios, procesos, código, configuración, estado, multimedia, usuario y reglas de firewall del NODE. Conserva MediaVPS/TimesMedia WEB y otros proyectos.

Limpieza independiente de MediaVPS WEB y TimesMedia WEB:

```bash
curl -fsSL https://raw.githubusercontent.com/whoisanone/timesmedia-installer/main/purge-web.sh | sudo bash -s -- --yes
```

Esta limpieza conserva `cloudflared`, SSH, el NODE y los demás proyectos. También se niega a declarar éxito si algún proceso antiguo continúa escuchando en el puerto 5000.

Instalación completamente limpia del panel WEB, sin migrar DB, portadas, configuración ni secretos de MediaVPS:

```bash
curl -fsSL https://raw.githubusercontent.com/whoisanone/timesmedia-installer/main/bootstrap.sh | sudo bash -s -- web --fresh
```

El instalador valida primero que el repositorio WEB privado esté completo; después borra exclusivamente el WEB anterior y crea una base de datos, secreto y administrador nuevos.

Reinstalación completamente limpia del NODE, sin migrar MediaVPS ni conservar su multimedia:

```bash
curl -fsSL https://raw.githubusercontent.com/whoisanone/timesmedia-installer/main/bootstrap.sh | sudo env TM_WEB_IP=IP_DEL_CONTROLADOR bash -s -- node --fresh
```

El modo `node --fresh` obtiene y valida primero el repositorio privado; después detiene y elimina exclusivamente los servicios, código, estado, configuración y multimedia del NODE anterior. No modifica TimesMedia WEB ni otros proyectos del servidor.

Los venv de WEB y NODE, y todas sus comprobaciones, se ejecutan desde sus rutas finales bajo `/opt`; no dependen del directorio temporal privado usado por `bootstrap.sh`.

También puede ejecutarse desde un checkout o ZIP:

```bash
sudo ./install-timesmedia.sh
```

El menú instala WEB, NODE o ambos. Los repos `timesmedia-web` y `timesmedia-node` permanecen privados: el instalador intenta primero una clave SSH/deploy key ya configurada y, si no existe, solicita un Fine-grained GitHub token con **Contents: Read-only**. El token se guarda únicamente en un directorio temporal privado `0700`, dentro de un archivo `0600`; se usa a través de `GIT_ASKPASS` y se elimina al terminar. No se inserta en la URL de Git ni en la línea de comandos.

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

`bootstrap.sh` reconecta la terminal incluso al ejecutarse mediante `curl | bash`. Usa primero una deploy key SSH y, si no existe, solicita el token por entrada oculta sin guardarlo permanentemente.
