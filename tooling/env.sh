# env.sh — environment for the shared toolchains (README.md). POSIX sh. Source it
# from the host's shell startup and the container's ~/.zshenv, and nothing else:
#   . /opt/tooling/env.sh
# Preset either root to point elsewhere (e.g. a TOOLING_PREFIX test install);
# everything else derives from them, one file per tool in env/.
: "${TOOLING_ROOT:=/opt/tooling}"
: "${WORKSPACE_ROOT:=/opt/workspace}"
export TOOLING_ROOT WORKSPACE_ROOT

case ":$PATH:" in
    *":$TOOLING_ROOT/bin:"*) ;;
    *) PATH="$TOOLING_ROOT/bin:$PATH"; export PATH ;;
esac

for _tooling_env in "$TOOLING_ROOT"/env/*.sh; do
    [ -r "$_tooling_env" ] && . "$_tooling_env"
done
unset _tooling_env
