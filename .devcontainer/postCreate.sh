#!/usr/bin/env bash
set -euo pipefail

if command -v sudo >/dev/null 2>&1; then
  SUDO="sudo"
else
  SUDO=""
fi

KUBECTL_TARGET_SERIES="1.23"
KUBECTL_TARGET_VERSION="1.23.17"
KUBECTL_AMD64_SHA256="f09f7338b5a677f17a9443796c648d2b80feaec9d6a094ab79a77c8a01fde941"
KUBECTL_ARM64_SHA256="c4a48fdc6038beacbc5de3e4cf6c23639b643e76656aabe2b7798d3898ec7f05"
HELM_TARGET_VERSION="3.15.4"
HELM_AMD64_SHA256="11400fecfc07fd6f034863e4e0c4c4445594673fd2a129e701fe41f31170cfa9"
HELM_ARM64_SHA256="fa419ecb139442e8a594c242343fafb7a46af3af34041c4eac1efcc49d74e626"
BREW_TOOLING_TAP="local/devcontainer-tools"

apt_update_with_recovery() {
  ${SUDO} apt-get update
}

install_docker_cli() {
  if command -v docker >/dev/null 2>&1 && docker buildx version >/dev/null 2>&1; then
    echo "docker cli and buildx already installed, skip install."
    return
  fi

  apt_update_with_recovery
  ${SUDO} apt-get install -y ca-certificates curl gnupg

  ${SUDO} install -m 0755 -d /etc/apt/keyrings
  if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
    curl -fsSL https://download.docker.com/linux/debian/gpg | ${SUDO} gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    ${SUDO} chmod a+r /etc/apt/keyrings/docker.gpg
  fi

  . /etc/os-release
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian ${VERSION_CODENAME} stable" \
    | ${SUDO} tee /etc/apt/sources.list.d/docker.list >/dev/null

  apt_update_with_recovery
  ${SUDO} apt-get install -y docker-ce-cli docker-buildx-plugin docker-compose-plugin
}

configure_docker_socket_group() {
  local socket_path="/var/run/docker.sock"
  local current_user="${USER:-$(id -un)}"

  if [ ! -S "${socket_path}" ]; then
    echo "warning: ${socket_path} not found, skip group configuration."
    return
  fi

  local socket_gid
  socket_gid="$(stat -c '%g' "${socket_path}")"

  local group_name
  group_name="$(getent group "${socket_gid}" | cut -d: -f1 || true)"
  if [ -z "${group_name}" ]; then
    group_name="docker-host"
    if getent group "${group_name}" >/dev/null 2>&1; then
      group_name="docker-host-${socket_gid}"
    fi
    ${SUDO} groupadd --gid "${socket_gid}" "${group_name}"
  fi

  if ! id -nG "${current_user}" | tr ' ' '\n' | grep -qx "${group_name}"; then
    ${SUDO} usermod -aG "${group_name}" "${current_user}"
    echo "added ${current_user} to group ${group_name}."
    echo "reopen terminal or rebuild container to refresh group membership."
  fi
}

validate_docker_tools() {
  docker --version
  docker buildx version || true
  docker version || true
}

get_kubectl_version() {
  if ! command -v kubectl >/dev/null 2>&1; then
    return 1
  fi

  kubectl version --client --output=yaml 2>/dev/null \
    | awk '/gitVersion:/ {print $2}' \
    | head -n 1 \
    | sed 's/^v//'
}

get_helm_version() {
  if ! command -v helm >/dev/null 2>&1; then
    return 1
  fi

  helm version --short 2>/dev/null \
    | sed -E 's/^v([0-9]+\.[0-9]+\.[0-9]+).*/\1/'
}

