#!/bin/bash
set -e  # 遇到错误时立即退出

echo "Starting postCreateCommand..."

# 检查 Homebrew 是否可用
if ! command -v brew &> /dev/null; then
    echo "Error: Homebrew is not installed or not in PATH."
    exit 1
fi

echo "Installing qwen-code..."
brew install qwen-code

echo "Unlinking node..."
brew unlink node

echo "postCreateCommand completed."