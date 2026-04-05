.PHONY: setup ecr-login docker-build docker-tag docker-push db-setup check-setup help

ENV_DIR       := terraform/aws/environments/techXX
REGION        := ap-northeast-1
ENV_FILE      := .env.handson

# デフォルト値
PROFILE       ?= aws-handson
BUCKET_PREFIX ?= ca26

# .env.handson から変数を読み込む（setup 後は保存済みの値を使用）
-include $(ENV_FILE)
export

####################
# Setup
####################

# Example:
#   make setup TEAM_NAME=tech01 USER_NAME=ibaraki DOMAIN_NAME=tech01-handson.ca26.ca-developers.io
#
# Private (CyberAgent) 用:
#   make setup TEAM_NAME=tech99 USER_NAME=ibaraki PROFILE=aws-ca26-tech99 DOMAIN_NAME=tech99-handson.ca26.ca-developers.io
setup:
ifndef TEAM_NAME
	$(error TEAM_NAME is required. Example: make setup TEAM_NAME=tech01 USER_NAME=ibaraki DOMAIN_NAME=tech01-handson.ca26.ca-developers.io)
endif
ifndef USER_NAME
	$(error USER_NAME is required. Example: make setup TEAM_NAME=tech01 USER_NAME=ibaraki DOMAIN_NAME=tech01-handson.ca26.ca-developers.io)
endif
ifndef DOMAIN_NAME
	$(error DOMAIN_NAME is required. Example: make setup TEAM_NAME=tech01 USER_NAME=ibaraki DOMAIN_NAME=tech01-handson.ca26.ca-developers.io)
endif
	@echo "========================================="
	@echo "  AWS Handson Setup"
	@echo "  TEAM_NAME:     $(TEAM_NAME)"
	@echo "  USER_NAME:     $(USER_NAME)"
	@echo "  DOMAIN_NAME:   $(DOMAIN_NAME)"
	@echo "  PROFILE:       $(PROFILE)"
	@echo "  BUCKET_PREFIX: $(BUCKET_PREFIX)"
	@echo "========================================="
	@# --- techXX の一括置換 ---
	@find $(ENV_DIR) -type f \( -name "*.tf" -o -name "*.md" \) \
		-exec sed -i '' 's/techXX/$(TEAM_NAME)/g' {} +
	@sed -i '' 's/techXX/$(TEAM_NAME)/g' README.md
	@# --- user-name の一括置換 ---
	@find $(ENV_DIR) -type f \( -name "*.tf" -o -name "*.md" \) \
		-exec grep -l 'user-name' {} + 2>/dev/null \
		| xargs sed -i '' 's|user-name|$(USER_NAME)|g'
	@# --- profile の置換 ---
	@find $(ENV_DIR) -type f \( -name "*.tf" -o -name "*.md" \) \
		-exec sed -i '' 's/aws-handson/$(PROFILE)/g' {} +
	@# --- bucket prefix の置換 ---
	@find $(ENV_DIR) -type f \( -name "*.tf" -o -name "*.md" \) \
		-exec sed -i '' 's/ca26-/$(BUCKET_PREFIX)-/g' {} +
	@sed -i '' 's/ca26-/$(BUCKET_PREFIX)-/g' README.md
	@# --- ecs/variables.tf: app_name と image_tag のデフォルト値を設定 ---
	@sed -i '' 's|# default     = "your-name" # 自分の名前に変更|default     = "$(USER_NAME)"|g' \
		$(ENV_DIR)/ecs/variables.tf
	@sed -i '' 's|# default     = "v1" # 自分のバージョンに変更|default     = "$(USER_NAME)"|g' \
		$(ENV_DIR)/ecs/variables.tf
	@# --- route53/variables.tf: sub_domain_prefix のデフォルト値を設定 ---
	@sed -i '' 's|# default     = "your-name"|default     = "$(USER_NAME)"|g' \
		$(ENV_DIR)/route53/variables.tf
	@# --- domain_name のデフォルト値を設定（ecs, route53） ---
	@sed -i '' 's|# default     = "your-domain-name" # 自分のチームのドメイン名に変更|default     = "$(DOMAIN_NAME)"|g' \
		$(ENV_DIR)/ecs/variables.tf
	@sed -i '' 's|# default     = "your-domain-name"|default     = "$(DOMAIN_NAME)"|g' \
		$(ENV_DIR)/route53/variables.tf
	@# --- .env.handson に設定を保存 ---
	@echo "TEAM_NAME=$(TEAM_NAME)" > $(ENV_FILE)
	@echo "USER_NAME=$(USER_NAME)" >> $(ENV_FILE)
	@echo "DOMAIN_NAME=$(DOMAIN_NAME)" >> $(ENV_FILE)
	@echo "PROFILE=$(PROFILE)" >> $(ENV_FILE)
	@echo "BUCKET_PREFIX=$(BUCKET_PREFIX)" >> $(ENV_FILE)
	@echo ""
	@echo "Setup complete!"
	@echo "Run 'git diff' to verify changes."

