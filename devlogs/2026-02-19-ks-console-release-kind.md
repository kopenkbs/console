# ks-console 本地 kind 发布记录（2026-02-19）

## 1. 目标与约束
- 命名空间：`kubesphere-system`
- 工作负载：`Deployment/ks-console`
- 对外服务：`Service/ks-console`（保持 `NodePort 30880`）
- 变更约束：尽量只改 `ConfigMap` 与镜像版本
- 发布方式：本地构建镜像 + 导入 kind（不走远端仓库）

## 2. 发布前基线
执行前已备份：
- `/tmp/ks-console-release-backup/deploy.ks-console.before.yaml`
- `/tmp/ks-console-release-backup/configmap.ks-console-config.before.yaml`
- `/tmp/ks-console-release-backup/local_config.before.yaml`

初始状态：
- 镜像：`kubespheredev/ks-console:v3.2.1`
- Service：`NodePort 30880`

## 3. 实施过程
### 3.1 首次构建尝试（失败）
命令：
```bash
docker build -f build/Dockerfile -t kubespheredev/ks-console:<tag> .
```
结果：失败。`apk add` 阶段无法正常拉取 Alpine 源（TLS/IO 异常），构建中断。

### 3.2 切换 dapper 打包（可构建）
先构建产物，再用 `build/Dockerfile.dapper` 打包：
```bash
yarn build
mkdir -p out/server
cp -r dist out/
cp -r server/locales server/public server/views server/sample out/server/
cp server/config.yaml out/server/
cp package.json out/
docker build -f build/Dockerfile.dapper -t kubespheredev/ks-console:<tag> .
```
镜像可构建，但部署后 `ks-console` 出现 `CrashLoopBackOff`。

### 3.3 故障定位
Pod 日志报错：
- `TypeError: getGeneratorFunction is not a function`

本地复现：
```bash
NODE_ENV=production node dist/server.js
```
同样崩溃，确认问题来自当前 `dist/server.js` 构建产物。

### 3.4 修复措施
处理方式：
1. 临时固定依赖版本（仅本地构建环境）：
```bash
npm install --no-save is-generator-function@1.0.10
```
2. 仅重建 server bundle：
```bash
yarn build:server
```
3. 本地启动验证：
```bash
NODE_ENV=production node dist/server.js
```
结果：启动成功（日志显示 `Dashboard app running at port 8000`）。

### 3.5 最终镜像打包与集群发布
最终镜像：
- `kubespheredev/ks-console:dev-202602190511-41ed8ef-fixed`

导入 kind 并发布：
```bash
docker save kubespheredev/ks-console:dev-202602190511-41ed8ef-fixed \
  | docker exec -i kind-1.23-control-plane ctr -n k8s.io images import -
```

ConfigMap 最小变更（仅后端地址）：
- `server.apiServer.url: http://ks-apiserver.kubesphere-system.svc`
- `server.apiServer.wsUrl: ws://ks-apiserver.kubesphere-system.svc`

更新镜像并滚动：
```bash
kubectl -n kubesphere-system set image deploy/ks-console \
  ks-console=kubespheredev/ks-console:dev-202602190511-41ed8ef-fixed
kubectl -n kubesphere-system rollout status deploy/ks-console --timeout=5m
```

## 4. 最终验证结果
按要求执行：
```bash
kubectl -n kubesphere-system rollout status deploy/ks-console --timeout=5m
kubectl -n kubesphere-system get deploy ks-console -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
kubectl -n kubesphere-system get svc ks-console -o wide
```

结果：
- rollout：成功
- 当前镜像：`kubespheredev/ks-console:dev-202602190511-41ed8ef-fixed`
- Service：`NodePort`，端口保持 `80:30880/TCP`
- `ks-console` Pod：`1/1 Running`

额外确认：
- `ks-console-config` 中 `apiServer.url/wsUrl` 已更新为 `ks-apiserver.kubesphere-system.svc`

## 5. 访问方式
- NodePort：`http://<任一NodeIP>:30880`
- 本机联调：
```bash
kubectl -n kubesphere-system port-forward svc/ks-console 18080:80
# 浏览器访问 http://127.0.0.1:18080
```

## 6. 回滚说明
### 6.1 镜像回滚
```bash
kubectl -n kubesphere-system rollout undo deploy/ks-console
```

### 6.2 ConfigMap 回滚
```bash
kubectl apply -f /tmp/ks-console-release-backup/configmap.ks-console-config.before.yaml
kubectl -n kubesphere-system rollout restart deploy/ks-console
kubectl -n kubesphere-system rollout status deploy/ks-console --timeout=5m
```

## 7. 结论
本次发布已完成，满足“仅变更 ConfigMap 与镜像版本”的目标；`Service/ks-console` 的 NodePort 配置保持不变，当前版本可正常运行。
