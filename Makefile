# We need to do some OS switching below.
UNAME := $(shell uname)

NIXNAME ?= $(shell hostname)
POENTTOE_IP ?= poenttoe.kalski.xyz

HAS_NH := $(shell command -v nh 2>/dev/null)
# Determine the 'nh' subcommand based on OS
ifeq ($(UNAME), Darwin)
	NH_SUBCMD := darwin
else
	NH_SUBCMD := os
	# Elevate local NixOS switches with systemd's run0 instead of sudo.
	NH_SWITCH_FLAGS := -e run0
endif

switch:
ifneq ($(HAS_NH),)
	nh $(NH_SUBCMD) switch -a $(NH_SWITCH_FLAGS) -H "${NIXNAME}" .
else ifeq ($(UNAME), Darwin)
	nix build --extra-experimental-features nix-command --extra-experimental-features flakes ".#darwinConfigurations.${NIXNAME}.system"
	./result/sw/bin/darwin-rebuild switch --flake "$$(pwd)#${NIXNAME}"
else
	sudo nixos-rebuild switch --flake ".#${NIXNAME}"
endif

build:
ifneq ($(HAS_NH),)
	nh $(NH_SUBCMD) build -H "${NIXNAME}" .
else ifeq ($(UNAME), Darwin)
	nix build --extra-experimental-features nix-command --extra-experimental-features flakes ".#darwinConfigurations.${NIXNAME}.system"
else
	sudo nixos-rebuild build --flake ".#${NIXNAME}"
endif

repl:
ifneq ($(HAS_NH),)
	nh $(NH_SUBCMD) repl -H "${NIXNAME}" .
else
	$(error repl command only requires nh)
endif

test:
ifeq ($(UNAME), Darwin)
	nix build ".#darwinConfigurations.${NIXNAME}.system"
	./result/sw/bin/darwin-rebuild test --flake "$$(pwd)#${NIXNAME}"
else
	sudo nixos-rebuild test --flake ".#$(NIXNAME)"
endif

bootloader:
ifeq ($(UNAME), Darwin)
	$(error boot only work on Linux)
else
	sudo nixos-rebuild switch --install-bootloader --flake ".#${NIXNAME}"
endif

deploy-pannu deploy-poenttoe deploy-zima: deploy-%:
	nh os switch -a -H $* --build-host $* --target-host $* .

build-pannu build-poenttoe build-zima: build-%:
	nh os build -H $* --build-host $* --target-host $* .

bootstrap-poenttoe:
	# Create user kahlstrm if not exists, set password, copy root keys
	ssh -t root@$(POENTTOE_IP) "id -u kahlstrm &>/dev/null || useradd -m -G wheel kahlstrm; echo 'Please set password for kahlstrm:'; passwd kahlstrm"
	ssh root@$(POENTTOE_IP) "mkdir -p /home/kahlstrm/.ssh && [ -f /home/kahlstrm/.ssh/authorized_keys ] || (cp /etc/ssh/authorized_keys.d/root /home/kahlstrm/.ssh/authorized_keys && chown -R kahlstrm: /home/kahlstrm/.ssh && chmod 700 /home/kahlstrm/.ssh && chmod 600 /home/kahlstrm/.ssh/authorized_keys)"

fmt:
	fd '\.nix$$'| xargs nixfmt
# This builds the given NixOS configuration and pushes the results to the
# cache. This does not alter the current running system. This requires
# cachix authentication to be configured out of band.
# TODO: determine if this is necessary for my use 
# cache:
#	$(call require_nixname)
#	nix build '.#nixosConfigurations.$(NIXNAME).config.system.build.toplevel' --json \
#		| jq -r '.[].outputs | to_entries[].value' \
#		| cachix push kahlstrm-nixos-config


# Build a WSL installer
.PHONY: \
	bootstrap-poenttoe \
	bootloader \
	build \
	build-pannu \
	build-poenttoe \
	build-zima \
	deploy-pannu \
	deploy-poenttoe \
	deploy-zima \
	fmt \
	repl \
	switch \
	test \
	wsl
wsl:
	 nix build --extra-experimental-features nix-command --extra-experimental-features flakes ".#nixosConfigurations.wsl.config.system.build.tarballBuilder"
	 sudo result/bin/nixos-wsl-tarball-builder
