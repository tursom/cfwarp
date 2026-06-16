# cfwarp

这是一个第三方 Docker 镜像项目，用来封装 Cloudflare One 官方 Linux WARP 客户端。镜像通过运行 `warp-svc` 和 `warp-cli connector new <TOKEN>`，以无头 Mesh 节点的形式加入 Cloudflare Mesh 网络。

本项目不实现 WARP 协议，也不实现非官方 WireGuard 客户端。镜像只从 `https://pkg.cloudflareclient.com/` 安装并运行 Cloudflare 官方 `cloudflare-warp` 软件包。

## 运行要求

- 支持 Docker Compose 的 Docker 环境。
- Linux 宿主机存在 `/dev/net/tun`。
- 允许容器使用 `network_mode: host` 和 `NET_ADMIN` 权限。
- 已启用 Cloudflare Mesh 的 Cloudflare Zero Trust 账号。
- 已在 Cloudflare Dashboard 中创建 Mesh connector token。

## Cloudflare 侧准备

先在 Cloudflare Dashboard 中创建 Mesh node，然后复制它的 connector token。容器只消费这个 token，不会创建 Mesh node、route 或其他 Cloudflare API 资源。

如果要使用子网路由，需要在 Cloudflare Mesh 中配置目标 CIDR route。容器侧只负责让 WARP connector 在线，并按配置启用宿主机网络命名空间里的 forwarding。

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

- `CFWARP_ENABLE_FORWARDING`：默认 `true`，自动启用宿主机网络命名空间里的 IPv4/IPv6 forwarding。
- `CFWARP_WARP_MODE`：默认 `warp`，用于执行 `warp-cli mode`。
- `CFWARP_HEALTHCHECK_INTERVAL`：默认 `30s`，用于状态检查循环和日志输出节流。

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

本仓库包含 GitHub Actions workflow，会把镜像发布到 GitHub Container Registry：

```sh
ghcr.io/<owner>/<repo>
```

需要先在 GitHub 仓库中启用 Actions。首次推送到 `main` 或 `master` 后，会生成 `latest`、分支名和 `sha-*` 标签；推送 `vX.Y.Z` 格式的 tag 后，会生成对应版本标签。

拉取示例：

```sh
docker pull ghcr.io/<owner>/<repo>:latest
```

如果 GitHub Packages 中的镜像保持私有，需要先登录 GHCR，或在 Packages 设置中调整镜像可见性。

## 网络行为

默认 Compose 配置使用宿主机网络：

```yaml
network_mode: host
```

当 `CFWARP_ENABLE_FORWARDING=true` 时，entrypoint 会在宿主机网络命名空间中执行以下 sysctl 设置：

```sh
sysctl -w net.ipv4.ip_forward=1
sysctl -w net.ipv6.conf.all.forwarding=1
sysctl -w net.ipv6.conf.all.accept_ra=2
```

这是为了支持子网路由场景而设计的行为。如果希望自行管理 forwarding，请设置 `CFWARP_ENABLE_FORWARDING=false`。

## 故障排查

如果容器退出并提示 `CFWARP_CONNECTOR_TOKEN is required`，说明持久化状态目录为空，首次注册必须提供 Mesh connector token。

如果提示 `/dev/net/tun is missing`，请使用本仓库提供的 Compose 文件运行，或在手动运行容器时添加：

```sh
--device /dev/net/tun --cap-add NET_ADMIN --network host
```

如果 Mesh node 没有上线，请检查：

- token 是 Mesh connector token，而不是用户设备 enrollment token。
- 宿主机可以正常访问 Cloudflare。
- `docker compose logs -f cfwarp` 中的 `warp-cli` 错误信息。
- Cloudflare Dashboard 中对应 Mesh node 的详情。

如果节点已经在线但子网路由不通，请检查：

- Cloudflare Mesh 中已经配置 route，并且 route 指向这个节点。
- 宿主机防火墙允许 WARP 接口和本地网络之间转发流量。
- 本地网络有回程路由指向这台宿主机，或者宿主机在容器外自行完成 NAT。
