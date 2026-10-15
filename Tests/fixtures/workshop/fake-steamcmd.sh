#!/bin/sh
# A stand-in for steamcmd in the download queue tests. It never contacts Steam. Behaviour by workshop id:
#   1xx  success (item folder with project.json under $FAKE_CONTENT)
#   2xx  no cached login: prints the notice and waits at a password prompt (the queue must stop it)
#   3xx  download failure
#   4xx  a preset whose project.json names dependency 1$FAKE_DEP_SUFFIX (default 101)
#   5xx  prints a Steam Guard prompt and waits
# +workshop_status 431960 (the subscription refresh): user "nologin" gets the no-cached-login prompt; otherwise the
# client's count line is printed and $FAKE_SUBS (a subscriptions.vdf) is written when set.
# The arguments are written to $FAKE_ARGS (one per line) when set.
[ -n "$FAKE_ARGS" ] && printf '%s\n' "$@" >> "$FAKE_ARGS"
id=""
prev=""
for a in "$@"; do
  if [ "$prev" = "431960" ]; then id="$a"; fi
  prev="$a"
done
user=""
prev=""
for a in "$@"; do
  if [ "$prev" = "+login" ]; then user="$a"; fi
  prev="$a"
done
echo "Redirecting stderr to '/dev/null'"
echo "[  0%] Checking for available updates..."
echo "[----] Verifying installation..."
echo "Steam Console Client (c) Valve Corporation - version 0"
echo "-- type 'quit' to exit --"
echo "Loading Steam API...OK"
status=""
for a in "$@"; do [ "$a" = "+workshop_status" ] && status=1; done
[ -n "$status" ] && [ "$user" = "nologin" ] && id=200
case "$id" in
  2*)
    printf "Logging in user '%s' to Steam Public...\n" "$user"
    echo "Cached credentials not found."
    printf "password: "
    sleep 30
    exit 5
    ;;
  5*)
    printf "Logging in user '%s' to Steam Public...\n" "$user"
    printf "Steam Guard code:"
    sleep 30
    exit 5
    ;;
esac
printf "Logging in user '%s' [U:1:1] to Steam Public...OK\n" "$user"
echo "Waiting for client config...OK"
echo "Waiting for user info...OK"
if [ -n "$status" ]; then
  if [ -n "$FAKE_SUBS" ]; then
    mkdir -p "$(dirname "$FAKE_SUBS")"
    printf '"subscribedfiles"\n{\n\t"appid"\t\t"431960"\n\t"time_last_updated"\t\t"300"\n\t"0"\n\t{\n\t\t"publishedfileid"\t\t"55"\n\t\t"time_subscribed"\t\t"50"\n\t}\n}\n' > "$FAKE_SUBS"
  fi
  echo "[AppID 431960] Subscribed items changed. Number of items: 1 (update time: 300)"
  exit 0
fi
echo "Downloading item $id ..."
case "$id" in
  3*)
    echo "ERROR! Download item $id failed (File Not Found)."
    exit 0
    ;;
esac
dir="$FAKE_CONTENT/$id"
mkdir -p "$dir"
case "$id" in
  4*) printf '{"title":"preset %s","dependency":"101","preset":{}}' "$id" > "$dir/project.json" ;;
  *) printf '{"title":"item %s","file":"scene.json"}' "$id" > "$dir/project.json" ;;
esac
printf 'Success. Downloaded item %s to "%s" (1234 bytes) \n' "$id" "$dir"
exit 0
