#!/bin/sh
# Maps environment variables to openflux flags and, for the exit node,
# installs the kernel-RST-drop rule *inside this container's netns*.
#
# Why the rule: the exit node's TCP connections live in a userspace (gVisor)
# stack, so the kernel has no socket for them and answers every inbound
# SYN-ACK with an RST, tearing the tunnel down. Confining the DROP to the
# container netns is the scoped variant of upstream's host-wide rule — it
# cannot affect the host or other containers.
set -eu

role="${ROLE:-client}"
transport="${TRANSPORT:-yandex}"
listen="${SOCKS5_LISTEN:-:1080}"

case "$role" in
  client|exit-node) ;;
  *)
    echo "ROLE must be 'client' or 'exit-node' (got '$role')" >&2
    exit 2
    ;;
esac

case "$transport" in
  yandex|vyandex|boards|mailru|cupsonline|oneme) ;;
  *)
    echo "TRANSPORT must be one of yandex, vyandex, boards, mailru, cupsonline, oneme (got '$transport')" >&2
    exit 2
    ;;
esac

if [ "$role" = exit-node ] && [ -d /data ]; then
  if [ -n "${DIRECT_LISTEN:-}" ]; then
    : "${SHARE_HOST:?Set SHARE_HOST to the public IP or DNS name of the Docker host}"
  fi
  if [ ! -s /data/channel.key ]; then
    umask 077
    openssl rand -hex 32 > /data/channel.key
  fi
  set -- --role=exit --mode=l4 --encryption-key-file=/data/channel.key --cookie-store=/data/cookies.json --share
  if [ -n "${DIRECT_LISTEN:-}" ]; then
    set -- "$@" --transports="direct:10,$transport:100" --direct-listen="$DIRECT_LISTEN" --share-host="$SHARE_HOST"
  else
    set -- "$@" --transport="$transport"
  fi
  if [ "$transport" = cupsonline ]; then
    # The built-in wizard creates a reusable list; persist it before starting.
    if [ ! -s /data/rooms ]; then
      printf '%s\n' '{"method":"createRooms"}' | openflux --node-wizard | jq -er '.rooms' > /data/rooms.tmp
      mv /data/rooms.tmp /data/rooms
    fi
    set -- "$@" --url="$(cat /data/rooms)"
  fi
else
  if [ "$role" = exit-node ]; then
    set -- --role=exit --mode=l4 --transport="$transport"
  else
    set -- --role=client --inbound=socks5 --transport="$transport"
  fi
fi

if [ "$role" = client ]; then
  set -- "$@" --socks5 "$listen"
fi

if [ -n "${URL:-}" ]; then
  set -- "$@" --url "$URL"
fi
if [ -n "${MAX_TOKEN:-}" ]; then
  set -- "$@" --maxToken "$MAX_TOKEN"
fi
if [ -n "${MAX_UID:-}" ]; then
  set -- "$@" --maxUid "$MAX_UID"
fi
if [ -n "${LOCAL_IP:-}" ]; then
  # Optional: pin the egress IP (alias IP) so the RST drop could be scoped
  # with `-s <ip>` too; inside a dedicated container netns it's usually
  # unnecessary.
  set -- "$@" --local-ip "$LOCAL_IP"
fi
case "${DEBUG:-0}" in
  1|true|yes) set -- "$@" --debug ;;
esac

if [ "$role" = exit-node ]; then
  echo "[entrypoint] dropping outbound TCP RSTs inside the container netns"
  if ! iptables -A OUTPUT -p tcp --tcp-flags RST RST -j DROP; then
    echo "[entrypoint] WARNING: iptables failed (missing NET_ADMIN?); kernel RSTs will kill tunnel connections" >&2
  fi
fi

echo "[entrypoint] exec: openflux $*"
exec openflux "$@"
