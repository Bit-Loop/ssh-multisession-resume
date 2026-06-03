ARG BASE_IMAGE=archlinux:base-devel
FROM ${BASE_IMAGE}

ARG BOOTSTRAP=":"
RUN /bin/sh -c "${BOOTSTRAP}"

WORKDIR /work
COPY . /work/

CMD ["/work/docker/test-in-container.sh", "--mode", "source-login"]
