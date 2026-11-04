#!/bin/sh
# The all-in-one image's command (#17): Dossier with a PostgreSQL of its own
# in the same container, for running it without a database server. The
# database lives in /data/postgres, next to the backups, and only listens on
# a socket inside the container. With DATABASE_URL set, it's the plain image.
set -eu

if [ -n "${DATABASE_URL:-}" ]; then exec ./start.sh; fi

PG_MAJOR=18
PG_BIN=/usr/lib/postgresql/$PG_MAJOR/bin
PGDATA=/data/postgres
SOCKET=/tmp

created=""
if [ ! -s "$PGDATA/PG_VERSION" ]; then
  echo "Creating Dossier's database in $PGDATA."
  created=yes
  "$PG_BIN/initdb" --pgdata="$PGDATA" --username=dossier --auth=trust --encoding=UTF8 --locale=C.UTF-8 > /dev/null
elif [ "$(cat "$PGDATA/PG_VERSION")" != "$PG_MAJOR" ]; then
  echo "Dossier didn't start: the database in $PGDATA is PostgreSQL $(cat "$PGDATA/PG_VERSION")'s, and this image has PostgreSQL $PG_MAJOR. Start the image you used before, export your data in Settings → Your data, then start this one with an empty /data/postgres and import it. See Upgrading in the wiki: https://github.com/AienTech/dossier/wiki/Upgrading" >&2
  exit 1
fi

# One user and a few connections: the app's pool, migrations and the seed.
"$PG_BIN/postgres" -D "$PGDATA" -c listen_addresses= -c unix_socket_directories="$SOCKET" -c max_connections=20 &
db=$!
until "$PG_BIN/pg_isready" -q -h "$SOCKET" -U dossier -d postgres; do
  if ! kill -0 "$db" 2> /dev/null; then
    echo "Dossier didn't start: its database stopped (see the error above)." >&2
    exit 1
  fi
  sleep 0.5
done
if [ -n "$created" ]; then "$PG_BIN/createdb" -h "$SOCKET" -U dossier dossier; fi
export DATABASE_URL="postgresql://dossier@localhost/dossier?host=$SOCKET"

# Migrations, the seed, then the server, as in the plain image.
./start.sh &
app=$!

# `docker stop`: the server first, then the database, so nothing is cut off.
stop() {
  kill -TERM "$app" 2> /dev/null || true
  wait "$app" 2> /dev/null || true
  kill -INT "$db" 2> /dev/null || true
  wait "$db" 2> /dev/null || true
}
trap 'stop; exit 0' TERM INT

# Whichever stops first stops the container, so Docker can restart it.
while kill -0 "$app" 2> /dev/null && kill -0 "$db" 2> /dev/null; do sleep 2; done
if ! kill -0 "$db" 2> /dev/null; then
  echo "Dossier stopped: its database stopped (see the error above)." >&2
  stop
  exit 1
fi
status=0
wait "$app" || status=$?
stop
exit "$status"
