# XHTTP and subscription notice release validation

Release candidates: OpenWrt24 1.1.15-r1; OpenWrt25 2.0.10-r1. Build and artifact provenance go through GitHub Actions. A green source test is not a published release; inspect the matching commit artifact and test the actual package before updating OTA metadata.

## Transport and routing

VLESS TCP/REALITY, Hysteria2 and VLESS XHTTP coexist. XHTTP has its own UI group and supports TLS/REALITY configuration, IPv4/IPv6 endpoint parsing, host/SNI separation, encoded parameters, modes and publisher extra. Invalid, insecure or unsupported options are rejected before replacing a working configuration. The actual core validates XHTTP and Hysteria candidates on manual selection.

Endpoint-only tagged DNS bootstrap prevents a tunnel hostname from depending on its own tunnel. It does not change ordinary LAN DNS policy or pin a server IP. All full/smart_ru/split_ru contracts remain. Smart merges the built-in41-root VK baseline with the downloaded feed for both direct domain rules and DNS/nftset mapping.

Actual ARM64 lab and client main-VPN pilots passed all three routing modes: each18HTTPS,9UDP-DNS,3VKcontrols and12STUN exchanges. The first client fixture accidentally used an already leased DHCP address; those failed DNS samples are invalid acceptance evidence. The corrected fixture uses an unused address outside the DHCP pool and passes. Fixture addresses and subscription indices must be discovered per router; never copy numeric indices across feeds.

Acceptance: European/international controls use the tunnel; configured Russian services bypass it in Smart/RF-direct mode. A Russian service rejecting a foreign exit IP is not by itself a transport failure or a reason to weaken full-tunnel routing. Private media playback, all physical architectures, H3, every CDN and indefinite endurance are not implied by these controls.

## Expiry notice

The independent observer reads Date and subscription-userinfo expire through bounded HTTPS HEAD requests, every300seconds. URLs stay in stdin; private headers and cookies are removed from RAM after parsing. Only expiry/status/timestamps remain. Invalid/duplicate/old responses, clock mismatch and transport errors yield unknown, not a fabricated expired status. Confirmed extension clears the notice automatically.

Authenticated LuCI shows the expiry badge and renewal links. It preserves router binding and does not mutate routing, DNS, server selection or VPN lifecycle. No captive-network interception, HTTP redirection, DHCP114 announcement or forced phone popup is enabled in this release. Such notification is a separate opt-in network behavior.

Both routers passed actual observer/RPC pilots; synthetic expiry, renewal and stale-cache behavior plus18metadata cases and10shell integration scenarios are covered. ucode function declaration order is guarded because forward lexical references differ from JavaScript. Managed OTA defers the observer until package replacement completes; the auto-update service also starts it for the first upgrade from an older running updater.

## Reproduction

- node deploy/test-subscription-notice.cjs
- node deploy/test-server-modal.cjs
- node deploy/test-network-modal.cjs (OpenWrt25)
- sh deploy/test-subscription-notice.sh (isolated OpenWrt transport fixtures)
- sh deploy/test-smart-vk-media.sh
- sh deploy/test-subscription-migration.sh
- sh deploy/test-subscription-unavailable.sh
- sh deploy/test-hysteria2-control.sh
- sh deploy/test-failover-protection.sh (runtime paths rewritten to the private fixture)
- node deploy/test-xhttp-fixtures.cjs prepare DIRECTORY; run its generated test.sh only in an owned /tmp/shpun-xhttp-* stage; retrieve results; then verify DIRECTORY.

The validated UDP reply-close core patch and hermetic tests live in deploy/xray. The dedicated pinned GitHub workflow builds its five architecture artifacts from exact Xray45cf289 and Go1.26.4. Building these artifacts does not automatically replace running cores. Core installation requires its own checksum/architecture/rollback checks; retain known-good backups.
