#!/bin/bash

hub=""
tag=""
debug_suffix=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --tag|-tag) tag="$2"; shift ;;
        --hub|-hub) hub="$2"; shift ;;
        --debug|-debug) debug_suffix="_debug";;
    esac
    shift
done

function die() {
    echo $@
    exit 1
}

echo ${tag}

[[ -z ${tag} ]] && die "--tag not set"
[[ -z ${hub} ]] && die "--hub not set"

set -ex

if [[ "$hub" =~ ^gcr\.io ]]; then
  gcloud docker --authorize-only
fi

for image in app init proxy manager; do
  bazel $BAZEL_ARGS run //docker:$image$debug_suffix
  docker tag istio/docker:$image$debug_suffix $hub/$image:$tag
  docker push $hub/$image:$tag
done
