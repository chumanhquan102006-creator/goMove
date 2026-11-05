# PostgreSQL 16 / PostGIS 3.5 compatibility spike. Build for linux/arm64.
# The official PostgreSQL manifest is multi-architecture; the digest pins its contents.
ARG POSTGRES_BASE=postgres:16.15-bookworm@sha256:e8a07d2c7579b038938cdba6c539e580e5001caf9ea203d397b5cc83e76bd938
FROM ${POSTGRES_BASE} AS build

ARG POSTGIS_VERSION=3.5.7
ARG POSTGIS_SHA256=af9ab591854d52a0d1115f90b797ef1cd60d01b85a11ff813073689e332272ff

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates curl build-essential \
        postgresql-server-dev-16=16.15-1.pgdg12+2 \
        libgeos-dev=3.11.1-1 \
        libgeos-c1v5=3.11.1-1 \
        libproj-dev=9.1.1-1+b1 \
        libproj25=9.1.1-1+b1 \
        libjson-c-dev libxml2-dev; \
    rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    curl --fail --show-error --silent --location \
        "https://download.osgeo.org/postgis/source/postgis-${POSTGIS_VERSION}.tar.gz" \
        --output /tmp/postgis.tar.gz; \
    echo "${POSTGIS_SHA256}  /tmp/postgis.tar.gz" | sha256sum -c -; \
    tar -xzf /tmp/postgis.tar.gz -C /tmp; \
    cd "/tmp/postgis-${POSTGIS_VERSION}"; \
    ./configure --with-pgconfig=/usr/lib/postgresql/16/bin/pg_config \
        --without-raster --without-topology --without-tiger --without-protobuf; \
    make -j2; \
    make DESTDIR=/opt/postgis-root install

FROM ${POSTGRES_BASE}

LABEL org.opencontainers.image.source="https://github.com/chumanhquan102006-creator/goMove" \
      org.opencontainers.image.description="GoMove PostgreSQL 16.15 + PostGIS 3.5.7 ARM64 compatibility spike"

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        libgeos-c1v5=3.11.1-1 \
        libproj25=9.1.1-1+b1 \
        libjson-c5 libxml2; \
    rm -rf /var/lib/apt/lists/*

COPY --from=build /opt/postgis-root/usr/ /usr/

# Flyway V1 creates the extension in its own fresh database. No initdb script is used.
HEALTHCHECK --interval=10s --timeout=5s --start-period=20s --retries=12 \
    CMD pg_isready -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-postgres}" || exit 1
