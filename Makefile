IMAGE ?= kdaweb/certbotbot

.PHONY: test image

test:
	bats tests

image:
	docker build -t "$(IMAGE)" .
