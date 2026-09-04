.PHONY: env sync help

# IDE-friendly entrypoint. The canonical implementation remains ./bdo env.
env:
	./bdo env

sync:
	./bdo sync

help:
	@printf '%s\n' 'make env   Show the run target from .env'
	@printf '%s\n' 'make sync  Show .env changes, materialize runtime, then save a masked snapshot'
