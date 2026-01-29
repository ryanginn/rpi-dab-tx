#!/bin/bash
#
# install.sh - Install the ODR-mmbTools software stack
# Copyright (C) 2023 StefCodes (stefcodes.co.uk)
#
# Licensed under the GNU General Public License v3.0 or later.
# See: https://www.gnu.org/licenses/gpl-3.0.en.html
#

set -euo pipefail

# Variables
HOME_DIR="${HOME}"
TOOLS_DIR="${HOME_DIR}/ODR-mmbTools"
CONFIG_DIR="${HOME_DIR}/dab"
SUPERVISOR_CONF="/etc/supervisor/supervisord.conf"
SUPERVISOR_PORT=8001

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# --- Functions ---
confirm() {
  read -p "Are you sure? This will take 1+ hours! (Y/N): " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo -e "${RED}Installation cancelled.${NC} Script by StefCodes."
    exit 1
  fi
}

check_error() {
  if [[ $? -ne 0 ]]; then
    echo -e "${RED}Error during: $1. Exiting.${NC}"
    exit 1
  fi
}

install_git_repo() {
  local repo_url=$1
  local folder_name=$2
  shift 2
  # Collect remaining arguments as flags
  local config_flags=("$@")

  echo -e "${GREEN}Processing $folder_name...${NC}"

  if [[ ! -d $folder_name ]]; then
    git clone "$repo_url" "$folder_name"
    check_error "cloning $folder_name"
  fi

  pushd "$folder_name" >/dev/null
  
  # Smart detection of bootstrap scripts
  if [[ -f "./bootstrap" ]]; then
    ./bootstrap
  elif [[ -f "./bootstrap.sh" ]]; then
    ./bootstrap.sh
  elif [[ -f "./autogen.sh" ]]; then
    ./autogen.sh
  else
    autoreconf -fi
  fi
  check_error "bootstrap in $folder_name"

  # Run configure with flags passed as an array to handle spaces/quotes correctly
  ./configure "${config_flags[@]}"
  check_error "configure in $folder_name"

  make -j"$(nproc)"
  check_error "make in $folder_name"

  sudo make install
  check_error "make install in $folder_name"
  
  sudo ldconfig
  popd >/dev/null
}

# --- Script starts here ---
confirm
echo -e "${GREEN}Starting installation...${NC}"

# Update system
echo "Updating system and installing dependencies..."
sudo apt-get update && sudo apt-get upgrade -y
check_error "system update/upgrade"

# Fixed: Added libboost-all-dev, libfftw3-dev, and libasound2-dev (now required by ODR)
sudo apt-get install -y \
  build-essential automake autoconf libtool git pkg-config \
  libboost-all-dev libzmq3-dev libzmq5 libfftw3-dev libasound2-dev \
  libvlc-dev vlc-data vlc-plugin-base libcurl4-openssl-dev \
  supervisor python3-pip python3-cherrypy3 python3-jinja2 \
  python3-serial python3-yaml python3-pysnmp4
check_error "package installation"

# Python packages
echo "Installing Python packages..."
# Fixed: pyyaml>=6.0.1 is required for Python 3.12+
pip_packages=("cherrypy" "jinja2" "pysnmp" "pyyaml>=6.0.1")
for package in "${pip_packages[@]}"; do
  sudo pip install --break-system-packages "$package"
  check_error "pip package ($package)"
done

# Prepare directories
echo "Creating tools directory at $TOOLS_DIR..."
mkdir -p "$TOOLS_DIR"
pushd "$TOOLS_DIR" >/dev/null

# Install repositories
echo "Installing ODR-mmbTools..."
# Note: fdk-aac first so others can link to it
install_git_repo "https://github.com/Opendigitalradio/fdk-aac.git" "fdk-aac"
install_git_repo "https://github.com/Opendigitalradio/ODR-AudioEnc.git" "ODR-AudioEnc" "--enable-vlc"
install_git_repo "https://github.com/Opendigitalradio/ODR-PadEnc.git" "ODR-PadEnc"
install_git_repo "https://github.com/Opendigitalradio/ODR-DabMux.git" "ODR-DabMux"

# Fixed the quoting for ODR-DabMod to prevent "unrecognized option" error
install_git_repo "https://github.com/Opendigitalradio/ODR-DabMod.git" "ODR-DabMod" \
  "CFLAGS=-O3 -DNDEBUG" "CXXFLAGS=-O3 -DNDEBUG" "--enable-fast-math" "--disable-output-uhd" "--disable-zeromq"

install_git_repo "https://github.com/Opendigitalradio/ODR-SourceCompanion.git" "ODR-SourceCompanion"

# User group setup
echo "Adding user to required groups..."
sudo usermod --append --group dialout "$(id -un)"
sudo usermod --append --group audio "$(id -un)"

# Supervisor config
if ! grep -q "inet_http_server" "$SUPERVISOR_CONF"; then
  echo "Configuring Supervisor HTTP server..."
  sudo tee -a "$SUPERVISOR_CONF" >/dev/null <<EOF
[inet_http_server]
port = ${SUPERVISOR_PORT}
username = odr
password = odr
EOF
fi

echo "Linking Supervisor configuration files..."
mkdir -p "${CONFIG_DIR}/supervisor/"
if ls "${CONFIG_DIR}/supervisor/"*.conf >/dev/null 2>&1; then
    sudo ln -sf "${CONFIG_DIR}/supervisor/"*.conf /etc/supervisor/conf.d/
fi

sudo supervisorctl reread || true
sudo supervisorctl reload || true

popd >/dev/null
echo -e "${GREEN}Installation complete. Script by StefCodes.${NC}"
