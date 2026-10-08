# Hysteria 2 acceptance and rollout

Keep Reality available. A working Reality selection is not migrated automatically.
When Hysteria is selected and Auto is enabled, failure recovery tries other Hysteria
nodes first, then permitted Reality nodes. Manual selection disables Auto.
The RU exclusion toggle excludes RF gateways, not every Russian exit node.

## Repeatable checks

1. Run `node deploy/test-server-modal.cjs` (also run by CI).
2. Copy the repository's package and deploy directories to a private temporary
   directory on each supported OpenWrt version. Run `sh deploy/test-hysteria2-control.sh`.
   This test never reads credentials or touches live services/configuration.
3. Run the config-generation fixtures with the router's actual Xray engine.
   The real-engine control test covers the `.validate.<PID>.json` switch path;
   an engine lacking Hysteria support must keep the working Reality config.
4. Build IPK/APK with the official SDK and verify the complete payload, permissions,
   declared dependencies, release number and versioned LuCI module.

## Canary gates (not replaceable by mock or loopback tests)

- Save a private router-state archive and a SHA256-verified previous package.
- Simulate installation first: no unrelated dependencies may be changed.
- Verify package upgrade, agent/config/Auto/selection preservation, real RPC manual
  selection, subscription normalization, Hysteria HTTPS and DNS proxy requests.
- Package replacement can stop old services in pre-deinstall. Always restore/start
  the agent if a post-install acceptance assertion fails; never leave the router
  stopped merely because a test fails.
- APK preserves edited `/etc` files as `.apk-new`. Do not blindly overwrite local
  modifications. Compare every retained critical runtime script and classify it.
  An unchanged known local routing-script edit is not permission to accept unknown
  differences in Hysteria builder, switch, agent or failover scripts.
- Exercise downgrade/restoration, verify actual traffic, then reinstall the accepted
  candidate. Restore the original server and Auto setting after bounded tests.
- Verify real LAN TCP redirect, UDP TProxy, DNS and an extended voice/game session
  from the RF client router. ICMP, process liveness, loopback proxy requests and
  growing packet counters alone do not prove end-user application connectivity.
- Check the installed LuCI widget on wide and narrow screens. Headless source
  fixtures are useful, but are not installed-widget acceptance.

## Promotion

Do not publish the fleet OTA manifest/billing metadata until all gates pass.
Use separate OpenWrt 24/25 artifacts and cohort release steps. Verify published
bytes against the accepted local SHA256 before atomic guarded metadata updates.
Record version/hash/URL, backup and rollback commands, pre/post RPC state, observed
traffic and any accepted local modifications. Keep credentials/config archives
private on the router; never include subscription URIs in release logs.
