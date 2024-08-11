F=
zig ?= zig
.PHONY: t
t:
	TEST_FILTER='${F}' '${zig}' build test -Dforce_blocking=false -freference-trace --summary all
	TEST_FILTER='${F}' '${zig}' build test -Dforce_blocking=true -freference-trace --summary all

.PHONY: tn
tn:
	TEST_FILTER='${F}' '${zig}' build test -Dforce_blocking=false -freference-trace --summary all

.PHONY: tb
tb:
	TEST_FILTER='${F}' '${zig}' build test -Dforce_blocking=true -freference-trace --summary all

.PHONY: abs
abs:
	bash support/autobahn/server/run.sh

.PHONY: abc
abc:
	bash support/autobahn/client/run.sh
