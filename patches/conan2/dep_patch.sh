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
	"xz_utils"
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
	
        # rocksbd 7.10.2+ 时去掉该补丁
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

        elif [[ "$dep" == "milvus-common" ]]; then
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

        elif [[ "$dep" == "icu" ]]; then
	    echo "hit icu! conanfile: $conanfile"
            sed -i 's/"mips64"/"mips64", "loongarch64"/' $conanfile

        # 本地构建时 xz_utils conandata.yml 中的两个源无法使用(网络原因)
        elif [[ "$dep" == "xz_utils" ]]; then
            conandata=$(find "$conan_data"* -path "*/conandata.yml" | head -n 1)
            sed -i '/https:\/\/tukaani\.org\/xz\/xz-5\.4\.5\.tar\.xz/i\
      - "https://github.com/tukaani-project/xz/releases/download/v5.4.5/xz-5.4.5.tar.xz"' $conandata
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
    message(STATUS "Patching diskann for knowhere...")
        
    # diskann
    set(DISKANN_PATCH_VAL "#if defined(__loongarch64)\\n#define SIMDE_ENABLE_NATIVE_ALIASES\\n#include <simde/x86/sse.h>\\n#include <simde/x86/avx.h>\\n#else\\n#include <xmmintrin.h>\\n#endif")
    execute_process(
        COMMAND sed -i "s|#include <xmmintrin.h>|${DISKANN_PATCH_VAL}|g"
        "${knowhere_SOURCE_DIR}/thirdparty/DiskANN/include/diskann/utils.h"
        "${knowhere_SOURCE_DIR}/thirdparty/DiskANN/src/index.cpp"
    )
EOF
                sed -i "/FetchContent_Populate( knowhere )/r LOONGARCH_PATCH" "$cmakelists"
                rm -f LOONGARCH_PATCH
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
