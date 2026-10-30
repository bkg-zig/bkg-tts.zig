FROM ubuntu:22.04 AS build

ARG DEBIAN_FRONTEND=noninteractive
ARG ZIG_VERSION=0.16.0

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl xz-utils git build-essential cmake pkg-config gnupg \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get update && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    curl -fSL --retry 3 "https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz" -o /tmp/zig.tar.xz; \
    mkdir -p /opt/zig; \
    tar -xJf /tmp/zig.tar.xz --strip-components=1 -C /opt/zig; \
    ln -s /opt/zig/zig /usr/local/bin/zig; \
    rm /tmp/zig.tar.xz; \
    zig version

COPY zig-body.bkg /opt/bkg/zig-body.bkg
COPY zig-app.bkg/bkg-magpietts.zig /opt/bkg/zig-app.bkg/bkg-magpietts.zig
WORKDIR /opt/bkg/zig-app.bkg/bkg-magpietts.zig

RUN zig build \
    && zig build test \
    && zig build wasm \
    && mkdir -p web/public/wasm \
    && cp zig-out/bin/bkg-magpietts-wasm.wasm web/public/wasm/bkg-magpietts-wasm.wasm \
    && cd web \
    && npm ci --no-audit --no-fund \
    && npm run build

COPY magpie-tts.cpp /tmp/magpie-tts.cpp

RUN set -eux; \
    cmake -S /tmp/magpie-tts.cpp -B /tmp/magpie-build \
      -DCMAKE_BUILD_TYPE=Release \
      -DMAGPIE_SHARED=ON \
      -DMAGPIE_BUILD_CLI=OFF \
      -DMAGPIE_BUILD_SERVER=OFF \
      -DMAGPIE_BUILD_TESTS=OFF \
      -DMAGPIE_GGML_CUDA=OFF \
      -DMAGPIE_GGML_METAL=OFF \
      -DMAGPIE_GGML_VULKAN=OFF \
      -DMAGPIE_GGML_HIP=OFF \
      -DGGML_NATIVE=OFF; \
    cmake --build /tmp/magpie-build --target magpie-tts -j2; \
    test -f /tmp/magpie-build/libmagpie-tts.so

FROM ubuntu:22.04 AS runtime
ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl libstdc++6 libgcc-s1 libgomp1 \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --system --home-dir /srv/magpie --shell /usr/sbin/nologin magpie \
    && mkdir -p /srv/magpie/models /srv/magpie/web/dist /srv/magpie/data \
    && printf '[]\n' > /srv/magpie/data/pronunciation.json \
    && chown -R magpie:magpie /srv/magpie

COPY --from=build /tmp/magpie-build/libmagpie-tts.so /usr/local/lib/libmagpie-tts.so
COPY --from=build /opt/bkg/zig-app.bkg/bkg-magpietts.zig/zig-out/bin/bkg-magpietts /usr/local/bin/bkg-magpietts
COPY --from=build /opt/bkg/zig-app.bkg/bkg-magpietts.zig/web/dist/ /srv/magpie/web/dist/

RUN ldconfig && chmod 0755 /usr/local/bin/bkg-magpietts /usr/local/lib/libmagpie-tts.so && chown -R root:root /srv/magpie/web/dist

ENV MAGPIE_HOST=0.0.0.0 \
    MAGPIE_PORT=8092 \
    MAGPIE_DEVICE=cpu \
    BKG_MAGPIE_LIB_PATH=/usr/local/lib/libmagpie-tts.so \
    BKG_MAGPIE_MODEL=/srv/magpie/models/magpie-tts-multilingual-357m-q8_0.gguf \
    MAGPIE_WEB_DIST=/srv/magpie/web/dist \
    MAGPIE_PRONUNCIATION_PATH=/srv/magpie/data/pronunciation.json

WORKDIR /srv/magpie
USER magpie
EXPOSE 8092
HEALTHCHECK --interval=30s --timeout=3s --start-period=180s --retries=3 CMD curl -fsS http://127.0.0.1:8092/health >/dev/null || exit 1
ENTRYPOINT ["/usr/local/bin/bkg-magpietts"]
