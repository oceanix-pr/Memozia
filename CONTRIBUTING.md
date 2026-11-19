# Contributing to Memozia

Thanks for helping improve Memozia. Useful contributions include clearer setup instructions, translation corrections, reproducible bug reports, accessibility improvements, and focused fixes.

## Start with a small, concrete change

Check [existing issues](https://github.com/oceanix-pr/Memozia/issues) before opening a new one. For a larger change, describe the user problem and proposed behavior in an issue first. For an existing issue, leave a short note about the approach before starting substantial work.

Good first contributions include:

- Follow the preview installation guide on a clean setup and identify a specific missing step.
- Check one translated screen against its English or Chinese source; include the string key, locale, and suggested wording.
- Improve keyboard navigation or an accessibility label on one screen, with steps to reproduce the issue.
- Add a short, fictional recording or text example that makes a reported problem reproducible.

Email bug reports and feature requests to [oceanix-pr@outlook.com](mailto:oceanix-pr@outlook.com). For public reports and documentation or translation feedback, use the [issue forms](https://github.com/oceanix-pr/Memozia/issues/new/choose).

## Development

Read [Build from source](docs/BUILDING.md) before making a code change. The project targets macOS only. Keep changes scoped to the reported problem and preserve surrounding behavior.

1. Create a branch for the change.
2. Update source, localized strings, and directly affected documentation together.
3. Run the checks appropriate to the change.
4. Explain the problem, the resulting behavior, and the checks you ran in the pull request.

User-facing text belongs in `Localizable.xcstrings`. Keep placeholder types consistent across languages. Translation work should improve meaning and fit the actual screen; a populated catalog alone does not establish language or layout quality.

For recording, persistence, or recovery changes, include the relevant runtime observations as well as test results. Avoid unmeasured performance claims. Keep required framework-verification build phases enabled.

## Safe examples and reports

Use synthetic meeting content. Do not publish private recordings, transcripts, screenshots, API keys, access tokens, Keychain data, or unredacted diagnostic bundles. Include the app version, macOS version, hardware family, chosen processing mode, and concise reproduction steps instead.

Report security-sensitive issues using [SECURITY.md](SECURITY.md), rather than a public issue.

## Pull request checklist

- The title names the concrete change.
- The description explains what a reviewer can reproduce and what changes for the user.
- Checks and manual verification are listed accurately, including relevant gaps.
- Documentation and screenshots match the implementation.
- Sample content is fictional and the diff contains no credentials.

AI assistance is welcome when the contributor reviews the result, verifies technical claims, and takes responsibility for the submitted change. Disclose substantial assistance when it helps reviewers understand how the contribution was prepared.

## License

Contributions are provided under the repository's [MIT License](LICENSE). Third-party code and assets must retain their own notices and licenses.
