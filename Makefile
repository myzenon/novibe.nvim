.PHONY: test test-deps clean-deps

# Run all tests via plenary's busted runner
test:
	nvim --headless --noplugin -u tests/minimal_init.lua \
		-c "PlenaryBustedDirectory tests/ {minimal_init = 'tests/minimal_init.lua', sequential = true}"

# Clone plenary into ./deps for CI / fresh checkouts
test-deps:
	@mkdir -p deps
	@if [ ! -d deps/plenary.nvim ]; then \
		git clone --depth 1 https://github.com/nvim-lua/plenary.nvim deps/plenary.nvim; \
	fi

clean-deps:
	rm -rf deps
