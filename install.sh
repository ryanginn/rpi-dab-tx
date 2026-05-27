#!/bin/bash
#
# install.sh - Install the ODR-mmbTools software stack (Enhanced Version)
# Copyright (C) 2023-2026 StefCodes
#
# Licensed under the GNU General Public License v3.0 or later.
# See: https://www.gnu.org/licenses/gpl-3.0.en.html
#

set -euo pipefail

# Variables
HOME_DIR="${HOME}"
TOOLS_DIR="${HOME_DIR}/ODR-mmbTools"
CONFIG_DIR="${HOME_DIR}/dab"
SCRIPT_SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUPERVISOR_CONF="/etc/supervisor/supervisord.conf"
SUPERVISOR_PORT=8001
CURRENT_USER="$(id -un)"

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
  local checkout_branch=${3:-""}
  shift 3
  local config_flags=("$@")

  echo -e "${GREEN}Processing $folder_name...${NC}"

  if [[ ! -d $folder_name ]]; then
    git clone "$repo_url" "$folder_name"
    check_error "cloning $folder_name"
  fi

  pushd "$folder_name" >/dev/null
  
  # Handle specific branch checkout if requested
  if [[ -n "$checkout_branch" ]]; then
    echo "Checking out branch/tag: $checkout_branch"
    git checkout "$checkout_branch"
    check_error "git checkout $checkout_branch in $folder_name"
  fi

  # Force a clean to ensure MagickWand/GStreamer is detected properly if re-running
  if [[ -f "Makefile" ]]; then
    make clean || true
  fi

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

# Combined dependency list including both original packages and new multimedia/utility frameworks
sudo apt-get install -y \
  build-essential automake autoconf libtool git pkg-config wget \
  sox alsa-tools alsa-utils mpg123 ncdu vim ntp links cpufrequtils \
  libboost-all-dev libboost-system-dev libzmq3-dev libzmq5 libfftw3-dev libasound2-dev \
  libvlc-dev vlc-data vlc-plugin-base libcurl4-openssl-dev \
  libmagickwand-dev libfaad2 libfaad-dev python3-mako \
  libjack-jackd2-dev jackd2 \
  gstreamer1.0-plugins-bad gstreamer1.0-plugins-base gstreamer1.0-plugins-good gstreamer1.0-plugins-ugly \
  libgstreamer-plugins-bad1.0-dev libgstreamer-plugins-base1.0-dev libgstreamer1.0-dev \
  supervisor python3-pip python3-cherrypy3 python3-jinja2 \
  python3-serial python3-yaml python3-pysnmp4
check_error "package installation"

# Python packages
echo "Installing Python packages..."
pip_packages=("cherrypy" "jinja2" "pysnmp" "pyyaml>=6.0.1")
for package in "${pip_packages[@]}"; do
  sudo pip install --break-system-packages "$package"
  check_error "pip package ($package)"
done

# Prepare tools directory
mkdir -p "$TOOLS_DIR"

# Handle the DAB configuration directory
if [[ -d "$CONFIG_DIR" ]]; then
    echo -e "${GREEN}Directory $CONFIG_DIR already exists. Skipping copy to prevent overwriting your configs.${NC}"
else
    echo "Creating directory structure at $CONFIG_DIR..."
    mkdir -p "$CONFIG_DIR/supervisor"
    mkdir -p "$CONFIG_DIR/logs"

    echo "Searching for source 'dab' folder in $SCRIPT_SRC_DIR..."
    if [[ -d "${SCRIPT_SRC_DIR}/dab" ]]; then
        echo "Found source folder. Copying contents..."
        cp -rv "${SCRIPT_SRC_DIR}/dab/"* "$CONFIG_DIR/"
        
        # Patch configurations for the current user
        echo "Patching configurations: replacing user 'pi' with '$CURRENT_USER'..."
        find "$CONFIG_DIR" -type f -name "*.conf" -exec sed -i "s/user=pi/user=$CURRENT_USER/g" {} +
        find "$CONFIG_DIR" -type f -name "*.conf" -exec sed -i "s/\/home\/pi/\/home\/$CURRENT_USER/g" {} +
        
        sudo chown -R "$(id -u):$(id -g)" "$CONFIG_DIR"
        echo "Files copied and patched successfully."
    else
        echo -e "${RED}Warning: Source 'dab' folder NOT FOUND at ${SCRIPT_SRC_DIR}/dab. Skipping copy.${NC}"
    fi
