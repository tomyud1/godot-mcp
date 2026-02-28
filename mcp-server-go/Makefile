BINARY = godot-mcp-server

.PHONY: all build clean build-all

all: build

build:
	go build -o bin/$(BINARY) ./cmd/godot-mcp-server

build-all:
	GOOS=linux   GOARCH=amd64 go build -o bin/$(BINARY)-linux-amd64       ./cmd/godot-mcp-server
	GOOS=linux   GOARCH=arm64 go build -o bin/$(BINARY)-linux-arm64       ./cmd/godot-mcp-server
	GOOS=darwin  GOARCH=amd64 go build -o bin/$(BINARY)-darwin-amd64      ./cmd/godot-mcp-server
	GOOS=darwin  GOARCH=arm64 go build -o bin/$(BINARY)-darwin-arm64      ./cmd/godot-mcp-server
	GOOS=windows GOARCH=amd64 go build -o bin/$(BINARY)-windows-amd64.exe ./cmd/godot-mcp-server

clean:
	rm -rf bin/
