# OneMCP Makefile
APP_NAME = OneMCP
VERSION = 1.0.0

.PHONY: help build run clean app dmg test

help: ## Show available commands
	@echo "OneMCP Build Commands:"
	@echo "====================="
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

build: ## Build for development
	swift build

run: ## Run in development mode
	swift run

release: ## Build release version
	swift build --configuration release

test: ## Run tests
	swift test

app: ## Create macOS app bundle
	@chmod +x assets/scripts/build_app.sh
	./assets/scripts/build_app.sh

dmg: ## Create DMG package
	@chmod +x assets/scripts/build_release.sh
	./assets/scripts/build_release.sh

clean: ## Clean build artifacts
	swift package clean
	rm -rf .build
	rm -rf $(APP_NAME).app
	rm -rf $(APP_NAME)-$(VERSION).dmg
	rm -rf assets/generated/$(APP_NAME).iconset
	rm -rf assets/generated/MenuBarIcon.iconset
	rm -rf assets/icons
	rm -f *.icns *.png

package: clean release dmg ## Full build and package pipeline
	@echo "✅ Package created: $(APP_NAME)-$(VERSION).dmg" 