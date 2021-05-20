# Virtual host proxy Docker image for Docksal

Automated HTTP/HTTPS virtual host proxy and container supervisor for Docksal.

This image(s) is part of the [Docksal](http://docksal.io) image library.

## Features

- HTTP/HTTPS and HTTP/2 virtual host routing
- On-demand stack starting (upon a HTTP/HTTPS request)
- Stack stopping after a given period of inactivity
- Stack cleanup after a given period of inactivity

## Usage

Start the proxy container:

```bash
docker run -d --name docksal-vhost-proxy --label "io.docksal.group=system" --restart=always --privileged --userns=host \
    -p "${DOCKSAL_VHOST_PROXY_PORT_HTTP:-80}":80 -p "${DOCKSAL_VHOST_PROXY_PORT_HTTPS:-443}":443 \
    -v /var/run/docker.sock:/var/run/docker.sock \
    docksal/vhost-proxy
```

## Container configuration 

Required labels for this VHost Proxy are `io.docksal.project-root` and `io.docksal.virtual-host`.

Proxy reads routing settings from container labels. The following labels are supported:

`io.docksal.project-root`

Project root. Supports CI/CD scenarios with the cleanup job (see [Advanced proxy configuration below](#advanced-proxy-configuration)) and project root volumes can be automatically un-mounted when not set to permanent.

`io.docksal.virtual-host`

Virtual host mapping. Supports any domain (but does not handle DNS), multiple values separated by commas, wildcard 
sub-domains.

Example: `io.docksal.virtual-host=example1.com,*.example2.com`


`io.docksal.virtual-port`

Virtual port mapping. Useful when a container exposes an non-default HTTP port (other than port `80`).
Only supports HTTP, single value.  

Example: `io.docksal.virtual-port=3000`

### Example

Launching a nodejs app container using port `3000` and host `myapp.example.com`

docker command
```bash
docker run -d --name=myapp_nodejs \
	-v $(pwd):/app \
	--label=com.docker.compose.project=myapp
	--label=io.docksal.project-root=$(pwd) \
	--label=io.docksal.virtual-host=myapp.example.com \
	--label=io.docksal.virtual-port=3000 \
	--network=myapp_default \
	--expose 3000 \
	node:alpine \
	node /app/index.js
``` 

docker compose `myapp/docker-compose.yml`
```yaml
---

version: "3"
networks:
	docksal_network:
		external:
			name: myapp_default

services:
	web:
		command: "node /app/index.js"
		image: node:alpine
		volumes:
			- "./:/app"
		labels:
			- "io.docksal.project-root=${PWD}"
			- "io.docksal.virtual-host=myapp.example.com"
			- "io.docksal.virtual-port=3000"
		networks:
			- docksal_network
```

## Advanced proxy configuration

These advanced settings can be used in CI sandbox environments and help keep the resource usage down by stopping 
Docksal project containers after a period of inactivity. Projects are automatically restarted upon a new HTTP request (unless `PROJECT_AUTOSTART` is set to `0`, see below.).

`PROJECT_INACTIVITY_TIMEOUT`

Defines the timeout (e.g. 0.5h) of inactivity after which the project stack will be stopped.  
This option is inactive by default (set to `0`).

`PROJECT_DANGLING_TIMEOUT`

**WARNING: This is a destructive option. Use at your own risk!**

Defines the timeout (e.g. 168h) of inactivity after which the project stack and code base will be entirely wiped out from the host.  
This option is inactive by default (set to `0`).

For the cleanup job to work, proxy needs access to the projects directory on the host.  
Create a Docker bind volume pointing to the directory where projects are stored:

```
docker volume create --name docksal_projects --opt type=none --opt device=$PROJECTS_ROOT --opt o=bind

```

then pass it using `-v docksal_projects:/projects` in `docker run` command.

Example (extra configuration in the middle): 

```bash
docker run -d --name docksal-vhost-proxy --label "io.docksal.group=system" --restart=always --privileged --userns=host \
    -p "${DOCKSAL_VHOST_PROXY_PORT_HTTP:-80}":80 -p "${DOCKSAL_VHOST_PROXY_PORT_HTTPS:-443}":443 \
    -e PROJECT_INACTIVITY_TIMEOUT="${PROJECT_INACTIVITY_TIMEOUT:-0}" \

    -e PROJECT_INACTIVITY_TIMEOUT="${PROJECT_INACTIVITY_TIMEOUT:-0}" \
    -e PROJECT_DANGLING_TIMEOUT="${PROJECT_DANGLING_TIMEOUT:-0}" \
    -v docksal_projects:/projects \
    
    -v /var/run/docker.sock:/var/run/docker.sock \
    docksal/vhost-proxy
```

`io.docksal.permanent=true`

It is possible to protect certain projects/containers from being automatically removed after `PROJECT_DANGLING_TIMEOUT`.

Projects/containers with the `io.docksal.permanent=true` label are considered permanent are skipped during the cleanup.
When running the default Docksal stack, this label can be set with `SANDBOX_PERMANENT=true` in `docksal.env` (or an 
environment specific equivalent, e.g. `docksal-ci.env`).

Note: permanent projects will still be put into hibernation according to `PROJECT_INACTIVITY_TIMEOUT`.

`PROJECT_AUTOSTART`

Setting this variable to `0` will disable autostart projects by visiting project url. This option is active by default (set to `1`).

## Default and custom certs for HTTPS

The default server cert is a self-signed cert for `*.docksal`. It allows a HTTPS connection to be established, but will 
make browsers complain that the cert is not valid. If that's not acceptable, you can use a valid custom cert. 

To use custom certs, mount a folder with certs to `/etc/certs/custom`. Certs are looked up by virtual host name. 

E.g., cert and key for `example.com` (or `*.example.com`) are expected in: 

```
/etc/certs/custom/example.com.crt
/etc/certs/custom/example.com.key
```

Shared certs (SNI) are also supported. Use `io.docksal.cert-name` label to set the cert name for a container.

Example: for `io.docksal.cert-name=shared` the following cert/key will be used:

```
/etc/certs/custom/shared.crt
/etc/certs/custom/shared.key
```

When multiple domain values are set in `io.docksal.virtual-host`, the first one is considered the primary one and 
used for certificate lookup. You can also always point to a specific cert with `io.docksal.cert-name`. 

When projects are (re)started over HTTPS, the default virtual host config kicks in first. It uses the default self-signed 
cert, which would trigger a browser warning, even though the actual virtual host is then served using a valid custom 
cert. To overcome this issue, you can specify the default custom cert name using the `DEFAULT_CERT` environment variable. 

You can use a single domain or a shared (SNI) cert, just like with other custom certs.

Example: `DEFAULT_CERT=example.com` or `DEFAULT_CERT=shared`  


## Logging and debugging

The following container environment variables can be used to enabled various logging options (disabled by default). 

`ACCESS_LOG` - Set to `1` to enable access logging.
`DEBUG_LOG` - Set to `1` to enable debug logging.
`STATS_LOG` - Set to `1` to enable project stats logging.

Check logs with `docker logs docksal-vhost-proxy`.


## Variable mapping for Docksal

When using this image with Docksal (99% of cases), settings for `vhost-proxy` are set via `$HOME/.docksal/docksal.env`. 

The following variable mappings should be applied:

| Configuration variable        | Variable in `$HOME/.docksal/docksal.env`  |
| ----------------------------- | ----------------------------------------  |
| `ACCESS_LOG`                  | `DOCKSAL_VHOST_PROXY_ACCESS_LOG`          |
| `DEBUG_LOG`                   | `DOCKSAL_VHOST_PROXY_DEBUG_LOG`           |
| `STATS_LOG`                   | `DOCKSAL_VHOST_PROXY_STATS_LOG`           |
| `PROJECT_INACTIVITY_TIMEOUT`  | `PROJECT_INACTIVITY_TIMEOUT`              |
| `PROJECT_DANGLING_TIMEOUT`    | `PROJECT_DANGLING_TIMEOUT`                |
| `DEFAULT_CERT`                | `DOCKSAL_VHOST_PROXY_DEFAULT_CERT`        |
