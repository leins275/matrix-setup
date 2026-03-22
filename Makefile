.PHONY: install run check hardening docker matrix help

ANSIBLE_DIR := ansible
PLAYBOOK    := $(ANSIBLE_DIR)/site.yml
INVENTORY   := $(ANSIBLE_DIR)/inventory.ini
TAGS        ?=

# Build the --tags flag only when TAGS is non-empty
ifdef TAGS
  TAGS_FLAG := --tags $(TAGS)
else
  TAGS_FLAG :=
endif

##@ General

help: ## Show this help message
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} \
	/^[a-zA-Z_-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 } \
	/^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) }' $(MAKEFILE_LIST)

##@ Setup

install: ## Install required Ansible collections
	ansible-galaxy collection install -r $(ANSIBLE_DIR)/requirements.yml

##@ Deployment

run: ## Run the full Ansible playbook (set TAGS=hardening|docker|matrix to run a subset)
	ansible-playbook -i $(INVENTORY) $(PLAYBOOK) $(TAGS_FLAG)

check: ## Dry-run the playbook without making changes
	ansible-playbook -i $(INVENTORY) $(PLAYBOOK) --check --diff $(TAGS_FLAG)

##@ Individual roles

hardening: ## Run only the system hardening role (common)
	ansible-playbook -i $(INVENTORY) $(PLAYBOOK) --tags common

docker: ## Run only the Docker installation role
	ansible-playbook -i $(INVENTORY) $(PLAYBOOK) --tags docker

matrix: ## Run only the Matrix stack deployment role
	ansible-playbook -i $(INVENTORY) $(PLAYBOOK) --tags matrix

##@ Utilities

ping: ## Test SSH connectivity to all hosts
	ansible -i $(INVENTORY) matrix_servers -m ping

facts: ## Gather and display host facts
	ansible -i $(INVENTORY) matrix_servers -m setup

lint: ## Lint the Ansible playbook (requires ansible-lint)
	ansible-lint $(PLAYBOOK)
