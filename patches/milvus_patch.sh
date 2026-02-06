#!/bin/bash

if [ $# -ne 1 ]; then
    echo "need milvus's path"
    exit 1
fi

src=$1

echo "patching milvus..."

# 去掉 rust 版本指定，使用系统包
sed -i "s/set(CARGO_CMD cargo +1.89 build/set(CARGO_CMD cargo build/" "$src/internal/core/thirdparty/tantivy/CMakeLists.txt"

# 修改 conan install，通过 profile 指定 loongarch 环境
sed -i "s/-s build_type=\${BUILD_TYPE} -s compiler.version=\${GCC_VERSION} -s compiler.libcxx=libstdc++11/-pr:b=loongarch -pr:h=loongarch/" "$src/scripts/3rdparty_build.sh"

# 纠正 libmilvus_core.so 路径
sed -i "s/lib\/libmilvus_core.so/lib64\/libmilvus_core.so/" "$src/scripts/setenv.sh"

echo "milvus patched"
