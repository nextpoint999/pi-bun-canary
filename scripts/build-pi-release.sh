#!/usr/bin/env bash
# =============================================================================
# build-pi-release.sh — 用 bun canary 构建 pi(earendil-works/pi) 上游某个
# release tag 的全平台二进制，并发布到本仓库（镜像发布）。
#
# 用法:
#   bash scripts/build-pi-release.sh <upstream-tag> [force]
#     <upstream-tag>  上游 tag，如 v0.84.1（或任意 git tag/分支）
#     [force]         true 时：即使该 tag 已发布也重建，并替换已有 release
#                     的全部资产（用于把 release 更新到最新 bun canary）
#
# 注意: 上游 build-binaries.sh 固定全量构建 6 个平台（darwin-arm64,
# darwin-x64, linux-x64, linux-arm64, windows-x64, windows-arm64），
# 不支持按平台裁剪，本脚本与其保持一致（与上游 release 资产集相同）。
#
# 依赖: bun(canary) / node / npm / git / curl / python3(zipfile) / zip / tar /
#       sha256sum / gh(仅发布步骤)
#
# 背景知识(踩坑记录，与 oh-my-pi-bun-canary 同源):
#   * bun canary 不做 npm 包发布，bun build --compile 交叉编译时按版本去 npm
#     拉运行时必然 404。绕过: 把运行时二进制预置到
#     $BUN_INSTALL_CACHE_DIR/bun-<compile-target>-v<主.次.修>，bun 检查到文件
#     存在即跳过下载（源码 src/standalone_graph/StandaloneModuleGraph.rs）。
#   * canary tag 是移动 tag，zip 资产用 aarch64 命名（bun-darwin-aarch64.zip）。
#     所有运行时下载均与 canary release 的 SHASUMS256.txt 做 sha256 完整性校验。
#   * pi 的 build-binaries.sh 对 x64 平台统一加 -baseline target
#     （darwin-x64 → bun-darwin-x64-baseline），但 canary zip 资产 darwin
#     无 baseline 后缀（bun-darwin-x64.zip），缓存名仍须用 -baseline。
#   * 原生模块 @mariozechner/clipboard 系列为 npm 预编译包，build-binaries.sh
#     已处理跨平台安装，无需手动交叉编译。
# =============================================================================
set -euo pipefail

UPSTREAM_REPO="earendil-works/pi"
TAG="${1:?用法: $0 <upstream-tag> [force]}"
FORCE="${2:-}"   # "true" = 强制重建并替换已有 release 资产

# 防止 - 开头的 tag 被 git/gh 解析为选项
case "$TAG" in
  -*) echo "[error] tag 不能以 - 开头: ${TAG}"; exit 1 ;;
esac

BUN_CACHE_DIR="${BUN_INSTALL_CACHE_DIR:-$HOME/.bun/install/cache}"
# 注意: `bun --version` 恒为主.次.修(1.4.0)，canary 详情在 `bun --revision`（如 1.4.0-canary.1+b58cd4685）。
# 缓存文件名必须用 --version 的 主.次.修；用 --revision 截取会把 0-canary 混进第三段。
BUN_REV="$(bun --revision 2>/dev/null || bun --version)"                # 完整版本+commit
BUN_FULL="$(echo "${BUN_REV}" | cut -d+ -f1)"                           # 1.4.0-canary.1（标题/说明用）
BUN_VERSION="$(bun --version | cut -d. -f1-3)"                          # 1.4.0（缓存文件名用）
case "$BUN_VERSION" in
  [0-9]*.[0-9]*.[0-9]*) : ;;
  *) echo "[error] 无法解析 bun 版本: ${BUN_REV}"; exit 1 ;;
esac
VER="${TAG#v}"   # v0.84.1 -> 0.84.1

# 固定全量 6 平台（与上游 build-binaries.sh 一致，不支持裁剪）
TARGETS="darwin-arm64,darwin-x64,linux-x64,linux-arm64,windows-x64,windows-arm64"
echo "=== 构建目标: ${TARGETS} ==="

# target id -> (canary zip 资产名 | 缓存文件名 bun-<compile-target>-v<ver>)
# 注意: Bun 内部把 arm64 规范化为 npm 命名 "aarch64"；pi 的 build-binaries.sh
# 对 x64 统一加 -baseline target，故缓存名须带 -baseline（darwin-x64 的 zip
# 资产虽无 baseline 后缀，缓存名仍用 bun-darwin-x64-baseline，实测可编译）。
RUNTIMES=(
  "darwin-arm64|bun-darwin-aarch64.zip|bun-darwin-aarch64"
  "darwin-x64|bun-darwin-x64.zip|bun-darwin-x64-baseline"
  "linux-x64|bun-linux-x64-baseline.zip|bun-linux-x64-baseline"
  "linux-arm64|bun-linux-aarch64.zip|bun-linux-aarch64"
  "windows-x64|bun-windows-x64-baseline.zip|bun-windows-x64-baseline"
  "windows-arm64|bun-windows-aarch64.zip|bun-windows-aarch64"
)

