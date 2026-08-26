.PHONY: test test-live

test:
	nvim -l tests/run.lua

# also exercises a real local model; needs an OpenAI-compatible server running
test-live:
	GERTY_TEST_LIVE=1 nvim -l tests/run.lua
