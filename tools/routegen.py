#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import ipaddress
import json
import os
import tempfile
import time
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Any

WORKDIR = Path(os.environ.get("SHPUN_ROUTEGEN_WORKDIR", "/opt/shpun-routegen"))
PUBDIR = Path(os.environ.get("SHPUN_ROUTEGEN_PUBDIR", "/var/www/files/routes"))

LEGACY_CIDR_FILE = PUBDIR / "ru.cidrs"
LEGACY_VERSION_FILE = PUBDIR / "ru.version"
LEGACY_SHA256_FILE = PUBDIR / "ru.sha256"

MANIFEST_FILE = PUBDIR / "manifest.json"
PRESETS_DIR = PUBDIR / "presets"

TMP_DIR = WORKDIR / "tmp"
TMP_DIR.mkdir(parents=True, exist_ok=True)

SOURCES = [
    "https://ftp.ripe.net/pub/stats/ripencc/delegated-ripencc-latest",
    "https://ftp.apnic.net/stats/apnic/delegated-apnic-latest",
    "https://ftp.arin.net/pub/stats/arin/delegated-arin-extended-latest",
    "https://ftp.lacnic.net/stats/lacnic/delegated-lacnic-extended-latest",
    "https://ftp.afrinic.net/stats/afrinic/delegated-afrinic-extended-latest",
]

TARGET_CC = "RU"

PROTECTED_ASN_SOURCE = "https://stat.ripe.net/data/announced-prefixes/data.json?resource=AS{asn}"

# Keep these curated and boring. The router can consume domains in Xray direct
# rules, while cidrs stay available for nft-based direct presets later.
PRESET_DOMAINS: dict[str, list[str]] = {
    "always_vpn": [
        "telegram.org",
        "*.telegram.org",
        "t.me",
        "*.t.me",
        "telegram.me",
        "*.telegram.me",
        "telegram-cdn.org",
        "*.telegram-cdn.org",
        "cdn-telegram.org",
        "*.cdn-telegram.org",
        "telesco.pe",
        "*.telesco.pe",
        "telegra.ph",
        "*.telegra.ph",
        "tdesktop.com",
        "*.tdesktop.com",
        "discord.com",
        "*.discord.com",
        "discord.gg",
        "*.discord.gg",
        "discordapp.com",
        "*.discordapp.com",
        "discordapp.net",
        "*.discordapp.net",
        "discord.media",
        "*.discord.media",
        "discordcdn.com",
        "*.discordcdn.com",
        "signal.org",
        "*.signal.org",
        "signal.me",
        "*.signal.me",
        "signal.art",
        "*.signal.art",
        "whatsapp.com",
        "*.whatsapp.com",
        "whatsapp.net",
        "*.whatsapp.net",
        "wa.me",
        "*.wa.me",
        "viber.com",
        "*.viber.com",
        "viber.co",
        "*.viber.co",
        "viber.me",
        "*.viber.me",
        "facetime.apple.com",
        "*.facetime.apple.com",
        "snapchat.com",
        "*.snapchat.com",
        "sc-cdn.net",
        "*.sc-cdn.net",
    ],
    "ru_core": [
        "gosuslugi.ru",
        "*.gosuslugi.ru",
        "esia.gosuslugi.ru",
        "mos.ru",
        "*.mos.ru",
        "nalog.gov.ru",
        "*.nalog.gov.ru",
        "2gis.ru",
        "*.2gis.ru",
        "drom.ru",
        "*.drom.ru",
    ],
    "ru_banks": [
        "sberbank.ru",
        "*.sberbank.ru",
        "sber.ru",
        "*.sber.ru",
        "online.sberbank.ru",
        "tbank.ru",
        "*.tbank.ru",
        "tinkoff.ru",
        "*.tinkoff.ru",
        "alfabank.ru",
        "*.alfabank.ru",
        "vtb.ru",
        "*.vtb.ru",
        "gazprombank.ru",
        "*.gazprombank.ru",
        "raiffeisen.ru",
        "*.raiffeisen.ru",
        "open.ru",
        "*.open.ru",
        "mkb.ru",
        "*.mkb.ru",
        "rshb.ru",
        "*.rshb.ru",
    ],
    "ru_market": [
        "ozon.ru",
        "*.ozon.ru",
        "wildberries.ru",
        "*.wildberries.ru",
        "wb.ru",
        "*.wb.ru",
        "market.yandex.ru",
        "*.market.yandex.ru",
        "avito.ru",
        "*.avito.ru",
        "megamarket.ru",
        "*.megamarket.ru",
        "lamoda.ru",
        "*.lamoda.ru",
        "detmir.ru",
        "*.detmir.ru",
    ],
    "ru_media": [
        "okko.tv",
        "*.okko.tv",
        "kinopoisk.ru",
        "*.kinopoisk.ru",
        "ivi.ru",
        "*.ivi.ru",
        "wink.ru",
        "*.wink.ru",
        "kion.ru",
        "*.kion.ru",
        "premier.one",
        "*.premier.one",
        "more.tv",
        "*.more.tv",
        "rutube.ru",
        "*.rutube.ru",
    ],
}

