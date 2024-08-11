#!/usr/bin/env bash
set -o errexit
set -o nounset

docker stop fuzzingserver || true

root=$(dirname $(realpath $BASH_SOURCE))
trap "docker stop fuzzingserver || true;" EXIT

docker run --rm \
	--rm \
	-p 9001:9001 \
	-v "${root}:/ab" \
	--name fuzzingserver \
	crossbario/autobahn-testsuite \
	/opt/pypy/bin/wstest --mode fuzzingserver --spec /ab/config.json &

cd support/autobahn/client/ && zig build run

if grep FAILED support/autobahn/client/reports/index.json*; then
	exit 1
else
	exit 0
fi
