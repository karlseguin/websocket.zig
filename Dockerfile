from ubuntu:latest
run apt-get update && apt-get install -y wget xz-utils

run wget "https://ziglang.org/builds/zig-linux-aarch64-0.14.0-dev.244+0d79aa017.tar.xz"
run tar -xJvf zig-linux-aarch64-0.14.0-dev.244+0d79aa017.tar.xz && \
    mv /zig-linux-aarch64-0.14.0-dev.244+0d79aa017/ /zig && \
    chmod a+x /zig && \
    rm -fr /zig-*

workdir /opt
entrypoint ["/zig/zig", "build", "test"]
