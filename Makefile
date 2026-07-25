# Convenience wrapper over the scripts. See README.md.
.PHONY: all build install setup uninstall vendor-cache verify clean distclean

all: build

build:                        ## build Wine + PipeASIO in a container -> dist/
	./build.sh

install:                      ## install the built Wine tree + launcher (end user)
	./scripts/install.sh

setup:                        ## create/refresh the Wine prefix (end user)
	./scripts/setup-prefix.sh

uninstall:                    ## remove installed Wine tree + launcher
	./scripts/uninstall.sh

vendor-cache:                 ## populate vendor/winetricks-cache for offline setup
	./scripts/vendor-winetricks-cache.sh

verify:                       ## check vendored inputs against pinned checksums
	cd vendor && sha256sum -c wine-base.sha256 pipeasio.sha256 pipewire-sdk.sha256 ntsync-uapi.sha256 link.sha256

clean:                        ## remove build outputs
	rm -rf dist

distclean: clean              ## also drop the container image
	-$${ENGINE:-podman} rmi ableton-wine-build:22.04
