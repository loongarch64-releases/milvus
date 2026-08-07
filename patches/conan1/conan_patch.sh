#!/bin/bash

if [ $# -ne 2 ]; then
    echo "need paths of milvus and patches"
    exit 1
fi

src=$1
patches=$2

echo "preparing conan env..."

pip3 install conan==1.64.1

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

# conan 架构列表添加 loongarch64
sed -i "s/arch_build: \[/arch_build: \[loongarch64, /" "$HOME/.conan/settings.yml"
sed -i "s/arch: \[/arch: \[loongarch64, /" "$HOME/.conan/settings.yml"


# 处理 conan 管理的三方包 config 过旧情况
cat > hook_loongarch.py << 'EOF'
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
mv hook_loongarch.py "$HOME/.conan/hooks/"
conan config set hooks.loongarch_hook


echo "done"
