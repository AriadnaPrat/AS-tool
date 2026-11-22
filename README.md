# Post-Quantum TLS — hybrid PQC key exchange with OpenSSL

![AI-assisted](https://img.shields.io/badge/AI--assisted-Claude-8A63D2)

> **AI usage:** The tool selection, test-case design, test environment and analysis of the results are my own work. I used an AI assistant (Claude, by Anthropic) for a first draft of the `test_pqc_tls.sh` script and of the presentation slides, and for help with the wording of this README. I reviewed, debugged and adapted all of it. All the results and performance figures come from my own runs of the script with OpenSSL 3.5.5.

## 1. Identification & selection

**Tool:** OpenSSL ≥ **3.5** (library + `openssl` CLI, Apache 2.0 license) — https://github.com/openssl/openssl

**What it provides:** since 3.5 it ships **ML-KEM** (FIPS 203) and **ML-DSA** (FIPS 204) natively, plus the **hybrid groups** for TLS 1.3, which combine a classical key exchange with a post-quantum one. The session stays secure as long as *either* of the two is unbroken, which protects against *harvest-now, decrypt-later* attacks.

| TLS group | Combination | NIST level | Codepoint |
|---|---|---|---|
| **X25519MLKEM768** | X25519 + ML-KEM-768 | 3 | `0x11EC` |
| SecP256r1MLKEM768 | P-256 + ML-KEM-768 | 3 | `0x11EB` |
| SecP384r1MLKEM1024 | P-384 + ML-KEM-1024 | 5 | `0x11ED` |

**Why OpenSSL and `X25519MLKEM768`:**
- OpenSSL is the most widely used TLS library (nginx, Apache, curl, Python…).
- It needs no external plugins; before 3.5 you needed `oqs-provider`.
- `X25519MLKEM768` is the **default** group in OpenSSL 3.5, and the one Chrome, Firefox and Cloudflare already use.

## 2. Installation

```bash
sudo apt update && sudo apt install -y build-essential perl wget && \
cd /tmp && \
wget -q https://github.com/openssl/openssl/releases/download/openssl-3.5.4/openssl-3.5.4.tar.gz && \
tar xzf openssl-3.5.4.tar.gz && cd openssl-3.5.4 && \
./Configure --prefix=/opt/openssl-3.5 --openssldir=/opt/openssl-3.5/ssl \
  -Wl,-rpath,/opt/openssl-3.5/lib64 && \
make -j$(nproc) && sudo make install_sw && \
sudo ln -sf /opt/openssl-3.5/bin/openssl /usr/local/bin/openssl && \
hash -r && openssl version
```

On Windows, **Git for Windows** already bundles OpenSSL 3.5. The demo was run with 3.5.5 in Git Bash.

Check:

```bash
openssl version                          # OpenSSL 3.5.x
openssl list -tls-groups -tls1_3         # ... X25519MLKEM768:SecP384r1MLKEM1024 ...
```

## 3. Integration

No code is needed: you only pick the group on the server and on the client.

```bash
export OPENSSL_CONF=/etc/ssl/openssl.cnf
# Test certificate (ECDSA; a post-quantum one also works: -newkey mldsa65)
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
  -keyout ec.key -out ec.crt -days 365 -subj "/CN=localhost"

# TLS 1.3 server and client using the hybrid group
openssl s_server -accept 4433 -cert ec.crt -key ec.key -tls1_3 -groups X25519MLKEM768 -www
openssl s_client -connect localhost:4433 -tls1_3 -groups X25519MLKEM768
#   -> Negotiated TLS1.3 group: X25519MLKEM768
```

Real applications are configured the same way: nginx `ssl_ecdh_curve X25519MLKEM768:X25519;`, or `Groups = X25519MLKEM768:X25519` in `openssl.cnf`.

## 4. Test: use cases & data

The [test_pqc_tls.sh](test_pqc_tls.sh) script generates the certificates, runs the test cases and saves `results.csv`:

```bash
./test_pqc_tls.sh            # use cases
./test_pqc_tls.sh --bench    # + performance
```

### Use cases (actual results, OpenSSL 3.5.5)

| ID | Case | Server | Client | Negotiated group | ClientHello | key_share C / S | Result |
|---|---|---|---|---|---|---|---|
| TC-01 | Main hybrid | X25519MLKEM768 | X25519MLKEM768 | X25519MLKEM768 | 1391 B | 1216 / 1120 B | ✅ |
| TC-02 | Hybrid, NIST curve | SecP256r1MLKEM768 | same | SecP256r1MLKEM768 | 1424 B | 1249 / 1153 B | ✅ |
| TC-03 | Hybrid, level 5 | SecP384r1MLKEM1024 | same | SecP384r1MLKEM1024 | 1840 B | 1665 / 1665 B | ✅ |
| TC-04 | Classical (baseline) | X25519 | X25519 | X25519 | 215 B | 32 / 32 B | ✅ |
| TC-05 | Fallback to classical | X25519MLKEM768:X25519 | X25519 | X25519 | 215 B | 32 / 32 B | ✅ |
| TC-06 | HelloRetryRequest | X25519MLKEM768 | X25519:X25519MLKEM768 | X25519MLKEM768 (2 ClientHellos) | 1401 B | 1216 / 1120 B | ✅ |
| TC-07 | No common group | X25519MLKEM768 | X25519 | — (*handshake failure* alert) | 215 B | 32 / — | ✅ expected failure |
| TC-08 | Full PQC (ML-DSA-65 cert) | X25519MLKEM768 | X25519MLKEM768 | X25519MLKEM768, `mldsa65` signature | 1391 B | 1216 / 1120 B | ✅ |

### Performance (`--bench`, laptop, Windows 11)

| Group | keygen/s | encaps/s | decaps/s | Handshakes/s (`s_time`) |
|---|---|---|---|---|
| X25519 | ~48,000 | ~7,700 | ~11,400 | ~1,990 |
| X25519MLKEM768 | ~8,500 | ~5,900 | ~6,500 | ~1,970 |
| SecP256r1MLKEM768 | ~9,200 | ~4,700 | ~5,000 | ~2,000 |
| SecP384r1MLKEM1024 | ~650 | ~430 | ~730 | ~395 |

### Conclusions

- **Works out of the box:** OpenSSL 3.5 negotiates all three hybrid groups without plugins, and falls back to X25519 when the peer doesn't support them.
- **Size cost:** the ClientHello grows from 215 B to ~1.4 KB (6.5×); at level 5 it reaches 1.8 KB.
- **Time cost:** with `X25519MLKEM768`, handshakes per second are practically the same as with X25519. Only `SecP384r1MLKEM1024` is noticeably slower (~5×), because of the P-384 curve.

License: see [LICENSE](LICENSE).
