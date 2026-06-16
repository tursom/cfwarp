# cfwarp

这是一个第三方 Docker 镜像项目，用来封装 Cloudflare One 官方 Linux WARP 客户端。镜像通过运行 `warp-svc` 和 `warp-cli connector new <TOKEN>`，以无头 Mesh 节点的形式加入 Cloudflare Mesh 网络。

本项目不实现 WARP 协议，也不实现非官方 WireGuard 客户端。镜像只从 `https://pkg.cloudflareclient.com/` 安装并运行 Cloudflare 官方 `cloudflare-warp` 软件包。

## 运行要求

- 支持 Docker Compose 的 Docker 环境。
- Linux 宿主机存在 `/dev/net/tun`。
- 允许 `cfwarp` 容器使用 `NET_ADMIN` 和 `/dev/net/tun`。
- 允许 `cfwarp-route-manager` sidecar 使用宿主机网络和 `NET_ADMIN`，用于维护宿主机到 WARP 容器的路由。
- 已启用 Cloudflare Mesh 的 Cloudflare Zero Trust 账号。
- 已在 Cloudflare Dashboard 中创建 Mesh connector token。

## Cloudflare 侧准备

先在 Cloudflare Dashboard 中创建 Mesh node，然后复制它的 connector token。容器只消费这个 token，不会创建 Mesh node、route 或其他 Cloudflare API 资源。

如果要使用子网路由，需要在 Cloudflare Mesh 中配置目标 CIDR route。默认部署会把 WARP 客户端隔离在 Docker bridge 网络里，WARP 创建的防火墙和策略路由只影响 `cfwarp` 容器，不接管宿主机网络。

Cloudflare 官方参考文档：

- https://developers.cloudflare.com/cloudflare-one/team-and-resources/devices/cloudflare-one-client/download/
- https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-mesh/
- https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-mesh/get-started/
- https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-mesh/routes/

## 配置

从示例文件创建 `.env`。Docker Compose 会在该文件存在时自动读取：

```sh
cp .env.example .env
```

填写 Mesh connector token：

```sh
CFWARP_CONNECTOR_TOKEN=your-cloudflare-mesh-connector-token
```

可选配置：

- `CFWARP_ENABLE_FORWARDING`：默认 `true`，自动启用 `cfwarp` 容器网络命名空间里的 IPv4 forwarding。
- `CFWARP_ENABLE_IPV6_FORWARDING`：默认 `false`。如果需要实验性 IPv6 Mesh 路由，可改为 `true`，但 Docker bridge 环境不一定允许容器修改 IPv6 forwarding。
- `CFWARP_WARP_MODE`：默认留空，不覆盖 Cloudflare Zero Trust 策略下发的模式。仅当策略允许本地切换模式时才设置该值。
- `CFWARP_HEALTHCHECK_INTERVAL`：默认 `30s`，用于状态检查循环和日志输出节流。
- `CFWARP_BRIDGE_NAME`：默认 `cfwarp0`，`cfwarp` 专用 Docker bridge 在宿主机上的网卡名。
- `CFWARP_BRIDGE_SUBNET`：默认 `172.30.0.0/24`，`cfwarp` 专用 Docker bridge 网段。
- `CFWARP_CONTAINER_IPV4`：默认 `172.30.0.2`，`cfwarp` 容器固定 IPv4 地址。
- `CFWARP_REMOTE_IPV4_CIDRS`：默认 `100.96.0.0/12`，远端 Mesh IPv4 地址段。route-manager 会在宿主机上把这些 CIDR 路由到 `cfwarp` 容器，`cfwarp` 容器内会把这些 CIDR 路由到 `CloudflareWARP`。多个 CIDR 可用逗号或空格分隔。
- `CFWARP_ROUTE_INTERVAL`：默认 `30s`，route-manager 刷新宿主机路由的间隔。
- `CFWARP_MANAGE_DOCKER_USER_RULES`：默认 `true`，route-manager 会在 Docker 的 `DOCKER-USER` 链放行发往远端 Mesh CIDR 的转发包。

## Docker Compose 部署

如果直接使用已发布镜像，可以在服务器上创建 `compose.yml`：

