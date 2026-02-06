#!/bin/bash

set -euo pipefail

VERSION=$1
if [ -z "$VERSION" ]; then
    echo "Error: Version argument is required."
    exit 1
fi

ORG='milvus-io'
PROJ='milvus'
# 容器工作目录
WORKSPACE="/workspace"
ARCH="$WORKSPACE/loong64"
SRCS="$WORKSPACE/srcs"
DISTS="$WORKSPACE/dists"
PATCHES="$WORKSPACE/patches"

mkdir -p "$DISTS/$VERSION" "$SRCS/$VERSION"

prepare()
{
    wget -O "$SRCS/$VERSION.tar.gz" --quiet --show-progress "https://github.com/$ORG/$PROJ/archive/refs/tags/v$VERSION.tar.gz"
    tar -xzf "$SRCS/$VERSION.tar.gz" -C "$SRCS/$VERSION" --strip-components=1

    "$PATCHES/milvus_patch.sh" "$SRCS/$VERSION"
    "$PATCHES/conan_patch.sh" "$SRCS/$VERSION"
    "$PATCHES/dep_patch.sh" "$SRCS/$VERSION" "$PATCHES"
}

build()
{
    pushd "$SRCS/$VERSION" > /dev/null

    make install
    
    popd > /dev/null
}

post_build()
{
    cp -r "$SRCS/$VERSION/bin/milvus" "$SRCS/$VERSION/configs" "$SRCS/$VERSION/lib" "$DISTS/$VERSION"
    tar -czf "$DISTS/$PROJ-$VERSION.tar.gz" -C "$DISTS" "$VERSION"
    rm -rf "$DISTS/$VERSION" "$SRC"
}

main()
{
    prepare
    build
    post_build
}

main
