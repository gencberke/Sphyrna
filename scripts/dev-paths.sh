# Sourced by the zsh scripts. Packages, fixtures and build scratch must live
# outside ~/Documents: every run host is its own TCC-responsible app, and a
# scoped child that executes a binary under ~/Documents blocks on a consent
# prompt (plans/cp5/OWN.md).
loom_default_app="$HOME/Library/Application Support/Loom-Dev/app/Loom Dev.app"
loom_default_scratch="$HOME/Library/Caches/loom-dev-build"

# loom_refuse_documents <label> <path>: stops the script when the path is
# (or resolves to) a location under ~/Documents.
loom_refuse_documents() {
  local resolved=${2:A} documents=${HOME:A}/Documents
  if [[ $resolved == $documents || $resolved == $documents/* ]]; then
    echo "$1 '$2' is under ~/Documents. Run hosts are separate TCC-responsible apps and block on a Documents consent prompt there. Use a path under ~/Library (default: ~/Library/Application Support/Loom-Dev/app)." >&2
    exit 2
  fi
}

# Release products and dsymutil stay out of ~/Documents unless the caller chose a scratch path.
loom_scratch_path() {
  local scratch=${LOOM_SCRATCH_PATH:-$loom_default_scratch}
  loom_refuse_documents "LOOM_SCRATCH_PATH" "$scratch"
  print -r -- "$scratch"
}

# Evidence command channel (Sources/LoomLaunchOptions): one distributed
# notification name per evidence directory, so concurrent evidence instances
# never hear each other's commands. The name is derived from the real path.
loom_command_channel() { # <evidence dir>
  mkdir -p "$1"
  local real
  real=$(cd "$1" && pwd -P) || return 1
  print -rn -- "$real" | shasum -a 256 | cut -c1-16 | sed 's/^/local.loom.desktop.dev.command./'
}

# loom_send_command <evidence dir> <command>
loom_send_command() {
  local channel
  channel=$(loom_command_channel "$1") || return 1
  osascript -l JavaScript -e "ObjC.import('Foundation'); \$.NSDistributedNotificationCenter.defaultCenter.postNotificationNameObjectUserInfoDeliverImmediately('$channel', '$2', \$(), true)" >/dev/null
}
