# syntax=docker/dockerfile:1.7
FROM python:3.12.7-slim-bookworm AS builder

ENV PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1

RUN apt-get update \
    && apt-get install --yes --no-install-recommends gcc libc6-dev linux-libc-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build
COPY requirements.txt .
RUN pip wheel --wheel-dir /wheels -r requirements.txt

FROM python:3.12.7-slim-bookworm AS runtime

ARG APP_UID=10001
ARG APP_GID=10001
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    COUNTER_CONFIG_PATH=/config/runtime.yaml \
    COUNTER_CREDENTIALS_PATH=/config/credentials.enc \
    COUNTER_KEY_PATH=/key/master.key

RUN groupadd --gid ${APP_GID} counter \
    && useradd --uid ${APP_UID} --gid ${APP_GID} --no-create-home --shell /usr/sbin/nologin counter

COPY --from=builder /wheels /wheels
COPY requirements.txt /tmp/requirements.txt
RUN pip install --no-index --find-links=/wheels -r /tmp/requirements.txt \
    && rm -rf /wheels /tmp/requirements.txt

WORKDIR /app
COPY counter_inspect ./counter_inspect
COPY counter_mqtt_bridge.py counter_ota.py scanner_inspect.py ./

USER ${APP_UID}:${APP_GID}
CMD ["python", "-m", "counter_inspect.bridge"]
