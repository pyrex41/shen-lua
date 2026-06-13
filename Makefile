# shen-lua Makefile — two clearly-separated test tiers, mirroring shen-go.
#
#   make test       PORT unit tests (fast): every test/*_spec.lua, aggregated.
#   make certify    CANONICAL Shen kernel certification (run-kernel-tests.lua).
#   make test-all   both tiers (test then certify).
#   make coverage   luacov over the port specs (skips gracefully if absent).
#
# LUA selects the interpreter (default: luajit, the project's primary host).
LUA ?= luajit

.PHONY: all test certify test-all coverage help

all: test

help:
	@echo "make test      - run the port-authored spec suite (fast)"
	@echo "make certify   - run the canonical Shen kernel certification suite"
	@echo "make test-all  - run both tiers"
	@echo "make coverage  - run luacov over the port specs (best-effort)"

# test: PORT-AUTHORED specs only. Fast, deterministic, no canonical kernel run.
# The unified runner aggregates pass/fail and exits nonzero on any failure.
test:
	$(LUA) scripts/run-tests.lua

# certify: the CANONICAL Shen kernel certification suite. This is the external
# bar ("Certified"), distinct from our own specs above. It loads the full
# kernel and runs the vendored ShenOSKernel acceptance tests under tests/.
certify:
	$(LUA) run-kernel-tests.lua

# test-all: both tiers — our specs plus the canonical certification.
test-all: test certify

# coverage: instrumented run of the port specs via luacov. Skips with a clear
# message (exit 0) if luacov is not installed, so it never breaks a plain build.
coverage:
	@sh scripts/coverage.sh
