.PHONY: collections install deploy check hardening docker matrix ping facts lint help

ANSIBLE_DIR := ansible
INVENTORY   := $(ANSIBLE_DIR)/inventory.ini

##@ General

help: ## Show this help message
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} \
	/^[a-zA-Z_-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 } \
	/^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) }' $(MAKEFILE_LIST)

##@ Setup

collections: ## Install required Ansible collections
	ansible-galaxy collection install -r $(ANSIBLE_DIR)/requirements.yml

##@ Deployment

install: collections ## Bootstrap server as root (system hardening + Docker)
	ansible-playbook -i $(INVENTORY) $(ANSIBLE_DIR)/install.yml

deploy: collections ## Deploy Matrix stack as deploy user (requires install to have run first)
	ansible-playbook -i $(INVENTORY) $(ANSIBLE_DIR)/deploy.yml

check: collections ## Dry-run the full playbook without making changes
	ansible-playbook -i $(INVENTORY) $(ANSIBLE_DIR)/site.yml --check --diff

##@ Individual roles

hardening: collections ## Run only the system hardening role
	ansible-playbook -i $(INVENTORY) $(ANSIBLE_DIR)/install.yml --tags common

docker: collections ## Run only the Docker installation role
	ansible-playbook -i $(INVENTORY) $(ANSIBLE_DIR)/install.yml --tags docker

matrix: collections ## Re-run only the Matrix stack role
	ansible-playbook -i $(INVENTORY) $(ANSIBLE_DIR)/deploy.yml --tags matrix

##@ Utilities

ping: ## Test SSH connectivity (as deploy user)
	ansible -i $(INVENTORY) matrix -m ping -u usr

facts: ## Gather and display host facts (as deploy user)
	ansible -i $(INVENTORY) matrix -m setup -u usr

lint: ## Lint the Ansible playbooks (requires ansible-lint)
	ansible-lint $(ANSIBLE_DIR)/install.yml $(ANSIBLE_DIR)/deploy.yml
