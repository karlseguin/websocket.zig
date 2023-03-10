.PHONY: t
t:
	zig build test

.PHONY: ab
ab:
	bash support/autobahn/run.sh
