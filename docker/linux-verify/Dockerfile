# Reproducible Linux verification image for ServerFoundationModels.
# Build:  docker build -f docker/linux-verify/Dockerfile -t sfm-linux-verify .
# Run:    docker run --rm sfm-linux-verify
# Live:   docker run --rm -e XAI_API_KEY=... sfm-linux-verify

FROM swift:6.2

WORKDIR /src
COPY . .

RUN bash scripts/linux-verify.sh

# Default entrypoint re-runs verify (override CMD for interactive use).
CMD ["bash", "scripts/linux-verify.sh"]