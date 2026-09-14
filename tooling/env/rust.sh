# rust: toolchains are shared and read-only; cargo's registry, git checkouts and
# `cargo install` output go to the workspace cache.
export RUSTUP_HOME="$TOOLING_ROOT/rustup"
export CARGO_HOME="$WORKSPACE_ROOT/cache/cargo"
