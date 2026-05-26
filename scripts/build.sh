#!/bin/bash
set -euo pipefail

UPSTREAM_OWNER=milvus-io
UPSTREAM_REPO=milvus
VERSION="${1}"
echo "   🏢 Org:   ${UPSTREAM_OWNER}"
echo "   📦 Proj:  ${UPSTREAM_REPO}"
echo "   🏷️  Ver:   ${VERSION}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "${SCRIPT_DIR}")"
DISTS="${ROOT_DIR}/dists"
SRCS="${ROOT_DIR}/srcs"
PATCHES="${ROOT_DIR}/patches"

mkdir -p "${DISTS}/${VERSION}" "${SRCS}"

# ==========================================
# 👇 用户自定义构建逻辑 (示例)
# ==========================================

echo "🔧 Compiling ${UPSTREAM_OWNER}/${UPSTREAM_REPO} ${VERSION}..."

# 1. 准备阶段：安装依赖、下载代码、应用补丁等
prepare()
{
    echo "📦 [Prepare] Setting up build environment..."

    local TAR_FILE="${SRCS}/${VERSION}.tar.gz"
    local SRC_DIR="${SRCS}/${VERSION}"

    [ -d "${SRC_DIR}" ] && rm -rf "${SRC_DIR}"
    mkdir -p ${SRC_DIR}

    if [ ! -f "${TAR_FILE}" ]; then
        wget -O "${TAR_FILE}" --quiet --show-progress \
    	    "https://github.com/${UPSTREAM_OWNER}/${UPSTREAM_REPO}/archive/refs/tags/v${VERSION}.tar.gz"
    fi
    tar -xzf "${TAR_FILE}" -C "${SRC_DIR}" --strip-components=1

    # patch
    "${PATCHES}/milvus_patch.sh" "${SRC_DIR}" "${VERSION}"
    "${PATCHES}/conan_patch.sh" "${SRC_DIR}"
    "${PATCHES}/dep_patch.sh" "${SRC_DIR}" "${PATCHES}"
    
    echo "✅ [Prepare] Environment ready."
}

# 2. 编译阶段：核心构建命令
build()
{
    echo "🔨 [Build] Compiling source code..."
    
    pushd "$SRCS/$VERSION"
    make install
    popd

    echo "✅ [Build] Compilation finished."
}

# 3. 后处理阶段：整理产物、清理临时文件、验证版本
post_build()
{
    echo "📦 [Post-Build] Organizing artifacts..."
    
    local BUILD_OUT="/tmp/${VERSION}"
    local PRODUCT="${DISTS}/${VERSION}/${UPSTREAM_REPO}-${VERSION}.tar.gz"

    mkdir -p "${BUILD_OUT}"
    cp -r "${SRCS}/${VERSION}/bin/milvus" "${SRCS}/${VERSION}/configs" "${SRCS}/${VERSION}/lib" "${BUILD_OUT}"
    tar -czf "${PRODUCT}" -C "/tmp" "${VERSION}"

    chown -R "${HOST_UID}:${HOST_GID}" "${DISTS}" "${SRCS}"
    
    echo "✅ [Post-Build] Artifacts ready in ./dists/${VERSION}."
}

# 主入口
main()
{
    prepare
    build
    post_build
}

main

# ==========================================
# 👆 自定义逻辑结束
# ==========================================

cat > "${DISTS}/${VERSION}/release.txt" <<EOF
Project: ${UPSTREAM_REPO}
Organization: ${UPSTREAM_OWNER}
Version: ${VERSION}
Build Time: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
EOF

echo "✅ Compilation finished."
ls -lh "${DISTS}/${VERSION}"