ensure_local_brew_k8s_formulas() {
  if ! brew tap | grep -qx "${BREW_TOOLING_TAP}"; then
    brew tap-new "${BREW_TOOLING_TAP}"
  fi

  local tap_repo
  tap_repo="$(brew --repository "${BREW_TOOLING_TAP}")"
  local formula_dir="${tap_repo}/Formula"
  mkdir -p "${formula_dir}"

  cat > "${formula_dir}/kubectl@${KUBECTL_TARGET_SERIES}.rb" <<EOF
class KubectlAT123 < Formula
  desc "Kubernetes command-line interface"
  homepage "https://kubernetes.io/"
  license "Apache-2.0"
  version "${KUBECTL_TARGET_VERSION}"

  if Hardware::CPU.arm?
    url "https://dl.k8s.io/release/v${KUBECTL_TARGET_VERSION}/bin/linux/arm64/kubectl"
    sha256 "${KUBECTL_ARM64_SHA256}"
  else
    url "https://dl.k8s.io/release/v${KUBECTL_TARGET_VERSION}/bin/linux/amd64/kubectl"
    sha256 "${KUBECTL_AMD64_SHA256}"
  end

  def install
    bin.install "kubectl"
  end

  test do
    assert_match "Client Version", shell_output("#{bin}/kubectl version --client --short 2>&1")
  end
end
EOF

  cat > "${formula_dir}/helm@${HELM_TARGET_VERSION}.rb" <<EOF
class HelmAT3154 < Formula
  desc "Kubernetes package manager"
  homepage "https://helm.sh/"
  license "Apache-2.0"
  version "${HELM_TARGET_VERSION}"

  if Hardware::CPU.arm?
    url "https://get.helm.sh/helm-v${HELM_TARGET_VERSION}-linux-arm64.tar.gz"
    sha256 "${HELM_ARM64_SHA256}"
  else
    url "https://get.helm.sh/helm-v${HELM_TARGET_VERSION}-linux-amd64.tar.gz"
    sha256 "${HELM_AMD64_SHA256}"
  end

  def install
    helm_binary = Dir["**/helm"].first
    odie "helm binary not found in extracted archive" if helm_binary.nil?
    bin.install helm_binary => "helm"
  end

  test do
    assert_match "v${HELM_TARGET_VERSION}", shell_output("#{bin}/helm version --short 2>&1")
  end
end
EOF
}

install_kubernetes_tools() {
  ensure_local_brew_k8s_formulas

  if brew list --formula "kubectl@${KUBECTL_TARGET_SERIES}" >/dev/null 2>&1; then
    echo "kubectl@${KUBECTL_TARGET_SERIES} already installed, skip install."
  else
    brew install "${BREW_TOOLING_TAP}/kubectl@${KUBECTL_TARGET_SERIES}"
  fi
  brew unlink kubernetes-cli >/dev/null 2>&1 || true
  brew link --overwrite --force "kubectl@${KUBECTL_TARGET_SERIES}"
  brew pin "kubectl@${KUBECTL_TARGET_SERIES}" >/dev/null 2>&1 || true

  if brew list --formula "helm@${HELM_TARGET_VERSION}" >/dev/null 2>&1; then
    echo "helm@${HELM_TARGET_VERSION} already installed, skip install."
  else
    brew install "${BREW_TOOLING_TAP}/helm@${HELM_TARGET_VERSION}"
  fi
  brew unlink helm >/dev/null 2>&1 || true
  brew unlink helm@3 >/dev/null 2>&1 || true
  brew link --overwrite --force "helm@${HELM_TARGET_VERSION}"
  brew pin "helm@${HELM_TARGET_VERSION}" >/dev/null 2>&1 || true

  local kubectl_version
  kubectl_version="$(get_kubectl_version || true)"
  if [[ "${kubectl_version}" == "${KUBECTL_TARGET_SERIES}"* ]]; then
    echo "kubectl ${kubectl_version} ready."
  else
    echo "warning: kubectl expected ${KUBECTL_TARGET_SERIES}.x (using ${KUBECTL_TARGET_VERSION}) but got ${kubectl_version:-not installed}."
  fi

  local helm_version
  helm_version="$(get_helm_version || true)"
  if [ "${helm_version}" = "${HELM_TARGET_VERSION}" ]; then
    echo "helm ${helm_version} ready."
  else
    echo "warning: helm expected ${HELM_TARGET_VERSION} but got ${helm_version:-not installed}."
  fi
}

install_existing_tools() {
  if ! command -v brew >/dev/null 2>&1; then
    echo "warning: Homebrew is not installed or not in PATH, skip brew-based tools."
    return
  fi

  echo "Installing version-pinned kubectl/helm..."
  install_kubernetes_tools

  echo "Installing qwen-code..."
  if brew list --formula qwen-code >/dev/null 2>&1; then
    echo "qwen-code already installed, skip."
  else
    brew install qwen-code
  fi

  echo "Installing codex ccman..."
  npm install -g ccman @openai/codex

  if brew list --formula node >/dev/null 2>&1; then
    echo "Unlinking node..."
    brew unlink node || true
  else
    echo "brew-managed node not found, skip unlink."
  fi
}

install_docker_cli
configure_docker_socket_group
validate_docker_tools
install_existing_tools
