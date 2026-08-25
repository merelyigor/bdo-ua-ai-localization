.PHONY: env help

# IDE-friendly entrypoint. The canonical implementation remains ./bdo env.
env:
	./bdo env

help:
	@printf '%s\n' 'make env  Materialize the local OpenCode runtime from .env'