fi

# Install repositories
pushd "$TOOLS_DIR" >/dev/null

# 1. fdk-aac (First checkout dabplus, build/install, then dabplus2)
install_git_repo "https://github.com/Opendigitalradio/fdk-aac.git" "fdk-aac" "dabplus"
install_git_repo "https://github.com/Opendigitalradio/fdk-aac.git" "fdk-aac" "dabplus2"

# 2. ODR-AudioEnc (using 'next' branch and explicit options for alsa, jack, vlc, and gst)
install_git_repo "https://github.com/Opendigitalradio/ODR-AudioEnc.git" "ODR-AudioEnc" "next" \
  "--enable-alsa" "--enable-jack" "--enable-vlc" "--enable-gst"

# 3. ODR-PadEnc
install_git_repo "https://github.com/Opendigitalradio/ODR-PadEnc.git" "ODR-PadEnc" ""

# 4. ODR-DabMux
install_git_repo "https://github.com/Opendigitalradio/ODR-DabMux.git" "ODR-DabMux" ""

# 5. ODR-DabMod (keeping original high-performance compilation flags)
install_git_repo "https://github.com/Opendigitalradio/ODR-DabMod.git" "ODR-DabMod" "" \
  "CFLAGS=-O3 -DNDEBUG" "CXXFLAGS=-O3 -DNDEBUG" "--enable-fast-math" "--disable-output-uhd" "--disable-zeromq"

# 6. ODR-SourceCompanion
install_git_repo "https://github.com/Opendigitalradio/ODR-SourceCompanion.git" "ODR-SourceCompanion" ""

# 7. digris-edi-zmq-bridge (Added from the secondary script stack)
install_git_repo "https://github.com/digris/digris-edi-zmq-bridge" "digris-edi-zmq-bridge" ""

popd >/dev/null

# User group setup
echo "Adding user to required groups..."
sudo usermod --append --group dialout "$CURRENT_USER"
sudo usermod --append --group audio "$CURRENT_USER"

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

# Link Supervisor configuration files
echo "Linking configuration files to Supervisor..."
if ls "${CONFIG_DIR}/supervisor/"*.conf >/dev/null 2>&1; then
    sudo ln -sf "${CONFIG_DIR}/supervisor/"*.conf /etc/supervisor/conf.d/
    echo "Links created successfully."
else
    echo -e "${RED}Warning: No .conf files found in ${CONFIG_DIR}/supervisor/ to link.${NC}"
fi

echo "Restarting Supervisor..."
sudo systemctl restart supervisor
sleep 2
sudo supervisorctl reread
sudo supervisorctl update

# Optional clean-up stage for compilation source trees
echo "--------------------------------------------------------"
read -p "Do you want to remove the cloned source code repositories from ODR-mmbTools folder? (y/n): " choice
if [[ "$choice" == "y" || "$choice" == "Y" ]]; then
    rm -rf "$TOOLS_DIR/fdk-aac" \
           "$TOOLS_DIR/ODR-AudioEnc" \
           "$TOOLS_DIR/ODR-PadEnc" \
           "$TOOLS_DIR/ODR-DabMux" \
           "$TOOLS_DIR/ODR-DabMod" \
           "$TOOLS_DIR/ODR-SourceCompanion" \
           "$TOOLS_DIR/digris-edi-zmq-bridge"
    echo "Source code directories cleaned up."
fi

echo -e "${GREEN}Installation complete. Configuration preserved at: $CONFIG_DIR${NC}"
