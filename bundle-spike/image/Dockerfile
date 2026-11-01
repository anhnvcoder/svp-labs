# A minimal image: one text file, no OS, nothing to scan. It exists only to be the subject of a signature, a vuln
# attestation and a build provenance attestation, all three as Sigstore bundles. VARIANT only changes a label, so the
# workflow gets a second digest of the same content (the control without a vuln attestation).
FROM scratch
ARG VARIANT=release
LABEL org.opencontainers.image.description="svp-labs bundle-spike ($VARIANT)"
COPY hello.txt /hello.txt
