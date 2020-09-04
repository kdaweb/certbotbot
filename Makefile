
tag := "certbotbot"
bucket := "certbotbotbucket"

flags := "--test-cert --dry-run"

image: Dockerfile entrypoint.sh
	docker build -t $(tag) .

all: image
	docker run \
	--rm \
	-it \
	-v ${HOME}/.aws:/root/.aws \
	-e BUCKET=$(bucket) \
	-e EMAIL=$(email) \
	-e DEBUGFLAGS=$(flags) \
	$(tag)
