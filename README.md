# bootc-man E2E Test Infrastructure

End-to-end test infrastructure for [bootc-man](https://github.com/tnk4on/bootc-man).

## Test Environments

| Platform | CI System | Method | Infrastructure |
|----------|-----------|--------|----------------|
| Linux (x86_64) | GitHub Actions | EC2 M8i.large + nested virtualization | KVM + QEMU |
| macOS (Apple Silicon) | Cirrus CI | macos_instance | vfkit |

## GitHub Actions: EC2 M8i

Tests nested virtualization (KVM/QEMU) on AWS EC2 M8i instances with bootc-man installed from [COPR](https://copr.fedorainfracloud.org/coprs/tnk4on/bootc-man/).

### Required Secrets

- `AWS_ACCESS_KEY_ID` — IAM user access key
- `AWS_SECRET_ACCESS_KEY` — IAM user secret key

### Usage

```bash
gh workflow run e2e-ec2-m8i.yml
```

## Cirrus CI: macOS

Tests vfkit availability on macOS Apple Silicon with bootc-man installed via [Homebrew](https://github.com/tnk4on/homebrew-bootc-man).

### Setup

1. Install [Cirrus CI GitHub App](https://github.com/marketplace/cirrus-ci)
2. Register billing information (free tier: 50 credits/month for public repos)
3. Grant access to this repository
4. Push triggers the macOS task automatically

## Related

- [bootc-man](https://github.com/tnk4on/bootc-man) — Main repository
