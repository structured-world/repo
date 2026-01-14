# SW Foundation Package Repository

Package repositories for Structured World Foundation software.

## Available Packages

| Package | Description |
|---------|-------------|
| `libstrongswan-pgsql` | PostgreSQL database backend for strongSwan |

## Ubuntu / Debian

```bash
# Add GPG key
curl -fsSL https://repo.sw.foundation/keys/sw.gpg | sudo gpg --dearmor -o /etc/apt/keyrings/sw.gpg

# Add repository
echo "deb [signed-by=/etc/apt/keyrings/sw.gpg] https://repo.sw.foundation/deb $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/sw.list

# Install
sudo apt update
sudo apt install libstrongswan-pgsql
```

Supported: Ubuntu 22.04 (jammy), Ubuntu 24.04 (noble)

## Fedora

```bash
# Add repository
sudo dnf config-manager --add-repo https://repo.sw.foundation/rpm/fc$(rpm -E %fedora)/sw.repo

# Install
sudo dnf install strongswan-pgsql
```

Supported: Fedora 40, Fedora 41, Fedora 42

## GPG Key

Key ID: `A187D55B5A043632`
Fingerprint: `4AC4 06DA 15C9 BE4D C1A0 2343 A187 D55B 5A04 3632`
Algorithm: Ed25519

```bash
# Import manually
curl -fsSL https://repo.sw.foundation/keys/sw.gpg | gpg --import
```

## Links

- [strongSwan fork](https://github.com/structured-world/strongswan)
- [SW Foundation](https://sw.foundation)

## Maintainer

Dmitry Prudnikov <mail@polaz.com>
