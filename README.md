# bootc-man E2E Test Infrastructure

[![E2E Test (EC2 M8i)](https://github.com/tnk4on/bootc-man-e2e-test/actions/workflows/e2e-ec2-m8i.yml/badge.svg)](https://github.com/tnk4on/bootc-man-e2e-test/actions/workflows/e2e-ec2-m8i.yml)
[![Cirrus CI](https://api.cirrus-ci.com/github/tnk4on/bootc-man-e2e-test.svg)](https://cirrus-ci.com/github/tnk4on/bootc-man-e2e-test)

End-to-end test infrastructure for [bootc-man](https://github.com/tnk4on/bootc-man).

## Test Environments

| Platform | CI System | Method | Hypervisor |
|----------|-----------|--------|------------|
| Linux (x86_64) | [GitHub Actions](https://github.com/tnk4on/bootc-man-e2e-test/actions) | EC2 M8i + nested virtualization | KVM + QEMU |
| macOS (Apple Silicon) | [Cirrus CI](https://cirrus-ci.com/github/tnk4on/bootc-man-e2e-test) | macos_instance | vfkit |

## How It Works

Both CI systems:
1. Clone [bootc-man](https://github.com/tnk4on/bootc-man) source
2. Build from source (`make build`)
3. Run E2E tests in 4 phases:
   - **Phase 1**: Non-VM tests (container, registry, CI pipeline)
   - **Phase 2**: VM boot tests (build → convert → boot → SSH)
   - **Phase 3**: Bootc tests (status, upgrade, switch, rollback)
   - **Phase 4**: VM cleanup

## GitHub Actions: EC2 M8i

### Required Secrets

- `AWS_ACCESS_KEY_ID` — IAM user access key
- `AWS_SECRET_ACCESS_KEY` — IAM user secret key

### Usage

```bash
# Run with defaults (m8i.large, us-east-1, main branch)
gh workflow run e2e-ec2-m8i.yml

# Run with specific bootc-man branch
gh workflow run e2e-ec2-m8i.yml -f bootc_man_ref=develop
```

## Cirrus CI: macOS

### Setup

1. Install [Cirrus CI GitHub App](https://github.com/marketplace/cirrus-ci)
2. Register billing information (free tier: 50 credits/month for public repos)
3. Grant access to this repository
4. Push triggers the macOS task automatically

### Cirrus CI Dashboard

- [Build History](https://cirrus-ci.com/github/tnk4on/bootc-man-e2e-test)

## Related

- [bootc-man](https://github.com/tnk4on/bootc-man) — Main repository