PRESET_BUNDLES: dict[str, list[str]] = {
    "smart_ru": ["ru_core", "ru_banks", "ru_market", "ru_media"],
    "smart_ru_min": ["ru_core", "ru_banks", "ru_market"],
}

# Optional static CIDR presets. Start empty: domain rules are safer for the
# planned smart direct mode. These files are still published for future router
# versions that want nft/ipset-based presets.
PRESET_CIDRS: dict[str, list[str]] = {
    "always_vpn": [],
    "ru_core": [],
    "ru_banks": [],
    "ru_market": [],
    "ru_media": [],
    "smart_ru": [],
    "smart_ru_min": [],
}

# Telegram often uses direct MTProto/CDN IPs. Always publish this known
# MTProto baseline, then extend it with current prefixes learned by ASN.
# Partial RIPEstat failures must not remove live DC networks.
ALWAYS_VPN_ASNS = [62041, 44907, 59930, 62014, 211157]
ALWAYS_VPN_FALLBACK_CIDRS = [
    "91.108.4.0/22",
    "91.108.8.0/22",
    "91.108.12.0/22",
    "91.108.16.0/22",
    "91.108.20.0/22",
    "91.108.56.0/22",
    "149.154.160.0/20",
]


@dataclass(frozen=True)
class PublishedFile:
    path: str
    version: int
    sha256: str
    size: int
    lines: int


def fetch_text(url: str) -> str:
    req = urllib.request.Request(
        url,
        headers={"User-Agent": "shpun-routegen/2.0"},
    )
    with urllib.request.urlopen(req, timeout=60) as resp:
        data = resp.read()
    return data.decode("utf-8", errors="replace")


def fetch_json(url: str) -> Any:
    return json.loads(fetch_text(url))


def ip_count_to_prefixes(start_ip: str, count_str: str) -> list[ipaddress.IPv4Network]:
    count = int(count_str)
    start = ipaddress.IPv4Address(start_ip)
    end = ipaddress.IPv4Address(int(start) + count - 1)
    return list(ipaddress.summarize_address_range(start, end))


def parse_delegated_text(text: str, country_code: str) -> list[ipaddress.IPv4Network]:
    result: list[ipaddress.IPv4Network] = []
    cc_upper = country_code.upper()

    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue

        parts = line.split("|")
        if len(parts) < 7:
            continue

        _, cc, rtype, start, value, _, _ = parts[:7]

        if cc.upper() != cc_upper:
            continue
        if rtype != "ipv4":
            continue

        try:
            nets = ip_count_to_prefixes(start, value)
        except Exception:
            continue

        result.extend(nets)

    return result


def collapse_and_sort(networks: list[ipaddress.IPv4Network]) -> list[str]:
    collapsed = list(ipaddress.collapse_addresses(networks))
    collapsed = [n for n in collapsed if isinstance(n, ipaddress.IPv4Network)]
    collapsed.sort(key=lambda n: (int(n.network_address), n.prefixlen))
    return [str(n) for n in collapsed]


def normalize_domains(domains: list[str]) -> list[str]:
    seen: set[str] = set()
    result: list[str] = []

    for raw in domains:
        domain = raw.strip().lower().rstrip(".")
        if not domain or domain.startswith("#"):
            continue
        if any(ch.isspace() for ch in domain):
            continue
        if domain in seen:
            continue
        seen.add(domain)
        result.append(domain)

    return sorted(result)


def normalize_cidrs(cidrs: list[str]) -> list[str]:
    nets: list[ipaddress.IPv4Network] = []

    for raw in cidrs:
        item = raw.strip()
        if not item or item.startswith("#"):
            continue
        try:
            nets.append(ipaddress.IPv4Network(item, strict=False))
        except Exception:
            continue

    return collapse_and_sort(nets)


