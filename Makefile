F="websocket.zig"

.PHONY: t
t:
	zig test ${F}

.PHONY: ab
ab:
	bash support/autobahn/run.sh
