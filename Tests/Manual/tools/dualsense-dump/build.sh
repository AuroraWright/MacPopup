#!/bin/sh
# Builds dualsense-dump next to this script: sh build.sh
cd "$(dirname "$0")" || exit 1
swiftc -O -o dualsense-dump dualsense-dump.swift && echo "Built $(pwd)/dualsense-dump"