```yaml
services:
  cfwarp:
    image: ghcr.io/tursom/cfwarp:latest
    container_name: cfwarp
    restart: unless-stopped
    environment:
      CFWARP_CONNECTOR_TOKEN: ${CFWARP_CONNECTOR_TOKEN:-}
      CFWARP_ENABLE_FORWARDING: ${CFWARP_ENABLE_FORWARDING:-true}
      CFWARP_ENABLE_IPV6_FORWARDING: ${CFWARP_ENABLE_IPV6_FORWARDING:-false}
      CFWARP_WARP_MODE: ${CFWARP_WARP_MODE:-}
      CFWARP_HEALTHCHECK_INTERVAL: ${CFWARP_HEALTHCHECK_INTERVAL:-30s}
      CFWARP_REMOTE_IPV4_CIDRS: ${CFWARP_REMOTE_IPV4_CIDRS:-100.96.0.0/12}
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun:/dev/net/tun
    volumes:
      - ./data/cloudflare-warp:/var/lib/cloudflare-warp
    networks:
      cfwarp_net:
        ipv4_address: ${CFWARP_CONTAINER_IPV4:-172.30.0.2}

  cfwarp-route-manager:
    image: ghcr.io/tursom/cfwarp:latest
    container_name: cfwarp-route-manager
    network_mode: host
    restart: unless-stopped
    depends_on:
      - cfwarp
    entrypoint:
      - /usr/bin/tini
      - --
      - /usr/local/bin/cfwarp-route-manager
    environment:
      CFWARP_CONTAINER_IPV4: ${CFWARP_CONTAINER_IPV4:-172.30.0.2}
      CFWARP_REMOTE_IPV4_CIDRS: ${CFWARP_REMOTE_IPV4_CIDRS:-100.96.0.0/12}
      CFWARP_ROUTE_INTERVAL: ${CFWARP_ROUTE_INTERVAL:-30s}
      CFWARP_MANAGE_DOCKER_USER_RULES: ${CFWARP_MANAGE_DOCKER_USER_RULES:-true}
    cap_add:
      - NET_ADMIN

networks:
  cfwarp_net:
    driver: bridge
    driver_opts:
      com.docker.network.bridge.name: ${CFWARP_BRIDGE_NAME:-cfwarp0}
    ipam:
      config:
        - subnet: ${CFWARP_BRIDGE_SUBNET:-172.30.0.0/24}
```

同目录创建 `.env`：

```env
CFWARP_CONNECTOR_TOKEN=your-cloudflare-mesh-connector-token
CFWARP_ENABLE_FORWARDING=true
CFWARP_ENABLE_IPV6_FORWARDING=false
CFWARP_WARP_MODE=
CFWARP_HEALTHCHECK_INTERVAL=30s
CFWARP_BRIDGE_NAME=cfwarp0
CFWARP_BRIDGE_SUBNET=172.30.0.0/24
CFWARP_CONTAINER_IPV4=172.30.0.2
CFWARP_REMOTE_IPV4_CIDRS=100.96.0.0/12
CFWARP_ROUTE_INTERVAL=30s
CFWARP_MANAGE_DOCKER_USER_RULES=true
```

启动服务：

```sh
docker compose up -d
```

查看日志和状态：

```sh
docker compose logs -f cfwarp
docker compose exec cfwarp warp-cli status
```

`./data/cloudflare-warp` 是持久化状态目录。保留它可以让容器重启或镜像升级后复用同一个 Mesh node 注册状态，不重复注册新节点。

默认配置不会让 WARP 客户端进入宿主机网络命名空间。`cfwarp` 容器只在自己的网络命名空间中启用 forwarding；`cfwarp-route-manager` 只在宿主机上维护到远端 Mesh 地址段的路由，不修改宿主机防火墙。

## 运行

构建并启动：

```sh
docker compose up -d --build
```

如果本地 apt 缓存或代理在镜像构建时不稳定，可以绕过它：

```sh
docker build --build-arg APT_DISABLE_PROXY=true -t cfwarp:local .
```

查看日志：

```sh
docker compose logs -f cfwarp
```

检查 WARP 状态：

```sh
docker compose exec cfwarp warp-cli status
```

Compose 文件会把 `./data/cloudflare-warp` 挂载到 `/var/lib/cloudflare-warp`。保留这个目录后，容器重建或重启时会复用同一个 Mesh node 注册状态，不会重复注册新节点。

## 发布镜像

项目仓库：

- https://github.com/tursom/cfwarp

本仓库包含 GitHub Actions workflow，会把镜像发布到 GitHub Container Registry：

- `ghcr.io/tursom/cfwarp`

首次推送到 `main` 或 `master` 后，会生成 `latest`、分支名和 `sha-*` 标签；推送 `vX.Y.Z` 格式的 tag 后，会生成对应版本标签。

拉取示例：

