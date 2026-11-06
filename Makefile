.PHONY: test test-spaces lint

test:
	./test/libs/bats-core/bin/bats test/

# The whole suite with every sandbox under a folder with a space in its name.
# The folder is left in place, empty, as bats removes its own sandboxes
test-spaces:
	mkdir -p "$${TMPDIR:-/tmp}/sil with space"
	TMPDIR="$${TMPDIR:-/tmp}/sil with space" ./test/libs/bats-core/bin/bats test/

lint:
	shellcheck sil.sh src/*.sh test/*.bats test/test_helper.bash