def fetch_asn_ipv4_prefixes(asn: int) -> list[str]:
    url = PROTECTED_ASN_SOURCE.format(asn=asn)
    data = fetch_json(url)
    prefixes = data.get("data", {}).get("prefixes", [])
    result: list[str] = []

    for item in prefixes:
        prefix = str(item.get("prefix", "")).strip()
        if not prefix:
            continue
        try:
            net = ipaddress.ip_network(prefix, strict=False)
        except Exception:
            continue
        if isinstance(net, ipaddress.IPv4Network):
            result.append(str(net))

    return result


def build_always_vpn_cidrs() -> list[str]:
    # Telegram clients commonly connect to MTProto DC IPs directly, without DNS.
    # Keep the known DC baseline even when one of the dynamic ASN lookups fails.
    cidrs = list(PRESET_CIDRS.get("always_vpn", [])) + ALWAYS_VPN_FALLBACK_CIDRS
    fetched = 0

    for asn in ALWAYS_VPN_ASNS:
        try:
            prefixes = fetch_asn_ipv4_prefixes(asn)
        except Exception as exc:
            print(f"  warning: failed to fetch protected ASN AS{asn}: {exc}")
            continue

        fetched += len(prefixes)
        cidrs.extend(prefixes)
        print(f"  protected ASN AS{asn}: {len(prefixes)} IPv4 prefixes")

    if fetched == 0:
        print("  warning: protected ASN fetch produced no CIDRs, using baseline Telegram CIDRs only")

    return normalize_cidrs(cidrs)


def sha256_text(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def read_version(path: Path) -> int:
    if not path.exists():
        return 0
    try:
        return int(path.read_text(encoding="utf-8").strip())
    except Exception:
        return 0


def atomic_write(path: Path, content: str, mode: int = 0o644) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        "w",
        delete=False,
        dir=str(path.parent),
        encoding="utf-8",
    ) as tmp:
        tmp.write(content)
        tmp.flush()
        os.fsync(tmp.fileno())
        tmp_path = Path(tmp.name)

    os.chmod(tmp_path, mode)
    tmp_path.replace(path)


def publish_versioned_text(path: Path, content: str) -> PublishedFile:
    sha_path = path.with_suffix(path.suffix + ".sha256")
    version_path = path.with_suffix(path.suffix + ".version")

    new_hash = sha256_text(content)
    old_hash = ""
    if sha_path.exists():
        old_hash = sha_path.read_text(encoding="utf-8").strip()

    if new_hash == old_hash and path.exists():
        version = read_version(version_path)
    else:
        version = read_version(version_path) + 1
        atomic_write(path, content, 0o644)
        atomic_write(sha_path, new_hash + "\n", 0o644)
        atomic_write(version_path, f"{version}\n", 0o644)

    return PublishedFile(
        path=str(path.relative_to(PUBDIR)),
        version=version,
        sha256=new_hash,
        size=len(content.encode("utf-8")),
        lines=len([line for line in content.splitlines() if line.strip()]),
    )


def publish_legacy_ru(cidrs: list[str]) -> PublishedFile:
    cidr_text = "\n".join(cidrs) + "\n"
    new_hash = sha256_text(cidr_text)

    old_hash = ""
    if LEGACY_SHA256_FILE.exists():
        old_hash = LEGACY_SHA256_FILE.read_text(encoding="utf-8").strip()

    if new_hash == old_hash and LEGACY_CIDR_FILE.exists():
        version = read_version(LEGACY_VERSION_FILE)
        print("legacy ru.cidrs unchanged")
    else:
        version = read_version(LEGACY_VERSION_FILE) + 1
        atomic_write(LEGACY_CIDR_FILE, cidr_text, 0o644)
        atomic_write(LEGACY_SHA256_FILE, new_hash + "\n", 0o644)
        atomic_write(LEGACY_VERSION_FILE, f"{version}\n", 0o644)
        print(f"published legacy ru.cidrs: {len(cidrs)} CIDRs, version={version}")

    return PublishedFile(
        path=str(LEGACY_CIDR_FILE.relative_to(PUBDIR)),
        version=version,
        sha256=new_hash,
        size=len(cidr_text.encode("utf-8")),
        lines=len(cidrs),
    )


def build_bundle_domains(bundle_name: str) -> list[str]:
    domains: list[str] = []
    for preset_name in PRESET_BUNDLES[bundle_name]:
        domains.extend(PRESET_DOMAINS.get(preset_name, []))
    return normalize_domains(domains)


