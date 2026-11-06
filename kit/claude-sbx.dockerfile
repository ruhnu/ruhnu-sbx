# Build with:
#   docker buildx build -f kit/claude-sbx.yaml -t claude-sbx:dev kit/
#
# The YAML descriptor beside this file is the build entrypoint, not this
# Dockerfile; sbx's buildx frontend reads the descriptor and this file together.
#
# The stock sandbox image already ships git, curl, jq, gh, rg and the Docker
# CLI, so this adds only the Java toolchain and OpenSpec. Probed 2026-11-06:
# the sandbox base is Debian 13 (trixie), not Ubuntu.

# Variants on docker/sandbox-templates are <agent>[-docker][-<version>]; there
# is no bare ":claude". The -docker flavour ships the in-sandbox Docker engine
# that dockerd@1 grants privileges for, which Testcontainers needs. Pinned
# rather than floating: `claude-code-docker` alone moves under you.
FROM docker/sandbox-templates:claude-code-docker-0.10.0

USER root

# Both JDKs, because the cdoc2 repos straddle versions: cdoc2-java-ref-impl
# lists Java 17 as a precondition ("tested with JDK 17 and Maven 3.8.8"), while
# siblings such as cdoc2-shares-server have moved to 21. Default to 21; switch
# per project with JAVA_HOME, or pin per module via maven.compiler.release.
#
# The repos ship ./mvnw, which fetches its own pinned Maven; the apt maven is
# for convenience and for anything without a wrapper.
RUN apt-get update && apt-get install -y --no-install-recommends \
      openjdk-21-jdk-headless \
      openjdk-17-jdk-headless \
      maven \
      haveged \
 && rm -rf /var/lib/apt/lists/*

ENV JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64
RUN update-java-alternatives --set java-1.21.0-openjdk-amd64 2>/dev/null || true

USER agent

# Maven settings for GitHub Packages. No token is baked in — this image is
# built from a public repo. settings.xml reads $MAVEN_GH_TOKEN, which has to be
# supplied at sandbox runtime; sbx's credential proxy does not cover
# maven.pkg.github.com (measured — see findings.md), so the real read:packages
# token must be inside the VM for Maven to resolve anything.
COPY --chown=agent:agent m2-settings.xml /home/agent/.m2/settings.xml

# OpenSpec via the standalone installer rather than npm: it drops a single
# binary in ~/.local/bin and doesn't pin us to a Node version. Pinned, because
# stores are a beta feature whose file formats can change between releases.
ENV OPENSPEC_VERSION=v1.16.0
RUN curl -fsSL https://openspec.dev/cli/install.sh | sh

ENV PATH="/home/agent/.local/bin:${PATH}"

# Keep OpenSpec off the network at runtime: no update check, no telemetry.
# Without these it reaches for openspec.dev / edge.openspec.dev, which the
# egress policy denies anyway, producing slow commands and confusing errors.
ENV OPENSPEC_NO_UPDATE_CHECK=1 \
    DO_NOT_TRACK=1
