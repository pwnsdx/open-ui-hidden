SHELL := /usr/bin/env bash

.PHONY: test test-static test-docker-smoke

test: test-static

test-static:
	./tests/test_static.sh

test-docker-smoke:
	./tests/test_compose_smoke.sh
