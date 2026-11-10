SHELL := /bin/zsh

APP_NAME := Headphone Monitor
APP_PATH := dist/$(APP_NAME).app

.DEFAULT_GOAL := all
.PHONY: all help build test verify run install package clean

all: verify

help:
	@printf '%s\n' \
		'make build    Build and sign the app bundle' \
		'make test     Run deterministic metrics tests' \
		'make verify   Build and run repository checks' \
		'make run      Build and launch the app' \
		'make package  Build, verify, zip, and checksum' \
		'make install  Build and install into /Applications' \
		'make clean    Remove generated build output'

build:
	./build.sh

test:
	./scripts/test.sh

verify: build test
	./scripts/verify.sh

run: build
	open "$(APP_PATH)"

install: build
	./scripts/install.sh

package: verify
	./scripts/package.sh

clean:
	./scripts/clean.sh