def build_bundle_cidrs(bundle_name: str) -> list[str]:
    cidrs: list[str] = []
    for preset_name in PRESET_BUNDLES[bundle_name]:
        cidrs.extend(PRESET_CIDRS.get(preset_name, []))
    return normalize_cidrs(cidrs)


def build_preset_cidrs(name: str) -> list[str]:
    if name == "always_vpn":
        return build_always_vpn_cidrs()
    if name in PRESET_BUNDLES:
        return build_bundle_cidrs(name)
    return normalize_cidrs(PRESET_CIDRS.get(name, []))


def publish_presets() -> dict[str, dict[str, PublishedFile]]:
    published: dict[str, dict[str, PublishedFile]] = {}

    all_names = set(PRESET_DOMAINS) | set(PRESET_CIDRS) | set(PRESET_BUNDLES)

    for name in sorted(all_names):
        if name in PRESET_BUNDLES:
            domains = build_bundle_domains(name)
        else:
            domains = normalize_domains(PRESET_DOMAINS.get(name, []))

        cidrs = build_preset_cidrs(name)

        domain_text = "\n".join(domains) + ("\n" if domains else "")
        cidr_text = "\n".join(cidrs) + ("\n" if cidrs else "")

        domain_info = publish_versioned_text(PRESETS_DIR / f"{name}.domains", domain_text)
        cidr_info = publish_versioned_text(PRESETS_DIR / f"{name}.cidrs", cidr_text)

        published[name] = {
            "domains": domain_info,
            "cidrs": cidr_info,
        }

        print(
            f"published preset {name}: "
            f"{domain_info.lines} domains, {cidr_info.lines} CIDRs"
        )

    return published


def write_manifest(legacy_ru: PublishedFile, presets: dict[str, dict[str, PublishedFile]]) -> None:
    manifest = {
        "schema": 1,
        "generated_at": int(time.time()),
        "legacy": {
            "ru": legacy_ru.__dict__,
        },
        "presets": {
            name: {
                kind: info.__dict__
                for kind, info in preset_files.items()
            }
            for name, preset_files in sorted(presets.items())
        },
        "recommended_modes": {
            "full": {
                "description": "All traffic through VPN, only custom direct bypasses it.",
            },
            "smart_ru": {
                "description": "All traffic through VPN, core Russian services direct.",
                "domains": presets["smart_ru"]["domains"].path,
                "cidrs": presets["smart_ru"]["cidrs"].path,
            },
            "smart_ru_min": {
                "description": "All traffic through VPN, banks/marketplaces/government direct.",
                "domains": presets["smart_ru_min"]["domains"].path,
                "cidrs": presets["smart_ru_min"]["cidrs"].path,
            },
            "split_ru": {
                "description": "Heavy mode: Russian TCP destinations direct; realtime UDP stays inside VPN.",
                "cidrs": legacy_ru.path,
            },
        },
        "protected": {
            "always_vpn": {
                "description": "Domains and IPv4 ranges that must stay inside VPN before any direct routing preset.",
                "domains": presets["always_vpn"]["domains"].path,
                "cidrs": presets["always_vpn"]["cidrs"].path,
            },
        },
    }

    content = json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    atomic_write(MANIFEST_FILE, content, 0o644)
    print(f"published manifest: {MANIFEST_FILE}")


def main() -> int:
    all_networks: list[ipaddress.IPv4Network] = []
    failed_sources: list[str] = []

    for url in SOURCES:
        print(f"fetching {url}")
        try:
            text = fetch_text(url)
        except Exception as exc:
            failed_sources.append(url)
            print(f"  warning: failed to fetch source: {exc}")
            continue

        nets = parse_delegated_text(text, TARGET_CC)
        print(f"  found {len(nets)} raw RU ipv4 blocks")
        all_networks.extend(nets)

    cidrs = collapse_and_sort(all_networks)
    if not cidrs:
        failed = ", ".join(failed_sources) if failed_sources else "none"
        raise SystemExit(f"no RU IPv4 CIDRs produced; failed_sources={failed}")

    if failed_sources:
        print(f"warning: {len(failed_sources)} source(s) failed, continuing with collected RU CIDRs")

    legacy_ru = publish_legacy_ru(cidrs)
    presets = publish_presets()
    write_manifest(legacy_ru, presets)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
