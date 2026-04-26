# syntax=docker/dockerfile:1
ARG GO_VERSION=1.22
FROM golang:${GO_VERSION}-alpine AS builder
WORKDIR /build
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -o leveldb-app ./cmd/leveldb-app

FROM alpine:3.20
RUN addgroup -S -g 1000 app \
    && adduser -S -u 1000 -G app app \
    && mkdir -p /data/leveldb \
    && chown -R app:app /data
COPY --from=builder /build/leveldb-app /usr/local/bin/leveldb-app
ENV DATA_DIR=/data/leveldb
EXPOSE 8080
USER app
ENTRYPOINT ["leveldb-app"]
