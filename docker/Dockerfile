FROM archlinux:base-devel

# Intentionally NOT pre-installing tmux or screen. The application owns its
# own dependency installation via `ssh-multisession-resume deps`. The
# container verifies that flow end-to-end. Everything below is either a
# system-level base (bash, sudo, openssh) or test-only tooling.
RUN pacman -Syu --noconfirm --needed \
        bash \
        openssh \
        sudo \
        shellcheck \
        zsh \
        dash \
        coreutils \
        findutils \
        gawk \
        grep \
        sed \
        procps-ng \
        util-linux \
        lsof \
    && pacman -Scc --noconfirm

# makepkg refuses to run as root, but most of our checks are package-free.
# A non-root user keeps things realistic and lets us test sudo-driven paths.
RUN useradd --create-home --shell /bin/bash --groups wheel tester \
    && printf '%%wheel ALL=(ALL:ALL) NOPASSWD: ALL\n' >> /etc/sudoers.d/wheel \
    && chmod 0440 /etc/sudoers.d/wheel

WORKDIR /work
COPY --chown=tester:tester . /work/

USER tester
ENV HOME=/home/tester
ENV TMUX= STY=
CMD ["/work/docker/test-in-container.sh"]