```sh
docker pull ghcr.io/tursom/cfwarp:latest
```

如果 GitHub Packages 中的镜像保持私有，需要先登录 GHCR，或在 Packages 设置中调整镜像可见性。

## 网络行为

默认 Compose 配置使用专用 Docker bridge 网络：

```yaml
networks:
  cfwarp_net:
    driver_opts:
      com.docker.network.bridge.name: cfwarp0
    ipv4_address: 172.30.0.2
```

WARP 客户端在 `cfwarp` 容器里创建 `CloudflareWARP` 接口、nftables 规则和策略路由。由于 `cfwarp` 不使用 `network_mode: host`，这些规则不会出现在宿主机网络命名空间，也不会接管宿主机 22 端口。

当 `CFWARP_ENABLE_FORWARDING=true` 时，entrypoint 会在 `cfwarp` 容器网络命名空间中执行以下 sysctl 设置：

```sh
sysctl -w net.ipv4.ip_forward=1
```

这是为了支持 IPv4 Mesh 转发场景而设计的行为。如果希望自行管理容器内 forwarding，请设置 `CFWARP_ENABLE_FORWARDING=false`。IPv6 forwarding 默认不启用；需要时设置 `CFWARP_ENABLE_IPV6_FORWARDING=true`。

`cfwarp-route-manager` 会在宿主机网络命名空间中维护以下路由：

```sh
ip route replace 100.96.0.0/12 via 172.30.0.2
```

`cfwarp` 容器内也会维护对应路由，把同一个远端 Mesh CIDR 送入 WARP 接口：

```sh
ip route replace 100.96.0.0/12 dev CloudflareWARP
```

它还会在 Docker 的 `DOCKER-USER` 链放行发往该远端 Mesh CIDR 的转发包。Docker bridge 默认会拦截从宿主机转发进容器网段的包；这条规则只打通纯路由回程，不修改 WARP 自己创建的防火墙。

这是纯路由不 NAT 方案。被访问的 LAN 默认网关或目标主机必须有回程路由，把 `100.96.0.0/12` 指向 Docker 宿主机，否则请求可以到达目标网段但响应无法回到 Mesh。

## 故障排查

如果容器退出并提示 `CFWARP_CONNECTOR_TOKEN is required`，说明持久化状态目录为空，首次注册必须提供 Mesh connector token。

如果提示 `/dev/net/tun is missing`，请使用本仓库提供的 Compose 文件运行，或在手动运行容器时添加：

```sh
--device /dev/net/tun --cap-add NET_ADMIN
```

如果日志中出现 `sysctl: permission denied on key "net.ipv4.ip_forward"`，说明 `cfwarp` 容器没有权限修改容器网络命名空间里的 forwarding sysctl。请确认 `cfwarp` 服务保留了 `cap_add: [NET_ADMIN]`，或设置 `CFWARP_ENABLE_FORWARDING=false` 后自行管理 forwarding。

如果日志中出现 `Operation not authorized in this context` 且发生在 `warp-cli mode` 后，说明 Zero Trust 策略不允许客户端本地切换模式。请保持 `CFWARP_WARP_MODE` 为空，让客户端使用策略下发的模式。

如果宿主机 22 端口或其他公网 TCP 端口在 WARP 连接后不可访问，通常说明仍在使用旧的 `network_mode: host` 部署。请切换到默认 bridge 部署，并确认宿主机上不再出现由当前容器创建的 `CloudflareWARP` 接口、`cloudflare-warp` nftables 表或 `lookup 65743` 策略路由。

如果 Mesh node 没有上线，请检查：

- token 是 Mesh connector token，而不是用户设备 enrollment token。
- 宿主机可以正常访问 Cloudflare。
- `docker compose logs -f cfwarp` 中的 `warp-cli` 错误信息。
- Cloudflare Dashboard 中对应 Mesh node 的详情。

如果节点已经在线但子网路由不通，请检查：

- Cloudflare Mesh 中已经配置 route，并且 route 指向这个节点。
- `cfwarp-route-manager` 日志显示已经维护 `CFWARP_REMOTE_IPV4_CIDRS` 到 `CFWARP_CONTAINER_IPV4` 的宿主机路由。
- Docker `DOCKER-USER` 链已放行发往 `CFWARP_REMOTE_IPV4_CIDRS` 的转发包，或已设置 `CFWARP_MANAGE_DOCKER_USER_RULES=true`。
- 本地网络有回程路由把 `CFWARP_REMOTE_IPV4_CIDRS` 指向这台 Docker 宿主机。
