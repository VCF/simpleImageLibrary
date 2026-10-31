.PHONY: test lint

test:
	./test/libs/bats-core/bin/bats test/

lint:
	shellcheck sil.sh src/*.sh test/*.bats test/test_helper.bash
