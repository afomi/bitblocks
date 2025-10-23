# Accessibility Testing

This project includes automated accessibility testing using axe-core to ensure WCAG 2.1 compliance.

## Prerequisites

### ChromeDriver

Wallaby requires ChromeDriver to run browser-based tests:

**macOS:**
```bash
brew install chromedriver
```

**Linux:**
```bash
# Download and install ChromeDriver matching your Chrome version
wget https://chromedriver.storage.googleapis.com/LATEST_RELEASE
# Follow installation instructions
```

**Verify installation:**
```bash
chromedriver --version
```

## Running Accessibility Tests

### Run all accessibility tests
```bash
# Full axe-core tests (requires ChromeDriver)
mix test --only accessibility_axe

# Legacy Floki-based tests (no browser required)
mix test test/bitblocks_web/accessibility_test.exs
```

### Run with visible browser (for debugging)
```bash
HEADLESS=false mix test --only accessibility_axe
```

### Run in CI/CD
The tests run in headless mode by default, suitable for CI/CD pipelines.

## Test Coverage

The axe-core tests (`accessibility_axe_test.exs`) scan all major pages:
- Home page (/)
- Status page (/status)
- Blocks index and show pages
- Transactions index and show pages
- Sync page (/sync)
- Protocols page (/protocols)
- Graph page (/graph)
- Highlights page (/highlights)
- Search page (/search)
- Builder page (/builder)
- Config page (/config)

## What's Tested

The axe-core library checks for:
- WCAG 2.1 Level A and AA violations
- Keyboard accessibility
- Screen reader compatibility
- Color contrast
- Form labels and ARIA attributes
- Heading hierarchy
- Image alt text
- And 90+ other accessibility rules

## Migration Plan

**Current state:**
- ✅ `accessibility_test.exs` - Floki-based tests (no browser required)
- ✅ `accessibility_axe_test.exs` - Full axe-core tests (requires ChromeDriver)

**Next steps:**
1. Set up ChromeDriver in CI/CD
2. Ensure all axe-core tests pass
3. Remove `accessibility_test.exs` and `accessibility_case.ex`
4. Keep only axe-core based tests going forward

## Troubleshooting

### ChromeDriver not found
```
** (RuntimeError) Neither chromedriver nor Google Chrome are installed
```

Install ChromeDriver using the instructions above.

### Connection refused
```
** (Wallaby.CommunicationError) Could not connect to ChromeDriver
```

Ensure ChromeDriver is running or installed correctly.

### Tests fail with violations
Review the violation details in the test output. Each violation includes:
- The accessibility rule that failed
- The HTML element causing the issue
- Suggested fixes

Fix the violations and re-run the tests.
