# Dependency installation router for iNiR
# This script is meant to be sourced.

# shellcheck shell=bash

printf "${STY_CYAN}[$0]: 1. Install dependencies${STY_RST}\n"

#####################################################################################
# Route to the appropriate installer based on OS
#####################################################################################

_install_target="$(inir_install_compositor_service 2>/dev/null || true)"
if [[ "$_install_target" == "umbriel-session.target" && "$OS_GROUP_ID" != "arch" ]]; then
  if command -v umbriel >/dev/null 2>&1; then
    tui_warn "Umbriel is already installed, but automated non-Arch dependency routing is not compositor-safe yet."
  else
    tui_warn "Automatic Umbriel compositor installation is currently supported only on Arch-based systems."
  fi
  tui_info "Install Umbriel and the runtime dependencies for your distro, then rerun: ./setup install --compositor umbriel --skip-deps"
  return 1
fi

case "$OS_GROUP_ID" in
  arch)
    printf "${STY_GREEN}Using Arch Linux installer${STY_RST}\n"
    source ./sdata/dist-arch/install-deps.sh
    ;;
    
  fedora)
    printf "${STY_GREEN}Using Fedora installer${STY_RST}\n"
    source ./sdata/dist-fedora/install-deps.sh
    ;;
    
  debian|ubuntu)
    printf "${STY_GREEN}Using Debian/Ubuntu installer${STY_RST}\n"
    source ./sdata/dist-debian/install-deps.sh
    ;;
    
  opensuse)
    printf "${STY_YELLOW}openSUSE support is experimental${STY_RST}\n"
    printf "${STY_YELLOW}Using generic installer with guidance${STY_RST}\n"
    source ./sdata/dist-generic/install-deps.sh
    ;;
    
  void)
    printf "${STY_YELLOW}Void Linux support is experimental${STY_RST}\n"
    printf "${STY_YELLOW}Using generic installer with guidance${STY_RST}\n"
    source ./sdata/dist-generic/install-deps.sh
    ;;
    
  gentoo)
    printf "${STY_YELLOW}Gentoo support requires manual configuration${STY_RST}\n"
    printf "${STY_YELLOW}Using generic installer with guidance${STY_RST}\n"
    source ./sdata/dist-generic/install-deps.sh
    ;;
    
  nixos)
    printf "${STY_YELLOW}NixOS requires declarative configuration${STY_RST}\n"
    echo ""
    echo "For NixOS, add iNiR to your configuration.nix or home-manager."
    echo "See: https://github.com/snowarch/inir/wiki/NixOS"
    echo ""
    echo "Basic steps:"
    echo "  1. Add quickshell and niri to your system packages"
    echo "  2. Clone this repo to ~/.config/quickshell/inir"
    echo "  3. Run: ./setup install --skip-deps"
    echo ""
    
    if $ask; then
      read -p "Continue with --skip-deps? [y/N]: " choice
      if [[ ! "$choice" =~ ^[yY]$ ]]; then
        exit 0
      fi
    fi
    
    # Skip to file installation
    return 0
    ;;
    
  alpine)
    printf "${STY_YELLOW}Alpine Linux support is experimental${STY_RST}\n"
    printf "${STY_YELLOW}Using generic installer with guidance${STY_RST}\n"
    source ./sdata/dist-generic/install-deps.sh
    ;;
    
  generic|*)
    printf "${STY_YELLOW}Using generic installer${STY_RST}\n"
    source ./sdata/dist-generic/install-deps.sh
    ;;
esac
