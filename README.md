# pi 镜像发布 Workflow

[earendil-works/pi](https://github.com/earendil-works/pi)（AI agent toolkit）的
**全平台二进制镜像仓库**：定时检测上游新 release，用**该 tag 的源码 + 最新
[bun canary](https://github.com/oven-sh/bun/releases/tag/canary)** 交叉编译全部
**6 个平台**的二进制，并以**与上游同名 tag** 发布到本仓库。

> 📦 所有 release 附 SHA256 校验和（`SHA256SUMS`）。
> 🔗 发布物列表：<https://github.com/nextpoint999/pi-bun-canary/releases>

## 目录

- [工作原理](#工作原理)
- [部署步骤](#部署步骤)
- [平台矩阵](#平台矩阵)
- [踩坑记录](#踩坑记录)
- [相关链接](#相关链接)

## 工作原理

```
定时(每 2h)
  └─▶ 取上游【最新一个】release
        ├─ 未镜像 ──────────────────────▶ 构建并发布
        └─ 已镜像，但 bun canary 已前进 ──▶ force 重建最新版（替换资产）

构建流程（单版本，复用上游官方 scripts/build-binaries.sh，固定全量 6 平台）：
  ├─ npm run hydrate:model-data（生成 bundled model data）
  ├─ npm ci（workspaces 依赖）
  ├─ 跨平台原生绑定 @mariozechner/clipboard
  ├─ npm run build:offline（tsgo 编译）
  ├─ 运行时：bun canary tag 注入缓存（两级完整性校验）
  └─ bun build --compile 6 平台
       └─ gh release create 发布（同名 tag + SHA256SUMS）
```

## 部署步骤

1. 把本目录两个文件放入你的 GitHub 仓库：

   ```
   .github/workflows/pi-mirror.yml   ← 定时 + 检测 + 发布逻辑
   scripts/build-pi-release.sh       ← 单版本构建脚本
   ```

2. 推送后 workflow 按 cron（UTC 每 2 小时）自动运行；也可到
   **Actions → Mirror pi releases → Run workflow** 手动触发，输入参数：

   | 参数 | 说明 |
   |---|---|
   | `tag` | 指定上游 tag 强制构建（如 `v0.84.1`，可补历史版本），留空则自动检测 |
   | `latest` | latest 徽标处理：`auto`（默认，按上游最新版本）/ `set`（本次构建版本设为 latest）/ `keep`（不修改）。**不能用 yes/no**——YAML 会解析为布尔值，GitHub 拒绝 |
   | `force` | 勾选后**强制重建**：即使该 tag 已发布也重新构建，替换已有 release 的全部资产（release 本体/说明/日期保留，只换二进制和 SHA256SUMS；用于把 release 更新到最新 bun canary） |

3. 发布权限：workflow 已声明 `permissions: contents: write`，使用 GitHub 自动提供的
   GITHUB_TOKEN，无需额外配置。仓库公开后 release 对所有人可见。

## 平台矩阵（target id → 产物）

| target | 产物 | 运行时注入（canary zip） |
|---|---|---|
| darwin-arm64 | pi-darwin-arm64.tar.gz | bun-darwin-aarch64.zip |
| darwin-x64 | pi-darwin-x64.tar.gz | bun-darwin-x64.zip（缓存名 -baseline） |
| linux-x64 | pi-linux-x64.tar.gz | bun-linux-x64-baseline.zip |
| linux-arm64 | pi-linux-arm64.tar.gz | bun-linux-aarch64.zip |
| windows-x64 | pi-windows-x64.zip | bun-windows-x64-baseline.zip |
| windows-arm64 | pi-windows-arm64.zip | bun-windows-aarch64.zip |

> 注：与 oh-my-pi 镜像（7 平台含 musl）不同，pi 官方只发布这 6 个平台，
> 镜像保持与上游一致。

## 踩坑记录

**canary 运行时注入**

- **canary 无 npm 包**：bun 交叉编译按 `@oven/bun-<platform>` 从 npm 拉运行时，
  canary 不发布 npm 包必然 404。绕过：把 canary tag 的 zip 里的运行时二进制
  预置到 `$BUN_INSTALL_CACHE_DIR/bun-<compile-target>-v<主.次.修>`，bun 检测到
  文件存在即跳过下载（Bun 源码 `StandaloneModuleGraph.rs`）。
- **arm64 用 aarch64 命名**：bun 内部把 arm64 规范化为 npm 命名 `aarch64`，缓存
  文件名（和 npm URL）都用 aarch64；canary 的 zip 资产也是
  `bun-darwin-aarch64.zip` / `bun-windows-aarch64.zip`。
- **darwin-x64 的 baseline 坑**：pi 的 build-binaries.sh 对 x64 统一加 `-baseline`
  target（darwin-x64 → `bun-darwin-x64-baseline`），但 canary zip 资产 darwin
  无 baseline 后缀（只有 `bun-darwin-x64.zip`）。缓存名仍须用
  `bun-darwin-x64-baseline-v<主.次.修>`（实测可编译）。
- **canary 移动 tag 竞态**：bun canary 每次 commit 都会重新构建发布，SHASUMS256.txt
  与 zip 分两次下载可能来自不同构建导致 sha256 不匹配（不是供应链攻击）。更关键的
  是 bun 的 SHASUMS256.txt 更新**滞后于 zip**（实测滞后 10+ 小时）。脚本采用两级
  校验：Tier1 比对 shas.txt（通过即最强证明）；不匹配时降级 Tier2——校验解包出的
  运行时内嵌 `1.4.0-canary` 版本串，并打印警告继续。
- **bun 版本号坑**：`bun --version` 只返回 `1.4.0`，完整 canary 版本号
  （`1.4.0-canary.1+b58cd4685`）要用 `bun --revision` 取。

**上游构建**

- **pi 是 npm workspaces monorepo**：用 `npm ci`（非 `bun install`），需要 Node.js；
  workflow 里 setup-bun canary + setup-node 22 都要装。
- **model data 需先 hydrate**：`build-binaries.sh --offline-model-data` 要求
  `packages/ai/src/providers/data/` 下已有模型数据，clone 的源码里没有（在
  .gitignore 内）；必须先 `npm run hydrate:model-data`（联网拉取模型列表，
  脚本内有容错）再构建，否则 `check:model-data` 直接失败。
- **build-binaries.sh 固定全量 6 平台**：该脚本忽略外部参数，总是构建全部
  darwin/linux/windows × arm64/x64；本镜像与其保持一致（与上游 release 资产集
  相同），不做平台裁剪。
- **原生模块不交叉编译**：`@mariozechner/clipboard` 系列是 npm 预编译包（含
  darwin/linux/win32 各架构），上游 build-binaries.sh 已处理跨平台安装（独立目录
  npm install + 拷贝进 node_modules），无需手动处理。

**gh 发布**

- **gh 仓库推断坑**：`gh` 默认按当前目录 git remote 推断目标仓库，而构建脚本 CWD
  在上游克隆里，必须显式 `export GH_REPO="$GITHUB_REPOSITORY"`，否则会把上游误判为
  发布目标（`gh release view` 误报"已存在"导致发布被跳过）。
- **gh 本地 tag 坑**：上游克隆自带同名本地 tag，`gh release create` 会报
  "tag exists locally but has not been pushed"；先 `git tag -d` 再带
  `--target main` 创建。
- **资产重复上传坑**：`"$BIN_DIR"/*` 通配已包含 SHA256SUMS，不要再显式传入，
  否则 422 `ReleaseAsset.name already exists`（gh 会自动回滚已建 release）。

**版本与 latest 维护**

- **latest 徽标维护**：GitHub 默认按发布时间（而非版本号）决定哪个 release 是
  Latest，补发旧版本会抢走徽标。workflow 已内置两层防护：1) 批次内按版本升序构建
  （`sort -V`），最新版最后发布；2) 构建完成后调用 `make_latest=true` API 把上游
  最新版本显式设为 latest，覆盖任何日期顺序误判。
- **不补历史版本**：定时任务只镜像"比已镜像版本更新"的 release（上游列表按最新
  优先，遇到第一个已镜像版本即停止）；需要历史版本时用 workflow_dispatch 手动
  指定 tag 构建。

## 相关链接

- 上游项目：[earendil-works/pi](https://github.com/earendil-works/pi)
- bun canary 构建：[oven-sh/bun releases（canary tag）](https://github.com/oven-sh/bun/releases/tag/canary)
- 本仓库发布物：[nextpoint999/pi-bun-canary/releases](https://github.com/nextpoint999/pi-bun-canary/releases)
- 构建日志：[Actions 页面](https://github.com/nextpoint999/pi-bun-canary/actions)
- 姊妹项目（oh-my-pi 镜像）：[nextpoint999/oh-my-pi-bun-canary](https://github.com/nextpoint999/oh-my-pi-bun-canary)
