FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    verilator build-essential g++ make \
    python3 python3-pip python3-dev ffmpeg wget \
    libavformat-dev libavcodec-dev libavdevice-dev libavutil-dev \
    libswscale-dev libswresample-dev pkg-config \
    && rm -rf /var/lib/apt/lists/*

RUN pip3 install --no-cache-dir numpy av

WORKDIR /workspace
