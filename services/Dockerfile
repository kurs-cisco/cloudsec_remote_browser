FROM golang:1.24-bookworm AS build

ARG SERVICE
WORKDIR /src

COPY go.mod ./
RUN go mod download

COPY . .
RUN test -n "${SERVICE}" \
    && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags="-s -w" -o /out/service "./cmd/${SERVICE}"

FROM debian:bookworm-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN groupadd --system rbi && useradd --system --no-create-home --gid rbi --shell /usr/sbin/nologin rbi

COPY --from=build /out/service /usr/local/bin/rbi-service

USER rbi
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/rbi-service"]
