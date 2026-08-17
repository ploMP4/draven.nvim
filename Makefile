NVIM ?= nvim
PLENARY_DIR := .tests/plenary.nvim

.PHONY: test deps fmt lint clean

test: deps
	@$(NVIM) --headless --noplugin -u tests/minimal_init.lua \
		-c "PlenaryBustedDirectory tests/ { minimal_init = 'tests/minimal_init.lua', sequential = true, timeout = 60000 }"

# Reuses an already-installed plenary when there is one; clones otherwise.
deps:
	@if [ -d "$(PLENARY_DIR)" ]; then exit 0; fi; \
	for d in "$$HOME/.local/share/nvim/lazy/plenary.nvim" \
	         "$$HOME/.local/share/nvim/site/pack"/*/start/plenary.nvim; do \
		if [ -d "$$d" ]; then exit 0; fi; \
	done; \
	echo "cloning plenary.nvim into $(PLENARY_DIR)"; \
	mkdir -p .tests && \
	git clone --depth 1 https://github.com/nvim-lua/plenary.nvim $(PLENARY_DIR)

fmt:
	@stylua lua/ plugin/ tests/

lint:
	@stylua --check lua/ plugin/ tests/

clean:
	@rm -rf .tests
