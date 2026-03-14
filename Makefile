# ─────────────────────────────────────────────────────────────
#  Mochicord — Dev Makefile
# ─────────────────────────────────────────────────────────────

.DEFAULT_GOAL := help
COMPOSE_FILE  := docker-compose.development.yaml
CARGO         := cargo

BOLD  := $(shell tput bold  2>/dev/null || echo '')
RESET := $(shell tput sgr0  2>/dev/null || echo '')
GREEN := $(shell tput setaf 2 2>/dev/null || echo '')
CYAN  := $(shell tput setaf 6 2>/dev/null || echo '')
RED   := $(shell tput setaf 1 2>/dev/null || echo '')

# ── Help ──────────────────────────────────────────────────────
.PHONY: help
help:
	@echo ""
	@echo "$(BOLD)Mochicord$(RESET) — available targets:"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  $(CYAN)%-26s$(RESET) %s\n", $$1, $$2}'
	@echo ""

# ── Infra ─────────────────────────────────────────────────────
.PHONY: up down infra-logs infra-ps minio-init

up: ## Start all dev infra (detached)
	docker compose -f $(COMPOSE_FILE) up -d --remove-orphans

down: ## Stop and remove all dev containers
	docker compose -f $(COMPOSE_FILE) down

infra-logs: ## Tail logs from all infra containers
	docker compose -f $(COMPOSE_FILE) logs -f

infra-ps: ## Show running infra containers
	docker compose -f $(COMPOSE_FILE) ps

minio-init: up ## Create dev buckets in MinIO (run once after first 'make up')
	@sleep 3
	docker run --rm --network mochicord-dev \
		--entrypoint sh minio/mc -c "\
		mc alias set local http://minio:9000 minioadmin minioadmin && \
		mc mb -p local/mochicord-media-sfw && \
		mc mb -p local/mochicord-media-nsfw && \
		mc mb -p local/mochicord-moq-cache && \
		mc mb -p local/mochicord-ingest && \
		echo 'Buckets created.'"

# ── Protobuf ──────────────────────────────────────────────────
.PHONY: proto proto-check proto-deps

proto: ## Compile .proto → Rust via tonic-build (requires protoc)
	@command -v protoc >/dev/null 2>&1 || \
		(echo "$(RED)protoc not found. Run: make proto-deps$(RESET)" && exit 1)
	$(CARGO) build -p mochicord-proto
	@echo "$(GREEN)Proto build complete.$(RESET)"

proto-check: ## Fast check proto crate without full codegen
	$(CARGO) check -p mochicord-proto

proto-deps: ## Install protoc (Debian/Ubuntu)
	sudo apt-get update && sudo apt-get install -y protobuf-compiler

# ── Build ─────────────────────────────────────────────────────
.PHONY: build build-release check

build: proto ## Build entire workspace
	$(CARGO) build --workspace

build-release: proto ## Release build
	$(CARGO) build --workspace --release

check: ## Fast check, no codegen
	$(CARGO) check --workspace

# ── Run individual services ───────────────────────────────────
.PHONY: gateway api rt media auth worker search proxy bot-runtime federation payments

gateway: ## Run gateway-svc (:443 TCP / :4433 UDP)
	$(CARGO) run -p mochicord-gateway

api: ## Run api-svc (:8080)
	$(CARGO) run -p mochicord-api

rt: ## Run rt-svc (:4433 QUIC primary / :8081 WS fallback)
	$(CARGO) run -p mochicord-rt

media: ## Run media-svc (:4434 QUIC + MoQ)
	$(CARGO) run -p mochicord-media

auth: ## Run auth-svc (:8083 — NOT in hot path, cache-miss only)
	$(CARGO) run -p mochicord-auth

worker: ## Run worker-svc (no HTTP — background jobs only)
	$(CARGO) run -p mochicord-worker

search: ## Run search-svc (:8084)
	$(CARGO) run -p mochicord-search

proxy: ## Run proxy-svc (:8085 — link proxy, IP leak prevention)
	$(CARGO) run -p mochicord-proxy

bot-runtime: ## Run bot-runtime-svc (:8086)
	$(CARGO) run -p mochicord-bot-runtime

federation: ## Run federation-svc (:8087 Matrix/Nostr/ActivityPub)
	$(CARGO) run -p mochicord-federation

payments: ## Run payments-svc (:8088 Helio)
	$(CARGO) run -p mochicord-payments

# ── Hot reload ────────────────────────────────────────────────
.PHONY: watch-gateway watch-api watch-rt watch-media watch-auth

watch-gateway: ## Hot-reload gateway-svc (requires cargo-watch)
	cargo watch -x "run -p mochicord-gateway"

watch-api: ## Hot-reload api-svc
	cargo watch -x "run -p mochicord-api"

watch-rt: ## Hot-reload rt-svc
	cargo watch -x "run -p mochicord-rt"

watch-media: ## Hot-reload media-svc
	cargo watch -x "run -p mochicord-media"

watch-auth: ## Hot-reload auth-svc
	cargo watch -x "run -p mochicord-auth"

# ── Test ──────────────────────────────────────────────────────
.PHONY: test test-integration test-auth test-proto

test: ## Unit tests across workspace
	$(CARGO) test --workspace

test-integration: up ## Start infra then run integration tests
	$(CARGO) test --workspace --test '*' -- --test-threads=1

test-auth: up ## Auth flow tests specifically (sig verify, cache, age-gate)
	$(CARGO) test -p mochicord-auth -p mochicord-gateway -- auth

test-proto: proto ## Build protos then test proto crate
	$(CARGO) test -p mochicord-proto

# ── gRPC dev tools ────────────────────────────────────────────
# Requires grpcurl: https://github.com/fullstorydev/grpcurl
GRPC_ADDR ?= localhost:50051

.PHONY: grpc-list grpc-health grpc-auth-validate

grpc-list: ## List services via gRPC reflection (set GRPC_ADDR=host:port)
	grpcurl -plaintext $(GRPC_ADDR) list

grpc-health: ## gRPC health check
	grpcurl -plaintext $(GRPC_ADDR) grpc.health.v1.Health/Check

grpc-auth-validate: ## Test ValidateKeypair RPC on auth-svc
	grpcurl -plaintext -d '{"public_key_hex":"$(KEY)"}' \
		localhost:50053 mochicord.auth.AuthService/ValidateKeypair

# ── Lint & Format ─────────────────────────────────────────────
.PHONY: lint fmt fmt-check

lint: ## Clippy — deny warnings
	$(CARGO) clippy --workspace --all-targets -- -D warnings

fmt: ## Format all Rust source
	$(CARGO) fmt --all

fmt-check: ## Check formatting without writing
	$(CARGO) fmt --all -- --check

# ── Audit ─────────────────────────────────────────────────────
.PHONY: audit

audit: ## CVE scan (requires cargo-audit)
	cargo audit

# ── Docs ──────────────────────────────────────────────────────
.PHONY: docs

docs: ## Build and open workspace docs
	$(CARGO) doc --workspace --no-deps --open

# ── Clean ─────────────────────────────────────────────────────
.PHONY: clean nuke env-init

clean: ## Remove Cargo build artefacts
	$(CARGO) clean

nuke: down clean ## Stop infra AND wipe build artefacts
	@echo "$(GREEN)All clear.$(RESET)"

env-init: ## Copy .env.example → .env if .env doesn't exist
	@test -f .env && echo ".env already exists." \
		|| (cp .env.example .env && echo "$(GREEN).env created.$(RESET)")
