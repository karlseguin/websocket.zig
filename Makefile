F=
.PHONY: t
t:
	TEST_FILTER="${F}" zig build test -freference-trace --summary all

.PHONY: abs
abs:
	bash support/autobahn/server/run.sh


.PHONY: abc
abc:
	bash support/autobahn/client/run.sh
