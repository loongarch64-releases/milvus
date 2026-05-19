#!/bin/bash

if [ $# -ne 2 ]; then
    echo "need milvus's path and version"
    exit 1
fi

src=$1
version=$2
major_ver=$(echo "$version" | cut -d. -f1)
minor_ver=$(echo "$version" | cut -d. -f2)
patch_ver=$(echo "$version" | cut -d. -f3)
ver_num=$(( 10#$major_ver * 1000000 + 10#$minor_ver * 1000 + 10#$patch_ver ))

echo "patching milvus..."

# 去掉 rust 版本指定，使用系统包
sed -i "s/set(CARGO_CMD cargo +1.89 build/set(CARGO_CMD cargo build/" "$src/internal/core/thirdparty/tantivy/CMakeLists.txt"

# 修改 conan install，通过 profile 指定 loongarch 环境
sed -i "s/-s build_type=\${BUILD_TYPE} -s compiler.version=\${GCC_VERSION} -s compiler.libcxx=libstdc++11/-pr:b=loongarch -pr:h=loongarch/" "$src/scripts/3rdparty_build.sh"

# 纠正 libmilvus_core.so 路径
sed -i "s/lib\/libmilvus_core.so/lib64\/libmilvus_core.so/" "$src/scripts/setenv.sh"

# 修复 openssl 动态库导致的 EVP_md2 符号问题(2.6.11开始)
if [ "$ver_num" -ge 2006011 ]; then
    sed -i 's/"openssl:shared": True/"openssl:shared": False/' "$src/internal/core/conanfile.py"
fi

# 2.6.16 引入向量化过滤功能，在 xsimd 适配loongarch之前，在loongarch上退回到标量过滤
simdFilterCpp="$src/internal/core/src/exec/expression/SimdFilter.cpp"
if [ "$ver_num" -ge 2006016 ]; then
    sed -i '/#include "SimdFilterImpl.h"/i \
#include <algorithm> \
#if defined(__x86_64__) || defined(__aarch64__)' "$simdFilterCpp"
    sed -i '/#include "SimdFilterImpl.h"/a \
#endif' "$simdFilterCpp"
    sed -i '/^#else$/{N;/\nusing Arch = xsimd::default_arch;$/d;}' "$simdFilterCpp"
    sed -i '/detail::filterChunkImpl<T, Arch>/i \
#if defined(__x86_64__) || defined(__aarch64__)' "$simdFilterCpp"
    sed -i '/detail::filterChunkImpl<T, Arch>/a \
#else \
    if (num_vals <= 0 || size <= 0) { \
	return; \
    } \
    for (int i = 0; i < size; ++i) { \
	if (std::binary_search(vals, vals + num_vals, data[i])) { \
	    bitmap[i / 8] |= static_cast<uint8_t>(1 << (i % 8)); \
	} \
    } \
#endif' "$simdFilterCpp"
    sed -i '/return xsimd::batch<T, Arch>::size;/i \
#if defined(__x86_64__) || defined(__aarch64__)' "$simdFilterCpp"
    sed -i '/return xsimd::batch<T, Arch>::size;/a \
#else \
    return 1; \
#endif' "$simdFilterCpp"
fi

echo "milvus patched"
