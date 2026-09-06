.PHONY: build smoke e2e

# Compile the bridge (agent loop + MCP server, one static binary).
build:
	go build -o bin/agent99-bridge ./bridge

# Bridge + LSP tools against a headless Neovim (no API calls, free).
# SUITES narrows the run while iterating (mcp headless multi debug):
#   make smoke SUITES=headless
# Run it with no SUITES before committing.
smoke: build
	bash tests/smoke.sh $(SUITES)

# One real agent edit through the configured provider (needs DEEPSEEK_API_KEY).
e2e: build
	bash tests/e2e.sh
