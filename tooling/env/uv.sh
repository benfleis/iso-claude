# uv: one Python install dir for both sides, so a venv built on either side finds
# its interpreter on the other (README.md).
export UV_CACHE_DIR="$WORKSPACE_ROOT/cache/uv"
export UV_PYTHON_INSTALL_DIR="$WORKSPACE_ROOT/cache/uv-python"
