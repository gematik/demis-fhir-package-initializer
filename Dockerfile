# Declare Source Digest for the Base Image
ARG SOURCE_DIGEST=4f1280cd30c9ee1242656106fb880c9d66b517657932037f2ee79cbd20cb7623
FROM gematik1/osadl-alpine-openjdk21-jre:1.0.6@sha256:${SOURCE_DIGEST}

# Redeclare Source Digest to be used in the build context
# https://docs.docker.com/engine/reference/builder/#understand-how-arg-and-from-interact
ARG SOURCE_DIGEST=4f1280cd30c9ee1242656106fb880c9d66b517657932037f2ee79cbd20cb7623

# install wget, tar and jq
USER root
RUN echo "https://dl-cdn.alpinelinux.org/alpine/v3.22/community" >> /etc/apk/repositories && \
    apk update && \
    apk add --no-cache jq && \
    rm -rf /var/cache/apk/*

# Default USERID and GROUPID
ARG USERID=10000
ARG GROUPID=10000

# Run as User (not root)
USER $USERID:$USERID

# Install FHIR package initializer scripts
COPY --chown=$USERID:$GROUPID scripts/init_snapshot_package.sh /usr/local/bin/init_snapshot_package.sh
COPY --chown=$USERID:$GROUPID scripts/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/init_snapshot_package.sh /usr/local/bin/entrypoint.sh
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

# The STOPSIGNAL instruction sets the system call signal that will be sent to the container to exit
# SIGTERM = 15 - https://de.wikipedia.org/wiki/Signal_(Unix)
STOPSIGNAL SIGTERM

# Git Args
ARG COMMIT_HASH
ARG VERSION

###########################
# Labels
###########################
LABEL de.gematik.vendor="gematik GmbH" \
      maintainer="software-development@gematik.de" \
      de.gematik.app="DEMIS FHIR package intializer" \
      de.gematik.git-repo-name="https://gitlab.prod.ccs.gematik.solutions/demis/deployment" \
      de.gematik.commit-sha=$COMMIT_HASH \
      de.gematik.version=$VERSION
