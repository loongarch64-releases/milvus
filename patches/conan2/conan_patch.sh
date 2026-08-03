#!/bin/bash

if [ $# -ne 2 ]; then
    echo "need paths of milvus and patches"
    exit 1
fi

src=$1
patches=$2

echo "preparing conan2 env..."

pip3 install conan==2.25.1

# 仓库
CONAN_REPO=$(grep -E '^\s*CONAN_ARTIFACTORY_URL=' "$src/scripts/3rdparty_build.sh" | head -n1)
eval "$CONAN_REPO"
conan remote add default-conan-local2 "$CONAN_ARTIFACTORY_URL" --force --index 0

# conan2 架构列表添加 loongarch64
sed -i "s/arch: \[/arch: \[loongarch64, /" "$HOME/.conan2/settings.yml"

# conanfile for loongarch
conan profile detect --name loongarch --force
sed -i "s/x86_64/loongarch64/" "$HOME/.conan2/profiles/loongarch"
# 使用系统 cmake
cat << 'EOF' >> "$HOME/.conan2/profiles/loongarch"
[platform_tool_requires]
cmake/3.27.9
EOF

# 处理 conan2 管理的三方包 config 过旧情况
CONAN2_HOOK_DIR="$(conan config home)/extensions/hooks"
mkdir -p "${CONAN2_HOOK_DIR}"

cat > "${CONAN2_HOOK_DIR}/hook_loongarch.py" << EOF
import os
import shutil

def pre_build(conanfile, **kwargs):
    source_folder = getattr(conanfile, "source_folder", None)
    if not source_folder or not os.path.isdir(source_folder):
        return
    conanfile.output.info(
        f"LoongArch Fix: patching config.guess/config.sub for {conanfile.name}"
    )
    for root, _, files in os.walk(source_folder):
        for f in ("config.guess", "config.sub"):
            if f not in files:
                continue
            patch_src = os.path.join("${patches}", f)
            target = os.path.join(root, f)
            if os.path.isfile(patch_src):
                shutil.copy2(patch_src, target)
EOF

echo "done"
