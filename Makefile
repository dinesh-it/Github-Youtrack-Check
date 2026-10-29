.PHONY: test
test:
	prove -r t

# Run the tests on the AlmaLinux perl base used by the EC2 hosts
.PHONY: test-docker
test-docker:
	docker build -t micro-ci-test -f docker/Dockerfile.test .
	docker run --rm micro-ci-test
