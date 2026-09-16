.PHONY: help hooks-install statusline-preview

help:
	@printf '%s\n' \
		'Available targets:' \
		'  hooks-install       Activate the repository Git hooks' \
		'  statusline-preview  Preview the Claude Code statusline'

hooks-install:
	git config --local core.hooksPath .githooks

statusline-preview:
	@.claude/statusline.sh --demo
