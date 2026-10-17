# Sourced by the in-container test scripts (POSIX sh: dash on Ubuntu/Debian, bash as sh on Fedora). Failures become
# GitHub error annotations, which the run page shows without opening the job log; package installs are retried when the
# error is one a mirror can cause.
#
#   CI_CONTEXT="AppImage on $PRETTY_NAME"   prefix of every annotation
#   ci_trap                                 annotate any other non-zero exit (set -e) with the current CI_STEP
#   CI_STEP=...                             what runs now, for that annotation
#   die_log <log> <step> [rc]               end of the log, an annotation with its error line, exit 1
#   fail <message>                          an annotation, exit 1
#   warn <message>                          a warning annotation
#   retry_install <log> <label> <command>   run a shell command up to 3 times (15 min each), logging every attempt
#   docker_pull <image> [platform args]     docker pull with retries (on the runner, outside a container)

CI_CONTEXT=${CI_CONTEXT:-CI}
CI_STEP=${CI_STEP:-setup}
ci_reported=

# Workflow-command escaping (% → %25, CR → %0D, line breaks → %0A) of stdin, as one line.
ci_escape() { LC_ALL=C awk 'BEGIN { ORS = "" } { gsub(/%/, "%25"); gsub(/\r/, "%0D"); if (NR > 1) printf "%%0A"; print }'; }

# At most 300 characters of stdin's first line, cut on a character boundary.
ci_short() { head -n 1 | head -c 300 | { iconv -c -f UTF-8 -t UTF-8 2> /dev/null || cat; }; }

ci_annotate() { # <error|warning> <message>
  printf '\n::%s::%s\n' "$1" "$(printf '%s' "$2" | ci_escape)"
}

warn() { ci_annotate warning "$CI_CONTEXT: $1"; }
fail() { ci_reported=1; ci_annotate error "$CI_CONTEXT: $1"; exit 1; }

# The lines of a log's last `--- attempt` section (the whole log when it has none).
ci_last_attempt() { awk '/^--- attempt / { buf = "" } { buf = buf $0 "\n" } END { printf "%s", buf }' "$1"; }

# The line that says what went wrong: the first error-looking line, else the last non-empty one.
ci_detail() { # <log>
  [ -s "$1" ] || { echo "(no output)"; return; }
  ci_last_attempt "$1" > "$1.last"
  line=$(grep -a -m 1 -E '^(E:|Error|ERROR|error:|FAIL|fatal|Fatal|Traceback|Unable to|No match for argument)' "$1.last" || true)
  [ -n "$line" ] || line=$(grep -a -v '^[[:space:]]*$' "$1.last" | tail -n 1)
  rm -f "$1.last"
  printf '%s' "$line" | tr -d '\000' | ci_short
}

die_log() { # <log> <step> [exit status]
  tail -n 20 "$1" 2> /dev/null || true
  fail "$2${3:+ (exit $3)}: $(ci_detail "$1")"
}

ci_trap() {
  trap 'ci_rc=$?; if [ $ci_rc != 0 ] && [ -z "$ci_reported" ]; then ci_annotate error "$CI_CONTEXT: $CI_STEP failed (exit $ci_rc)"; fi' EXIT
}

# Errors no retry can fix: a package name the repositories do not have.
ci_permanent() {
  ci_last_attempt "$1" | grep -a -q -E "Unable to locate package|has no installation candidate|Couldn't find any package|No match for argument|Unable to find a match"
}

retry_install() { # <log> <label> <shell command>
  ci_log=$1; ci_label=$2; ci_cmd=$3
  : > "$ci_log"
  ci_n=1
  while :; do
    echo "--- attempt $ci_n: $ci_cmd" >> "$ci_log"
    if timeout 900 sh -c "$ci_cmd" >> "$ci_log" 2>&1; then return 0; else ci_status=$?; fi
    [ $ci_status = 124 ] && echo "--- attempt $ci_n timed out after 15 min" >> "$ci_log"
    if [ $ci_n -ge 3 ] || ci_permanent "$ci_log"; then return $ci_status; fi
    if [ $ci_n = 1 ]; then ci_wait=20; else ci_wait=60; fi
    warn "$ci_label: attempt $ci_n failed (exit $ci_status), retrying in ${ci_wait}s: $(ci_detail "$ci_log")"
    sleep $ci_wait
    ci_n=$((ci_n + 1))
  done
}

# apt-get update fails on any repository it cannot fetch (instead of warning and leaving stale lists), each fetch is
# retried by apt itself with a time limit, and the docker images' docker-clean hook does not delete what a failed
# attempt downloaded.
APT_NET="-o Acquire::Retries=2 -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30"
apt_prepare() { rm -f /etc/apt/apt.conf.d/docker-clean; export DEBIAN_FRONTEND=noninteractive; }
apt_update() { echo "apt-get update -qq --error-on=any $APT_NET"; }

docker_pull() { # <image> [--platform …]
  for ci_n in 1 2 3; do
    [ -z "$2" ] && docker image inspect "$1" > /dev/null 2>&1 && return 0
    # shellcheck disable=SC2086
    docker pull -q $2 "$1" > /dev/null && return 0
    [ $ci_n = 3 ] && break
    ci_annotate warning "docker pull $1: attempt $ci_n failed, retrying in $((ci_n * 20))s"
    sleep $((ci_n * 20))
  done
  ci_annotate error "docker pull $1 failed 3 times"
  return 1
}