# セットアップ済みか確認
check-setup:
	@if [ ! -f $(ENV_FILE) ]; then \
		echo "Error: $(ENV_FILE) not found. Run 'make setup' first."; \
		exit 1; \
	fi

####################
# ECR
####################

# ECR リポジトリ URL を取得
ecr-url: check-setup
	@cd $(ENV_DIR)/ecr && \
		terraform output -raw repository_url

# ECR にログイン
ecr-login: check-setup
	@REPO_URL=$$(cd $(ENV_DIR)/ecr && terraform output -raw repository_url) && \
		aws ecr get-login-password \
			--region $(REGION) \
			--profile $(PROFILE) \
		| docker login \
			--username AWS \
			--password-stdin \
			$$REPO_URL

####################
# Docker
####################

# docker build
docker-build: check-setup
	docker build -t bookshelf:$(USER_NAME) -f api/Dockerfile .

# docker tag（USER_NAME をタグとして使用）
docker-tag: check-setup
	@REPO_URL=$$(cd $(ENV_DIR)/ecr && terraform output -raw repository_url) && \
		docker tag bookshelf:$(USER_NAME) $$REPO_URL:$(USER_NAME) && \
		echo "Tagged: $$REPO_URL:$(USER_NAME)"

# docker push
docker-push: check-setup
	@REPO_URL=$$(cd $(ENV_DIR)/ecr && terraform output -raw repository_url) && \
		docker push $$REPO_URL:$(USER_NAME) && \
		echo "Pushed: $$REPO_URL:$(USER_NAME)"

####################
# Database
####################

SECRET_ID := /rds/bookshelf/bookshelf-password
MIGRATION_SQL := db/migrations/20250331054301_create_books_table.sql