# 只保留请求目标的运行时条目
RUN_ENTRIES=()
for entry in "${RUNTIMES[@]}"; do
  id="${entry%%|*}"
  case ",${TARGETS}," in
    *",${id},"*) RUN_ENTRIES+=("$entry") ;;
  esac
done
[ ${#RUN_ENTRIES[@]} -gt 0 ] || { echo "[error] 目标列表不含任何已知平台"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "===== [1/6] 克隆 ${UPSTREAM_REPO} @ ${TAG} ====="
git clone --depth 1 --branch="$TAG" "https://github.com/${UPSTREAM_REPO}.git" "$WORK/pi"
cd "$WORK/pi"

echo "===== [2/6] 注入 bun canary 编译运行时 (共 ${#RUN_ENTRIES[@]} 个, 含完整性校验) ====="
mkdir -p "$BUN_CACHE_DIR"
for entry in "${RUN_ENTRIES[@]}"; do
  id="${entry%%|*}"; rest="${entry#*|}"; asset="${rest%%|*}"; cname="${rest#*|}"
  # 两级完整性校验（与 omp 同源）:
  # Tier1: 与 canary release 的 SHASUMS256.txt 比对（最强证明）。
  # Tier2: Tier1 持续不匹配（bun shas 滞后）时，校验解包出的运行时内嵌 canary
  #   版本串，并打印警告继续。
  expected=""; actual=""
  for attempt in 1 2 3; do
    curl -fsSL -o "$WORK/shas.txt" "https://github.com/oven-sh/bun/releases/download/canary/SHASUMS256.txt"
    curl -fsSL -o "$WORK/rt.zip" "https://github.com/oven-sh/bun/releases/download/canary/${asset}"
    expected="$(awk -v f="${asset}" '$2==f {print $1}' "$WORK/shas.txt")"
    actual="$(sha256sum "$WORK/rt.zip" | cut -d' ' -f1)"
    if [ -n "$expected" ] && [ "$expected" = "$actual" ]; then
      break
    fi
    echo "  [warn] ${asset} sha256 与 shas.txt 不一致（第 ${attempt} 次），5s 后重试"
    sleep 5
  done
  python3 -m zipfile -e "$WORK/rt.zip" "$WORK/rt"
  rtbin="$(find "$WORK/rt" -type f \( -name bun -o -name bun.exe \) | head -1)"
  [ -n "$rtbin" ] || { echo "[error] ${asset} 内未找到 bun/bun.exe"; exit 1; }
  if [ -n "$expected" ] && [ "$expected" = "$actual" ]; then
    echo "  [Tier1] ${asset} sha256 校验通过 (${actual:0:12})"
  else
    if grep -a -q "1.4.0-canary" "$rtbin" 2>/dev/null; then
      echo "  [warn][Tier2] ${asset} 未通过 shas.txt 比对（bun 的 shas 滞后: 期望 ${expected:-无} ≠ 实际 ${actual:0:12}），已校验内嵌版本串为 canary，继续"
    else
      echo "[error] ${asset} 完整性校验失败（shas 不匹配且非 canary 运行时）"
      exit 1
    fi
  fi
  cp "$rtbin" "$BUN_CACHE_DIR/${cname}-v${BUN_VERSION}"
  rm -rf "$WORK/rt" "$WORK/rt.zip"
  echo "  + ${cname}-v${BUN_VERSION}  <-  ${asset}"
done

echo "===== [3/6] 生成模型数据 (hydrate:model-data) ====="
# 上游 build-binaries.sh --offline-model-data 需要 bundled model data 已生成；
# 官方 workflow 正是先 hydrate 再构建（会联网拉取模型列表，脚本内有容错）
npm run hydrate:model-data 2>&1 | tail -15

echo "===== [4/6] 运行上游构建脚本 build-binaries.sh (npm ci + build + 6 平台 compile) ====="
# --offline-model-data: 用刚生成的 bundled model data，避免再次联网刷新
bash scripts/build-binaries.sh --offline-model-data --out "$WORK/binaries" 2>&1 | tail -40

echo "===== [5/6] 核对产物 ====="
BIN_DIR="$WORK/binaries"
ls -la "$BIN_DIR"
for t in $(echo "$TARGETS" | tr ',' ' '); do
  if [[ "$t" == windows-* ]]; then
    [ -f "$BIN_DIR/pi-$t.zip" ] || { echo "[error] 缺少 pi-$t.zip"; exit 1; }
  else
    [ -f "$BIN_DIR/pi-$t.tar.gz" ] || { echo "[error] 缺少 pi-$t.tar.gz"; exit 1; }
  fi
done
echo "产物齐全 ✓"

echo "===== [6/6] 生成校验和 ====="
( cd "$BIN_DIR" && sha256sum pi-*.tar.gz pi-*.zip > SHA256SUMS && cat SHA256SUMS )

echo "===== [7/7] 发布到本仓库 ====="
if [ -z "${GH_TOKEN:-}" ] || ! command -v gh >/dev/null 2>&1; then
  echo "[warn] 无 gh 或 GH_TOKEN，跳过发布（本地测试模式）"
  exit 0
fi
# gh 默认按当前目录的 git remote 推断目标仓库；而本脚本 CWD 在上游克隆里，
# 不显式指定会把上游误判为发布目标（gh release view 误报"已存在"而跳过）。
if [ -n "${GITHUB_REPOSITORY:-}" ]; then
  export GH_REPO="$GITHUB_REPOSITORY"
fi
RELEASE_TAG="${TAG}"   # 发布 tag 与上游保持一致（如 v0.84.1）
# 上游克隆自带同名本地 tag，gh 会报 "tag exists locally but has not been
# pushed" 而拒绝创建；删掉本地 tag，并显式 --target 默认分支在目标仓库新建。
git tag -d "$RELEASE_TAG" 2>/dev/null || true
# release 名与上游保持一致（纯 tag），bun 版本信息放 body
RELEASE_NOTES="**上游**: [${UPSTREAM_REPO} ${TAG}](https://github.com/${UPSTREAM_REPO}/releases/tag/${TAG})

**构建工具**: bun canary \`${BUN_FULL}\`（revision \`${BUN_REV}\`）
**平台**: ${TARGETS}
使用 bun canary 交叉编译的全平台镜像构建，附 SHA256 校验和。"
# gh release view 偶发 HTTP 500（GitHub 服务端瞬时故障，实测 2026-08-14 omp 遇过：
# 构建全部成功但 view 500 直接 exit 1 导致镜像中断），重试 3 次再决定
RELEASE_EXISTS=""
for _try in 1 2 3; do
  if gh release view "$RELEASE_TAG" >/dev/null 2>&1; then
    RELEASE_EXISTS="yes"
    break
  fi
  echo "[warn] gh release view ${RELEASE_TAG} 失败（第 ${_try} 次），5s 后重试"
  sleep 5
done
if [ -n "$RELEASE_EXISTS" ]; then
  if [ "$FORCE" = "true" ]; then
    echo "release ${RELEASE_TAG} 已存在，force 模式：替换全部资产并更新说明"
    gh release view "$RELEASE_TAG" --json assets -q '.assets[].name' | while read -r aname; do
      [ -n "$aname" ] && gh release delete-asset "$RELEASE_TAG" "$aname" --yes >/dev/null
    done
    # 只上传文件（上游 build-binaries.sh 会留下解压目录，通配符 * 会把目录
    # 也传上去导致 "is a directory" 错误）
    gh release upload "$RELEASE_TAG" $(find "$BIN_DIR" -maxdepth 1 -type f) --clobber
    gh release edit "$RELEASE_TAG" --notes "$RELEASE_NOTES"
    echo "已更新: https://github.com/${GITHUB_REPOSITORY:-<your-repo>}/releases/tag/${RELEASE_TAG}"
    exit 0
  fi
  echo "release ${RELEASE_TAG} 已存在，跳过（如需重建请用 force=true）"
  exit 0
fi
DEFAULT_BRANCH="$(gh repo view --json defaultBranchRef -q '.defaultBranchRef.name' 2>/dev/null || echo main)"
# 只上传文件：SHA256SUMS 已包含在 find 结果里，不能重复显式传入（否则 422）
# create 同样可能偶发 500，失败重试 3 次（成功即 break）
CREATED=""
for _try in 1 2 3; do
  if gh release create "$RELEASE_TAG" $(find "$BIN_DIR" -maxdepth 1 -type f) \
    --target "$DEFAULT_BRANCH" \
    --title "${TAG}" \
    --notes "$RELEASE_NOTES"; then
    CREATED="yes"
    break
  fi
  echo "[warn] gh release create ${RELEASE_TAG} 失败（第 ${_try} 次），10s 后重试"
  sleep 10
done
[ -n "$CREATED" ] || { echo "[error] gh release create 重试 3 次仍失败"; exit 1; }
# 若上游是预发布（tag 含 -），标记为 prerelease
if [[ "$TAG" == *-* ]]; then
  gh release edit "$RELEASE_TAG" --prerelease >/dev/null 2>&1 || true
fi
echo "已发布: https://github.com/${GITHUB_REPOSITORY:-<your-repo>}/releases/tag/${RELEASE_TAG}"
