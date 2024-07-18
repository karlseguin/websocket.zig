#!/usr/bin/env bash
set -o errexit
set -o nounset

root=$(dirname $(realpath $BASH_SOURCE))
echo "starting server..."
cd support/autobahn/server/ && zig build run &

sleep 3 # give chance for socket to listen
trap "killall autobahn_test_server || true;" EXIT

docker run --rm \
	--net="host" \
	--rm \
	-v "${root}:/ab" \
	--name fuzzingclient \
	crossbario/autobahn-testsuite \
	/opt/pypy/bin/wstest --mode fuzzingclient --spec /ab/config.json;

if grep FAILED support/autobahn/server/reports/index.json*; then
	exit 1
else
	exit 0
fi
