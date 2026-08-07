#!/bin/bash

if [ $# -ne 2 ]; then
    echo "need paths of milvus and patches"
    exit 1
fi

src=$1
patches=$2

dep_list_from_conan=(
	"boost" 
	"rocksdb" 
	"milvus-common"
	"icu"
)

get_conan_ref() {
    local conanfile="$1"
    local dep_name="$2"

    awk -v dep="$dep_name" '
        function emit_ref(line, ref) {
            ref = line
            sub(/^[^"]*"/, "", ref)
            sub(/".*$/, "", ref)

            if (index(ref, dep "/") == 1) {
                print ref
                found = 1
                exit
            }
        }

        # 处理：
        # requires = (
        #     "rocksdb/...",
        # )
        /^[[:space:]]*requires[[:space:]]*=[[:space:]]*\(/ {
            in_requires = 1
            next
        }

        in_requires {
            if ($0 ~ /^[[:space:]]*\)[[:space:]]*$/) {
                in_requires = 0
                next
            }

            emit_ref($0)
            next
        }

        # 处理：
        # self.requires("boost/...", force=True)
        /^[[:space:]]*self\.requires[[:space:]]*\(/ {
            emit_ref($0)
        }

        END {
            if (!found) {
                exit 1
            }
        }
    ' "$conanfile"
}

conan_download_dep() {
    local milvus_conanfile="$src/internal/core/conanfile.py"
    
    for dep_name in "${dep_list_from_conan[@]}"; do
	if ! dep="$(get_conan_ref "$milvus_conanfile" "$dep_name")"; then
            echo "[dep_patch] Cannot find conan reference: $dep_name"
        fi
    
        echo "[dep_patch] pre-download $dep"
        conan download $dep -r default-conan-local2 --only-recipe \
	  || conan download $dep -r conancenter --only-recipe
    done

    # b2/5.4.2 (boost 的依赖)。default-conan-local2 若有更高版本b2的配方，该补丁可丢弃
    conan download b2/5.4.2 -r default-conan-local2 --only-recipe

}

conan_patch_dep() {
    echo "pathing conanfile..."

    dep_list_from_conan+=("b2")

    for dep in "${dep_list_from_conan[@]}"; do
        # conan2 recipe 习惯使用依赖名的前 5 个字符作为路径开头
        local conan_data="$HOME/.conan2/p/${dep:0:5}"
        conanfile=$(find "$conan_data"* -path "*/conanfile.py" | head -n 1)
	
        # 修复 b2/5.4.2 存在的缺陷 (5.5.0已修复)
        if [[ "$dep" == "b2" ]]; then
            sed -i '/from conan.tools.files/a\
from conan.tools.files import replace_in_file' "$conanfile"

            cat > LOONGARCH_PATCH <<'EOF'
        variable_cpp = os.path.join(
            self.source_folder, "src", "engine", "variable.cpp"
        )
        replace_in_file(
            self,
            variable_cpp,
            (
                "\t\t::b2::string_view var(def.begin(), def.find('='));\n"
                "\t\t::b2::string_view val(def.begin() + var.size() + 1);\n"
            ),
            (
                "\t\t::b2::string_view var = def;\n"
                "\t\t::b2::string_view val;\n"
                "\t\tauto eq = def.find('=');\n"
                "\t\tif (eq != ::b2::string_view::npos)\n"
                "\t\t{\n"
                "\t\t\tvar = ::b2::string_view(def.begin(), eq);\n"
                "\t\t\tval = ::b2::string_view(def.begin() + eq + 1);\n"
                "\t\t}\n"
            ),
            strict=True,
        )
        replace_in_file(
            self,
            variable_cpp,
            "if (var.size() == def.size()) continue;",
            "if (val.empty()) continue;",
            strict=True,
        )
EOF

            sed -i '/def build(self):/r LOONGARCH_PATCH' "$conanfile"
            rm -f LOONGARCH_PATCH

	# 目前依赖的1.83.0中的 else if [ os.platform ] in ARM ARM64 { tmp = aapcs ; } 会导致loongarch的abi被误判为aapcs
	# 最终构建出的 libboost_context.so.1.83.0 缺少jump_fcontext ontop_fcontext make_fcontext 符号
	# 1.84.0 已修复该问题 
	elif [[ "$dep" == "boost" ]]; then
            sed -i 's/if self.settings.arch in (/if self.settings.arch in ("loongarch64", /' $conanfile
            
            cat > LOONGARCH_PATCH << 'EOF'
        jamfile = os.path.join(
            self.source_folder,
            "libs",
            "context",
            "build",
            "Jamfile.v2",
        )
        if os.path.exists(jamfile):
            replace_in_file(
                self,
                jamfile,
                "else if [ os.platform ] in ARM ARM64 { tmp = aapcs ; }",
                "else if [ os.platform ] = \"ARM\" { tmp = aapcs ; }\n"
                "    else if [ os.platform ] = \"ARM64\" { tmp = aapcs ; }",
            )
EOF
            sed -i '/apply_conandata_patches(self)/r LOONGARCH_PATCH' "$conanfile"
            rm -f LOONGARCH_PATCH
	
        elif [[ "$dep" == "rocksdb" ]]; then
            sed -i 's/"mips64"/"mips64", "loongarch64"/' $conanfile

            if ! grep -q 'replace_in_file' "$conanfile"; then
                sed -i '/from conan.tools.files import/a\
from conan.tools.files import replace_in_file' "$conanfile"
            fi

            cat > LOONGARCH_PATCH << 'EOF'
        self.output.info("Patching rocksdb for LoongArch64")
        
        source_dir = self.source_folder
        # 1. 修改 port/port_posix.h
        port_file = os.path.join(source_dir, "port", "port_posix.h")
        if os.path.exists(port_file):
            replace_in_file(
                self,
                port_file,
                "#elif defined(__powerpc64__)",
                "#elif defined(__loongarch64)\n  asm volatile(\"dbar 0\");\n#elif defined(__powerpc64__)"
            )

        # 2. 修改 util/xxhash.h
        xxhash_file = os.path.join(source_dir, "util", "xxhash.h")
        if os.path.exists(xxhash_file):
            replace_in_file(
                self,
                xxhash_file,
                'defined(__aarch64__) \\',
                'defined(__aarch64__) || defined(__loongarch64) \\'
            )

        # 3. 修改 toku_time.h
        toku_time_file = os.path.join(
            source_dir,
            "utilities", "transactions", "lock", "range", "range_tree",
            "lib", "portability", "toku_time.h"
        )
        if os.path.exists(toku_time_file):
            replace_in_file(
                self,
                toku_time_file,
                "#elif defined(__powerpc__)",
                "#elif defined(__loongarch64)\n  unsigned long result;\n  asm volatile (\"rdtime.d\\t%0,$r0\" : \"=r\" (result));\n  return result;\n#elif defined(__powerpc__)"
            )

        # 4. 修改 CMakeLists.txt
        cmake_file = os.path.join(source_dir, "CMakeLists.txt")
        if os.path.exists(cmake_file):
            replace_in_file(
                self,
                cmake_file,
                "include(CheckCCompilerFlag)",
                "include(CheckCCompilerFlag)\n"
                "\n"
                "if(CMAKE_SYSTEM_PROCESSOR MATCHES \"loongarch64\")\n"
                "  CHECK_C_COMPILER_FLAG(\"-march=loongarch64\" HAS_LOONGARCH64)\n"
                "  if(HAS_LOONGARCH64)\n"
                "    set(CMAKE_C_FLAGS \"${CMAKE_C_FLAGS} -march=loongarch64 -mtune=loongarch64\")\n"
                "    set(CMAKE_CXX_FLAGS \"${CMAKE_CXX_FLAGS} -march=loongarch64 -mtune=loongarch64\")\n"
                "  endif(HAS_LOONGARCH64)\n"
                "endif(CMAKE_SYSTEM_PROCESSOR MATCHES \"loongarch64\")"
            )

            replace_in_file(
                self,
                cmake_file,
                'if(CMAKE_SYSTEM_PROCESSOR MATCHES "^s390x")',
                '    if(CMAKE_SYSTEM_PROCESSOR MATCHES "^loongarch64")\n'
                '      set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -march=loongarch64")\n'
                '    endif()\n'
                '    if(CMAKE_SYSTEM_PROCESSOR MATCHES "^s390x")'
            )

        # 5. 修改 Makefile
        makefile = os.path.join(source_dir, "Makefile")
        if os.path.exists(makefile):
            replace_in_file(
                self,
                makefile,
                "sparc64",
                "sparc64 loongarch64"
            )
EOF
            sed -i '/apply_conandata_patches(self)/r LOONGARCH_PATCH' "$conanfile"
            rm -f LOONGARCH_PATCH

        elif [[ "$dep_name" == "milvus-common" ]]; then
            if ! grep -q 'def _patch_sources(self):' "$conanfile"; then
                echo "[dep_patch ERROR] _patch_sources() not found in $conanfile" >&2
                return 1
            fi

            cat > LOONGARCH_PATCH <<'EOF'
        thread_pool_header = os.path.join(
            self.source_folder,
            "include",
            "knowhere",
            "thread_pool.h",
        )
        replace_in_file(
            self,
            thread_pool_header,
            "#include <cblas.h>",
            "#if defined(__loongarch__) || defined(__loongarch64)\n"
            "#include <openblas/cblas.h>\n"
            "#else\n"
            "#include <cblas.h>\n"
            "#endif",
        )
EOF

            sed -i '/def _patch_sources(self)/r LOONGARCH_PATCH' "$conanfile"
            rm -f LOONGARCH_PATCH

        elif [[ "$dep_name" == "icu" ]]; then
            sed -i 's/"mips64"/"mips64", "loongarch64"/' $conanfile

        fi
    done
    rm -f LOONGARCH_PATCH
    echo "conanfile patched"
}

cmake_patch_dep() {
    #wget -O "$patches/config.sub" 'https://git.savannah.gnu.org/gitweb/?p=config.git;a=blob_plain;f=config.sub;hb=HEAD'
    #wget -O "$patches/config.guess" 'https://git.savannah.gnu.org/gitweb/?p=config.git;a=blob_plain;f=config.guess;hb=HEAD'

    local dep_list=(
        "jemalloc" 
        "knowhere"
    )
    
    echo "pathing dep's cmakelists..." 
    for dep in "${dep_list[@]}"; do
        cmakelists="$src/internal/core/thirdparty/$dep/CMakeLists.txt"

        # 替换旧的 config
        if [[ "$dep" == "jemalloc" ]]; then
            if ! grep -q "loongarch" "$cmakelists"; then
                sed -i '/PATCH_COMMAND touch doc\/jemalloc.3 doc\/jemalloc.html/a \        COMMAND sed -i "/#  ifdef __s390__/i #  if defined __loongarch__\\\\n#    define LG_QUANTUM          4\\\\n#  endif" include/jemalloc/internal/quantum.h' $cmakelists
                sed -i "/PATCH_COMMAND touch doc\/jemalloc.3 doc\/jemalloc.html/a \        COMMAND cp -f $patches/config.guess build-aux/config.guess\n        COMMAND cp -f $patches/config.sub build-aux/config.sub" $cmakelists
            fi

        elif [[ "$dep" == "knowhere" ]]; then
            if ! grep -q "loongarch" "$cmakelists"; then
                cat > LOONGARCH_PATCH << 'EOF'
    if (CMAKE_SYSTEM_PROCESSOR MATCHES "loongarch64")
        set(KNOWHERE_PATCH_MARKER "${knowhere_SOURCE_DIR}/.loongarch_patched")
        if(NOT EXISTS "${KNOWHERE_PATCH_MARKER}")
            message(STATUS "Patching Knowhere for LoongArch...")
        
            # diskann
            set(DISKANN_PATCH_VAL "#if defined(__loongarch64)\\n#define SIMDE_ENABLE_NATIVE_ALIASES\\n#include <simde/x86/sse.h>\\n#include <simde/x86/avx.h>\\n#else\\n#include <xmmintrin.h>\\n#endif")
            execute_process(
                COMMAND sed -i "s|#include <xmmintrin.h>|${DISKANN_PATCH_VAL}|g" 
                "${knowhere_SOURCE_DIR}/thirdparty/DiskANN/include/diskann/utils.h"
                "${knowhere_SOURCE_DIR}/thirdparty/DiskANN/src/index.cpp"
            )
        
            # knowhere -- add distances_lsx
            file(COPY "__PATCHES_DIR__/distances_lsx.cc" DESTINATION "${knowhere_SOURCE_DIR}/src/simd/")
            file(COPY "__PATCHES_DIR__/distances_lsx.h" DESTINATION "${knowhere_SOURCE_DIR}/src/simd/")
        
            # knowhere -- libfaiss.cmake 
            set(FAISS_CMAKE "${knowhere_SOURCE_DIR}/cmake/libs/libfaiss.cmake")
            set(FAISS_INS_A [=[if(__LOONGARCH64)
  set(UTILS_SRC src/simd/hook.cc src/simd/distances_lsx.cc src/simd/distances_ref.cc)
  add_library(knowhere_utils STATIC ${UTILS_SRC})
  target_link_libraries(knowhere_utils PUBLIC glog::glog)
endif()]=])
            string(REPLACE "\n" "\\n" FAISS_INS_A_ESC "${FAISS_INS_A}")
            execute_process(COMMAND sed -i "/list(REMOVE_ITEM FAISS_SRCS \${FAISS_RHNSW_SRCS})/a ${FAISS_INS_A_ESC}" ${FAISS_CMAKE})

            set(FAISS_INS_B [=[if(__LOONGARCH64)
    knowhere_file_glob(GLOB FAISS_SPECIFIC_SRCS
            thirdparty/faiss/faiss/impl/*avx.cpp
            thirdparty/faiss/faiss/impl/*neon.cpp
            thirdparty/faiss/faiss/impl/*sve.cpp
            thirdparty/faiss/faiss/impl/*rvv.cpp
            thirdparty/faiss/faiss/impl/*avx2.cpp
            thirdparty/faiss/faiss/impl/*avx512.cpp
            thirdparty/faiss/faiss/impl/*sse.cpp
    )

  list(REMOVE_ITEM FAISS_SRCS ${FAISS_SPECIFIC_SRCS})
  add_library(faiss STATIC ${FAISS_SRCS})
  target_sources(faiss PRIVATE ${FAISS_FASTSCAN_SRCS})

  target_compile_options(
    faiss
    PRIVATE $<$<COMPILE_LANGUAGE:CXX>:
            -mlsx
            -Wno-sign-compare
            -Wno-unused-variable
            -Wno-reorder
            -Wno-unused-local-typedefs
            -Wno-unused-function
            -Wno-strict-aliasing>)

  add_dependencies(faiss knowhere_utils)
  target_link_libraries(faiss PUBLIC OpenMP::OpenMP_CXX ${BLAS_LIBRARIES}
                                     ${LAPACK_LIBRARIES} knowhere_utils)
  target_compile_definitions(faiss PRIVATE FINTEGER=int)
endif()]=])
            string(REPLACE "\n" "\\n" FAISS_INS_B_ESC "${FAISS_INS_B}")
            execute_process(COMMAND sed -i "/include_directories(\${xxHash_INCLUDE_DIRS})/a ${FAISS_INS_B_ESC}" ${FAISS_CMAKE})
        
            # knowhere -- platform_check.cmake
            set(PLAT_CMAKE "${knowhere_SOURCE_DIR}/cmake/utils/platform_check.cmake")
            execute_process(COMMAND sed -i "/macro(detect_target_arch)/a \    check_symbol_exists(__loongarch64 \"\" __LOONGARCH64)" ${PLAT_CMAKE})
            execute_process(COMMAND sed -i "s/AND NOT __X86_64/AND NOT __X86_64\\n     AND NOT __LOONGARCH64/g" ${PLAT_CMAKE})

            # knowhere -- hook.cc
            set(HOOK_CC "${knowhere_SOURCE_DIR}/src/simd/hook.cc")
            execute_process(COMMAND sed -i "/#include \"distances_ref.h\"/i #if defined(__loongarch64)\\n#include \"distances_lsx.h\"\\n#endif" ${HOOK_CC})
            execute_process(COMMAND sed -i "/decltype(fvec_inner_product)/i #if !defined(__loongarch__)" ${HOOK_CC})
        
            set(HOOK_LSX_PTRS [=[#else
decltype(fvec_inner_product) fvec_inner_product = fvec_inner_product_lsx;
decltype(fvec_L2sqr) fvec_L2sqr = fvec_L2sqr_lsx;
decltype(fvec_L1) fvec_L1 = fvec_L1_lsx;
decltype(fvec_Linf) fvec_Linf = fvec_Linf_lsx;
decltype(fvec_norm_L2sqr) fvec_norm_L2sqr = fvec_norm_L2sqr_lsx;
decltype(fvec_L2sqr_ny) fvec_L2sqr_ny = fvec_L2sqr_ny_lsx;
decltype(fvec_inner_products_ny) fvec_inner_products_ny = fvec_inner_products_ny_lsx;
decltype(fvec_madd) fvec_madd = fvec_madd_lsx;
decltype(fvec_madd_and_argmin) fvec_madd_and_argmin = fvec_madd_and_argmin_lsx;

decltype(fvec_L2sqr_ny_nearest) fvec_L2sqr_ny_nearest = fvec_L2sqr_ny_nearest_lsx;
decltype(fvec_L2sqr_ny_nearest_y_transposed) fvec_L2sqr_ny_nearest_y_transposed =
    fvec_L2sqr_ny_nearest_y_transposed_lsx;
decltype(fvec_L2sqr_ny_transposed) fvec_L2sqr_ny_transposed = fvec_L2sqr_ny_transposed_lsx;

decltype(fvec_inner_product_batch_4) fvec_inner_product_batch_4 = fvec_inner_product_batch_4_lsx;
decltype(fvec_L2sqr_batch_4) fvec_L2sqr_batch_4 = fvec_L2sqr_batch_4_lsx;

decltype(ivec_inner_product) ivec_inner_product = ivec_inner_product_lsx;
decltype(ivec_L2sqr) ivec_L2sqr = ivec_L2sqr_lsx;
#endif]=])
            string(REPLACE "\n" "\\n" HOOK_LSX_PTRS_ESC "${HOOK_LSX_PTRS}")
            execute_process(COMMAND sed -i "/decltype(ivec_L2sqr)/a ${HOOK_LSX_PTRS_ESC}" ${HOOK_CC})

            set(HOOK_INIT [=[#if defined(__loongarch64)
    fvec_inner_product = fvec_inner_product_lsx;
    fvec_L2sqr = fvec_L2sqr_lsx;
    fvec_L1 = fvec_L1_lsx;
    fvec_Linf = fvec_Linf_lsx;

    fvec_norm_L2sqr = fvec_norm_L2sqr_lsx;
    fvec_L2sqr_ny = fvec_L2sqr_ny_lsx;
    fvec_inner_products_ny = fvec_inner_products_ny_lsx;
    fvec_madd = fvec_madd_lsx;
    fvec_madd_and_argmin = fvec_madd_and_argmin_lsx;

    ivec_inner_product = ivec_inner_product_lsx;
    ivec_L2sqr = ivec_L2sqr_lsx;

    fp16_vec_inner_product = fp16_vec_inner_product_ref;
    fp16_vec_L2sqr = fp16_vec_L2sqr_ref;
    fp16_vec_norm_L2sqr = fp16_vec_norm_L2sqr_ref;
    fp16_vec_inner_product_batch_4 = fp16_vec_inner_product_batch_4_ref;
    fp16_vec_L2sqr_batch_4 = fp16_vec_L2sqr_batch_4_ref;

    bf16_vec_inner_product = bf16_vec_inner_product_ref;
    bf16_vec_L2sqr = bf16_vec_L2sqr_ref;
    bf16_vec_norm_L2sqr = bf16_vec_norm_L2sqr_ref;
    bf16_vec_inner_product_batch_4 = bf16_vec_inner_product_batch_4_ref;
    bf16_vec_L2sqr_batch_4 = bf16_vec_L2sqr_batch_4_ref;

    int8_vec_inner_product = int8_vec_inner_product_ref;
    int8_vec_L2sqr = int8_vec_L2sqr_ref;
    int8_vec_norm_L2sqr = int8_vec_norm_L2sqr_ref;
    int8_vec_inner_product_batch_4 = int8_vec_inner_product_batch_4_ref;
    int8_vec_L2sqr_batch_4 = int8_vec_L2sqr_batch_4_ref;

    rabitq_dp_popcnt = rabitq_dp_popcnt_ref;
    fvec_masked_sum = fvec_masked_sum_ref;

    u64_binary_search_eq = u64_binary_search_eq_ref;
    u64_binary_search_ge = u64_binary_search_ge_ref;
    calculate_hash = calculate_hash_ref;
    u32_jaccard_distance = u32_jaccard_distance_ref;
    u32_jaccard_distance_batch_4 = u32_jaccard_distance_batch_4_ref;
    u64_jaccard_distance = u64_jaccard_distance_ref;
    u64_jaccard_distance_batch_4 = u64_jaccard_distance_batch_4_ref;
    minhash_lsh_hit = minhash_lsh_hit_ref;

    simd_type = "GENERIC";
    support_pq_fast_scan = false;
#endif]=])
            string(REPLACE "\n" "\\n" HOOK_INIT_ESC "${HOOK_INIT}")
            execute_process(COMMAND sed -i "/fvec_hook(std::string& simd_type)/,/#if defined(__x86_64__)/ {/#if defined(__x86_64__)/i ${HOOK_INIT_ESC}
}" ${HOOK_CC})
            file(WRITE "${KNOWHERE_PATCH_MARKER}" "patched")
        endif()
    endif()

    # make Knowhere masked-vbyte SSE code compile through SIMDe
    set(_milvus_loongarch_varintdecode
        "${knowhere_SOURCE_DIR}/src/index/sparse/codec/varintdecode.c")
    if(EXISTS "${_milvus_loongarch_varintdecode}")
        file(READ "${_milvus_loongarch_varintdecode}" _varintdecode_src)

        string(REPLACE
            "#elif defined(__aarch64__)\n#define SIMDE_ENABLE_NATIVE_ALIASES"
            "#elif defined(__aarch64__) || defined(__loongarch64)\n#define SIMDE_ENABLE_NATIVE_ALIASES"
            _varintdecode_src
            "${_varintdecode_src}")

        string(REPLACE
            "#include <stdint.h>"
            "#include <stddef.h>\n#include <stdint.h>"
            _varintdecode_src
            "${_varintdecode_src}")

        file(WRITE "${_milvus_loongarch_varintdecode}" "${_varintdecode_src}")
    endif()
EOF
                sed -i "/FetchContent_Populate( knowhere )/r LOONGARCH_PATCH" "$cmakelists"
                rm -f LOONGARCH_PATCH

                sed -i "s|__PATCHES_DIR__|$patches|" "$cmakelists"

		# 修复conan管理milvus-common时，knowhere没有继承milvus-common::milvus-common头文件路径的问题
                sed -i '/set_property(DIRECTORY/a\
include_directories(SYSTEM ${milvus-common_INCLUDE_DIRS})' "$cmakelists"
            fi
        fi
    done
    echo "cmakelists patched"
}

main() {
    conan_download_dep
    conan_patch_dep
    cmake_patch_dep
}

main
