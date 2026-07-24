#!/bin/bash
set -eou pipefail

UPSTREAM_OWNER=milvus-io
UPSTREAM_REPO=milvus

# 最新的 release
#curl -s https://api.github.com/repos/"$UPSTREAM_OWNER"/"$UPSTREAM_REPO"/releases/latest \
#     | jq -r ".tag_name"

# 最新的 tag
git ls-remote --tags https://github.com/${UPSTREAM_OWNER}/${UPSTREAM_REPO}.git \
    | cut -d'/' -f3- \
    | cut -d'^' -f1 \
    | grep -E '^v[0-9]{1,2}.[0-9]+.[0-9]+$' \
    | sort -V \
    | uniq \
    | tail -1
