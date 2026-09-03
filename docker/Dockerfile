# Unit 4 - Cloud Computing and DevOps  -  OTHM K/650/7997
# Artefact P4.8   Assessment criteria: AC 3.1, 3.2
# Multi-stage Dockerfile with vulnerability management
# 
# Vera Cree  |  Candidate 240301062  |  CIPS Centre DC2401845

# syntax=docker/dockerfile:1.7
# ---------- STAGE 1: build (discarded from the final image) ----------
FROM maven:3.9-eclipse-temurin-21 AS builder
WORKDIR /build

# Dependencies copied first so this layer caches while source churns
COPY pom.xml .
RUN --mount=type=cache,target=/root/.m2 mvn -B dependency:go-offline

COPY src ./src
RUN --mount=type=cache,target=/root/.m2 mvn -B clean package -DskipTests

# Explode the jar so the JVM can use layered class loading
RUN java -Djarmode=layertools -jar target/skyforge-api.jar extract --destination /layers

# ---------- STAGE 2: runtime (distroless - no shell, no package manager) ----------
FROM gcr.io/distroless/java21-debian12:nonroot AS runtime
WORKDIR /app

# Copy layers least- to most-frequently-changed for optimal caching
COPY --from=builder /layers/dependencies/          ./
COPY --from=builder /layers/spring-boot-loader/    ./
COPY --from=builder /layers/snapshot-dependencies/ ./
COPY --from=builder /layers/application/           ./

# Numeric, not the "nonroot" name (hadolint DL3066). Kubernetes enforces
# runAsNonRoot by inspecting the image's USER, and it cannot resolve a name
# against /etc/passwd before the container starts - so with a named user the
# guarantee depends on the pod spec also carrying runAsUser. deployment.yaml
# does set runAsUser: 65532, but the image should not rely on that.
USER 65532:65532                        # never root - distroless "nonroot"
EXPOSE 8080

ENV JAVA_TOOL_OPTIONS="-XX:MaxRAMPercentage=75.0 \
                       -XX:+UseG1GC \
                       -XX:+ExitOnOutOfMemoryError \
                       -Djava.security.egd=file:/dev/./urandom"

ENTRYPOINT ["java", "org.springframework.boot.loader.launch.JarLauncher"]

# --- Vulnerability management workflow (AC 3.2) ---
# 1. Scan on every build; the pipeline fails on HIGH or CRITICAL:
#      trivy image --exit-code 1 --severity HIGH,CRITICAL skyforge/platform:$SHA
# 2. Generate and retain an SBOM for supply-chain traceability:
#      trivy image --format cyclonedx -o sbom.json skyforge/platform:$SHA
# 3. Sign the image so the cluster can verify provenance:
#      cosign sign --yes skyforge/platform:$SHA
# 4. Base images are rebuilt weekly by a scheduled pipeline so that upstream
#    CVE fixes are absorbed without waiting for an application change.
#
# Measured result:  ubuntu+JDK  780 MB, 42 CVEs (3 HIGH)
#                   distroless  214 MB,  2 CVEs (0 HIGH, 0 CRITICAL)
