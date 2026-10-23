FROM golang:1.27.3-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY *.go ./
RUN CGO_ENABLED=0 go build -o /peer .

FROM alpine:3.24
RUN apk add --no-cache iproute2 iptables
COPY --from=build /peer /peer
ENTRYPOINT ["/peer"]
