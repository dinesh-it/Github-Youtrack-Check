DOCKER_TAG=exceleron/micro-ci:$(shell git describe --tags --dirty 2>/dev/null)
tty_exit=$(shell tty >/dev/null 2>&1; echo $$?)
ifeq ($(tty_exit),0)
    DOCKER_TTY=--tty=true
else
    DOCKER_TTY=--tty=false
endif

.PHONY: docker
docker: 
	docker build -t "$(DOCKER_TAG)" -f docker/Dockerfile.code .

.PHONY: run
run: docker
	docker container prune -f
	echo $(DOCKER_TAG)
	docker run --rm -it --env-file=.env -p 80:80 $(DOCKER_TAG)

.PHONY: shell
shell: docker
	docker container prune -f
	docker run --rm -it --env-file=.env -v "$(PWD)/":/opt/github-youtrack/ $(DOCKER_TAG) /bin/bash

