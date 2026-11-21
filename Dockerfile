# BKG TTS — self-contained image for the generic TTS engine.
#
# The image is built locally. No registry is contacted at runtime, the model
# weights come from a mounted directory. The build has four stages:
#
#   zig  the pinned Zig toolchain
#   ort  the pinned ONNX runtime
#   build the server binary and the browser WASM module
#   web  the React client
#
# The final stage carries the server, the ONNX runtime, espeak-ng and the
# built web client. It runs as a non-root user and writes only into the
# mounted data volume.

ARG DEBIAN_FRONTEND=noninteractive

FROM debian:trixie-slim AS zig
ARG ZIG_VERSION=0.16.0
ARG ZIG_SHA256=70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl xz-utils \
    && rm -rf /var/lib/apt/lists/*
RUN curl -fsSL --retry 3 \
      "https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz" \
      -o /tmp/zig.tar.xz \
    && echo "${ZIG_SHA256}  /tmp/zig.tar.xz" | sha256sum -c - \
    && mkdir -p /opt/zig \
    && tar -xJf /tmp/zig.tar.xz --strip-components=1 -C /opt/zig \
    && rm -f /tmp/zig.tar.xz
ENV PATH="/opt/zig:${PATH}"

FROM debian:trixie-slim AS ort
ARG ORT_VERSION=1.22.0
ARG ORT_SHA256=8344d55f93d5bc5021ce342db50f62079daf39aaafb5d311a451846228be49b3
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*
RUN curl -fsSL --retry 3 \
      "https://github.com/microsoft/onnxruntime/releases/download/v${ORT_VERSION}/onnxruntime-linux-x64-${ORT_VERSION}.tgz" \
      -o /tmp/onnxruntime.tgz \
    && echo "${ORT_SHA256}  /tmp/onnxruntime.tgz" | sha256sum -c - \
    && mkdir -p /opt/onnxruntime \
    && tar -xzf /tmp/onnxruntime.tgz -C /opt/onnxruntime --strip-components=1 \
    && rm -f /tmp/onnxruntime.tgz

FROM debian:trixie-slim AS build
RUN apt-get update \
    && apt-get install -y --no-install-recommends libc6-dev libespeak-ng1 espeak-ng-data \
    && rm -rf /var/lib/apt/lists/*
COPY --from=zig /opt/zig /opt/zig
ENV PATH="/opt/zig:${PATH}"
WORKDIR /src
COPY . .
RUN zig build --prefix /out --release=safe \
    && zig build test --release=safe \
    && zig build wasm

FROM node:22-trixie-slim AS web
WORKDIR /web
COPY web/package.json web/package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY web/ ./
COPY --from=build /src/zig-out/bin/bkg-tts-wasm.wasm /web/public/wasm/bkg-tts-wasm.wasm
RUN npm run build

FROM debian:trixie-slim AS runtime
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
         ca-certificates curl libespeak-ng1 espeak-ng-data libstdc++6 libgcc-s1 \
    && rm -rf /var/lib/apt/lists/*
# Die Bibliothek bleibt unter /opt/onnxruntime, weil die Engine diesen Ort
# ohne Konfiguration sucht. ldconfig macht die SONAME auffindbar.
COPY --from=ort /opt/onnxruntime/lib /opt/onnxruntime/lib
RUN echo "/opt/onnxruntime/lib" > /etc/ld.so.conf.d/onnxruntime.conf \
    && ldconfig
COPY --from=build /out/bin/bkg-tts /usr/local/bin/bkg-tts
COPY --from=web /web/dist /srv/bkg-tts/web/dist
RUN groupadd --system --gid 10001 bkg-tts \
    && useradd --system --uid 10001 --gid bkg-tts \
        --home-dir /srv/bkg-tts --shell /usr/sbin/nologin bkg-tts \
    && mkdir -p /srv/bkg-tts/models /srv/bkg-tts/data \
    && chown -R bkg-tts:bkg-tts /srv/bkg-tts

ENV BKG_TTS_HOST=0.0.0.0 \
    BKG_TTS_PORT=8092 \
    BKG_TTS_MODELS_DIR=/srv/bkg-tts/models \
    BKG_TTS_ORT_LIBRARY=/opt/onnxruntime/lib/libonnxruntime.so \
    BKG_TTS_ESPEAK_LIBRARY=/usr/lib/x86_64-linux-gnu/libespeak-ng.so.1 \
    BKG_TTS_ESPEAK_DATA=/usr/lib/x86_64-linux-gnu/espeak-ng-data \
    BKG_TTS_WEB_DIST=/srv/bkg-tts/web/dist \
    BKG_TTS_PRONUNCIATION_PATH=/srv/bkg-tts/data/pronunciation.json

USER bkg-tts
WORKDIR /srv/bkg-tts
EXPOSE 8092
VOLUME ["/srv/bkg-tts/data"]
HEALTHCHECK --interval=30s --timeout=5s --start-period=120s --retries=3 \
    CMD curl -fsS http://127.0.0.1:8092/health >/dev/null || exit 1
ENTRYPOINT ["/usr/local/bin/bkg-tts"]
