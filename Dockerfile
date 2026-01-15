FROM alpine:3.21

ARG TARGETARCH
ARG BINARY_NAME=sed

# Install Vulkan runtime and drivers
RUN apk add --no-cache vulkan-loader mesa-vulkan-swrast && \
    if [ "${TARGETARCH}" = "amd64" ]; then \
        apk add --no-cache mesa-vulkan-ati mesa-vulkan-intel || true; \
    elif [ "${TARGETARCH}" = "arm64" ]; then \
        apk add --no-cache mesa-vulkan-broadcom mesa-vulkan-freedreno mesa-vulkan-panfrost || true; \
    fi

# Copy the architecture-specific binary
COPY binaries/${TARGETARCH}/${BINARY_NAME} /usr/local/bin/${BINARY_NAME}
RUN chmod +x /usr/local/bin/${BINARY_NAME}

ENTRYPOINT ["sed"]
CMD ["--help"]
