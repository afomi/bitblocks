# Contributing to Bitblocks

Thank you for your interest in contributing! We welcome contributions from the community.

> **Coding standards, project structure, testing, and commit conventions live in [AGENTS.md](AGENTS.md).**
> This document covers the contribution *workflow*; AGENTS.md is the source of truth for *standards*.

## Getting Started

1. **Fork the repository** on GitHub.
2. **Clone your fork** locally:
   ```bash
   git clone https://github.com/YOUR_USERNAME/bitblocks.git
   cd bitblocks
   ```
3. **Set up your environment** following [README.md](README.md) (`mix setup`).

## Development Workflow

1. **Create a branch** for your feature or bugfix:
   ```bash
   git checkout -b feature/your-feature-name   # or fix/your-bugfix-name
   ```
2. **Make your changes** following the standards in [AGENTS.md](AGENTS.md).
3. **Test**: `mix test` (run `mix format` first).
4. **Commit** with a clear, imperative subject (see AGENTS.md → Commit Guidelines).
5. **Push** to your fork and **open a Pull Request** with a clear description.

## What to Contribute

Look for issues labeled `good first issue`. Areas we need help: documentation, test coverage, bug fixes, roadmap features, sync performance, and UI/UX.

### Reporting Bugs

Open an issue with: a descriptive title, steps to reproduce, expected vs. actual behavior, your environment (Elixir version, OS), and any relevant logs.

### Suggesting Enhancements

Open an issue describing the feature, why it would be useful, and any implementation ideas.

## Code Review Process

A maintainer reviews your PR, may request changes, and merges once approved. Your contribution ships in the next release.

## Community

Be respectful and inclusive. Follow our [Code of Conduct](CODE_OF_CONDUCT.md), help others, and share knowledge.

## Questions?

Open an issue with the `question` label or reach out to the maintainers.

## License

By contributing, you agree that your contributions will be licensed under the MIT License.

Thank you for contributing to Bitblocks! 🚀
