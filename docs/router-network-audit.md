# Router networking audit and WAN roadmap

Date: 2026-09-27

## Current findings

The current firmware is a voucher captive-portal gateway, not yet a general-purpose router UI. The current admin **Network** tab only saves shop/SSID/channel/client-limit settings (`rns-http.sh` `/api/admin/settings`). There are no WAN interface, DHCP/static/PPPoE, gateway, DNS, health-check, route-policy, LAN-port, VLAN, or WAN load-balancing controls.

`etc/init.d/S20network` currently:

- discovers non-Wi-Fi interfaces, sorts their names alphabetically, and assumes the first is the only WAN and the second is the only LAN;
- bridges only that one LAN interface, assigns the LAN address, and starts DHCP client (`udhcpc`) on that one WAN;
- writes the chosen names to `/data/rns/{wan,lan,br}.if`, but this selection is not a user-managed multi-WAN configuration;
- has no WAN health probes, failover policy, connection marks, or multi-uplink NAT policy.

`bin/net.sh`'s `wan_if()` resolves one configured `WAN_IF` or the first default-route interface. Its masquerade rule is a single-interface rule; that does not implement resilient multi-WAN. Thus adding multiple interfaces does not safely make this a load-balanced router. The current name-sorting heuristic can also choose unintended roles when hardware/interface naming differs.

## Design direction

Build this as staged, testable router functionality rather than adding UI controls that do not affect the running network:

1. **Interface inventory and explicit roles:** display detected interfaces, link state, address, and current role. Require explicit WAN/LAN selection (with a first-boot safe default and console recovery). Never silently reassign a port based only on alphabetical ordering once config exists.
2. **WAN profiles:** support DHCP first, then static IPv4; show lease/gateway/DNS/link state. Keep PPPoE as a separate later feature because it needs package/config and credential handling. Validate all input and preserve the last-known-good configuration on failure.
3. **Failover:** allow ordered WANs and link/Internet health checks; use per-WAN NAT and deterministic primary/backup routing. Probe beyond the local Ethernet link (with configurable targets and timeouts) so a connected modem with dead upstream is detected. Keep router-originated traffic and established connections consistent with the selected uplink.
4. **Load balancing:** offer explicit modes: failover (recommended default) and per-connection balancing. Use connection-level classification/sticky routing, not per-packet splitting, because independent WANs have different public addresses and NAT state. Make weights and health withdrawal explicit; when one uplink fails, stop assigning new flows to it and allow existing flows to expire/reconnect. Clearly explain that balancing combines flows across users/connections, not the bandwidth of one single TCP download.
5. **Safe application / observability:** apply with a rollback timer or saved last-known-good config; expose per-WAN status, selected default route, probe result, bytes/packets, and active policy. Keep LAN/captive portal reachable during WAN reconfiguration. Add shell-level tests using stubbed `ip`, `iptables`, and probe commands before enabling changes in production.

MikroTik RouterOS documentation provides useful design patterns, not code to copy: WAN failover with route priority and gateway checking, and PCC (Per Connection Classifier) for per-connection rather than per-packet distribution. This project's BusyBox/Linux networking stack, Buildroot packages, firewall implementation, and configuration model differ, so the actual Linux implementation must be independently tested.

References:

- MikroTik, [Load Balancing](https://help.mikrotik.com/docs/spaces/ROS/pages/4390920/Load+Balancing): differentiates per-connection and per-packet balancing; discusses failover.
- MikroTik, [Per connection classifier](https://help.mikrotik.com/docs/spaces/ROS/pages/152600617/Per+Connection+Classifier): PCC hashing and policy-routing concepts.
- MikroTik, [Failover (WAN Backup)](https://help.mikrotik.com/docs/exportword?pageId=26476608): route health-check and recursive failover concepts.

## Verification baseline

`sh rns-router/tests/run-tests.sh` passed on 2026-09-27 (115 passed, 0 failed). Existing tests validate captive portal/firewall behaviors, not multi-WAN routing. Multi-WAN should not be called implemented until its own tests and a VM/hardware failure test are added.

## Topology needed before implementation

Confirm the intended physical port layout and policy: which interface(s) are WAN, which port(s) should be LAN (one port vs a bridged switch), whether WANs use DHCP or static addressing, and whether multiple WAN should default to failover or weighted per-connection balancing. PPPoE, VLAN-tagged ISP, IPv6, and LTE modems should be treated as explicit requirements rather than assumed support.
