FROM lcr.loongnix.cn/openeuler/openeuler:24.03

RUN sed -i '/\[update-source\]/,$d' /etc/yum.repos.d/openEuler.repo 
RUN sed -i "s#openEuler-24.03-LTS/#openEuler-24.03-LTS-SP3/#" /etc/yum.repos.d/openEuler.repo

RUN dnf install -y \
    wget curl which git make automake autoconf libtool m4 \
    python3 python3-devel python3-pip libatomic-static \
    gcc gcc-c++ gcc-gfortran libstdc++-static simde-devel \
    go cmake cargo clang clang-tools-extra xxhash-devel \
    openblas-devel libaio libaio-devel libuuid-devel \
    zlib-devel openssl-devel boost-devel ccache zip unzip \
    && rm -rf /var/lib/apt/lists/*

RUN pip3 install jinja2==3.1.3 conan==1.64.1

WORKDIR /workspace

CMD ["/bin/bash"]
