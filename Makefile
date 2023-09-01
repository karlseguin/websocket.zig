.PHONY: t
t:
	zig build test --summary all -freference-trace

.PHONY: abs
abs:
	bash support/autobahn/server/run.sh


.PHONY: abc
abc:
	bash support/autobahn/client/run.sh