# DB セットアップ（bookshelf_w ユーザー作成 + テーブル作成）
# operation EC2 上で Secrets Manager からパスワードを取得して実行する。
# パスワードがローカルやコマンドラインに露出しない。
db-setup: check-setup
	@echo "========================================="
	@echo "  DB Setup via Operation EC2"
	@echo "========================================="
	@INSTANCE_ID=$$(cd $(ENV_DIR)/operation && terraform output -raw instance_id) && \
	echo "Instance: $$INSTANCE_ID" && \
	echo "" && \
	echo "Creating user bookshelf_w and running migration..." && \
	COMMAND_ID=$$(aws ssm send-command \
		--instance-ids "$$INSTANCE_ID" \
		--document-name "AWS-RunShellScript" \
		--parameters '{"commands":["#!/bin/bash","set -e","SECRET=$$(aws secretsmanager get-secret-value --secret-id $(SECRET_ID) --region $(REGION) --query SecretString --output text)","DB_HOST=$$(echo $$SECRET | python3 -c \"import sys,json; print(json.load(sys.stdin)['"'"'host'"'"'])\" 2>/dev/null || echo $$SECRET | python -c \"import sys,json; print(json.load(sys.stdin)['"'"'host'"'"'])\" )","ADMIN_USER=$$(echo $$SECRET | python3 -c \"import sys,json; print(json.load(sys.stdin)['"'"'admin_username'"'"'])\" 2>/dev/null || echo $$SECRET | python -c \"import sys,json; print(json.load(sys.stdin)['"'"'admin_username'"'"'])\" )","ADMIN_PASS=$$(echo $$SECRET | python3 -c \"import sys,json; print(json.load(sys.stdin)['"'"'admin_password'"'"'])\" 2>/dev/null || echo $$SECRET | python -c \"import sys,json; print(json.load(sys.stdin)['"'"'admin_password'"'"'])\" )","APP_PASS=$$(echo $$SECRET | python3 -c \"import sys,json; print(json.load(sys.stdin)['"'"'password'"'"'])\" 2>/dev/null || echo $$SECRET | python -c \"import sys,json; print(json.load(sys.stdin)['"'"'password'"'"'])\" )","echo \"DB Host: $$DB_HOST\"","mysql -h $$DB_HOST -u $$ADMIN_USER -p\"$$ADMIN_PASS\" -e \"CREATE USER IF NOT EXISTS '"'"'bookshelf_w'"'"'@'"'"'%%'"'"' IDENTIFIED BY '"'"'$$APP_PASS'"'"'; GRANT ALL PRIVILEGES ON bookshelf.* TO '"'"'bookshelf_w'"'"'@'"'"'%%'"'"'; FLUSH PRIVILEGES;\"","echo \"User bookshelf_w created.\"","mysql -h $$DB_HOST -u bookshelf_w -p\"$$APP_PASS\" bookshelf -e \"CREATE TABLE IF NOT EXISTS books ( id BIGINT AUTO_INCREMENT PRIMARY KEY, title VARCHAR(255) NOT NULL, author VARCHAR(255) NOT NULL, isbn VARCHAR(20), publisher VARCHAR(255), description TEXT, created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP, updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP );\"","echo \"Table books created.\"","echo \"Done!\""]}' \
		--profile $(PROFILE) \
		--query 'Command.CommandId' \
		--output text) && \
	echo "SSM Command: $$COMMAND_ID" && \
	echo "Waiting for completion..." && \
	sleep 10 && \
	aws ssm get-command-invocation \
		--command-id "$$COMMAND_ID" \
		--instance-id "$$INSTANCE_ID" \
		--profile $(PROFILE) \
		--query '{Status:Status,Output:StandardOutputContent,Error:StandardErrorContent}' \
		--output json && \
	echo "" && \
	echo "DB setup complete!"

####################
# Help
####################

help:
	@echo ""
	@echo "AWS Handson Makefile"
	@echo ""
	@echo "  Setup:"
	@echo "    make setup TEAM_NAME=tech01 USER_NAME=ibaraki DOMAIN_NAME=tech01-handson.ca26.ca-developers.io"
	@echo ""
	@echo "    Parameters:"
	@echo "      TEAM_NAME      (required) Team identifier (e.g., tech01, tech99)"
	@echo "      USER_NAME      (required) Your name (e.g., ibaraki)"
	@echo "      DOMAIN_NAME    (required) Team domain (e.g., tech01-handson.ca26.ca-developers.io)"
	@echo "      PROFILE        (optional) AWS profile name (default: aws-handson)"
	@echo "      BUCKET_PREFIX  (optional) S3 bucket prefix (default: ca26)"
	@echo ""
	@echo "    Example:"
	@echo "      make setup TEAM_NAME=tech99 USER_NAME=ibaraki DOMAIN_NAME=tech99-handson.ca26.ca-developers.io PROFILE=aws-ca26-tech99"
	@echo ""
	@echo "  ECR:"
	@echo "    make ecr-url        ECR Repository URL を表示"
	@echo "    make ecr-login      ECR にログイン"
	@echo ""
	@echo "  Docker:"
	@echo "    make docker-build   docker build を実行"
	@echo "    make docker-tag     docker tag (USER_NAME をタグに使用)"
	@echo "    make docker-push    docker push"
	@echo ""
	@echo "  Database (運営者向け):"
	@echo "    make db-setup       bookshelf_w ユーザー作成 + テーブル作成"
	@echo ""
