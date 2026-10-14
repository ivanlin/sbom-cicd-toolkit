# syntax=docker/dockerfile:1.7
# sbom-cicd-toolkit — one image, two architectures, pinned tools.
# Every binary version + sha256 comes from tools.lock (see that file).
ARG BASE_IMAGE=cgr.dev/chainguard/wolfi-base@sha256:256c88bb066424045021090932d50be93c8e3f2ce3586707702a401b146f3e43

FROM ${BASE_IMAGE} AS fetch
ARG TARGETARCH
USER root
RUN apk add --no-cache curl
COPY tools.lock /tmp/tools.lock
WORKDIR /dl
# shellcheck disable=SC2039
RUN set -eu; . /tmp/tools.lock; \
    arch="$TARGETARCH"; \
    case "$arch" in amd64) trivy_arch=64bit ;; arm64) trivy_arch=ARM64 ;; *) echo "unsupported arch $arch" >&2; exit 1 ;; esac; \
    sha() { eval "printf '%s' \"\$${1}_SHA256_linux_${arch}\""; }; \
    fetch() { curl -fsSL --retry 3 -o "$2" "$1"; echo "$3  $2" | sha256sum -c -; }; \
    fetch "https://github.com/anchore/syft/releases/download/v${SYFT_VERSION}/syft_${SYFT_VERSION}_linux_${arch}.tar.gz" syft.tgz "$(sha SYFT)"; \
    fetch "https://github.com/anchore/grype/releases/download/v${GRYPE_VERSION}/grype_${GRYPE_VERSION}_linux_${arch}.tar.gz" grype.tgz "$(sha GRYPE)"; \
    fetch "https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}/trivy_${TRIVY_VERSION}_Linux-${trivy_arch}.tar.gz" trivy.tgz "$(sha TRIVY)"; \
    fetch "https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}/yq_linux_${arch}" yq "$(sha YQ)"; \
    fetch "https://github.com/jqlang/jq/releases/download/jq-${JQ_VERSION}/jq-linux-${arch}" jq "$(sha JQ)"; \
    mkdir -p /out/bin; \
    tar -xzf syft.tgz -C /out/bin syft; tar -xzf grype.tgz -C /out/bin grype; tar -xzf trivy.tgz -C /out/bin trivy; \
    install -m 0755 yq /out/bin/yq; install -m 0755 jq /out/bin/jq; chmod 0755 /out/bin/*

FROM ${BASE_IMAGE}
ARG TOOLKIT_VERSION=0.0.0-dev
ARG VCS_REF=unknown
USER root
RUN apk add --no-cache bash git ca-certificates-bundle coreutils findutils
COPY --from=fetch /out/bin/ /usr/local/bin/
COPY bin/sbomgate /usr/local/bin/sbomgate
COPY tools.lock VERSION /opt/sbom-cicd-toolkit/
RUN chmod 0755 /usr/local/bin/sbomgate && mkdir -p /cache /out /src && chmod 0777 /cache /out
ENV SBOMGATE_HOME=/opt/sbom-cicd-toolkit \
    GRYPE_DB_CACHE_DIR=/cache/grype \
    TRIVY_CACHE_DIR=/cache/trivy \
    SYFT_CHECK_FOR_APP_UPDATE=false \
    GRYPE_CHECK_FOR_APP_UPDATE=false \
    TRIVY_NO_PROGRESS=true \
    HOME=/tmp
LABEL org.opencontainers.image.title="sbom-cicd-toolkit" \
      org.opencontainers.image.description="SBOM generation (CycloneDX+SPDX) + CVE scan (grype, trivy) + policy gate, pinned & reproducible" \
      org.opencontainers.image.version="${TOOLKIT_VERSION}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.source="https://github.com/ivanlin/sbom-cicd-toolkit" \
      org.opencontainers.image.licenses="MIT"
WORKDIR /src
ENTRYPOINT ["/usr/local/bin/sbomgate"]
CMD ["help"]
