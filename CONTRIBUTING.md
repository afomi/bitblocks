# Contributing to Bitblocks

Thank you for your interest in contributing to Bitblocks! We welcome contributions from the community.

## Getting Started

1. **Fork the repository** on GitHub
2. **Clone your fork** locally:
   ```bash
   git clone https://github.com/YOUR_USERNAME/bitblocks.git
   cd bitblocks
   ```
3. **Set up your development environment** following the instructions in [README.md](README.md)

## Development Workflow

1. **Create a new branch** for your feature or bugfix:
   ```bash
   git checkout -b feature/your-feature-name
   ```
   or
   ```bash
   git checkout -b fix/your-bugfix-name
   ```

2. **Make your changes** following our coding standards (see below)

3. **Test your changes**:
   ```bash
   mix test
   ```

4. **Commit your changes** with clear, descriptive commit messages:
   ```bash
   git commit -m "Add feature: description of what you added"
   ```

5. **Push to your fork**:
   ```bash
   git push origin feature/your-feature-name
   ```

6. **Open a Pull Request** on GitHub with a clear description of your changes

## Coding Standards

### Elixir Style

- Follow the [Elixir Style Guide](https://github.com/christopheradams/elixir_style_guide)
- Use `mix format` to format your code before committing
- Write clear, descriptive function names and module documentation
- Add `@doc` and `@spec` annotations for public functions

### Code Quality

- Write tests for new features and bug fixes
- Ensure all tests pass before submitting a PR
- Keep functions small and focused on a single responsibility
- Add comments for complex logic

### Commits

- Write clear, concise commit messages
- Use present tense ("Add feature" not "Added feature")
- Reference issue numbers when applicable (e.g., "Fix #123: Handle timeout errors")

## What to Contribute

### Good First Issues

Look for issues labeled `good first issue` - these are great for newcomers!

### Areas We Need Help

- **Documentation**: Improve or expand documentation
- **Testing**: Add test coverage for existing features
- **Bug Fixes**: Fix open issues
- **Features**: Implement features from the roadmap
- **Performance**: Optimize sync performance
- **UI/UX**: Improve the web interface

### Reporting Bugs

If you find a bug, please open an issue with:

- A clear, descriptive title
- Steps to reproduce the bug
- Expected behavior
- Actual behavior
- Your environment (Elixir version, OS, etc.)
- Any relevant error messages or logs

### Suggesting Enhancements

We welcome feature suggestions! Please open an issue with:

- A clear description of the feature
- Why this feature would be useful
- Any implementation ideas you have

## Code Review Process

1. A maintainer will review your PR
2. They may request changes or ask questions
3. Once approved, a maintainer will merge your PR
4. Your contribution will be included in the next release!

## Community

- Be respectful and inclusive
- Follow our [Code of Conduct](CODE_OF_CONDUCT.md)
- Help others in discussions and issues
- Share knowledge and learn together

## Questions?

If you have questions about contributing, feel free to:

- Open an issue with the `question` label
- Reach out to the maintainers
- Check existing issues and discussions

## License

By contributing to Bitblocks, you agree that your contributions will be licensed under the MIT License.

Thank you for contributing to Bitblocks! 🚀
