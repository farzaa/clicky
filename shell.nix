{ pkgs ? import <nixpkgs> {} }:

pkgs.mkShell {
  name = "sewa-companion-dev";

  nativeBuildInputs = with pkgs; [
    pkg-config
    gobject-introspection
  ];

  buildInputs = with pkgs; [
    # Tauri v2 GTK/WebKit stack
    webkitgtk_4_1
    gtk3
    libsoup_3
    glib
    cairo
    pango
    gdk-pixbuf
    atk         # alias for at-spi2-core

    # TLS
    openssl
    openssl.dev

    # Rust toolchain
    rustc
    cargo
    cargo-tauri

    # Node.js (18+ required; 20 is LTS available in nixpkgs)
    nodejs_20
  ];

  # Required so pkg-config can find the GTK/WebKit headers.
  # Nix puts .pc files under lib/pkgconfig; collect all buildInputs.
  shellHook = ''
    export PKG_CONFIG_PATH="$(pkg-config --variable pc_path pkg-config):$PKG_CONFIG_PATH"

    # OpenSSL — required by both cargo and tauri-cli
    export OPENSSL_DIR="${pkgs.openssl.dev}"
    export OPENSSL_LIB_DIR="${pkgs.openssl.out}/lib"
    export OPENSSL_INCLUDE_DIR="${pkgs.openssl.dev}/include"

    # GIO/gobject-introspection typelib path (needed by some tauri helpers)
    export GIO_MODULE_DIR="${pkgs.glib}/lib/gio/modules"
    export GI_TYPELIB_PATH="${pkgs.gobject-introspection}/lib/girepository-1.0"

    echo "Tauri v2 NixOS shell ready."
    echo "  rustc:        $(rustc --version)"
    echo "  cargo:        $(cargo --version)"
    echo "  cargo-tauri:  $(cargo tauri --version)"
    echo "  node:         $(node --version)"
  '';
}
