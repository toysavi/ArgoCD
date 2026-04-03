#!/bin/bash

check_kubectl() {
    if ! command -v kubectl &>/dev/null; then
        echo "[ERROR] kubectl not found"
        exit 1
    fi
}

namespace_exists() {
    kubectl get ns "$1" &>/dev/null
}