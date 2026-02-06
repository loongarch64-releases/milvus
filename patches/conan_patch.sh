#!/bin/bash

if [ $# -ne 1 ]; then
    echo "need milvus's path"
    exit 1
fi

src=$1

echo "preparing conan env..."

conan config init
# 允许拉包
conan config set general.revisions_enabled=1
# 仓库
CONAN_REPO=$(grep -E '^\s*CONAN_ARTIFACTORY_URL=' "$src/scripts/3rdparty_build.sh" | head -n1)
eval "$CONAN_REPO"
conan remote add default-conan-local "$CONAN_ARTIFACTORY_URL"

# conanfile for loongarch
la_conan_profile="$HOME/.conan/profiles/loongarch"
cp "$HOME/.conan/profiles/default" $la_conan_profile
sed -i "s/x86_64/loongarch64/" $la_conan_profile
sed -i "s/compiler.libcxx.*/compiler.libcxx=libstdc++11/" $la_conan_profile
sed -i "s/arch_build: \[/arch_build: \[loongarch64, /" "$HOME/.conan/settings.yml"
sed -i "s/arch: \[/arch: \[loongarch64, /" "$HOME/.conan/settings.yml"


# 处理conan管理的三方包config过旧情况
cat > loongarch_hook.py << 'EOF'
import os
import shutil

def pre_build(output, conanfile, **kwargs):
    source_folder = getattr(conanfile, "source_folder", None)
    if source_folder and os.path.exists(source_folder):
        output.info(f"LoongArch Fix: Patching config.guess for {conanfile.name}")
        for root, dirs, files in os.walk(source_folder):
            for f in files:
                if f in ("config.guess", "config.sub"):
                    target = os.path.join(root, f)
                    patch_src = os.path.join("/usr/share/libtool/build-aux", f)
                    if os.path.exists(patch_src):
                        shutil.copy(patch_src, target)
EOF
mkdir -p "$HOME/.conan/hooks"
mv loongarch_hook.py "$HOME/.conan/hooks/"
conan config set hooks.loongarch_hook


# 使用系统 cmake
cat > conanfile.py << 'EOF'
from conans import ConanFile

class CMakeLoongarch64(ConanFile):
    name = "cmake"
    version = "3.30.5" # 欺骗依赖链，匹配版本要求
    settings = "os", "arch", "compiler", "build_type"
    description = "Fake CMake package for LoongArch64 to use system binary"

    def package_info(self):
        self.cpp_info.includedirs = []
        self.cpp_info.libdirs = []
        self.output.info("Using system CMake for LoongArch64 adapter")
EOF
conan export-pkg . cmake/3.30.5@ -s os=Linux -s arch=loongarch64
rm -f conanfile.py

echo "done"
