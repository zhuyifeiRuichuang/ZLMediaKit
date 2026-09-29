# ZLMediaKit 部署（deploy/）

> 镜像来源：`ghcr.io/zhuyifeiRuichuang/zlmediakit`（由 `building/` 流水线构建，多架构 amd64/arm64）。
> 镜像启动命令固定为 `./MediaServer -s default.pem -c ../conf/config.ini -l 0`，
> 配置目录 `/opt/media/conf`、证书 `/opt/media/bin/default.pem`、Web 目录 `/opt/media/bin/www`。

## 目录结构

```
deploy/
├── docker-compose.yml   # 单机 Docker 部署（host 网络）
├── .env.example         # 环境变量示例
├── config/config.ini    # 默认配置（可修改后挂载覆盖）
├── cert/default.pem     # 默认证书（生产请替换为自有证书）
└── k8s/                 # Kubernetes 部署
    ├── namespace.yaml
    ├── configmap.yaml    # 由 config.ini 生成
    ├── secret.yaml       # 由 default.pem 生成（Opaque）
    ├── deployment.yaml   # hostNetwork 部署
    └── service.yaml      # 集群内部 ClusterIP 访问
```

## 一、Docker Compose 部署

```bash
cd deploy
cp .env.example .env          # 按需修改镜像/版本/时区
# 修改 config/config.ini 与 cert/default.pem 进行自定义
docker compose up -d
docker compose ps             # 观察健康状态（HEALTHCHECK 探测 80 端口）
docker compose logs -f        # 查看日志
```

- 默认使用 `network_mode: host`（媒体服务器需要大量 UDP 端口，host 网络最直接）。**仅支持 Linux 宿主机**。
- 若宿主机无法使用 host 网络，请改用端口映射方式（删除 `network_mode: host`，改为 `ports:` 映射 1935/554/80/443/10000/8000/9000 的 TCP+UDP；RTP/RTCP 与 RTC 动态端口范围需在 config.ini 中收紧或同样映射）。
- 配置/证书覆盖：`./config` → `/opt/media/conf`，`./cert` → `/opt/media/bin`（含 default.pem）。

## 二、Kubernetes 部署

```bash
cd deploy/k8s
kubectl apply -f namespace.yaml
kubectl apply -f configmap.yaml
kubectl apply -f secret.yaml
kubectl apply -f deployment.yaml
kubectl apply -f service.yaml

kubectl -n zlmediakit get pods -w
kubectl -n zlmediakit logs -f deploy/zlmediakit
```

- **hostNetwork**：Pod 直接监听节点 IP 与端口，适合媒体服务器；单节点单副本。多副本需按节点划分（亲和性 / 拓扑分布）。
- 集群内部访问：通过 `zlmediakit.zlmediakit.svc`（ClusterIP）访问 80/443/1935/554 等。
- 集群外部访问（非 hostNetwork 场景）：将 `service.yaml` 的 `type` 改为 `NodePort` 或 `LoadBalancer`，并为 Deployment 去掉 `hostNetwork`。
- **版本升级**：修改 `deployment.yaml` 中 `image` 的 tag 为新的发布版本（如 `1.0.1`），再 `kubectl apply -f deployment.yaml`；滚动更新即可。

### 自定义配置 / 证书

- 修改配置：编辑 `config/config.ini` 后 `kubectl create configmap zlm-config -n zlmediakit --from-file=config.ini --dry-run=client -o yaml | kubectl apply -f -`（或重新 apply `configmap.yaml`）。
- 替换证书：将自有 `default.pem` 放入 `cert/`，或在 k8s 侧 `kubectl create secret generic zlm-cert -n zlmediakit --from-file=default.pem --dry-run=client -o yaml | kubectl apply -f -`。

### api.secret（务必更换）

`[api] secret` 不可使用 ZLMediaKit 上游默认值 `035c73f7-bb6b-4889-a715-d9eb2d1925cc`，也不可留空：
服务端检测到此值会在启动时随机生成新 secret 并写回配置文件（`server/main.cpp`），
日志为 `The api.secret is invalid, modified it to: ...`。后果：

- **compose**：配置文件若可写会被容器改写，导致 Git 中的配置与实际运行值不一致；
- **k8s**：ConfigMap 只读，写回失败，运行实例持有无人知晓的随机 secret，
  所有 HTTP API 返回 `code=-100 "Please login first"`（`./index/api/getServerConfig` 等均无法调用）。

本目录 `config/config.ini` 与 `k8s/configmap.yaml` 已使用专有的示例 secret，生产部署请替换为自有值，
并同步到 ConfigMap（compose 侧 `config/` 以只读方式挂载，避免被容器改写）。

## 三、端口说明（与 conf/config.ini 默认一致）

| 端口 | 协议 | 用途 |
| --- | --- | --- |
| 1935 | TCP | RTMP |
| 554 | TCP | RTSP |
| 80 | TCP | HTTP（含 Web 管理/播放器） |
| 443 | TCP | HTTPS |
| 10000 | TCP/UDP | RTP_PROXY |
| 8000 | TCP/UDP | RTC（WebRTC 媒体） |
| 9000 | TCP/UDP | RTC 备用 |
| 30000-35000 | UDP | RTP/RTCP 动态范围 |
| 49152-65535 | UDP | RTC 动态范围 |

