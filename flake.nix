{
  description = "Sewa Companion — Tauri v2 desktop companion";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in
    {
      devShells.${system}.default = pkgs.mkShell {
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
          atk

          # TLS
          openssl
          openssl.dev

          # Rust toolchain
          rustc
          cargo
          cargo-tauri

          # Node.js
          nodejs_20
        ];

        shellHook = ''
          export PKG_CONFIG_PATH="$(pkg-config --variable pc_path pkg-config):$PKG_CONFIG_PATH"

          # OpenSSL
          export OPENSSL_DIR="${pkgs.openssl.dev}"
          export OPENSSL_LIB_DIR="${pkgs.openssl.out}/lib"
          export OPENSSL_INCLUDE_DIR="${pkgs.openssl.dev}/include"

          # GIO/gobject-introspection
          export GIO_MODULE_DIR="${pkgs.glib}/lib/gio/modules"
          export GI_TYPELIB_PATH="${pkgs.gobject-introspection}/lib/girepository-1.0"

          echo "Sewa Companion dev shell ready."
          echo "  rustc:        $(rustc --version)"
          echo "  cargo:        $(cargo --version)"
          echo "  cargo-tauri:  $(cargo tauri --version)"
          echo "  node:         $(node --version)"
        '';
      };
    };
}
