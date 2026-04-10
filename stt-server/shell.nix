{ pkgs ? import <nixpkgs> {} }:

let
  python = pkgs.python313.withPackages (ps: with ps; [
    numpy
    sherpa-onnx
  ]);
in
pkgs.mkShell {
  name = "parakeet-stt-server";
  buildInputs = [
    python
    pkgs.ffmpeg
  ];
  shellHook = ''
    if [ ! -d .venv ]; then
      python -m venv .venv --system-site-packages
      .venv/bin/pip install -q websockets
    fi
    source .venv/bin/activate
    echo "Parakeet STT server shell ready."
    echo "  python: $(python --version)"
    echo "  Run: python parakeet_stt_server.py"
  '';
}
