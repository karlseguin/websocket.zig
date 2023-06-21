.PHONY: t
t:
	zig build test --summary all

.PHONY: ab
ab:
	bash support/autobahn/run.sh