## 四、CI 自动化部署测试

流水线 `.github/workflows/zlm-deploy-test.yml`（手动触发，输入镜像 tag）包含两个并行 job，**均仅测 amd64**（arm64 由真机/节点侧验证）：

| Job | 场景 | 环境 | 断言内容 |
| --- | --- | --- | --- |
| `deploy-test-compose-amd64` | docker compose | runner 原生 docker | 镜像架构=amd64、容器 healthy、配置 secret 非上游默认且未被容器改写、`getServerConfig` code=0、1935/554 监听 |
| `deploy-test-k8s-amd64` | Kubernetes | 单节点 kind 集群（`.github/kind-config.yaml` + extraPortMappings） | 见下 |

k8s job 覆盖点（5 项断言）：

1. **配置 secret 合法**：非上游默认值；容器内生效值与 ConfigMap 一致（未被服务端随机重写）。
2. **镜像与运行态**：`sed` 把 `deployment.yaml` 的 `:latest` 替换为本次测试 `$IMAGE:$VERSION`，校验 Pod 实际使用镜像一致；Pod phase=Running、Ready=True 且 `restartCount=0`。
3. **挂载生效**：`ConfigMap(config.ini)` 与 `Secret(default.pem, subPath)` 在容器内均存在且非空。
4. **hostNetwork 暴露**：集群端口经 kind `extraPortMappings`（80→30080、1935→31935、554→30554）在 runner 本机可访问；`getServerConfig` 返回 code=0，1935/554 可连通。
5. **Service 转发**：`endpoints` 有可用地址，Pod 内经 ClusterIP:80 发起 HTTP 请求返回 200 且业务 code=0。

编排对象在 apply 前先做 `kubectl apply --dry-run=server` 预检（由 API Server 严格校验字段，如 Secret 卷须用 `secretName`）。

### 流水线自身的工程约定

按 GitHub 官方《Security hardening for GitHub Actions》与 Actions 生态现状梳理，与上面两个 job 的行为一一对应：

| 项 | 做法 | 依据 |
| --- | --- | --- |
| k8s 工具来源 | 直接使用 GitHub 官方 `ubuntu-24.04` runner 镜像**预装**的 Kind / Kubectl，不在 CI 中联网下载二进制 | 见 `actions/runner-images` 的 Ubuntu2404 工具清单。少一个外网依赖失败面、省去下载耗时，且二进制来自 GitHub 维护的镜像（有 SBOM 可核查）；代价是版本随镜像升级跟进，故 job 启动即打印 `kind version` / `kubectl version --client` 留痕 |
| kind 集群拓扑 | 声明式入库 `.github/kind-config.yaml`，由 `kind create cluster --config` 引用 | 集群拓扑与流水线解耦，本地可复现同一套配置；hostPort 须与 job 的 `PORT_HTTP/PORT_RTMP/PORT_RTSP` 一致 |
| action 引用方式 | `actions/checkout`、`actions/upload-artifact` 锁定到 **full commit SHA**（附对应 tag 注释） | 官方原文：“锁定到完整 SHA 是当前唯一可将 action 视为不可变发布的方式”，tag 可被仓库 owner 移动或删除 |
| 凭证使用 | `${{ secrets.GITHUB_TOKEN }}`、`${{ github.actor }}` 先赋给 `env` 中间变量，不内联进 `run:` 脚本 | 官方针对 inline script 的脚本注入缓解措施；相较于原先的 `echo "${{ secrets.GITHUB_TOKEN }}" \| docker login` |
| 报告呈现 | 每项断言通过后即时写入 `$GITHUB_STEP_SUMMARY`，job 页面直接显示结论表格 | 官方 Job Summary 机制，无需翻日志即可看到通过了什么 |
| 失败取证 | 失败时执行 kind 官方诊断命令 `kind export logs` 导出节点日志，连同 describe/logs/events 由 `actions/upload-artifact` 上传（保留 7 天） | 集群在 `always()` 清理步骤即被删除，须在失败时优先固化证据 |
| 并发互斥 | 顶层 `concurrency.group: zlm-deploy-test` + `cancel-in-progress: true` | 两个 job 共用 runner 本机端口与 kind 集群名，重复手动触发会撞资源造成假失败 |
| 超时兜底 | 每个 job 均设 `timeout-minutes: 30` | 官方建议为所有 job 显式设置超时上限，避免异常时长期占用 runner |

## 五、部署测试建议

1. **冒烟**：部署后 `curl -sI http://<节点IP>/` 应返回 200（HTTP 服务/Web 页面）。
2. **推流**：用 RTMP 推流 `rtmp://<节点IP>/live/stream`，再用 VLC/Web 播放器拉流验证。
3. **WebRTC**：访问 `http://<节点IP>/webrtc/` 或自带播放器测试 ICE/媒体连通（注意 8000/9000 UDP 与 STUN 映射）。
4. **配置生效**：修改 config.ini 后确认 Pod 已重载（重启或热加载），日志中无配置错误。
5. **多架构验证**：在 amd64 与 arm64 节点分别部署，确认镜像均可拉取运行（`docker inspect` / `kubectl describe` 确认架构匹配）。
