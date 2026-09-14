# go: never download the toolchain a go.mod asks for, or host and container drift.
export GOTOOLCHAIN=local
export GOPATH="$WORKSPACE_ROOT/cache/go"
export GOMODCACHE="$GOPATH/mod"
export GOCACHE="$GOPATH/build"
