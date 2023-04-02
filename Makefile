.PHONY: t
t:
	zig build test -fsummary

.PHONY: ab
ab:
	bash support/autobahn/run.sh
