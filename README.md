# SW Foundation Package Repository

Package repositories for Structured World Foundation software.

## Available Packages

| Package | Description | Documentation |
|---------|-------------|---------------|
| `libstrongswan-pgsql` (DEB) / `strongswan-pgsql` (RPM) | PostgreSQL database backend for strongSwan | [Guide](docs/pgsql-plugin.md) |

## Quick Install

### Ubuntu / Debian

```bash
# Add GPG key
curl -fsSL https://repo.sw.foundation/keys/sw.gpg | sudo gpg --dearmor -o /etc/apt/keyrings/sw.gpg

# Add repository
echo "deb [signed-by=/etc/apt/keyrings/sw.gpg] https://repo.sw.foundation/deb $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/sw.list

# Install
sudo apt update
sudo apt install libstrongswan-pgsql
```

**Supported:** Ubuntu 22.04 (jammy), Ubuntu 24.04 (noble)

### Fedora

```bash
# Add repository
sudo dnf config-manager --add-repo https://repo.sw.foundation/rpm/fc$(rpm -E %fedora)/sw.repo

# Install
sudo dnf install strongswan-pgsql
```

**Supported:** Fedora 40, 41, 42

## After Installation

### Configure PostgreSQL Plugin

1. Enable the plugin in `/etc/strongswan.d/charon/pgsql.conf`:
   ```
   pgsql {
       load = yes
   }
   ```

2. Configure database connection in `/etc/strongswan.d/charon/sql.conf`:
   ```
   sql {
       load = yes
       database = postgresql://user:password@localhost/strongswan
   }
   ```

3. Restart strongSwan:
   ```bash
   sudo systemctl restart strongswan
   ```

See [full documentation](docs/pgsql-plugin.md) for database setup and advanced configuration.

## GPG Key

All packages are signed with our GPG key.

| Property | Value |
|----------|-------|
| Key ID | `A187D55B5A043632` |
| Fingerprint | `4AC4 06DA 15C9 BE4D C1A0 2343 A187 D55B 5A04 3632` |
| Algorithm | Ed25519 |

```bash
# Import manually
curl -fsSL https://repo.sw.foundation/keys/sw.gpg | gpg --import
```

## Links

- [strongSwan fork](https://github.com/structured-world/strongswan) - Source code with pgsql plugin
- [SW Foundation](https://sw.foundation)

## Maintainer

Dmitry Prudnikov <mail@polaz.com>
