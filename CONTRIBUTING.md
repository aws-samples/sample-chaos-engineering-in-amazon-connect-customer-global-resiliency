# Contributing Guidelines

Thank you for your interest in contributing to our project. Whether it's a bug report, new feature, correction, or additional
documentation, we greatly value feedback and contributions from our community.

Please read through this document before submitting any issues or pull requests to ensure we have all the necessary
information to effectively respond to your bug report or contribution.

## Reporting Bugs/Feature Requests

We welcome you to use the GitHub issue tracker to report bugs or suggest features.

When filing an issue, please check existing open, or recently closed, issues to make sure somebody else hasn't already
reported the issue. Please try to include as much information as you can.

## Contributing via Pull Requests

Contributions via pull requests are much appreciated. Before sending us a pull request, please ensure that:

1. You are working against the latest source on the *main* branch.
2. You check existing open, and recently merged, pull requests to make sure someone else hasn't addressed the problem already.
3. You open an issue to discuss any significant work - we would hate for your time to be wasted.

To send us a pull request, please:

1. Fork the repository.
2. Modify the source; please focus on the specific change you are contributing.
3. Run `make lint` and make sure it passes. There is no CI in this repository, so this is the check.
4. Commit to your fork using clear commit messages.
5. Send us a pull request, answering any default questions in the pull request interface.
6. Stay involved in the conversation on your pull request.

GitHub provides additional document on [forking a repository](https://help.github.com/articles/fork-a-repo/) and
[creating a pull request](https://help.github.com/articles/creating-a-pull-request/).

## Before you commit

`make lint` runs `scripts/scan-secrets.py`, which fails on AWS access keys, private keys,
credential assignments, and any identifier tied to one deployment: account IDs, phone numbers,
Connect instance / TDG / flow / queue / contact UUIDs, VPC and subnet IDs, FIS experiment
template IDs, and Lex bot or alias IDs.

Every check is a **pattern**, never a denylist of known values, because a denylist would have to
contain the very values it exists to keep out. Add a value to `ALLOWED_LITERALS` only if it is
genuinely public, or append `scan-secrets: allow` to a single line.

Scan only what is about to be committed, rather than the whole tree, with:

```bash
python3 scripts/scan-secrets.py --staged
```

There is no CI in this repository; validation is local. The `cfn-lint` warning `W1030` is expected,
because the `ReplicatedLexBot*` parameters are intentionally empty in source-Region deploys.

## Finding contributions to work on

Looking at the existing issues is a great way to find something to contribute on.

## Code of Conduct

This project has adopted the [Amazon Open Source Code of Conduct](https://aws.github.io/code-of-conduct).
For more information see the [Code of Conduct FAQ](https://aws.github.io/code-of-conduct-faq) or contact
opensource-codeofconduct@amazon.com with any additional questions or comments.

## Security issue notifications

If you discover a potential security issue in this project we ask that you notify AWS/Amazon Security via our [vulnerability reporting page](http://aws.amazon.com/security/vulnerability-reporting/). Please do **not** create a public GitHub issue.

## Licensing

See the [LICENSE](LICENSE) file for our project's licensing. We will ask you to confirm the licensing of your contribution.
